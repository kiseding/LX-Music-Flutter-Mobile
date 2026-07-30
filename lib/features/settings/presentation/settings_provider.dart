import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/audio/audio_handler.dart';
import '../../../core/storage/storage_service.dart';
import '../../../core/network/outbound_url.dart';

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

final syncServerUrlProvider =
    StateNotifierProvider<SyncServerUrlNotifier, String?>((ref) {
  return SyncServerUrlNotifier();
});

/// 默认搜索平台：tx / kw / wy
final defaultSearchPlatformProvider =
    StateNotifierProvider<DefaultSearchPlatformNotifier, String>((ref) {
  return DefaultSearchPlatformNotifier();
});

// ---- Notifiers ----

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(ThemeMode.system) {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final index = storage.getInt('theme_mode');
      if (generation == _generation && index != null) {
        state = ThemeMode.values[index.clamp(0, ThemeMode.values.length - 1)];
      }
    } catch (_) {
      // load failure must not overwrite a newer mutation
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    ++_generation;
    final previous = state;
    state = mode;
    try {
      await (await _storage()).setInt('theme_mode', mode.index);
    } catch (_) {
      if (state == mode) state = previous;
      rethrow;
    }
  }

  void applyCommitted(ThemeMode mode) {
    ++_generation;
    state = mode;
  }
}

class AudioQualityNotifier extends StateNotifier<AudioQualityOption> {
  AudioQualityNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(AudioQualityOption.high) {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final index = storage.getInt('audio_quality');
      if (generation == _generation && index != null) {
        state = AudioQualityOption
            .values[index.clamp(0, AudioQualityOption.values.length - 1)];
      }
    } catch (_) {}
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    ++_generation;
    final previous = state;
    state = quality;
    try {
      await (await _storage()).setInt('audio_quality', quality.index);
    } catch (_) {
      if (state == quality) state = previous;
      rethrow;
    }
    // 立即让正在播放的队列按新音质重解析，避免继续用旧 extras.url
    final token = switch (quality) {
      AudioQualityOption.low => '128k',
      AudioQualityOption.high => '320k',
      AudioQualityOption.lossless => 'flac',
      AudioQualityOption.lossless24 => 'flac24bit',
      AudioQualityOption.hires => 'hires',
    };
    try {
      if (audioHandler is LxAudioHandler) {
        await (audioHandler as LxAudioHandler).applyPreferredQuality(token);
      }
    } catch (_) {
      // audioHandler 可能尚未 init（单测）；忽略
    }
  }

  void applyCommitted(AudioQualityOption quality) {
    ++_generation;
    state = quality;
  }
}

class DownloadQualityNotifier extends StateNotifier<AudioQualityOption> {
  DownloadQualityNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(AudioQualityOption.high) {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final index = storage.getInt('download_quality');
      if (generation == _generation && index != null) {
        state = AudioQualityOption
            .values[index.clamp(0, AudioQualityOption.values.length - 1)];
      }
    } catch (_) {}
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    ++_generation;
    final previous = state;
    state = quality;
    try {
      await (await _storage()).setInt('download_quality', quality.index);
    } catch (_) {
      if (state == quality) state = previous;
      rethrow;
    }
  }

  void applyCommitted(AudioQualityOption quality) {
    ++_generation;
    state = quality;
  }
}

class WifiOnlyDownloadNotifier extends StateNotifier<bool> {
  WifiOnlyDownloadNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(true) {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final value = storage.getBool('wifi_only_download');
      if (generation == _generation && value != null) state = value;
    } catch (_) {}
  }

  Future<void> setWifiOnly(bool value) async {
    ++_generation;
    final previous = state;
    state = value;
    try {
      await (await _storage()).setBool('wifi_only_download', value);
    } catch (_) {
      if (state == value) state = previous;
      rethrow;
    }
  }

  void applyCommitted(bool value) {
    ++_generation;
    state = value;
  }
}

class SyncServerUrlNotifier extends StateNotifier<String?> {
  SyncServerUrlNotifier({StorageLoader? storage, String? initialValue})
      : _storage = storage ?? (() => StorageService.instance),
        super(
          initialValue == null ? null : validateHttpsServiceUrl(initialValue),
        ) {
    if (initialValue == null) {
      _load();
    }
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final saved = storage.getString('sync_server_url');
      if (generation != _generation) return;
      if (saved == null || saved.isEmpty) return;
      try {
        state = validateHttpsServiceUrl(saved);
      } on ArgumentError {
        state = null;
      }
    } catch (_) {}
  }

  Future<void> setUrl(String? url) async {
    ++_generation;
    final previous = state;
    if (url != null) {
      final validated = validateHttpsServiceUrl(url);
      state = validated;
      try {
        await (await _storage()).setString('sync_server_url', validated);
      } catch (_) {
        if (state == validated) state = previous;
        rethrow;
      }
    } else {
      state = null;
      try {
        await (await _storage()).remove('sync_server_url');
      } catch (_) {
        if (state == null) state = previous;
        rethrow;
      }
    }
  }

  void applyCommitted(String? url) {
    ++_generation;
    state = url;
  }
}

class DefaultSearchPlatformNotifier extends StateNotifier<String> {
  DefaultSearchPlatformNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super('tx') {
    _load();
  }

  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    try {
      final storage = await _storage();
      final v = storage.getString('default_search_platform');
      if (generation == _generation && (v == 'tx' || v == 'kw' || v == 'wy')) {
        state = v!;
      }
    } catch (_) {}
  }

  Future<void> setPlatform(String platform) async {
    if (platform != 'tx' && platform != 'kw' && platform != 'wy') return;
    ++_generation;
    final previous = state;
    state = platform;
    try {
      await (await _storage()).setString('default_search_platform', platform);
    } catch (_) {
      if (state == platform) state = previous;
      rethrow;
    }
  }

  void applyCommitted(String platform) {
    ++_generation;
    state = platform;
  }
}
