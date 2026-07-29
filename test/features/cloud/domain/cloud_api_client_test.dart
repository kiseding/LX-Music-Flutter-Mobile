import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/secure_token_store.dart';
import 'package:lx_music_flutter/features/cloud/domain/cloud_api_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class FakeSecureTokenStore implements SecureTokenStore {
  FakeSecureTokenStore({
    this.failWrite = false,
    this.failDelete = false,
    this.readAfterWrite,
    this.failWriteValue,
  });

  final Map<String, String> values = {};
  final bool failWrite;
  final bool failDelete;
  final String? readAfterWrite;
  final String? failWriteValue;
  bool _wrote = false;
  bool throwOnRead = false;

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete failed');
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('read failed');
    return _wrote && readAfterWrite != null ? readAfterWrite : values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite || value == failWriteValue) {
      throw StateError('write failed');
    }
    values[key] = value;
    _wrote = true;
  }
}

final class FakeCloudSessionPreferences implements CloudSessionPreferences {
  FakeCloudSessionPreferences(
    Map<String, String> initialValues, {
    this.failRemoveKey,
    this.failSetKey,
  }) : values = Map<String, String>.from(initialValues);

  final Map<String, String> values;
  final String? failRemoveKey;
  final String? failSetKey;

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> remove(String key) async {
    if (key == failRemoveKey) throw StateError('remove $key failed');
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == failSetKey) throw StateError('set $key failed');
    values[key] = value;
  }
}

Dio responseDio({
  int statusCode = 200,
  Object? data,
  DioExceptionType? error,
}) {
  final dio = Dio();
  dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
    if (error != null) {
      handler.reject(DioException(requestOptions: options, type: error));
      return;
    }
    final response = Response(
      requestOptions: options,
      statusCode: statusCode,
      data: data,
    );
    if (statusCode >= 400) {
      handler.reject(DioException(
        requestOptions: options,
        response: response,
        type: DioExceptionType.badResponse,
      ));
      return;
    }
    handler.resolve(response);
  }));
  return dio;
}

