import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 对接 workers/ 子项目（lx-music-api）的客户端。
class CloudApiClient {
  static const _kBase = 'cloud_api_base';
  static const _kToken = 'cloud_api_token';
  static const _kUsername = 'cloud_api_username';
  static const _kRole = 'cloud_api_role';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 12),
    receiveTimeout: const Duration(seconds: 30),
    headers: {'Content-Type': 'application/json'},
  ));

  String? _baseUrl;
  String? _token;
  String? _username;
  String? _role;

  String? get baseUrl => _baseUrl;
  String? get token => _token;
  String? get username => _username;
  String? get role => _role;
  bool get isLoggedIn => _token != null && _token!.isNotEmpty && _baseUrl != null;
  bool get isAdmin => _role == 'admin';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_kBase);
    _token = prefs.getString(_kToken);
    _username = prefs.getString(_kUsername);
    _role = prefs.getString(_kRole);
  }

  Future<void> setBaseUrl(String url) async {
    _baseUrl = url.replaceAll(RegExp(r'/+$'), '');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBase, _baseUrl!);
  }

  Future<void> _persistSession() async {
    final prefs = await SharedPreferences.getInstance();
    if (_token != null) await prefs.setString(_kToken, _token!);
    if (_username != null) await prefs.setString(_kUsername, _username!);
    if (_role != null) await prefs.setString(_kRole, _role!);
  }

  Future<void> clearSession() async {
    _token = null;
    _username = null;
    _role = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kToken);
    await prefs.remove(_kUsername);
    await prefs.remove(_kRole);
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
    _token = data['token'] as String;
    _username = data['username']?.toString() ?? username;
    _role = data['role']?.toString() ?? 'user';
    await _persistSession();
    return data;
  }

  Future<Map<String, dynamic>> register(String username, String password) async {
    final resp = await _dio.post(
      _url('/api/user/register'),
      data: {'username': username, 'password': password},
      options: Options(headers: {'Content-Type': 'application/json'}),
    );
    final data = Map<String, dynamic>.from(resp.data as Map);
    if (data['token'] == null) {
      throw Exception(data['error']?.toString() ?? '注册失败');
    }
    _token = data['token'] as String;
    _username = data['username']?.toString() ?? username;
    _role = data['role']?.toString() ?? 'user';
    await _persistSession();
    return data;
  }

  Future<bool> verify() async {
    if (!isLoggedIn) return false;
    try {
      final resp = await _dio.get(_url('/api/user/auth/verify'), options: _authOptions());
      final data = resp.data;
      if (data is Map && data['valid'] == true) {
        if (data['role'] != null) _role = data['role'].toString();
        if (data['username'] != null) _username = data['username'].toString();
        await _persistSession();
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> fetchUserList() async {
    final resp = await _dio.get(_url('/api/user/list'), options: _authOptions());
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
    final resp = await _dio.get(_url('/api/admin/users'), options: _authOptions());
    final data = resp.data;
    if (data is Map && data['users'] is List) {
      return (data['users'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
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
