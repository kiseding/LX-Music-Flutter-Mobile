import 'dart:async';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/network/app_http_client.dart';
import '../../../core/storage/secure_token_store.dart';
import '../../../core/network/outbound_url.dart';

/// 对接 workers/ 子项目（lx-music-api）的客户端。
enum CloudVerification { valid, unauthorized, unavailable, noSession }

final class CloudSessionSafetyError implements Exception {
  const CloudSessionSafetyError(this.message);

  final String message;

  @override
  String toString() => message;
}

abstract interface class CloudSessionPreferences {
  String? getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

final class _SharedPreferencesCloudSessionPreferences
    implements CloudSessionPreferences {
  _SharedPreferencesCloudSessionPreferences(this._preferences);

  final SharedPreferences _preferences;

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<void> remove(String key) => _preferences.remove(key);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);
}

final class _CloudSessionSnapshot {
  const _CloudSessionSnapshot({
    required this.token,
    required this.legacyToken,
    required this.username,
    required this.role,
    required this.tokenKey,
  });

  final String? token;
  final String? legacyToken;
  final String? username;
  final String? role;
  final String? tokenKey;
}

class CloudApiClient {
  static const _kBase = 'cloud_api_base';
  static const _kToken = 'cloud_api_token';
  static const _kUsername = 'cloud_api_username';
  static const _kRole = 'cloud_api_role';
  static const _kTokenInvalidated = 'cloud_api_token_invalidated';

  final Dio _dio;
  final SecureTokenStore _secureStore;
  final Future<SharedPreferences> Function() _preferences;
  final Future<CloudSessionPreferences> Function() _sessionPreferences;
  final Future<CloudSessionPreferences> Function() _baseUrlPreferences;

  String? _baseUrl;
  String? _token;
  String? _username;
  String? _role;
  String? _configurationError;
  int _sessionRevision = 0;
  int _baseUrlRevision = 0;
  Future<void> _sessionMutation = Future.value();
  Future<void> _baseUrlMutation = Future.value();

  CloudApiClient({
    Dio? dio,
    SecureTokenStore? secureStore,
    Future<SharedPreferences> Function()? preferences,
    Future<CloudSessionPreferences> Function()? sessionPreferences,
    Future<CloudSessionPreferences> Function()? baseUrlPreferences,
  }) : _dio =
           dio ??
           AppHttpClient.create(
             options: BaseOptions(
               connectTimeout: const Duration(seconds: 12),
               receiveTimeout: const Duration(seconds: 30),
               headers: {'Content-Type': 'application/json'},
             ),
           ),
       _secureStore = secureStore ?? FlutterSecureTokenStore(),
       _preferences = preferences ?? SharedPreferences.getInstance,
       _sessionPreferences =
           sessionPreferences ??
           (() async => _SharedPreferencesCloudSessionPreferences(
             await (preferences ?? SharedPreferences.getInstance)(),
           )),
       _baseUrlPreferences =
           baseUrlPreferences ??
           (() async => _SharedPreferencesCloudSessionPreferences(
             await (preferences ?? SharedPreferences.getInstance)(),
           ));

  String? get baseUrl => _baseUrl;
  String? get token => _token;
  String? get username => _username;
  String? get role => _role;
  int get sessionRevision => _sessionRevision;
  String? get configurationError => _configurationError;
  bool get isLoggedIn =>
      _token != null && _token!.isNotEmpty && _baseUrl != null;
  bool get isAdmin => _role == 'admin';

  String? _tokenKeyFor(String? serviceUrl) {
    if (serviceUrl == null || serviceUrl.isEmpty) return null;
    try {
      return originTokenKey(_kToken, serviceUrl);
    } catch (_) {
      return null;
    }
  }

  String? get _activeTokenKey => _tokenKeyFor(_baseUrl);

