import 'dart:async';

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
  bool failWrite;
  final bool failDelete;
  final String? readAfterWrite;
  final String? failWriteValue;
  bool _wrote = false;
  bool throwOnRead = false;
  Completer<void>? pauseNextRead;
  Completer<void>? readPaused;
  Completer<void>? pauseDelete;
  Completer<void>? deleteStarted;
  Completer<void>? pauseWrite;
  Completer<void>? writeStarted;

  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('delete failed');
    values.remove(key);
    if (deleteStarted != null && !deleteStarted!.isCompleted) {
      deleteStarted!.complete();
    }
    final pause = pauseDelete;
    if (pause != null) await pause.future;
  }

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('read failed');
    final value =
        _wrote && readAfterWrite != null ? readAfterWrite : values[key];
    final pause = pauseNextRead;
    if (pause != null) {
      pauseNextRead = null;
      if (readPaused != null && !readPaused!.isCompleted) {
        readPaused!.complete();
      }
      await pause.future;
    }
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite || value == failWriteValue) {
      throw StateError('write failed');
    }
    if (writeStarted != null && !writeStarted!.isCompleted) {
      writeStarted!.complete();
    }
    final pause = pauseWrite;
    if (pause != null) await pause.future;
    values[key] = value;
    _wrote = true;
  }
}

final class DelayedAuthResponses {
  final Map<String, Completer<Map<String, dynamic>>> responses = {};
  final Map<String, Completer<void>> started = {};

  Future<void> startedFor(String username) =>
      started.putIfAbsent(username, Completer<void>.new).future;

  Dio createDio() {
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      final username = (options.data as Map)['username'] as String;
      final startedCompleter =
          started.putIfAbsent(username, Completer<void>.new);
      if (!startedCompleter.isCompleted) startedCompleter.complete();
      final response = await responses
          .putIfAbsent(username, Completer<Map<String, dynamic>>.new)
          .future;
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: response,
      ));
    }));
    return dio;
  }

  void complete(String username, Map<String, dynamic> response) {
    final completer =
        responses.putIfAbsent(username, Completer<Map<String, dynamic>>.new);
    completer.complete(response);
  }
}

final class DelayedVerifyResponses {
  final started = Completer<void>();
  final response = Completer<Map<String, dynamic>>();

  Dio createDio() {
    final dio = Dio();
    dio.interceptors
        .add(InterceptorsWrapper(onRequest: (options, handler) async {
      if (options.path.endsWith('/api/user/auth/verify')) {
        if (!started.isCompleted) started.complete();
        handler.resolve(Response(
          requestOptions: options,
          statusCode: 200,
          data: await response.future,
        ));
        return;
      }
      handler.resolve(Response(
        requestOptions: options,
        statusCode: 200,
        data: {
          'token': 'new-token',
          'username': 'new-user',
          'role': 'user',
        },
      ));
    }));
    return dio;
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
  Completer<void>? pauseRemove;
  Completer<void>? removeStarted;

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> remove(String key) async {
    if (key == failRemoveKey) throw StateError('remove $key failed');
    if (removeStarted != null && !removeStarted!.isCompleted) {
      removeStarted!.complete();
    }
    final pause = pauseRemove;
    if (pause != null) await pause.future;
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    if (key == failSetKey) throw StateError('set $key failed');
    values[key] = value;
  }
}

final class DelayedBaseUrlPreferences implements CloudSessionPreferences {
  DelayedBaseUrlPreferences(this.values);

  final Map<String, String> values;
  final Map<String, Completer<void>> _started = {};
  final Map<String, Completer<void>> _pauses = {};
  String? failSetValue;

  Future<void> startedFor(String value) =>
      _started.putIfAbsent(value, Completer<void>.new).future;

  void pause(String value) {
    _pauses[value] = Completer<void>();
  }

  void release(String value) => _pauses[value]!.complete();

  @override
  String? getString(String key) => values[key];

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }

