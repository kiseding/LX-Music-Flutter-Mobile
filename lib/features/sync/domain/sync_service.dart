import 'dart:async';
import 'package:dio/dio.dart';
import '../../playlist/domain/playlist.dart';
import '../../player/domain/music_item.dart';
import '../../../core/storage/storage_service.dart';

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

/// 纯 HTTP 同步服务，参考桌面版 lx-music-sync-server 协议
class SyncService {
  final Dio _dio = Dio();
  String? _serverUrl;
  String? _token;
  DateTime? _lastSyncTime;

  SyncStatus _status = SyncStatus.disconnected;
  SyncStatus get status => _status;
  String? get serverUrl => _serverUrl;
  bool get isConnected => _status == SyncStatus.connected || _status == SyncStatus.synced;

  final StreamController<SyncStatus> _statusController = StreamController<SyncStatus>.broadcast();
  Stream<SyncStatus> get statusStream => _statusController.stream;

  // ---- 连接管理 ----

  /// 连接到同步服务器（HTTP 健康检查）
  Future<bool> connect(String serverUrl, {String? token}) async {
    try {
      _serverUrl = serverUrl.replaceAll(RegExp(r'/+$'), '');
      _token = token;
      _updateStatus(SyncStatus.connecting);

      final response = await _dio.get(
        '$_serverUrl/api/health',
        options: Options(
          headers: _getHeaders(),
          sendTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 5),
        ),
      );

      if (response.statusCode == 200) {
        _updateStatus(SyncStatus.connected);
        return true;
      }
      _updateStatus(SyncStatus.error);
      return false;
    } catch (e) {
      _updateStatus(SyncStatus.error);
      return false;
    }
  }

  /// 断开连接
  void disconnect() {
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

    try {
      _updateStatus(SyncStatus.syncing);

      final payload = {
        'playlists': playlists.map((p) => _playlistToJson(p)).toList(),
        'history': history.map((m) => _musicItemToJson(m)).toList(),
        'timestamp': DateTime.now().toIso8601String(),
      };

      final response = await _dio.post(
        '$_serverUrl/api/sync/push',
        data: payload,
        options: Options(headers: _getHeaders()),
      );

      if (response.statusCode == 200) {
        _lastSyncTime = DateTime.now();
        _updateStatus(SyncStatus.synced);
        return true;
      }
      return false;
    } catch (e) {
      _updateStatus(SyncStatus.error);
      return false;
    }
  }

  /// 从服务器拉取数据
  Future<Map<String, dynamic>?> pull({DateTime? lastSyncTime}) async {
    if (_serverUrl == null) return null;

    try {
      _updateStatus(SyncStatus.syncing);

      final response = await _dio.get(
        '$_serverUrl/api/sync/pull',
        queryParameters: {
          if (lastSyncTime != null) 'lastSyncTime': lastSyncTime.toIso8601String(),
        },
        options: Options(headers: _getHeaders()),
      );

      if (response.statusCode == 200) {
        _lastSyncTime = DateTime.now();
        _updateStatus(SyncStatus.synced);
        return response.data;
      }
      return null;
    } catch (e) {
      _updateStatus(SyncStatus.error);
      return null;
    }
  }

  /// 获取同步列表（查看服务端有哪些同步快照）
  Future<List<Map<String, dynamic>>?> listSnapshots() async {
    if (_serverUrl == null) return null;

    try {
      final response = await _dio.get(
        '$_serverUrl/api/sync/list',
        options: Options(headers: _getHeaders()),
      );

      if (response.statusCode == 200 && response.data is List) {
        return (response.data as List).cast<Map<String, dynamic>>();
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  DateTime? get lastSyncTime => _lastSyncTime;

  // ---- 认证 ----

  Future<bool> login(String username, String password) async {
    if (_serverUrl == null) return false;

    try {
      final response = await _dio.post(
        '$_serverUrl/api/auth/login',
        data: {'username': username, 'password': password},
      );

      if (response.statusCode == 200) {
        _token = response.data['token'];
        await _saveToken(_token!);
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  Future<bool> register(String username, String password) async {
    if (_serverUrl == null) return false;

    try {
      final response = await _dio.post(
        '$_serverUrl/api/auth/register',
        data: {'username': username, 'password': password},
      );
      return response.statusCode == 201;
    } catch (e) {
      return false;
    }
  }

  // ---- Token 持久化 ----

  Future<void> _saveToken(String token) async {
    final storage = await StorageService.instance;
    await storage.setString('sync_token', token);
  }

  Future<String?> loadSavedToken() async {
    final storage = await StorageService.instance;
    return storage.getString('sync_token');
  }

  // ---- 工具方法 ----

  Map<String, String> _getHeaders() {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (_token != null) {
      headers['Authorization'] = 'Bearer $_token';
    }
    return headers;
  }

  void _updateStatus(SyncStatus status) {
    _status = status;
    _statusController.add(status);
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
    _statusController.close();
    _dio.close();
  }
}
