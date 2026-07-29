import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/storage/secure_token_store.dart';
import '../../../core/network/outbound_url.dart';

/// 对接 workers/ 子项目（lx-music-api）的客户端。
enum CloudVerification { valid, unauthorized, unavailable, noSession }

class CloudApiClient {
  static const _kBase = 'cloud_api_base';
  static const _kToken = 'cloud_api_token';
  static const _kUsername = 'cloud_api_username';
  static const _kRole = 'cloud_api_role';

  final Dio _dio;
  final SecureTokenStore _secureStore;
  final Future<SharedPreferences> Function() _preferences;

  String? _baseUrl;
  String? _token;
  String? _username;
  String? _role;
  String? _configurationError;

  CloudApiClient({
    Dio? dio,
    SecureTokenStore? secureStore,
    Future<SharedPreferences> Function()? preferences,
  })  : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 30),
              headers: {'Content-Type': 'application/json'},
            )),
        _secureStore = secureStore ?? FlutterSecureTokenStore(),
        _preferences = preferences ?? SharedPreferences.getInstance;

  String? get baseUrl => _baseUrl;
  String? get token => _token;
  String? get username => _username;
  String? get role => _role;
  String? get configurationError => _configurationError;
  bool get isLoggedIn =>
      _token != null && _token!.isNotEmpty && _baseUrl != null;
  bool get isAdmin => _role == 'admin';

  Future<void> load() async {
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

    _baseUrl = baseUrl;
    _configurationError = configurationError;
    _token = token;
    _username = username;
    _role = role;
  }

  Future<void> setBaseUrl(String url) async {
    final validated = validateHttpsServiceUrl(url);
    _baseUrl = validated;
    _configurationError = null;
    final prefs = await _preferences();
    await prefs.setString(_kBase, validated);
  }

  Future<void> _persistSession() async {
    final token = _token;
    if (token == null || token.isEmpty) {
      throw StateError('Cannot persist an empty cloud token');
    }
    await _secureStore.write(_kToken, token);
    if (await _secureStore.read(_kToken) != token) {
      throw StateError('Secure token verification failed');
    }
    final prefs = await _preferences();
    await prefs.remove(_kToken);
    if (_username != null) await prefs.setString(_kUsername, _username!);
    if (_role != null) await prefs.setString(_kRole, _role!);
  }

  Future<void> clearSession() async {
    await _secureStore.delete(_kToken);
    final prefs = await _preferences();
    await prefs.remove(_kToken);
    await prefs.remove(_kUsername);
    await prefs.remove(_kRole);
    _token = null;
    _username = null;
    _role = null;
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
    final resp = await _dio.post(
      _url('/api/user/login'),
      data: {'username': username, 'password': password},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(resp.data as Map);
    if (data['token'] == null) {
      throw Exception(data['error']?.toString() ?? '登录失败');
    }
    final previousToken = _token;
    final previousUsername = _username;
    final previousRole = _role;
    _token = data['token'] as String;
    _username = data['username']?.toString() ?? username;
    _role = data['role']?.toString() ?? 'user';
    try {
      await _persistSession();
    } catch (_) {
      _token = previousToken;
      _username = previousUsername;
      _role = previousRole;
      rethrow;
    }
    return data;
  }

  Future<Map<String, dynamic>> register(
      String username, String password) async {
    final resp = await _dio.post(
      _url('/api/user/register'),
      data: {'username': username, 'password': password},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(resp.data as Map);
    if (data['token'] == null) {
      throw Exception(data['error']?.toString() ?? '注册失败');
    }
    final previousToken = _token;
    final previousUsername = _username;
    final previousRole = _role;
    _token = data['token'] as String;
    _username = data['username']?.toString() ?? username;
    _role = data['role']?.toString() ?? 'user';
    try {
      await _persistSession();
    } catch (_) {
      _token = previousToken;
      _username = previousUsername;
      _role = previousRole;
      rethrow;
    }
    return data;
  }

  Future<CloudVerification> verify() async {
    if (!isLoggedIn) return CloudVerification.noSession;
    try {
      final resp = await _dio.get(_url('/api/user/auth/verify'),
          options: _authOptions());
      final data = resp.data;
      if (data is Map && data['valid'] == true) {
        final previousUsername = _username;
        final previousRole = _role;
        _role = data['role']?.toString() ?? _role;
        _username = data['username']?.toString() ?? _username;
        try {
          await _persistSession();
        } catch (_) {
          _username = previousUsername;
          _role = previousRole;
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
