import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/sync_service.dart';
import '../../settings/presentation/settings_provider.dart';
import '../../playlist/presentation/playlist_provider.dart';

final syncServiceProvider = Provider<SyncService>((ref) {
  final service = SyncService();
  ref.onDispose(() => service.dispose());
  return service;
});

final syncStatusProvider = StreamProvider<SyncStatus>((ref) {
  final syncService = ref.watch(syncServiceProvider);
  return syncService.statusStream;
});

final isSyncEnabledProvider = Provider<bool>((ref) {
  final serverUrl = ref.watch(syncServerUrlProvider);
  return serverUrl != null && serverUrl.isNotEmpty;
});

/// 同步连接管理器 - 自动连接/断开
final syncConnectionProvider = StateNotifierProvider<SyncConnectionNotifier, bool>((ref) {
  return SyncConnectionNotifier(ref);
});

class SyncConnectionNotifier extends StateNotifier<bool> {
  final Ref _ref;
  SyncConnectionNotifier(this._ref) : super(false);

  /// 连接到同步服务器
  Future<bool> connect() async {
    final serverUrl = _ref.read(syncServerUrlProvider);
    if (serverUrl == null || serverUrl.isEmpty) return false;

    final syncService = _ref.read(syncServiceProvider);
    final token = await syncService.loadSavedToken();
    final ok = await syncService.connect(serverUrl, token: token);
    state = ok;
    return ok;
  }

  /// 断开连接
  void disconnect() {
    _ref.read(syncServiceProvider).disconnect();
    state = false;
  }

  /// 手动同步 - 推送本地数据
  Future<bool> pushSync() async {
    final syncService = _ref.read(syncServiceProvider);
    if (!syncService.isConnected) return false;

    final playlistService = _ref.read(playlistServiceProvider);
    final playlists = playlistService.playlists;
    final history = playlistService.recent?.songs ?? [];

    return syncService.push(playlists: playlists, history: history);
  }

  /// 手动同步 - 拉取远程数据
  Future<Map<String, dynamic>?> pullSync() async {
    final syncService = _ref.read(syncServiceProvider);
    if (!syncService.isConnected) return null;
    return syncService.pull();
  }

  /// 登录
  Future<bool> login(String username, String password) async {
    return _ref.read(syncServiceProvider).login(username, password);
  }

  /// 注册
  Future<bool> register(String username, String password) async {
    return _ref.read(syncServiceProvider).register(username, password);
  }
}
