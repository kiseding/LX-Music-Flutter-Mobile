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
      'default_search_platform': 'tx',
    });
    final prefs = await SharedPreferences.getInstance();

    for (final kind in const [
      'audio',
      'download',
      'wifi',
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

  test('failed download quality persistence rolls back the optimistic state',
      () async {
    SharedPreferences.setMockInitialValues({
      'download_quality': AudioQualityOption.high.index,
    });
    final preferences = await SharedPreferences.getInstance();
    final notifier = DownloadQualityNotifier(
      storage: () async => StorageService.forTesting(
        preferences,
        writeOverride: (_, __, ___) async => false,
      ),
    );

    await expectLater(
      notifier.setQuality(AudioQualityOption.lossless),
      throwsA(isA<StorageWriteException>()),
    );

    expect(notifier.state, AudioQualityOption.high);
  });

  test('stale failed download write cannot roll back a newer same-value write',
      () async {
    SharedPreferences.setMockInitialValues({
      'download_quality': AudioQualityOption.high.index,
    });
    final preferences = await SharedPreferences.getInstance();
    final firstWriteStarted = Completer<void>();
    final firstWrite = Completer<bool>();
    var writeCount = 0;
    final storage = StorageService.forTesting(
      preferences,
      writeOverride: (_, __, ___) {
        if (writeCount++ == 0) {
          firstWriteStarted.complete();
          return firstWrite.future;
        }
        return Future.value(true);
      },
    );
    final notifier = DownloadQualityNotifier(storage: () async => storage);

    final staleWrite = notifier.setQuality(AudioQualityOption.lossless);
    await firstWriteStarted.future;
    final newerWrite = notifier.setQuality(AudioQualityOption.lossless);
    firstWrite.complete(false);

    await expectLater(staleWrite, throwsA(isA<StorageWriteException>()));
    await newerWrite;
    expect(notifier.state, AudioQualityOption.lossless);
  });

  test('stale delayed loader cannot persist over a newer download quality',
      () async {
    SharedPreferences.setMockInitialValues({
      'download_quality': AudioQualityOption.high.index,
    });
    final preferences = await SharedPreferences.getInstance();
    final storage = StorageService.forTesting(preferences);
    final firstMutationLoaderRequested = Completer<void>();
    final firstMutationStorage = Completer<StorageService>();
    var loadCount = 0;
    final notifier = DownloadQualityNotifier(storage: () {
      loadCount++;
      if (loadCount == 2) {
        firstMutationLoaderRequested.complete();
        return firstMutationStorage.future;
      }
      return Future.value(storage);
    });
    await Future<void>.delayed(Duration.zero);

    final staleWrite = notifier.setQuality(AudioQualityOption.lossless);
    await firstMutationLoaderRequested.future;
    await notifier.setQuality(AudioQualityOption.hires);
    expect(
      preferences.getInt('download_quality'),
      AudioQualityOption.hires.index,
    );

    firstMutationStorage.complete(storage);
    await staleWrite;

    expect(notifier.state, AudioQualityOption.hires);
    expect(
      preferences.getInt('download_quality'),
      AudioQualityOption.hires.index,
    );
  });

  test('stale audio quality completion cannot apply the old quality', () async {
    SharedPreferences.setMockInitialValues({
      'audio_quality': AudioQualityOption.high.index,
    });
    final preferences = await SharedPreferences.getInstance();
    final firstWriteStarted = Completer<void>();
    final firstWrite = Completer<bool>();
    final appliedQualities = <String>[];
    var writeCount = 0;
    final storage = StorageService.forTesting(
      preferences,
      writeOverride: (_, __, ___) {
        if (writeCount++ == 0) {
          firstWriteStarted.complete();
          return firstWrite.future;
        }
        return Future.value(true);
      },
    );
    final notifier = AudioQualityNotifier(
      storage: () async => storage,
      applyPreferredQuality: (quality) async => appliedQualities.add(quality),
    );

    final staleWrite = notifier.setQuality(AudioQualityOption.low);
    await firstWriteStarted.future;
    final newerWrite = notifier.setQuality(AudioQualityOption.hires);
    firstWrite.complete(true);
    await staleWrite;
    await newerWrite;

    expect(notifier.state, AudioQualityOption.hires);
    expect(appliedQualities, ['hires']);
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
