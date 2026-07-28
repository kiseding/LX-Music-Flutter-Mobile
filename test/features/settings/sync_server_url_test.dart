import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('legacy persisted HTTP sync URL loads as unconfigured', () async {
    SharedPreferences.setMockInitialValues({
      'sync_server_url': 'http://legacy-sync.example.com',
    });

    final notifier = SyncServerUrlNotifier();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, isNull);
  });

  test('setUrl rejects HTTP and stores normalized HTTPS', () async {
    SharedPreferences.setMockInitialValues({});
    final notifier = SyncServerUrlNotifier();
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      notifier.setUrl('http://sync.example.com'),
      throwsA(isA<ArgumentError>()),
    );
    expect(notifier.state, isNull);

    await notifier.setUrl('  https://sync.example.com///  ');
    expect(notifier.state, 'https://sync.example.com');
  });
}
