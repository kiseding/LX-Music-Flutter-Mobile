import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/audio/audio_handler.dart';
import '../../../core/storage/storage_service.dart';

// 音质选择
enum AudioQualityOption {
  low, // 128kbps
  high, // 320kbps
  lossless, // FLAC
  lossless24, // FLAC 24bit（臻品母带）
  hires, // Hi-Res
}

/// 持久化设置 Provider
/// 使用 StorageService（SharedPreferences）存储，重启后保留

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((
  ref,
) {
  return ThemeModeNotifier();
});

final audioQualityProvider =
    StateNotifierProvider<AudioQualityNotifier, AudioQualityOption>((ref) {
  return AudioQualityNotifier();
});

final downloadQualityProvider =
    StateNotifierProvider<DownloadQualityNotifier, AudioQualityOption>((ref) {
  return DownloadQualityNotifier();
});

final wifiOnlyDownloadProvider =
    StateNotifierProvider<WifiOnlyDownloadNotifier, bool>((ref) {
  return WifiOnlyDownloadNotifier();
});

final autoResumePlaybackProvider =
    StateNotifierProvider<AutoResumePlaybackNotifier, bool>((ref) {
  return AutoResumePlaybackNotifier();
});

/// 默认搜索平台：tx / kw / wy
final defaultSearchPlatformProvider =
    StateNotifierProvider<DefaultSearchPlatformNotifier, String>((ref) {
  return DefaultSearchPlatformNotifier();
});

// ---- Notifiers ----

abstract class _PersistedSettingNotifier<T> extends StateNotifier<T> {
  _PersistedSettingNotifier(T initialState, {StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(initialState);

  final StorageLoader _storage;
  int _generation = 0;
  Future<void> _writeTail = Future.value();

  Future<void> _load(T? Function(StorageService storage) read) async {
    final generation = _generation;
    try {
      final value = read(await _storage());
      if (generation == _generation && value != null) state = value;
    } catch (_) {
      // A failed load must not overwrite a newer mutation.
    }
  }

  Future<bool> _persist(
    T value,
    Future<bool> Function(StorageService storage) write,
  ) async {
    final generation = ++_generation;
    final previous = state;
    state = value;
    try {
      final storage = await _storage();
      if (generation != _generation) return false;

      final pendingWrite = _writeTail.then<bool>((_) async {
        if (generation != _generation) return false;
        await write(storage);
        return generation == _generation;
      });
      _writeTail = pendingWrite.then<void>(
        (_) {},
        onError: (_, __) {},
      );
      return await pendingWrite;
    } catch (_) {
      if (generation == _generation && state == value) state = previous;
      rethrow;
    }
  }

  void applyCommittedValue(T value) {
    ++_generation;
    state = value;
  }
}

class ThemeModeNotifier extends _PersistedSettingNotifier<ThemeMode> {
  ThemeModeNotifier({StorageLoader? storage})
      : super(ThemeMode.system, storage: storage) {
    _load((storage) {
      final index = storage.getInt('theme_mode');
      return index == null
          ? null
          : ThemeMode.values[index.clamp(0, ThemeMode.values.length - 1)];
    });
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _persist(mode, (storage) => storage.setInt('theme_mode', mode.index));
  }

  void applyCommitted(ThemeMode mode) {
    applyCommittedValue(mode);
  }
}

class AudioQualityNotifier
    extends _PersistedSettingNotifier<AudioQualityOption> {
  AudioQualityNotifier({
    StorageLoader? storage,
    Future<void> Function(String quality)? applyPreferredQuality,
  }) : _applyPreferredQuality =
            applyPreferredQuality ?? _applyPreferredQualityToHandler,
        super(AudioQualityOption.high, storage: storage) {
    _load((storage) {
      final index = storage.getInt('audio_quality');
      return index == null
          ? null
          : AudioQualityOption
              .values[index.clamp(0, AudioQualityOption.values.length - 1)];
    });
  }

  final Future<void> Function(String quality) _applyPreferredQuality;

  static Future<void> _applyPreferredQualityToHandler(String quality) async {
    if (audioHandler is LxAudioHandler) {
      await (audioHandler as LxAudioHandler).applyPreferredQuality(quality);
    }
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    final ownsPersistedValue = await _persist(
      quality,
      (storage) => storage.setInt('audio_quality', quality.index),
    );
    if (!ownsPersistedValue) return;
    // 立即让正在播放的队列按新音质重解析，避免继续用旧 extras.url
    final token = switch (quality) {
      AudioQualityOption.low => '128k',
      AudioQualityOption.high => '320k',
      AudioQualityOption.lossless => 'flac',
      AudioQualityOption.lossless24 => 'flac24bit',
      AudioQualityOption.hires => 'hires',
    };
    try {
      await _applyPreferredQuality(token);
    } catch (_) {
      // audioHandler 可能尚未 init（单测）；忽略
    }
  }

  void applyCommitted(AudioQualityOption quality) {
    applyCommittedValue(quality);
  }
}

class DownloadQualityNotifier
    extends _PersistedSettingNotifier<AudioQualityOption> {
  DownloadQualityNotifier({StorageLoader? storage})
      : super(AudioQualityOption.high, storage: storage) {
    _load((storage) {
      final index = storage.getInt('download_quality');
      return index == null
          ? null
          : AudioQualityOption
              .values[index.clamp(0, AudioQualityOption.values.length - 1)];
    });
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    await _persist(
      quality,
      (storage) => storage.setInt('download_quality', quality.index),
    );
  }

  void applyCommitted(AudioQualityOption quality) {
    applyCommittedValue(quality);
  }
}

class WifiOnlyDownloadNotifier extends _PersistedSettingNotifier<bool> {
  WifiOnlyDownloadNotifier({StorageLoader? storage})
      : super(true, storage: storage) {
    _load((storage) => storage.getBool('wifi_only_download'));
  }

  Future<void> setWifiOnly(bool value) async {
    await _persist(
      value,
      (storage) => storage.setBool('wifi_only_download', value),
    );
  }

  void applyCommitted(bool value) {
    applyCommittedValue(value);
  }
}

class AutoResumePlaybackNotifier extends _PersistedSettingNotifier<bool> {
  AutoResumePlaybackNotifier({StorageLoader? storage})
      : super(false, storage: storage) {
    _load((storage) => storage.getBool('auto_resume_playback'));
  }

  Future<void> setAutoResume(bool value) async {
    await _persist(
      value,
      (storage) => storage.setBool('auto_resume_playback', value),
    );
  }

  void applyCommitted(bool value) {
    applyCommittedValue(value);
  }
}

class DefaultSearchPlatformNotifier extends _PersistedSettingNotifier<String> {
  DefaultSearchPlatformNotifier({StorageLoader? storage})
      : super('tx', storage: storage) {
    _load((storage) {
      final value = storage.getString('default_search_platform');
      return value == 'tx' || value == 'kw' || value == 'wy' ? value : null;
    });
  }

  Future<void> setPlatform(String platform) async {
    if (platform != 'tx' && platform != 'kw' && platform != 'wy') return;
    await _persist(
      platform,
      (storage) => storage.setString('default_search_platform', platform),
    );
  }

  void applyCommitted(String platform) {
    applyCommittedValue(platform);
  }
}
