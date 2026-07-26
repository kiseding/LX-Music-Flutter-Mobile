import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/storage/storage_service.dart';

// 音质选择
enum AudioQualityOption {
  low,        // 128kbps
  high,       // 320kbps
  lossless,   // FLAC
  lossless24, // FLAC 24bit（臻品母带）
  hires,      // Hi-Res
}

/// 持久化设置 Provider
/// 使用 StorageService（SharedPreferences）存储，重启后保留

final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>((ref) {
  return ThemeModeNotifier();
});

final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier();
});

final audioQualityProvider = StateNotifierProvider<AudioQualityNotifier, AudioQualityOption>((ref) {
  return AudioQualityNotifier();
});

final downloadQualityProvider = StateNotifierProvider<DownloadQualityNotifier, AudioQualityOption>((ref) {
  return DownloadQualityNotifier();
});

final wifiOnlyDownloadProvider = StateNotifierProvider<WifiOnlyDownloadNotifier, bool>((ref) {
  return WifiOnlyDownloadNotifier();
});

final syncServerUrlProvider = StateNotifierProvider<SyncServerUrlNotifier, String?>((ref) {
  return SyncServerUrlNotifier();
});

/// 默认搜索平台：tx / kw / wy
final defaultSearchPlatformProvider =
    StateNotifierProvider<DefaultSearchPlatformNotifier, String>((ref) {
  return DefaultSearchPlatformNotifier();
});

// ---- Notifiers ----

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier() : super(ThemeMode.system) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final index = storage.getInt('theme_mode');
    if (index != null) {
      state = ThemeMode.values[index.clamp(0, ThemeMode.values.length - 1)];
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    final storage = await StorageService.instance;
    await storage.setInt('theme_mode', mode.index);
  }
}

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('zh', 'CN')) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final code = storage.getString('locale');
    if (code != null) {
      state = Locale(code);
    }
  }

  Future<void> setLocale(Locale locale) async {
    state = locale;
    final storage = await StorageService.instance;
    await storage.setString('locale', locale.languageCode);
  }
}

class AudioQualityNotifier extends StateNotifier<AudioQualityOption> {
  AudioQualityNotifier() : super(AudioQualityOption.high) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final index = storage.getInt('audio_quality');
    if (index != null) {
      state = AudioQualityOption.values[index.clamp(0, AudioQualityOption.values.length - 1)];
    }
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    state = quality;
    final storage = await StorageService.instance;
    await storage.setInt('audio_quality', quality.index);
  }
}

class DownloadQualityNotifier extends StateNotifier<AudioQualityOption> {
  DownloadQualityNotifier() : super(AudioQualityOption.high) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final index = storage.getInt('download_quality');
    if (index != null) {
      state = AudioQualityOption.values[index.clamp(0, AudioQualityOption.values.length - 1)];
    }
  }

  Future<void> setQuality(AudioQualityOption quality) async {
    state = quality;
    final storage = await StorageService.instance;
    await storage.setInt('download_quality', quality.index);
  }
}

class WifiOnlyDownloadNotifier extends StateNotifier<bool> {
  WifiOnlyDownloadNotifier() : super(true) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final val = storage.getBool('wifi_only_download');
    if (val != null) state = val;
  }

  Future<void> setWifiOnly(bool value) async {
    state = value;
    final storage = await StorageService.instance;
    await storage.setBool('wifi_only_download', value);
  }
}

class SyncServerUrlNotifier extends StateNotifier<String?> {
  SyncServerUrlNotifier() : super(null) {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    state = storage.getString('sync_server_url');
  }

  Future<void> setUrl(String? url) async {
    state = url;
    final storage = await StorageService.instance;
    if (url != null) {
      await storage.setString('sync_server_url', url);
    } else {
      await storage.remove('sync_server_url');
    }
  }
}

class DefaultSearchPlatformNotifier extends StateNotifier<String> {
  DefaultSearchPlatformNotifier() : super('tx') {
    _load();
  }

  Future<void> _load() async {
    final storage = await StorageService.instance;
    final v = storage.getString('default_search_platform');
    if (v == 'tx' || v == 'kw' || v == 'wy') state = v!;
  }

  Future<void> setPlatform(String platform) async {
    if (platform != 'tx' && platform != 'kw' && platform != 'wy') return;
    state = platform;
    final storage = await StorageService.instance;
    await storage.setString('default_search_platform', platform);
  }
}