  @override
  Future<void> setString(String key, String value) async {
    final started = _started.putIfAbsent(value, Completer<void>.new);
    if (!started.isCompleted) started.complete();
    final pause = _pauses[value];
    if (pause != null) await pause.future;
    if (value == failSetValue) throw StateError('set $key failed');
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

  test('a stale base URL write cannot overwrite a newer durable URL', () async {
    final preferences = DelayedBaseUrlPreferences({});
    preferences.pause('https://old.example');
    final client = CloudApiClient(
      baseUrlPreferences: () async => preferences,
    );

    final old = client.setBaseUrl('https://old.example');
    await preferences.startedFor('https://old.example');
    final newer = client.setBaseUrl('https://new.example');
    preferences.release('https://old.example');
    await Future.wait<void>([old, newer]);

    expect(client.baseUrl, 'https://new.example');
    expect(preferences.values['cloud_api_base'], 'https://new.example');
  });

  test('a delayed base URL write survives a newer login', () async {
    final preferences = DelayedBaseUrlPreferences({});
    preferences.pause('https://new.example');
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'token',
        'username': 'user',
        'role': 'user',
      }),
      secureStore: FakeSecureTokenStore(),
      baseUrlPreferences: () async => preferences,
    );

    final setBaseUrl = client.setBaseUrl('https://new.example');
    await preferences.startedFor('https://new.example');
    final login = client.login('user', 'password');
    preferences.release('https://new.example');
    await Future.wait<void>([setBaseUrl, login]);

