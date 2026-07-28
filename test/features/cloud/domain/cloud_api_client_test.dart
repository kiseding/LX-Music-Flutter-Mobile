import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/cloud/domain/cloud_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('setBaseUrl rejects HTTP instead of silently rewriting it', () async {
    SharedPreferences.setMockInitialValues({});
    final client = CloudApiClient();

    await expectLater(
      client.setBaseUrl('http://cloud.example.com/'),
      throwsA(isA<ArgumentError>()),
    );
    expect(client.baseUrl, isNull);
  });

  test('setBaseUrl stores normalized HTTPS service URL', () async {
    SharedPreferences.setMockInitialValues({});
    final client = CloudApiClient();

    await client.setBaseUrl('  https://cloud.example.com/api///  ');

    expect(client.baseUrl, 'https://cloud.example.com/api');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cloud_api_base'), 'https://cloud.example.com/api');
  });

  test('load does not migrate a persisted HTTP endpoint', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'http://legacy.example.com',
      'cloud_api_token': 'legacy-token',
    });
    final client = CloudApiClient();

    await client.load();

    expect(client.baseUrl, isNull);
    expect(client.isLoggedIn, isFalse);
    expect(client.configurationError, contains('HTTPS'));
  });
}