  Future<void> load() async {
    final revision = _sessionRevision;
    final baseUrlRevision = _baseUrlRevision;
    final canAssignBaseUrl = baseUrlRevision == 0;
    final prefs = await _preferences();
    final savedBaseUrl = prefs.getString(_kBase);
    String? baseUrl;
    String? configurationError;
    if (savedBaseUrl != null && savedBaseUrl.isNotEmpty) {
      try {
        baseUrl = validateHttpsServiceUrl(savedBaseUrl);
      } on ArgumentError catch (error) {
        configurationError = error.message?.toString();
      }
    }
    if (prefs.getString(_kTokenInvalidated) == 'true') {
      if (_sessionRevision != revision || _baseUrlRevision != baseUrlRevision) {
        return;
      }
      if (canAssignBaseUrl) {
        _baseUrl = baseUrl;
        _configurationError =
            'Cloud credential was invalidated after interrupted persistence. Please sign in again.';
      }
      _token = null;
      _username = prefs.getString(_kUsername);
      _role = prefs.getString(_kRole);
      return;
    }

    String? token;
    if (baseUrl != null) {
      try {
        token =
            await LegacyTokenMigrator(
              secureStore: _secureStore,
              preferences: prefs,
            ).readAndMigrateToOrigin(
              legacyKey: _kToken,
              serviceUrl: baseUrl,
              canMutate: () => _sessionRevision == revision,
              mutate: _runSessionMutation,
              discardStaleToken: (value) =>
                  _discardStaleMigrationToken(value, baseUrl),
            );
      } on SecureTokenMigrationException {
        // Keep any already-published in-memory session; require reauth only
        // when this load would have been the first assignment.
        if (_sessionRevision == revision &&
            _baseUrlRevision == baseUrlRevision &&
            !isLoggedIn) {
          _token = null;
          if (canAssignBaseUrl) {
            _baseUrl = baseUrl;
            _configurationError = configurationError;
          }
        }
        rethrow;
      }
    }

    final username = prefs.getString(_kUsername);
    final role = prefs.getString(_kRole);

    if (_sessionRevision != revision || _baseUrlRevision != baseUrlRevision) {
      return;
    }
    if (canAssignBaseUrl) {
      _baseUrl = baseUrl;
      _configurationError = configurationError;
    }
    _token = token;
    _username = username;
    _role = role;
  }

  Future<void> setBaseUrl(String url) async {
    final validated = validateHttpsServiceUrl(url);
    final previousBaseUrl = _baseUrl;
    final previousConfigurationError = _configurationError;
    final previousOrigin = previousBaseUrl == null
        ? null
        : normalizedOrigin(previousBaseUrl);
    final nextOrigin = normalizedOrigin(validated);
    final originChanged =
        previousOrigin != null && previousOrigin != nextOrigin;

    if (originChanged) {
      final sessionRevision = ++_sessionRevision;
      final baseUrlRevision = ++_baseUrlRevision;
      final previousToken = _token;
      final previousUsername = _username;
      final previousRole = _role;
      // Invalidate concurrent session work immediately; old-origin secure
      // tokens stay partitioned under their origin key.
      _token = null;
      _username = null;
      _role = null;

      try {
        await _runBaseUrlMutation(() async {
          if (!_ownsBaseUrlRevision(baseUrlRevision)) return;
          final preferences = await _baseUrlPreferences();
          if (!_ownsBaseUrlRevision(baseUrlRevision)) return;
          final previousMetaUsername = preferences.getString(_kUsername);
          final previousMetaRole = preferences.getString(_kRole);
          try {
            await preferences.remove(_kUsername);
            if (!_ownsBaseUrlRevision(baseUrlRevision)) {
              await _restorePreference(
                preferences,
                _kUsername,
                previousMetaUsername,
              );
              await _restorePreference(preferences, _kRole, previousMetaRole);
              return;
            }
            await preferences.remove(_kRole);
            if (!_ownsBaseUrlRevision(baseUrlRevision)) {
              await _restorePreference(
                preferences,
                _kUsername,
                previousMetaUsername,
              );
              await _restorePreference(preferences, _kRole, previousMetaRole);
              return;
            }
            await preferences.setString(_kBase, validated);
            if (!_ownsBaseUrlRevision(baseUrlRevision)) return;
            _baseUrl = validated;
            _configurationError = null;
          } catch (_) {
            try {
              await _restorePreference(
                preferences,
                _kUsername,
                previousMetaUsername,
              );
              await _restorePreference(preferences, _kRole, previousMetaRole);
            } catch (_) {}
            if (_ownsBaseUrlRevision(baseUrlRevision)) {
              _baseUrl = previousBaseUrl;
              _configurationError =
                  previousConfigurationError ??
                  'Cloud server address could not be saved. Please try again.';
            }
            rethrow;
          }
        });
      } catch (error) {
        if (_sessionRevision == sessionRevision) {
          _token = previousToken;
          _username = previousUsername;
          _role = previousRole;
        }
        rethrow;
      }
      return;
    }

    ++_sessionRevision;
    final revision = ++_baseUrlRevision;
    _baseUrl = validated;
    _configurationError = null;
    await _runBaseUrlMutation(
      () => _persistBaseUrlLocked(
        validated: validated,
        expectedRevision: revision,
        previousBaseUrl: previousBaseUrl,
        previousConfigurationError: previousConfigurationError,
      ),
    );
  }