    expect(client.baseUrl, 'https://new.example');
    expect(preferences.values['cloud_api_base'], 'https://new.example');
    expect(client.token, 'token');
  });

  test('a delayed base URL write survives a concurrent load', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://old.example',
    });
    final preferences = DelayedBaseUrlPreferences({
      'cloud_api_base': 'https://old.example',
    });
    preferences.pause('https://new.example');
    final client = CloudApiClient(
      secureStore: FakeSecureTokenStore(),
      baseUrlPreferences: () async => preferences,
    );

    final setBaseUrl = client.setBaseUrl('https://new.example');
    await preferences.startedFor('https://new.example');
    final load = client.load();
    preferences.release('https://new.example');
    await Future.wait<void>([setBaseUrl, load]);

    expect(client.baseUrl, 'https://new.example');
    expect(preferences.values['cloud_api_base'], 'https://new.example');
  });

  test('a failed current base URL write restores the prior coherent state',
      () async {
    final preferences = DelayedBaseUrlPreferences({});
    final client = CloudApiClient(
      baseUrlPreferences: () async => preferences,
    );
    await client.setBaseUrl('https://old.example');
    preferences.failSetValue = 'https://new.example';

    await expectLater(
      client.setBaseUrl('https://new.example'),
      throwsStateError,
    );

    expect(client.baseUrl, 'https://old.example');
    expect(preferences.values['cloud_api_base'], 'https://old.example');
    expect(client.configurationError, contains('could not be saved'));
  });

  test('a failed base URL persistence does not poison a later update',
      () async {
    final preferences = DelayedBaseUrlPreferences({});
    final client = CloudApiClient(
      baseUrlPreferences: () async => preferences,
    );
    await client.setBaseUrl('https://old.example');
    preferences.failSetValue = 'https://failed.example';

    await expectLater(
      client.setBaseUrl('https://failed.example'),
      throwsStateError,
    );
    preferences.failSetValue = null;

    await client.setBaseUrl('https://recovered.example');

    expect(client.baseUrl, 'https://recovered.example');
    expect(preferences.values['cloud_api_base'], 'https://recovered.example');
  });

  test('a stale failed base URL mutation leaves the newer update authoritative',
      () async {
    final preferences = DelayedBaseUrlPreferences({})
      ..pause('https://stale.example')
      ..failSetValue = 'https://stale.example';
    final client = CloudApiClient(
      baseUrlPreferences: () async => preferences,
    );

    final stale = client.setBaseUrl('https://stale.example');
    await preferences.startedFor('https://stale.example');
    final current = client.setBaseUrl('https://current.example');
    preferences.release('https://stale.example');
    await Future.wait<void>([stale, current]);

    expect(client.baseUrl, 'https://current.example');
    expect(preferences.values['cloud_api_base'], 'https://current.example');
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

  test('a failed session persistence does not poison a later login or clear',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final secure = FakeSecureTokenStore(failWrite: true);
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
    secure.failWrite = false;

    await client.login('new-user', 'password');
    await client.clearSession();

    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.isLoggedIn, isFalse);
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
    expect(client.username, 'old-user');
    expect(client.role, 'user');
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

  test('a delayed login response cannot restore a session after logout',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final responses = DelayedAuthResponses();
    final secure = FakeSecureTokenStore()
      ..pauseDelete = Completer<void>()
      ..deleteStarted = Completer<void>();
    final client = CloudApiClient(
      dio: responses.createDio(),
      secureStore: secure,
    );
    await client.load();

    final login = client.login('delayed', 'password');
    await responses.startedFor('delayed');
    final logout = client.clearSession();
    await secure.deleteStarted!.future;
    responses.complete('delayed', {
      'token': 'delayed-token',
      'username': 'delayed',
      'role': 'user',
    });
    secure.pauseDelete!.complete();
    await logout;
    await login;

    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.token, isNull);
    expect(client.username, isNull);
    expect(client.role, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cloud_api_username'), isNull);
    expect(prefs.getString('cloud_api_role'), isNull);
  });

  test('a delayed login response cannot mutate a newer base URL session',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final responses = DelayedAuthResponses();
    final secure = FakeSecureTokenStore();
    final client = CloudApiClient(
      dio: responses.createDio(),
      secureStore: secure,
    );
    await client.load();

    final login = client.login('delayed', 'password');
    await responses.startedFor('delayed');
    await client.setBaseUrl('https://new.example');
    responses.complete('delayed', {
      'token': 'delayed-token',
      'username': 'delayed',
      'role': 'user',
    });
    await login;

    expect(client.baseUrl, 'https://new.example');
    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.token, isNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cloud_api_username'), isNull);
    expect(prefs.getString('cloud_api_role'), isNull);
  });

  test('an older login response cannot overwrite a newer registration',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
    });
    final responses = DelayedAuthResponses();
    final secure = FakeSecureTokenStore();
    final client = CloudApiClient(
      dio: responses.createDio(),
      secureStore: secure,
    );
    await client.load();

    final login = client.login('older-login', 'password');
    await responses.startedFor('older-login');
    final register = client.register('newer-register', 'password');
    await responses.startedFor('newer-register');
    responses.complete('newer-register', {
      'token': 'newer-token',
      'username': 'newer-register',
      'role': 'admin',
    });
    await register;
    responses.complete('older-login', {
      'token': 'older-token',
      'username': 'older-login',
      'role': 'user',
    });
    await login;

    expect(await secure.read('cloud_api_token'), 'newer-token');
    expect(client.token, 'newer-token');
    expect(client.username, 'newer-register');
    expect(client.role, 'admin');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('cloud_api_username'), 'newer-register');
    expect(prefs.getString('cloud_api_role'), 'admin');
  });

  test('stale cleanup reports a failed secure restoration and syncs memory',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final secure = FakeSecureTokenStore(failWriteValue: 'old-token')
      ..values['cloud_api_token'] = 'old-token'
      ..pauseDelete = Completer<void>()
      ..deleteStarted = Completer<void>();
    final client = CloudApiClient(secureStore: secure);
    await client.load();

    final clear = client.clearSession();
    await secure.deleteStarted!.future;
    await client.setBaseUrl('https://new.example');
    secure.pauseDelete!.complete();

    await expectLater(
      clear,
      throwsA(
          predicate((error) => error.toString().contains('cleanup failed'))),
    );
    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.token, isNull);
    expect(client.username, 'old-user');
    expect(client.role, 'user');
  });

  test('a delayed load cannot assign an old snapshot after a newer login',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://old.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final releaseRead = Completer<void>();
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token'
      ..pauseNextRead = releaseRead
      ..readPaused = Completer<void>();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.setBaseUrl('https://new.example');

    final load = client.load();
    await secure.readPaused!.future;
    await client.login('new-user', 'password');
    releaseRead.complete();
    await load;

    expect(client.baseUrl, 'https://new.example');
    expect(client.token, 'new-token');
    expect(client.username, 'new-user');
    expect(client.role, 'admin');
  });

  test('a stale legacy migration cannot write its plaintext token after login',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_token': 'legacy-token',
    });
    final releaseMigration = Completer<void>();
    final secure = FakeSecureTokenStore()
      ..pauseWrite = releaseMigration
      ..writeStarted = Completer<void>();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'new-token',
        'username': 'new-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.setBaseUrl('https://cloud.example');

    final load = client.load();
    await secure.writeStarted!.future;
    secure.pauseWrite = null;
    final login = client.login('new-user', 'password');
    releaseMigration.complete();
    await login;
    await load;

    expect(await secure.read('cloud_api_token'), 'new-token');
    expect(client.token, 'new-token');
  });

  test(
      'a stale legacy migration cannot write its plaintext token after base URL change',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://old.example',
      'cloud_api_token': 'legacy-token',
    });
    final releaseMigration = Completer<void>();
    final secure = FakeSecureTokenStore()
      ..pauseWrite = releaseMigration
      ..writeStarted = Completer<void>();
    final client = CloudApiClient(secureStore: secure);

    final load = client.load();
    await secure.writeStarted!.future;
    final setBaseUrl = client.setBaseUrl('https://new.example');
    releaseMigration.complete();
    await setBaseUrl;
    await load;

    expect(await secure.read('cloud_api_token'), isNull);
    expect((await SharedPreferences.getInstance()).getString('cloud_api_token'),
        'legacy-token');
    expect(client.baseUrl, 'https://new.example');
    expect(client.token, isNull);
  });

  test('a stale verify response cannot update newer token metadata', () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final responses = DelayedVerifyResponses();
    final secure = FakeSecureTokenStore()
      ..values['cloud_api_token'] = 'old-token';
    final client = CloudApiClient(
      dio: responses.createDio(),
      secureStore: secure,
    );
    await client.load();

    final verify = client.verify();
    await responses.started.future;
    await client.login('new-user', 'password');
    responses.response.complete({
      'valid': true,
      'username': 'old-user',
      'role': 'admin',
    });

    expect(await verify, CloudVerification.valid);
    expect(await secure.read('cloud_api_token'), 'new-token');
    expect(client.username, 'new-user');
    expect(client.role, 'user');
  });

  test(
      'a stale verify persistence safety failure is reported without clearing durable state',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final releaseWrite = Completer<void>();
    final secure = FakeSecureTokenStore(failDelete: true)
      ..values['cloud_api_token'] = 'old-token'
      ..pauseWrite = releaseWrite
      ..writeStarted = Completer<void>();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'valid': true,
        'username': 'old-user',
        'role': 'user',
      }),
      secureStore: secure,
    );
    await client.load();

    final verify = client.verify();
    await secure.writeStarted!.future;
    await client.setBaseUrl('https://new.example');
    releaseWrite.complete();

    await expectLater(verify, throwsA(isA<CloudSessionSafetyError>()));
    expect(await secure.read('cloud_api_token'), 'old-token');
    expect(client.token, 'old-token');
    expect(client.username, 'old-user');
    expect(client.role, 'user');
    expect(
      (await SharedPreferences.getInstance())
          .getString('cloud_api_token_invalidated'),
      'true',
    );
  });

  test(
      'stale login deletes its token when restoration cannot recover the prior token',
      () async {
    SharedPreferences.setMockInitialValues({
      'cloud_api_base': 'https://cloud.example',
      'cloud_api_username': 'old-user',
      'cloud_api_role': 'user',
    });
    final releaseWrite = Completer<void>();
    final secure = FakeSecureTokenStore(failWriteValue: 'old-token')
      ..values['cloud_api_token'] = 'old-token'
      ..pauseWrite = releaseWrite
      ..writeStarted = Completer<void>();
    final client = CloudApiClient(
      dio: responseDio(data: {
        'token': 'stale-token',
        'username': 'stale-user',
        'role': 'admin',
      }),
      secureStore: secure,
    );
    await client.load();

    final login = client.login('stale-user', 'password');
    await secure.writeStarted!.future;
    await client.setBaseUrl('https://new.example');
    releaseWrite.complete();

    await expectLater(login, throwsA(isA<CloudSessionSafetyError>()));
    expect(await secure.read('cloud_api_token'), isNull);
    expect(client.token, isNull);
  });
}
