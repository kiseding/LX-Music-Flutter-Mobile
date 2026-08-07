import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('播放默认音质为 320k (high)', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = AudioQualityNotifier();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(notifier.state, AudioQualityOption.high);
  });
}
