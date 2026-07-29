import 'dart:async';

import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/storage/secure_token_store.dart';
import '../../../core/network/outbound_url.dart';

/// 对接 workers/ 子项目（lx-music-api）的客户端。
enum CloudVerification { valid, unauthorized, unavailable, noSession }

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
  });

  final String? token;
  final String? legacyToken;
  final String? username;
  final String? role;
}

class CloudApiClient {
  static const _kBase = 'cloud_api_base';
  static const _kToken = 'cloud_api_token';
  static const _kUsername = 'cloud_api_username';
  static const _kRole = 'cloud_api_role';

  final Dio _dio;
  final SecureTokenStore _secureStore;
  final Future<SharedPreferences> Function() _preferences;
  final Future<CloudSessionPreferences> Function() _sessionPreferences;

  String? _baseUrl;
  String? _token;
  String? _username;
  String? _role;
  String? _configurationError;
  int _sessionRevision = 0;
  Future<void> _sessionMutation = Future.value();

  CloudApiClient({
    Dio? dio,
    SecureTokenStore? secureStore,
    Future<SharedPreferences> Function()? preferences,
    Future<CloudSessionPreferences> Function()? sessionPreferences,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'Content-Type': 'application/json'},
            )),
        _secureStore = secureStore ?? FlutterSecureTokenStore(),
        _preferences = preferences ?? SharedPreferences.getInstance,
        _sessionPreferences = sessionPreferences ??
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

  Future<void> load() async {
    final revision = _sessionRevision;
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
    final token = await LegacyTokenMigrator(
      secureStore: _secureStore,
      preferences: prefs,
    ).readAndMigrate(_kToken);
    final username = prefs.getString(_kUsername);
    final role = prefs.getString(_kRole);

    if (_sessionRevision != revision) return;
    _baseUrl = baseUrl;
    _configurationError = configurationError;
    _token = token;
    _username = username;
    _role = role;
  }

  Future<void> setBaseUrl(String url) async {
    final validated = validateHttpsServiceUrl(url);
    _sessionRevision++;
    _baseUrl = validated;
    _configurationError = null;
    final prefs = await _preferences();
    await prefs.setString(_kBase, validated);
  }

  Future<_CloudSessionSnapshot> _snapshotSession(
      CloudSessionPreferences preferences) async {
    return _CloudSessionSnapshot(
      token: await _secureStore.read(_kToken),
      legacyToken: preferences.getString(_kToken),
      username: preferences.getString(_kUsername),
      role: preferences.getString(_kRole),
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

  Future<bool> _restoreSecureToken(String? token) async {
    try {
      if (token == null || token.isEmpty) {
        await _secureStore.delete(_kToken);
      } else {
        await _secureStore.write(_kToken, token);
      }
      return await _secureStore.read(_kToken) == token;
    } catch (_) {
      return false;
    }
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

  Future<void> _syncSessionMemory(CloudSessionPreferences preferences) async {
    try {
      _token = await _secureStore.read(_kToken);
      _username = preferences.getString(_kUsername);
      _role = preferences.getString(_kRole);
    } catch (_) {
      _token = null;
      _username = null;
      _role = null;
    }
  }

  Future<T> _runSessionMutation<T>(Future<T> Function() operation) {
    final previous = _sessionMutation;
    final completed = Completer<void>();
    _sessionMutation = completed.future;
    return previous.then((_) => operation()).whenComplete(completed.complete);
  }

  Future<void> _persistSession({
    required String token,
    required String? username,
    required String? role,
    int? expectedRevision,
  }) {
    return _runSessionMutation(() => _persistSessionLocked(
          token: token,
          username: username,
          role: role,
          expectedRevision: expectedRevision,
        ));
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
    if (expectedRevision != null && _sessionRevision != expectedRevision) {
      return;
    }
    final previousToken = _token;
    final previousUsername = _username;
    final previousRole = _role;
    CloudSessionPreferences? preferences;
    _CloudSessionSnapshot? snapshot;
    try {
      preferences = await _sessionPreferences();
      snapshot = await _snapshotSession(preferences);
      if (expectedRevision != null && _sessionRevision != expectedRevision) {
        return;
      }
      await _secureStore.write(_kToken, token);
      if (await _secureStore.read(_kToken) != token) {
        throw StateError('Secure token verification failed');
      }
      await preferences.remove(_kToken);
      if (username != null) await preferences.setString(_kUsername, username);
      if (role != null) await preferences.setString(_kRole, role);
      if (expectedRevision != null && _sessionRevision != expectedRevision) {
        final restored = await _restoreSecureToken(snapshot.token);
        await _restoreMetadata(preferences, snapshot);
        await _syncSessionMemory(preferences);
        if (!restored) {
          throw StateError(
            'Cloud session persistence became stale and could not be restored',
          );
        }
        return;
      }
      _token = token;
      _username = username;
      _role = role;
    } catch (_) {
      if (preferences != null && snapshot != null) {
        await _restoreSecureToken(snapshot.token);
        await _restoreMetadata(preferences, snapshot);
        await _syncSessionMemory(preferences);
      } else {
        _token = previousToken;
        _username = previousUsername;
        _role = previousRole;
      }
      rethrow;
    }
  }

  Future<void> _compensateStaleCleanup(
    CloudSessionPreferences preferences,
    _CloudSessionSnapshot snapshot,
  ) async {
    final restored = await _restoreSecureToken(snapshot.token);
    await _restoreMetadata(preferences, snapshot);
    await _syncSessionMemory(preferences);
    if (!restored) {
      throw StateError(
        'Cloud session cleanup failed: secure token could not be restored',
      );
    }
  }

  Future<void> clearSession({String? expectedToken, int? expectedRevision}) {
    final revision = expectedRevision ?? ++_sessionRevision;
    return _runSessionMutation(() => _clearSessionLocked(
          expectedToken: expectedToken,
          expectedRevision: revision,
        ));
  }

  Future<void> _clearSessionLocked({
    String? expectedToken,
    required int expectedRevision,
  }) async {
    if (!await _matchesClearExpectation(expectedToken, expectedRevision)) {
      return;
    }
    final preferences = await _sessionPreferences();
    if (!await _matchesClearExpectation(expectedToken, expectedRevision)) {
      return;
    }
    final snapshot = await _snapshotSession(preferences);
    if (!await _matchesClearExpectation(expectedToken, expectedRevision)) {
      return;
    }
    await _secureStore.delete(_kToken);
    try {
      if (!await _matchesClearExpectation(null, expectedRevision)) {
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kToken);
      if (!await _matchesClearExpectation(null, expectedRevision)) {
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kUsername);
      if (!await _matchesClearExpectation(null, expectedRevision)) {
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      await preferences.remove(_kRole);
      if (!await _matchesClearExpectation(null, expectedRevision)) {
        await _compensateStaleCleanup(preferences, snapshot);
        return;
      }
      _token = null;
      _username = null;
      _role = null;
    } catch (_) {
      final restored = await _restoreSecureToken(snapshot.token);
      await _restoreMetadata(preferences, snapshot);
      if (restored) {
        await _syncSessionMemory(preferences);
        rethrow;
      }
      await _syncSessionMemory(preferences);
      throw StateError(
        'Cloud session cleanup failed: secure token could not be restored',
      );
    }
  }

  Future<bool> _matchesClearExpectation(
    String? expectedToken,
    int expectedRevision,
  ) async {
    if (_sessionRevision != expectedRevision) return false;
    return expectedToken == null ||
        await _secureStore.read(_kToken) == expectedToken;
  }

  Options _authOptions() {
    return Options(headers: {
      'Content-Type': 'application/json',
      if (_token != null) 'Authorization': 'Bearer $_token',
    });
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
      String username, String password) async {
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
    try {
      final resp = await _dio.get(_url('/api/user/auth/verify'),
          options: _authOptions());
      final data = resp.data;
      if (data is Map && data['valid'] == true) {
        try {
          await _persistSession(
            token: _token!,
            username: data['username']?.toString() ?? _username,
            role: data['role']?.toString() ?? _role,
          );
        } catch (_) {
          return CloudVerification.unavailable;
        }
        return CloudVerification.valid;
      }
      return CloudVerification.unavailable;
    } on DioException catch (error) {
      return error.response?.statusCode == 401
          ? CloudVerification.unauthorized
          : CloudVerification.unavailable;
    } catch (_) {
      return CloudVerification.unavailable;
    }
  }

  Future<Map<String, dynamic>> fetchUserList() async {
    final resp =
        await _dio.get(_url('/api/user/list'), options: _authOptions());
    return Map<String, dynamic>.from(resp.data as Map);
  }

  /// Phase1 preview: {songs, name, source, listId}
  Future<Map<String, dynamic>> importPlaylistPreview({
    required String urlOrId,
    String? platform,
  }) async {
    final resp = await _dio.post(
      _url('/api/music/playlist/import'),
      data: {
        'url': urlOrId,
        if (platform != null) 'platform': platform,
      },
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
    final resp =
        await _dio.get(_url('/api/admin/users'), options: _authOptions());
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
