import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('late theme load cannot overwrite a user mutation', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': ThemeMode.dark.index});
    final gate = Completer<StorageService>();
    final notifier = ThemeModeNotifier(storage: () => gate.future);

    final mutation = notifier.setThemeMode(ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    gate.complete(StorageService.forTesting(prefs));
    await mutation;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, ThemeMode.light);
    expect(prefs.getInt('theme_mode'), ThemeMode.light.index);
  });

  test('late history load cannot resurrect entries after clear', () async {
    SharedPreferences.setMockInitialValues({'search_history': ['old']});
    final gate = Completer<StorageService>();
    final notifier = SearchHistoryNotifier(storage: () => gate.future);

    final clear = notifier.clear();
    final prefs = await SharedPreferences.getInstance();
    gate.complete(StorageService.forTesting(prefs));
    await clear;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, isEmpty);
    expect(prefs.getStringList('search_history'), isEmpty);
  });

  test('late settings loads cannot overwrite public setter mutations', () async {
    SharedPreferences.setMockInitialValues({
      'audio_quality': AudioQualityOption.low.index,
      'download_quality': AudioQualityOption.low.index,
      'wifi_only_download': true,
      'sync_server_url': 'https://old.example',
      'default_search_platform': 'tx',
    });
    final prefs = await SharedPreferences.getInstance();

    for (final kind in const [
      'audio',
      'download',
      'wifi',
      'syncUrl',
      'platform',
    ]) {
      final gate = Completer<StorageService>();
      final StorageLoader loader = () => gate.future;
      late final Object? Function() readState;
      late final Future<void> mutation;
      late final Object expected;
      switch (kind) {
        case 'audio':
          final value = AudioQualityNotifier(storage: loader);
          readState = () => value.state;
          expected = AudioQualityOption.hires;
          mutation = value.setQuality(AudioQualityOption.hires);
          break;
        case 'download':
          final value = DownloadQualityNotifier(storage: loader);
          readState = () => value.state;
          expected = AudioQualityOption.lossless;
          mutation = value.setQuality(AudioQualityOption.lossless);
          break;
        case 'wifi':
          final value = WifiOnlyDownloadNotifier(storage: loader);
          readState = () => value.state;
          expected = false;
          mutation = value.setWifiOnly(false);
          break;
        case 'syncUrl':
          final value = SyncServerUrlNotifier(storage: loader);
          readState = () => value.state;
          expected = 'https://new.example';
          mutation = value.setUrl('https://new.example');
          break;
        case 'platform':
          final value = DefaultSearchPlatformNotifier(storage: loader);
          readState = () => value.state;
          expected = 'wy';
          mutation = value.setPlatform('wy');
          break;
        default:
          throw StateError(kind);
      }
      gate.complete(StorageService.forTesting(prefs));
      await mutation;
      await Future<void>.delayed(Duration.zero);
      expect(readState(), expected, reason: kind);
    }

    expect(prefs.getInt('audio_quality'), AudioQualityOption.hires.index);
    expect(prefs.getInt('download_quality'), AudioQualityOption.lossless.index);
    expect(prefs.getBool('wifi_only_download'), isFalse);
    expect(prefs.getString('sync_server_url'), 'https://new.example');
    expect(prefs.getString('default_search_platform'), 'wy');
  });

  test('failed load does not overwrite a user mutation', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': ThemeMode.dark.index});
    final prefs = await SharedPreferences.getInstance();
    final loadReady = Completer<void>();
    var calls = 0;
    final notifier = ThemeModeNotifier(storage: () async {
      calls++;
      if (calls == 1) {
        await loadReady.future;
        throw Exception('load failed');
      }
      return StorageService.forTesting(prefs);
    });

    final mutation = notifier.setThemeMode(ThemeMode.light);
    loadReady.complete();
    await mutation;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, ThemeMode.light);
    expect(prefs.getInt('theme_mode'), ThemeMode.light.index);
  });

  test('failed history load does not overwrite clear mutation', () async {
    SharedPreferences.setMockInitialValues({'search_history': ['old']});
    final prefs = await SharedPreferences.getInstance();
    final loadReady = Completer<void>();
    var calls = 0;
    final notifier = SearchHistoryNotifier(storage: () async {
      calls++;
      if (calls == 1) {
        await loadReady.future;
        throw Exception('load failed');
      }
      return StorageService.forTesting(prefs);
    });

    final clear = notifier.clear();
    loadReady.complete();
    await clear;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, isEmpty);
    expect(prefs.getStringList('search_history'), isEmpty);
  });

  test('applyCommitted updates memory and blocks late load', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': ThemeMode.dark.index});
    final gate = Completer<StorageService>();
    final notifier = ThemeModeNotifier(storage: () => gate.future);

    notifier.applyCommitted(ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    gate.complete(StorageService.forTesting(prefs));
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, ThemeMode.light);
    expect(prefs.getInt('theme_mode'), ThemeMode.dark.index);
  });
}
