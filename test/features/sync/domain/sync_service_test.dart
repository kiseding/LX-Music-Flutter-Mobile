import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/secure_token_store.dart';
import 'package:lx_music_flutter/features/sync/domain/sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';


String syncTokenKey([String base = 'https://sync.example.com']) =>
    originTokenKey('sync_token', base);

final class FakeSecureTokenStore implements SecureTokenStore {
  FakeSecureTokenStore({this.readAfterWrite, this.failDelete = false});

  final String? readAfterWrite;
  final bool failDelete;
  final Map<String, String> values = {};
  var writes = 0;
  bool throwOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('keychain unavailable');
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

Future<void> _waitUntil(bool Function() ready) async {
  for (var i = 0; i < 50; i++) {
    if (ready()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('condition not met');
}

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
      'sync_server_url': 'https://sync.example.com',
    });
    final secure = FakeSecureTokenStore();
    final service = SyncService(
      dio: Dio(),
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    expect(await service.loadSavedToken(), 'sync-secret');
    expect(await secure.read(syncTokenKey()), 'sync-secret');
    expect(await secure.read('sync_token'), isNull);
    expect(await secure.read('cloud_api_token'), isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  });

  test('failed sync token verification removes plaintext and requires auth',
      () async {
    SharedPreferences.setMockInitialValues({
      'sync_token': 'sync-secret',
      'sync_server_url': 'https://sync.example.com',
    });
    final service = SyncService(
      dio: Dio(),
      secureStore: FakeSecureTokenStore(readAfterWrite: 'different'),
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.loadSavedToken(),
      throwsA(isA<SecureTokenMigrationException>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
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
    expect(await secure.read(syncTokenKey()), 'sync-secret');
    expect(await secure.read('sync_token'), isNull);
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
      'sync_server_url': 'https://sync.example.com',
    });
    final secure = FakeSecureTokenStore()
      ..values[syncTokenKey()] = 'sync-secret'
      ..values['cloud_api_token'] = 'cloud-secret';
    final service = SyncService(
      dio: Dio(),
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await service.forgetSavedToken();

    expect(await secure.read(syncTokenKey()), isNull);
    expect(await secure.read('cloud_api_token'), 'cloud-secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  });

  test('failed forget preserves legacy sync token for retry', () async {
    SharedPreferences.setMockInitialValues({
      'sync_token': 'legacy-sync-secret',
      'sync_server_url': 'https://sync.example.com',
    });
    final service = SyncService(
      dio: Dio(),
      secureStore: FakeSecureTokenStore(failDelete: true)
        ..values[syncTokenKey()] = 'sync-secret',
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await expectLater(service.forgetSavedToken(), throwsStateError);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sync_token'), 'legacy-sync-secret');
  });

  test('disconnect cancels pull and late response cannot publish synced',
      () async {
    final started = Completer<CancelToken>();
    final response = Completer<Response<dynamic>>();
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.uri.path.endsWith('/api/health')) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200),
            );
            return;
          }
          started.complete(options.cancelToken!);
          final late = await response.future;
          handler.resolve(late);
        },
      ));
    final service = SyncService(dio: dio);
    addTearDown(service.dispose);
    await service.connect('https://sync.example');

    final pull = service.pull();
    final token = await started.future;
    service.disconnect();
    expect(token.isCancelled, isTrue);
    response.complete(Response(
      requestOptions: RequestOptions(path: '/pull'),
      statusCode: 200,
      data: {'snapshot': 1},
    ));

    expect(await pull, isNull);
    expect(service.status, SyncStatus.disconnected);
    expect(service.lastSyncTime, isNull);
  });

  test('newer push owns status when older push completes last', () async {
    final requests = <Completer<Response<dynamic>>>[];
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) async {
          if (options.uri.path.endsWith('/api/health')) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 200),
            );
            return;
          }
          final pending = Completer<Response<dynamic>>();
          requests.add(pending);
          handler.resolve(await pending.future);
        },
      ));
    final service = SyncService(dio: dio);
    addTearDown(service.dispose);
    await service.connect('https://sync.example');

    final older = service.push(playlists: const [], history: const []);
    await _waitUntil(() => requests.isNotEmpty);
    final newer = service.push(playlists: const [], history: const []);
    await _waitUntil(() => requests.length >= 2);
    requests.last.complete(Response(
        requestOptions: RequestOptions(path: '/new'), statusCode: 200));
    expect(await newer, isTrue);
    requests.first.complete(Response(
        requestOptions: RequestOptions(path: '/old'), statusCode: 500));
    expect(await older, isFalse);
    expect(service.status, SyncStatus.synced);
  });

  test('total deadline cancels transport and returns controlled failure',
      () async {
    CancelToken? token;
    final dio = Dio()
      ..interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          token = options.cancelToken;
        },
      ));
    final service = SyncService(
      dio: dio,
      deadlines: const SyncDeadlines(
        connect: Duration(milliseconds: 5),
        send: Duration(milliseconds: 5),
        receive: Duration(milliseconds: 5),
        total: Duration(milliseconds: 10),
      ),
    );
    addTearDown(service.dispose);

    expect(await service.connect('https://sync.example'), isFalse);
    expect(token?.isCancelled, isTrue);
    expect(service.status, SyncStatus.error);
  });

  test('sync tokens are isolated by normalized origin', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
    String? authorization;
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          authorization = options.headers['Authorization'] as String?;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {'token': 'one-token'},
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

    await service.connect('https://one.example');
    expect(await service.login('user', 'password'), isTrue);
    final oneKey = originTokenKey('sync_token', 'https://one.example');
    expect(await secure.read(oneKey), 'one-token');

    authorization = null;
    await service.connect('https://two.example');
    expect(authorization, isNull);
    expect(
      await secure.read(originTokenKey('sync_token', 'https://two.example')),
      isNull,
    );
    expect(await secure.read(oneKey), 'one-token');
  });

  test('legacy sync plaintext is deleted when Keychain is unavailable',
      () async {
    SharedPreferences.setMockInitialValues({
      'sync_token': 'plaintext',
      'sync_server_url': 'https://sync.example',
    });
    final secure = FakeSecureTokenStore()..throwOnRead = true;
    final service = SyncService(
      dio: Dio(),
      secureStore: secure,
      preferences: preferences,
    );
    addTearDown(service.dispose);

    await expectLater(
      service.loadSavedToken(),
      throwsA(isA<SecureTokenMigrationException>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('sync_token'), isFalse);
  });
}
