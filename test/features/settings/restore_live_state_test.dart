import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restore APIs update live state and durable preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container
        .read(themeModeProvider.notifier)
        .setThemeMode(ThemeMode.dark);
    await container
        .read(audioQualityProvider.notifier)
        .setQuality(AudioQualityOption.lossless);
    await container
        .read(downloadQualityProvider.notifier)
        .setQuality(AudioQualityOption.low);
    await container.read(wifiOnlyDownloadProvider.notifier).setWifiOnly(false);
    await container
        .read(searchHistoryProvider.notifier)
        .replaceAll(['one', 'two']);

    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(container.read(audioQualityProvider), AudioQualityOption.lossless);
    expect(container.read(downloadQualityProvider), AudioQualityOption.low);
    expect(container.read(wifiOnlyDownloadProvider), isFalse);
    expect(container.read(searchHistoryProvider), ['one', 'two']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('theme_mode'), ThemeMode.dark.index);
    expect(prefs.getStringList('search_history'), ['one', 'two']);
  });
}
