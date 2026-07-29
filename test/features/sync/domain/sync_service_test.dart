import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/secure_token_store.dart';
import 'package:lx_music_flutter/features/sync/domain/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class FakeSecureTokenStore implements SecureTokenStore {
  FakeSecureTokenStore({this.readAfterWrite, this.failDelete = false});

  final String? readAfterWrite;
  final bool failDelete;
  final Map<String, String> values = {};
  var writes = 0;

  @override
  Future<String?> read(String key) async {
    if (writes > 0 && readAfterWrite != null) return readAfterWrite;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('secure deletion failed');
    values.remove(key);
  }
}

Future<SharedPreferences> preferences() => SharedPreferences.getInstance();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect rejects HTTP instead of silently rewriting it', () async {
    final service = SyncService(dio: Dio());
    addTearDown(service.dispose);

    await expectLater(
      service.connect('http://sync.example.com'),
      throwsA(isA<ArgumentError>()),
    );
    expect(service.serverUrl, isNull);
  });

  test('connect uses normalized HTTPS URL for health check', () async {
    final dio = Dio();
    String? requestedUrl;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          requestedUrl = options.uri.toString();
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
            ),
          );
        },
      ),
    );
    final service = SyncService(dio: dio);
    addTearDown(service.dispose);

    final connected =
        await service.connect('  https://sync.example.com/base///  ');

    expect(connected, isTrue);
    expect(service.serverUrl, 'https://sync.example.com/base');
    expect(requestedUrl, 'https://sync.example.com/base/api/health');
  });

  test('sync token migrates to its own secure key', () async {
    SharedPreferences.setMockInitialValues({
      'sync_token': 'sync-secret',
      'cloud_api_token': 'cloud-secret',
    });
    final secure = FakeSecureTokenStore();
    final service = SyncService(
      dio: Dio(),
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    expect(await service.loadSavedToken(), 'sync-secret');
    expect(await secure.read('sync_token'), 'sync-secret');
    expect(await secure.read('cloud_api_token'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  });

  test('failed sync token verification preserves plaintext for retry',
      () async {
    SharedPreferences.setMockInitialValues({'sync_token': 'sync-secret'});
    final service = SyncService(
      dio: Dio(),
      secureStore: FakeSecureTokenStore(readAfterWrite: 'different'),
      preferences: preferences,
    );
    addTearDown(service.dispose);

    expect(await service.loadSavedToken(), 'sync-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sync_token'), 'sync-secret');
    expect(prefs.getBool('secure_token_migrated_v1_sync_token'), isNot(true));
  });

  test('login writes only the verified secure sync token', () async {
    SharedPreferences.setMockInitialValues({'cloud_api_token': 'cloud-secret'});
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'token': 'sync-secret'},
            ),
          );
        },
      ),
    );
    final secure = FakeSecureTokenStore();
    final service = SyncService(
      dio: dio,
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await service.connect('https://sync.example.com');

    expect(await service.login('user', 'password'), isTrue);
    expect(await secure.read('sync_token'), 'sync-secret');
    expect(await secure.read('cloud_api_token'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  });

  test('failed login verification does not retain the unverified token',
      () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
    String? pushAuthorization;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.endsWith('/api/auth/login')) {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'token': 'sync-secret'},
              ),
            );
            return;
          }
          pushAuthorization = options.headers['Authorization'] as String?;
          handler.resolve(Response(requestOptions: options, statusCode: 200));
        },
      ),
    );
    final service = SyncService(
      dio: dio,
      secureStore: FakeSecureTokenStore(readAfterWrite: 'different'),
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await service.connect('https://sync.example.com');

    expect(await service.login('user', 'password'), isFalse);
    expect(await service.push(playlists: [], history: []), isTrue);
    expect(pushAuthorization, isNull);
  });

  test('forgetSavedToken deletes only sync credentials', () async {
    SharedPreferences.setMockInitialValues({
      'sync_token': 'legacy-sync-secret',
      'cloud_api_token': 'cloud-secret',
    });
    final secure = FakeSecureTokenStore()
      ..values['sync_token'] = 'sync-secret'
      ..values['cloud_api_token'] = 'cloud-secret';
    final service = SyncService(
      dio: Dio(),
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await service.forgetSavedToken();

    expect(await secure.read('sync_token'), isNull);
    expect(await secure.read('cloud_api_token'), 'cloud-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  });

  test('failed forget preserves legacy sync token for retry', () async {
    SharedPreferences.setMockInitialValues(
        {'sync_token': 'legacy-sync-secret'});
    final service = SyncService(
      dio: Dio(),
      secureStore: FakeSecureTokenStore(failDelete: true)
        ..values['sync_token'] = 'sync-secret',
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await expectLater(service.forgetSavedToken(), throwsStateError);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sync_token'), 'legacy-sync-secret');
  });
}