Future<CloudApiClient> loadedClient({
  int statusCode = 200,
  Object? data,
  DioExceptionType? error,
}) async {
  SharedPreferences.setMockInitialValues({
    'cloud_api_base': 'https://cloud.example',
  });
  final secure = FakeSecureTokenStore()..values['cloud_api_token'] = 'token';
  final client = CloudApiClient(
    dio: responseDio(statusCode: statusCode, data: data, error: error),
    secureStore: secure,
  );
  await client.load();
  return client;
}

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

  test('path-prefixed base constructs the expected login endpoint', () async {
    SharedPreferences.setMockInitialValues({});
    final dio = Dio();
    String? requestedUrl;
    dio.interceptors.add(InterceptorsWrapper(onRequest: (options, handler) {
      requestedUrl = options.uri.toString();
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'token': 'token',
          'username': 'user',
          'role': 'user',
        },
      ));
    }));
    final client =
        CloudApiClient(dio: dio, secureStore: FakeSecureTokenStore());

    await client.setBaseUrl('https://cloud.example.com/base///');
    await client.login('user', 'password');

    expect(client.baseUrl, 'https://cloud.example.com/base');
    expect(requestedUrl, 'https://cloud.example.com/base/api/user/login');
  });

  test('load does not migrate a persisted HTTP endpoint', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'http://legacy.example.com',
      'cloud_api_token': 'legacy-token',
    });
    final client = CloudApiClient(secureStore: FakeSecureTokenStore());

    await client.load();

    expect(client.baseUrl, isNull);
    expect(client.isLoggedIn, isFalse);
    expect(client.configurationError, contains('HTTPS'));
  });

  test('load treats persisted query and fragment endpoints as invalid',
      () async {
    for (final value in [
      'https://legacy.example.com/base?target=/api',
      'https://legacy.example.com/base#section',
    ]) {
      SharedPreferences.setMockInitialValues({
        'cloud_api_base': value,
        'cloud_api_token': 'legacy-token',
      });
      final client = CloudApiClient(secureStore: FakeSecureTokenStore());

      await client.load();

      expect(client.baseUrl, isNull, reason: value);
      expect(client.isLoggedIn, isFalse, reason: value);
      expect(client.configurationError, isNotNull, reason: value);
    }
  });

  test('load migrates the token through the secure store and removes plaintext',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_token': 'legacy-token',
      'cloud_api_username': 'legacy',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore();
    final client = CloudApiClient(secureStore: secure);

    await client.load();

    expect(client.token, 'legacy-token');
    expect(await secure.read('cloud_api_token'), 'legacy-token');
    expect(
        (await SharedPreferences.getInstance()).containsKey('cloud_api_token'),
        isFalse);
  });

  test('load retains the current session when secure storage read fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()..values['cloud_api_token'] = 'token';
    final client = CloudApiClient(secureStore: secure);
    await client.load();
    secure.throwOnRead = true;

    await expectLater(client.load(), throwsStateError);

    expect(client.isLoggedIn, isTrue);
    expect(client.token, 'token');
    expect(client.username, 'user');
    expect(client.role, 'user');
  });

  test('login stores token securely and leaves no plaintext token', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final secure = FakeSecureTokenStore();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'user',
        'role': 'user',
      }),
      secureStore: secure,
    );
    await client.load();

    await client.login('user', 'password');

    expect(await secure.read('cloud_api_token'), 'new-token');
    expect(
        (await SharedPreferences.getInstance()).containsKey('cloud_api_token'),
        isFalse);
  });

  test('register stores token securely and leaves no plaintext token',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final secure = FakeSecureTokenStore();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'user',
        'role': 'user',
      }),
      secureStore: secure,
    );
    await client.load();

    await client.register('user', 'password');

    expect(await secure.read('cloud_api_token'), 'new-token');
    expect(
        (await SharedPreferences.getInstance()).containsKey('cloud_api_token'),
        isFalse);
  });

  test('register restores the previous session when secure persistence fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(failWrite: true)
      ..values['cloud_api_token'] = 'old-token';
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.load();

    await expectLater(
        client.register('new-user', 'password'), throwsStateError);

    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test('verify persists refreshed session credentials securely', () async {
    final secure = FakeSecureTokenStore()..values['cloud_api_token'] = 'token';
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final client = CloudApiClient(
      dio: responseDio(data: {
        'valid': true,
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.load();

    expect(await client.verify(), CloudVerification.valid);

    expect(await secure.read('cloud_api_token'), 'token');
    expect(client.username, 'new-user');
    expect(client.role, 'admin');
    expect(
        (await SharedPreferences.getInstance()).containsKey('cloud_api_token'),
        isFalse);
  });

  test('login restores the previous session when secure persistence fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(failWrite: true)
      ..values['cloud_api_token'] = 'old-token';
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.load();

    await expectLater(client.login('new-user', 'password'), throwsStateError);

    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test('login restores the secure token when preferences acquisition fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token';
    var preferenceCalls = 0;
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
      preferences: () async {
        preferenceCalls++;
        if (preferenceCalls == 2) throw StateError('preferences unavailable');
        return SharedPreferences.getInstance();
      },
    );
    await client.load();

    await expectLater(client.login('new-user', 'password'), throwsStateError);

    expect(await secure.read('cloud_api_token'), 'old-token');
    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test(
      'login restores secure token and preference state when metadata write fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token';
    final sessionPreferences = FakeCloudSessionPreferences({
      'cloud_api_token': 'old-token',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    }, failSetKey: 'cloud_api_username');
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
      sessionPreferences: () async => sessionPreferences,
    );
    await client.load();

    await expectLater(client.login('new-user', 'password'), throwsStateError);

    expect(await secure.read('cloud_api_token'), 'old-token');
    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
    expect(sessionPreferences.values, {
      'cloud_api_token': 'old-token',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
  });

  test('register restores the previous session when metadata persistence fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token';
    final sessionPreferences = FakeCloudSessionPreferences({
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    }, failSetKey: 'cloud_api_username');
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
      sessionPreferences: () async => sessionPreferences,
    );
    await client.load();

    await expectLater(
        client.register('new-user', 'password'), throwsStateError);

    expect(await secure.read('cloud_api_token'), 'old-token');
    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
    expect(sessionPreferences.values, {
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
  });

  test('verify restores metadata when refreshed credentials cannot persist',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()..values['cloud_api_token'] = 'token';
    final sessionPreferences = FakeCloudSessionPreferences({
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    }, failSetKey: 'cloud_api_username');
    final client = CloudApiClient(
      dio: responseDio(data: {
        'valid': true,
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
      sessionPreferences: () async => sessionPreferences,
    );
    await client.load();

    expect(await client.verify(), CloudVerification.unavailable);

    expect(await secure.read('cloud_api_token'), 'token');
    expect(client.token, 'token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
    expect(sessionPreferences.values, {
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
  });

  test('clearSession restores the secure token when preferences cleanup fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token';
    final sessionPreferences = FakeCloudSessionPreferences({
      'cloud_api_token': 'old-token',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    }, failRemoveKey: 'cloud_api_username');
    final client = CloudApiClient(
      secureStore: secure,
      sessionPreferences: () async => sessionPreferences,
    );
    await client.load();

    await expectLater(client.clearSession(), throwsStateError);

    expect(await secure.read('cloud_api_token'), 'old-token');
    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test('clearSession clears memory when secure restoration also fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(failWriteValue: 'old-token')
      ..values['cloud_api_token'] = 'old-token';
    final sessionPreferences = FakeCloudSessionPreferences({
      'cloud_api_token': 'old-token',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    }, failRemoveKey: 'cloud_api_username');
    final client = CloudApiClient(
      secureStore: secure,
      sessionPreferences: () async => sessionPreferences,
    );
    await client.load();

    await expectLater(
      client.clearSession(),
      throwsA(
          predicate((error) => error.toString().contains('cleanup failed'))),
    );

    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.isLoggedIn, isFalse);
    expect(client.token, isNull);
    expect(client.username, isNull);
    expect(client.role, isNull);
  });

  test('verify distinguishes 401 from outages and malformed responses',
      () async {
    expect(await (await loadedClient(statusCode: 401)).verify(),
        CloudVerification.unauthorized);
    expect(await (await loadedClient(statusCode: 503)).verify(),
        CloudVerification.unavailable);
    expect(
      await (await loadedClient(error: DioExceptionType.connectionTimeout))
          .verify(),
      CloudVerification.unavailable,
    );
    expect(await (await loadedClient(data: {'valid': false})).verify(),
        CloudVerification.unavailable);
  });

  test('verify preserves the session when secure verification fails', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(readAfterWrite: 'different')
      ..values['cloud_api_token'] = 'token';
    final client = CloudApiClient(
      dio: responseDio(data: {
        'valid': true,
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.load();

    expect(await client.verify(), CloudVerification.unavailable);

    expect(client.isLoggedIn, isTrue);
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test('verify reports no session without a token and base URL pair', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final client = CloudApiClient(secureStore: FakeSecureTokenStore());
    await client.load();

    expect(await client.verify(), CloudVerification.noSession);
  });

  test('clearSession retains in-memory session when secure deletion fails',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(failDelete: true)
      ..values['cloud_api_token'] = 'token';
    final client = CloudApiClient(secureStore: secure);
    await client.load();

    await expectLater(client.clearSession(), throwsStateError);

    expect(client.isLoggedIn, isTrue);
    expect(client.token, 'token');
    expect(client.username, 'user');
    expect(client.role, 'user');
  });
}
