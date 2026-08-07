import '../../../core/storage/storage_service.dart';
import 'playback_session.dart';

/// 播放会话的本地持久化，供下次启动时恢复上次播放状态。
class PlaybackSessionStore {
  PlaybackSessionStore(this._load);

  static const _key = 'playback_session_v1';

  final StorageLoader _load;

  Future<PlaybackSession?> load() async {
    try {
      final json = (await _load()).getJson(_key);
      if (json == null) return null;
      return PlaybackSession.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(PlaybackSession session) async {
    try {
      await (await _load()).setJson(_key, session.toJson());
    } catch (_) {}
  }

  Future<void> clear() async {
    try {
      await (await _load()).remove(_key);
    } catch (_) {}
  }
}
