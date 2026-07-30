import 'dart:async';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/storage/secure_token_store.dart';
import '../../playlist/domain/playlist.dart';
import '../../player/domain/music_item.dart';
import '../../../core/network/outbound_url.dart';

enum SyncStatus {
  disconnected,
  connecting,
  connected,
  syncing,
  synced,
  error,
}

class SyncConflict {
  final String entityType;
  final String entityId;
  final dynamic localValue;
  final dynamic remoteValue;
  final DateTime localTimestamp;
  final DateTime remoteTimestamp;

  const SyncConflict({
    required this.entityType,
    required this.entityId,
    required this.localValue,
    required this.remoteValue,
    required this.localTimestamp,
    required this.remoteTimestamp,
  });
}

class SyncDeadlines {
  final Duration connect;
  final Duration send;
  final Duration receive;
  final Duration total;

  const SyncDeadlines({
    this.connect = const Duration(seconds: 5),
    this.send = const Duration(seconds: 10),
    this.receive = const Duration(seconds: 15),
    this.total = const Duration(seconds: 25),
  });
}

/// HTTPS 同步服务，参考桌面版 lx-music-sync-server 协议。
class SyncService {
  final Dio _dio;
  final SecureTokenStore _secureStore;
  final Future<SharedPreferences> Function() _preferences;
  final SyncDeadlines _deadlines;
  String? _serverUrl;
  String? _token;
  DateTime? _lastSyncTime;

  SyncStatus _status = SyncStatus.disconnected;
  SyncStatus get status => _status;
  String? get serverUrl => _serverUrl;
  bool get isConnected =>
      _status == SyncStatus.connected || _status == SyncStatus.synced;

  final StreamController<SyncStatus> _statusController =
      StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _statusController.stream;

  int _sessionGeneration = 0;
  int _operationGeneration = 0;
  CancelToken? _activeCancelToken;
  bool _disposed = false;

  int get sessionGeneration => _sessionGeneration;
  int get operationGeneration => _operationGeneration;

  SyncService({
    Dio? dio,
    SecureTokenStore? secureStore,
    Future<SharedPreferences> Function()? preferences,
    SyncDeadlines deadlines = const SyncDeadlines(),
  })  : _dio = dio ?? Dio(),
        _secureStore = secureStore ?? FlutterSecureTokenStore(),
        _preferences = preferences ?? SharedPreferences.getInstance,
        _deadlines = deadlines;

  // ---- 连接管理 ----