  Future<T> _runBaseUrlMutation<T>(Future<T> Function() operation) {
    final result = _baseUrlMutation
        .catchError((Object _) {})
        .then((_) => operation());
    _baseUrlMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _persistBaseUrlLocked({
    required String validated,
    required int expectedRevision,
    required String? previousBaseUrl,
    required String? previousConfigurationError,
    bool publishEagerly = true,
  }) async {
    if (!_ownsBaseUrlRevision(expectedRevision)) return;
    try {
      final preferences = await _baseUrlPreferences();
      if (!_ownsBaseUrlRevision(expectedRevision)) return;
      await preferences.setString(_kBase, validated);
      // A later revision is queued behind this write and owns the final value.
      if (!_ownsBaseUrlRevision(expectedRevision)) return;
      if (publishEagerly) {
        _baseUrl = validated;
        _configurationError = null;
      }
    } catch (_) {
      if (!_ownsBaseUrlRevision(expectedRevision)) return;
      _baseUrl = previousBaseUrl;
      _configurationError =
          previousConfigurationError ??
          'Cloud server address could not be saved. Please try again.';
      rethrow;
    }
  }

  Future<_CloudSessionSnapshot> _snapshotSession(
    CloudSessionPreferences preferences, {
    String? tokenKey,
  }) async {
    final key = tokenKey ?? _activeTokenKey;
    return _CloudSessionSnapshot(
      token: key == null ? null : await _secureStore.read(key),
      legacyToken: preferences.getString(_kToken),
      username: preferences.getString(_kUsername),
      role: preferences.getString(_kRole),
      tokenKey: key,
    );
  }

  Future<void> _restorePreference(
    CloudSessionPreferences preferences,
    String key,
    String? value,
  ) async {
    if (value == null) {
      await preferences.remove(key);
    } else {
      await preferences.setString(key, value);
    }
  }

  Future<bool> _restoreSecureToken(String? token, {String? tokenKey}) async {
    final key = tokenKey ?? _activeTokenKey;
    if (key == null) return token == null || token.isEmpty;
    try {
      if (token == null || token.isEmpty) {
        await _secureStore.delete(key);
      } else {
        await _secureStore.write(key, token);
      }
      return await _secureStore.read(key) == token;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _deleteStaleToken({String? tokenKey}) async {
    final key = tokenKey ?? _activeTokenKey;
    if (key == null) return true;
    try {
      await _secureStore.delete(key);
      return await _secureStore.read(key) == null;
    } catch (_) {
      return false;
    }
  }

  Future<void> _discardStaleMigrationToken(String token, String? serviceUrl) {
    final key = _tokenKeyFor(serviceUrl);
    return _runSessionMutation(() async {
      if (key == null) return;
      if (await _secureStore.read(key) == token) {
        await _secureStore.delete(key);
      }
    });
  }

  Future<Never> _reportUnrecoverableStaleCredential(
    CloudSessionPreferences preferences, {
    String? tokenKey,
  }) async {
    final deleted = await _deleteStaleToken(tokenKey: tokenKey);
    if (deleted) {
      throw const CloudSessionSafetyError(
        'Cloud session became stale; its credential was removed. Please sign in again.',
      );
    }
    try {
      await preferences.setString(_kTokenInvalidated, 'true');
    } catch (_) {
      throw const CloudSessionSafetyError(
        'Cloud session became stale and could not be secured. Please clear secure storage and sign in again.',
      );
    }
    throw const CloudSessionSafetyError(
      'Cloud session became stale and was invalidated. Please sign in again.',
    );
  }

  Future<void> _restoreMetadata(
    CloudSessionPreferences preferences,
    _CloudSessionSnapshot snapshot,
  ) async {
    for (final entry in [
      (_kToken, snapshot.legacyToken),
      (_kUsername, snapshot.username),
      (_kRole, snapshot.role),
    ]) {
      try {
        await _restorePreference(preferences, entry.$1, entry.$2);
      } catch (_) {
        // Best effort compensation cannot mask the operation that failed.
      }
    }
  }

  Future<void> _syncSessionMemory(
    CloudSessionPreferences preferences, {
    String? tokenKey,
  }) async {
    final key = tokenKey ?? _activeTokenKey;
    try {
      _token = key == null ? null : await _secureStore.read(key);
      _username = preferences.getString(_kUsername);
      _role = preferences.getString(_kRole);
    } catch (_) {
      _token = null;
      _username = null;
      _role = null;
    }
  }

  Future<T> _runSessionMutation<T>(Future<T> Function() operation) {
    final result = _sessionMutation
        .catchError((Object _) {})
        .then((_) => operation());
    _sessionMutation = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> _persistSession({
    required String token,
    required String? username,
    required String? role,
    int? expectedRevision,
  }) {
    return _runSessionMutation(
      () => _persistSessionLocked(
        token: token,
        username: username,
        role: role,
        expectedRevision: expectedRevision,
      ),
    );
  }

  Future<void> _persistSessionLocked({
    required String token,
    required String? username,
    required String? role,
    int? expectedRevision,
  }) async {
    if (token.isEmpty) {
      throw StateError('Cannot persist an empty cloud token');
    }
    if (!_ownsRevision(expectedRevision)) {
      return;
    }
    final previousToken = _token;
    final previousUsername = _username;
    final previousRole = _role;
    final tokenKey = _activeTokenKey;
    if (tokenKey == null) {
      throw StateError('Cannot persist cloud token without a base URL');
    }
    CloudSessionPreferences? preferences;
    _CloudSessionSnapshot? snapshot;
    try {
      preferences = await _sessionPreferences();
      snapshot = await _snapshotSession(preferences, tokenKey: tokenKey);
      if (!_ownsRevision(expectedRevision)) {
        return;
      }
      if (!_ownsRevision(expectedRevision)) return;
      await _secureStore.write(tokenKey, token);
      if (await _secureStore.read(tokenKey) != token) {
        throw StateError('Secure token verification failed');
      }
      if (!_ownsRevision(expectedRevision)) {
        await _reportUnrecoverableStaleCredential(
          preferences,
          tokenKey: tokenKey,
        );
      }
      // If authority moved to a different origin, do not write old-origin
      // metadata into the new base URL's active session prefs.
      if (_tokenKeyFor(_baseUrl) != tokenKey) {
        await _reportUnrecoverableStaleCredential(
          preferences,
          tokenKey: tokenKey,
        );
      }
      await preferences.remove(_kToken);
      if (!_ownsRevision(expectedRevision) ||
          _tokenKeyFor(_baseUrl) != tokenKey) {
        await _reportUnrecoverableStaleCredential(
          preferences,
          tokenKey: tokenKey,
        );
      }
      if (username != null) await preferences.setString(_kUsername, username);
      if (!_ownsRevision(expectedRevision) ||
          _tokenKeyFor(_baseUrl) != tokenKey) {
        await _reportUnrecoverableStaleCredential(
          preferences,
          tokenKey: tokenKey,
        );
      }
      if (role != null) await preferences.setString(_kRole, role);
      if (!_ownsRevision(expectedRevision) ||
          _tokenKeyFor(_baseUrl) != tokenKey) {
        await _reportUnrecoverableStaleCredential(
          preferences,
          tokenKey: tokenKey,
        );
      }
      if (!_ownsRevision(expectedRevision) ||
          _tokenKeyFor(_baseUrl) != tokenKey) {
        return;
      }
      await preferences.remove(_kTokenInvalidated);
      _token = token;
      _username = username;
      _role = role;
    } on CloudSessionSafetyError {
      // Do not re-publish a superseded origin session into memory.
      if (preferences != null && _tokenKeyFor(_baseUrl) == tokenKey) {
        await _syncSessionMemory(preferences, tokenKey: tokenKey);
      }
      rethrow;
    } catch (_) {
      if (preferences != null && snapshot != null) {
        await _restoreSecureToken(snapshot.token, tokenKey: snapshot.tokenKey);
        if (_tokenKeyFor(_baseUrl) == snapshot.tokenKey) {
          await _restoreMetadata(preferences, snapshot);
          await _syncSessionMemory(preferences, tokenKey: snapshot.tokenKey);
        }
      } else if (_tokenKeyFor(_baseUrl) == tokenKey) {
        _token = previousToken;
        _username = previousUsername;
        _role = previousRole;
      }
      rethrow;
    }
  }

  bool _ownsRevision(int? expectedRevision) =>
      expectedRevision == null || _sessionRevision == expectedRevision;

  bool _ownsBaseUrlRevision(int expectedRevision) =>
      _baseUrlRevision == expectedRevision;

  Future<void> _compensateStaleCleanup(
    CloudSessionPreferences preferences,
    _CloudSessionSnapshot snapshot,
  ) async {
    final restored = await _restoreSecureToken(
      snapshot.token,
      tokenKey: snapshot.tokenKey,
    );
    await _restoreMetadata(preferences, snapshot);
    await _syncSessionMemory(preferences, tokenKey: snapshot.tokenKey);
    if (!restored) {
      throw StateError(
        'Cloud session cleanup failed: secure token could not be restored',
      );
    }
  }

  Future<void> clearSession({String? expectedToken, int? expectedRevision}) {
    final revision = expectedRevision ?? ++_sessionRevision;
    return _runSessionMutation(
      () => _clearSessionLocked(
        expectedToken: expectedToken,
        expectedRevision: revision,
      ),
    );
  }

  Future<void> _clearSessionLocked({
    String? expectedToken,
    required int expectedRevision,
  }) async {
    // Capture the origin key before any concurrent authority change.
    final tokenKey = _tokenKeyFor(_baseUrl);
    if (!await _matchesClearExpectation(
      expectedToken,
      expectedRevision,
      tokenKey: tokenKey,
    )) {
      return;
    }
    final preferences = await _sessionPreferences();
    if (!await _matchesClearExpectation(
      expectedToken,
      expectedRevision,
      tokenKey: tokenKey,
    )) {
      return;
    }
    final snapshot = await _snapshotSession(preferences, tokenKey: tokenKey);
    if (!await _matchesClearExpectation(
      expectedToken,
      expectedRevision,
      tokenKey: tokenKey,
    )) {
      return;
    }
    if (tokenKey != null) {
      await _secureStore.delete(tokenKey);
    }
    try {
      if (!await _matchesClearExpectation(
        null,
        expectedRevision,
        tokenKey: tokenKey,
      )) {
        // Origin/session superseded mid-cleanup: leave durable origin partition
        // as-is and do not resurrect old-origin metadata into the new authority.
        if (snapshot.tokenKey != null && snapshot.tokenKey != _activeTokenKey) {
          final restored = await _restoreSecureToken(
            snapshot.token,
            tokenKey: snapshot.tokenKey,
          );
          if (!restored) {
            throw StateError(
              'Cloud session cleanup failed: secure token could not be restored',
            );
          }
          return;
        }
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kToken);
      if (!await _matchesClearExpectation(
        null,
        expectedRevision,
        tokenKey: tokenKey,
      )) {
        if (snapshot.tokenKey != null && snapshot.tokenKey != _activeTokenKey) {
          final restored = await _restoreSecureToken(
            snapshot.token,
            tokenKey: snapshot.tokenKey,
          );
          if (!restored) {
            throw StateError(
              'Cloud session cleanup failed: secure token could not be restored',
            );
          }
          return;
        }
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kUsername);
      if (!await _matchesClearExpectation(
        null,
        expectedRevision,
        tokenKey: tokenKey,
      )) {
        if (snapshot.tokenKey != null && snapshot.tokenKey != _activeTokenKey) {
          final restored = await _restoreSecureToken(
            snapshot.token,
            tokenKey: snapshot.tokenKey,
          );
          if (!restored) {
            throw StateError(
              'Cloud session cleanup failed: secure token could not be restored',
            );
          }
          return;
        }
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kRole);
      if (!await _matchesClearExpectation(
        null,
        expectedRevision,
        tokenKey: tokenKey,
      )) {
        if (snapshot.tokenKey != null && snapshot.tokenKey != _activeTokenKey) {
          final restored = await _restoreSecureToken(
            snapshot.token,
            tokenKey: snapshot.tokenKey,
          );
          if (!restored) {
            throw StateError(
              'Cloud session cleanup failed: secure token could not be restored',
            );
          }
          return;
        }
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      _token = null;
      _username = null;
      _role = null;
    } catch (_) {
      final restored = await _restoreSecureToken(
        snapshot.token,
        tokenKey: snapshot.tokenKey,
      );
      if (snapshot.tokenKey == null || snapshot.tokenKey == _activeTokenKey) {
        await _restoreMetadata(preferences, snapshot);
      }
      if (restored) {
        if (snapshot.tokenKey == null || snapshot.tokenKey == _activeTokenKey) {
          await _syncSessionMemory(preferences, tokenKey: snapshot.tokenKey);
        }
        rethrow;
      }
      if (snapshot.tokenKey == null || snapshot.tokenKey == _activeTokenKey) {
        await _syncSessionMemory(preferences, tokenKey: snapshot.tokenKey);
      }
      throw StateError(
        'Cloud session cleanup failed: secure token could not be restored',
      );
    }
  }

  Future<bool> _matchesClearExpectation(
    String? expectedToken,
    int expectedRevision, {
    String? tokenKey,
  }) async {
    if (_sessionRevision != expectedRevision) return false;
    if (expectedToken == null) return true;
    final key = tokenKey ?? _activeTokenKey;
    if (key == null) return false;
    return await _secureStore.read(key) == expectedToken;
  }

  Options _authOptions() {
    return Options(
      headers: {
        'Content-Type': 'application/json',
        if (_token != null && _baseUrl != null)
          'Authorization': 'Bearer $_token',
      },
    );
  }

  String _url(String path) {
    if (_baseUrl == null || _baseUrl!.isEmpty) {
      throw Exception('未配置服务器地址');
    }
    return '$_baseUrl$path';
  }

  Future<bool> ping() async {
    try {
      final resp = await _dio.get(
        _url('/api/health'),
        options: Options(
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );
      return resp.statusCode == 200;
    } catch (_) {
      try {
        final resp = await _dio.get(_url('/api/ping'));
        return resp.statusCode == 200;
      } catch (_) {
        return false;
      }
    }
  }

  Future<Map<String, dynamic>> login(String username, String password) async {
    final revision = ++_sessionRevision;
    final resp = await _dio.post(
      _url('/api/user/login'),
      data: {'username': username, 'password': password},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(resp.data as Map);
    if (data['token'] == null) {
      throw Exception(data['error']?.toString() ?? '登录失败');
    }
    await _persistSession(
      token: data['token'] as String,
      username: data['username']?.toString() ?? username,
      role: data['role']?.toString() ?? 'user',
      expectedRevision: revision,
    );
    return data;
  }

  Future<Map<String, dynamic>> register(
    String username,
    String password,
  ) async {
    final revision = ++_sessionRevision;
    final resp = await _dio.post(
      _url('/api/user/register'),
      data: {'username': username, 'password': password},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(resp.data as Map);
    if (data['token'] == null) {
      throw Exception(data['error']?.toString() ?? '注册失败');
    }
    await _persistSession(
      token: data['token'] as String,
      username: data['username']?.toString() ?? username,
      role: data['role']?.toString() ?? 'user',
      expectedRevision: revision,
    );
    return data;
  }

  Future<CloudVerification> verify() async {
    if (!isLoggedIn) return CloudVerification.noSession;
    final token = _token!;
    final revision = _sessionRevision;
    try {
      final resp = await _dio.get(
        _url('/api/user/auth/verify'),
        options: _authOptions(),
      );
      final data = resp.data;
      if (data is Map && data['valid'] == true) {
        await _persistSession(
          token: token,
          username: data['username']?.toString() ?? _username,
          role: data['role']?.toString() ?? _role,
          expectedRevision: revision,
        );
        return CloudVerification.valid;
      }
      return CloudVerification.unavailable;
    } on CloudSessionSafetyError {
      rethrow;
    } on DioException catch (error) {
      return error.response?.statusCode == 401
          ? CloudVerification.unauthorized
          : CloudVerification.unavailable;
    } catch (_) {
      return CloudVerification.unavailable;
    }
  }

  Future<Map<String, dynamic>> fetchUserList() async {
    final resp = await _dio.get(
      _url('/api/user/list'),
      options: _authOptions(),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// Stores the merged cloud snapshot. The server upserts every playlist, so
  /// callers must fetch and merge before saving to avoid losing another device's
  /// additions.
  Future<void> saveUserList({
    required List<Map<String, dynamic>> loveList,
    required List<Map<String, dynamic>> userList,
  }) async {
    await _dio.post(
      _url('/api/user/list'),
      data: {'loveList': loveList, 'userList': userList},
      options: _authOptions(),
    );
  }

  /// Phase1 preview: {songs, name, source, listId}
  Future<Map<String, dynamic>> importPlaylistPreview({
    required String urlOrId,
    String? platform,
  }) async {
    final resp = await _dio.post(
      _url('/api/music/playlist/import'),
      data: {'url': urlOrId, if (platform != null) 'platform': platform},
      options: _authOptions(),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// Phase2 save
  Future<Map<String, dynamic>> importPlaylistSave({
    required String name,
    required String source,
    required String sourceId,
    required List songs,
  }) async {
    final resp = await _dio.post(
      _url('/api/music/playlist/import'),
      data: {
        'name': name,
        'source': source,
        'sourceId': sourceId,
        'songs': songs,
      },
      options: _authOptions(),
    );
    return Map<String, dynamic>.from(resp.data as Map);
  }

  Future<List<Map<String, dynamic>>> adminListUsers() async {
    final resp = await _dio.get(
      _url('/api/admin/users'),
      options: _authOptions(),
    );
    final data = resp.data;
    if (data is Map && data['users'] is List) {
      return (data['users'] as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  Future<void> adminCreateUser(String username, String password) async {
    await _dio.post(
      _url('/api/admin/users'),
      data: {'username': username, 'password': password},
      options: _authOptions(),
    );
  }

  Future<void> adminDeleteUser(int id) async {
    await _dio.delete(
      _url('/api/admin/users'),
      data: {'id': id},
      options: _authOptions(),
    );
  }

  Future<void> adminResetPassword(int id, String password) async {
    await _dio.put(
      _url('/api/admin/users'),
      data: {'id': id, 'password': password},
      options: _authOptions(),
    );
  }

  Future<void> deletePlaylist(String id) async {
    await _dio.delete(
      _url('/api/user/playlist'),
      queryParameters: {'id': id},
      options: _authOptions(),
    );
  }
}