  /// 连接到同步服务器（HTTPS 健康检查）
  Future<bool> connect(String serverUrl, {String? token}) async {
    final validatedUrl = validateHttpsServiceUrl(serverUrl);
    cancelActiveOperation('connect');
    _sessionGeneration++;
    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    final previousOrigin =
        _serverUrl == null ? null : normalizedOrigin(_serverUrl!);
    final nextOrigin = normalizedOrigin(validatedUrl);
    final originChanged =
        previousOrigin != null && previousOrigin != nextOrigin;

    _serverUrl = validatedUrl;
    if (token != null) {
      _token = token;
    } else if (originChanged) {
      _token = null;
    }
    if (_owns(session, op, cancelToken)) {
      _updateStatus(SyncStatus.connecting);
    }
    try {
      final response = await _request(
        () => _dio.get(
          '$_serverUrl/api/health',
          options: _options(headers: _getHeaders()),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return false;
      if (response.statusCode == 200) {
        _updateStatus(SyncStatus.connected);
        return true;
      }
      _updateStatus(SyncStatus.error);
      return false;
    } on TimeoutException {
      return _publishTimeoutError(session, op);
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return false;
      if (_isCancellation(e)) return false;
      _updateStatus(SyncStatus.error);
      return false;
    }
  }

  /// 断开连接
  void disconnect() {
    cancelActiveOperation('disconnect');
    _sessionGeneration++;
    _serverUrl = null;
    _token = null;
    _updateStatus(SyncStatus.disconnected);
  }

  // ---- HTTP 同步 API ----

  /// 推送数据到服务器
  Future<bool> push({
    required List<Playlist> playlists,
    required List<MusicItem> history,
  }) async {
    if (_serverUrl == null) return false;

    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    try {
      if (_owns(session, op, cancelToken)) {
        _updateStatus(SyncStatus.syncing);
      }

      final payload = {
        'playlists': playlists.map((p) => _playlistToJson(p)).toList(),
        'history': history.map((m) => _musicItemToJson(m)).toList(),
        'timestamp': DateTime.now().toIso8601String(),
      };

      final response = await _request(
        () => _dio.post(
          '$_serverUrl/api/sync/push',
          data: payload,
          options: _options(headers: _getHeaders()),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return false;
      if (response.statusCode == 200) {
        _lastSyncTime = DateTime.now();
        _updateStatus(SyncStatus.synced);
        return true;
      }
      return false;
    } on TimeoutException {
      return _publishTimeoutError(session, op);
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return false;
      if (_isCancellation(e)) return false;
      _updateStatus(SyncStatus.error);
      return false;
    }
  }

  /// 从服务器拉取数据
  Future<Map<String, dynamic>?> pull({DateTime? lastSyncTime}) async {
    if (_serverUrl == null) return null;

    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    try {
      if (_owns(session, op, cancelToken)) {
        _updateStatus(SyncStatus.syncing);
      }

      final response = await _request(
        () => _dio.get(
          '$_serverUrl/api/sync/pull',
          queryParameters: {
            if (lastSyncTime != null)
              'lastSyncTime': lastSyncTime.toIso8601String(),
          },
          options: _options(headers: _getHeaders()),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return null;
      if (response.statusCode == 200) {
        _lastSyncTime = DateTime.now();
        _updateStatus(SyncStatus.synced);
        return response.data is Map<String, dynamic>
            ? response.data as Map<String, dynamic>
            : Map<String, dynamic>.from(response.data as Map);
      }
      return null;
    } on TimeoutException {
      _publishTimeoutError(session, op);
      return null;
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return null;
      if (_isCancellation(e)) return null;
      _updateStatus(SyncStatus.error);
      return null;
    }
  }

  /// 获取同步列表（查看服务端有哪些同步快照）
  Future<List<Map<String, dynamic>>?> listSnapshots() async {
    if (_serverUrl == null) return null;

    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    try {
      final response = await _request(
        () => _dio.get(
          '$_serverUrl/api/sync/list',
          options: _options(headers: _getHeaders()),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return null;
      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List).cast<Map<String, dynamic>>();
      }
      return null;
    } on TimeoutException {
      return null;
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return null;
      if (_isCancellation(e)) return null;
      return null;
    }
  }

  DateTime? get lastSyncTime => _lastSyncTime;

  // ---- 认证 ----

  Future<bool> login(String username, String password) async {
    if (_serverUrl == null) return false;

    cancelActiveOperation('login');
    _sessionGeneration++;
    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    try {
      final response = await _request(
        () => _dio.post(
          '$_serverUrl/api/auth/login',
          data: {'username': username, 'password': password},
          options: _options(),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return false;
      if (response.statusCode == 200) {
        final token = response.data['token'] as String;
        await _saveToken(token);
        if (!_owns(session, op, cancelToken)) return false;
        _token = token;
        return true;
      }
      return false;
    } on TimeoutException {
      return false;
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return false;
      if (_isCancellation(e)) return false;
      return false;
    }
  }

  Future<bool> register(String username, String password) async {
    if (_serverUrl == null) return false;

    cancelActiveOperation('register');
    _sessionGeneration++;
    final session = _sessionGeneration;
    final op = _beginOperation();
    final cancelToken = _activeCancelToken!;

    try {
      final response = await _request(
        () => _dio.post(
          '$_serverUrl/api/auth/register',
          data: {'username': username, 'password': password},
          options: _options(),
          cancelToken: cancelToken,
        ),
        cancelToken,
      );

      if (!_owns(session, op, cancelToken)) return false;
      return response.statusCode == 201;
    } on TimeoutException {
      return false;
    } catch (e) {
      if (!_owns(session, op, cancelToken)) return false;
      if (_isCancellation(e)) return false;
      return false;
    }
  }

  // ---- Token 持久化 ----

  String? _tokenKeyFor(String? serviceUrl) {
    if (serviceUrl == null || serviceUrl.isEmpty) return null;
    try {
      return originTokenKey('sync_token', serviceUrl);
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToken(String token) async {
    final key = _tokenKeyFor(_serverUrl);
    if (key == null) {
      throw StateError('Cannot persist sync token without a server URL');
    }
    await _secureStore.write(key, token);
    if (await _secureStore.read(key) != token) {
      throw StateError('Secure token verification failed');
    }
  }

  Future<String?> loadSavedToken({String? serverUrl}) async {
    final preferences = await _preferences();
    final rawUrl = serverUrl ??
        preferences.getString('sync_server_url') ??
        _serverUrl;
    if (rawUrl == null || rawUrl.isEmpty) return null;
    final validated = validateHttpsServiceUrl(rawUrl);
    final migrator = LegacyTokenMigrator(
      secureStore: _secureStore,
      preferences: preferences,
    );
    return migrator.readAndMigrateToOrigin(
      legacyKey: 'sync_token',
      serviceUrl: validated,
    );
  }

  Future<void> forgetSavedToken({String? serverUrl}) async {
    final preferences = await _preferences();
    final rawUrl = serverUrl ??
        preferences.getString('sync_server_url') ??
        _serverUrl;
    Object? secureError;
    if (rawUrl != null && rawUrl.isNotEmpty) {
      try {
        final key = originTokenKey(
          'sync_token',
          validateHttpsServiceUrl(rawUrl),
        );
        await _secureStore.delete(key);
      } catch (error) {
        secureError = error;
      }
    }
    try {
      await _secureStore.delete('sync_token');
    } catch (error) {
      secureError ??= error;
    }
    if (secureError != null) {
      Error.throwWithStackTrace(
        secureError,
        StackTrace.current,
      );
    }
    await preferences.remove('sync_token');
  }

  // ---- 工具方法 ----

  void cancelActiveOperation([String reason = 'cancelled']) {
    final token = _activeCancelToken;
    if (token != null && !token.isCancelled) {
      token.cancel(reason);
    }
    _activeCancelToken = null;
    _operationGeneration++;
  }

  int _beginOperation() {
    cancelActiveOperation('superseded');
    final token = CancelToken();
    _activeCancelToken = token;
    return _operationGeneration;
  }

  bool _owns(int session, int operation, CancelToken token) =>
      !_disposed &&
      session == _sessionGeneration &&
      operation == _operationGeneration &&
      identical(token, _activeCancelToken) &&
      !token.isCancelled;

  bool _generationCurrent(int session, int operation) =>
      !_disposed &&
      session == _sessionGeneration &&
      operation == _operationGeneration;

  Options _options({Map<String, dynamic>? headers}) {
    return Options(
      headers: headers,
      connectTimeout: _deadlines.connect,
      sendTimeout: _deadlines.send,
      receiveTimeout: _deadlines.receive,
    );
  }

  Future<Response<dynamic>> _request(
    Future<Response<dynamic>> Function() run,
    CancelToken cancelToken,
  ) {
    return run().timeout(_deadlines.total, onTimeout: () {
      cancelToken.cancel('sync total deadline exceeded');
      throw TimeoutException(
          'sync total deadline exceeded', _deadlines.total);
    });
  }

  bool _isCancellation(Object e) {
    if (e is DioException && CancelToken.isCancel(e)) return true;
    return false;
  }

  bool _publishTimeoutError(int session, int operation) {
    if (_generationCurrent(session, operation)) {
      _updateStatus(SyncStatus.error);
    }
    return false;
  }

  Map<String, String> _getHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }

  void _updateStatus(SyncStatus status) {
    _status = status;
    if (!_statusController.isClosed) {
      _statusController.add(status);
    }
  }

  Map<String, dynamic> _playlistToJson(Playlist playlist) {
    return {
      'id': playlist.id,
      'name': playlist.name,
      'description': playlist.description,
      'songs': playlist.songs.map((s) => _musicItemToJson(s)).toList(),
      'createdAt': playlist.createdAt.toIso8601String(),
      'updatedAt': playlist.updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> _musicItemToJson(MusicItem music) {
    return {
      'id': music.id,
      'name': music.name,
      'singer': music.singer,
      'album': music.album,
      'duration': music.duration.inSeconds,
      'source': music.source,
      'artwork': music.artwork,
    };
  }

  void dispose() {
    if (_disposed) return;
    cancelActiveOperation('dispose');
    _sessionGeneration++;
    _disposed = true;
    _statusController.close();
    _dio.close();
  }
}
