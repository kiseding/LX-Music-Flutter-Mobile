import '../../../features/player/domain/music_item.dart';
import 'music_platform.dart';
import 'kw_source.dart';
import 'tx_source.dart';
import 'wy_source.dart';

class BuiltInSourceManager {
  final Map<String, MusicPlatform> _platforms = {};

  BuiltInSourceManager({List<MusicPlatform>? platforms}) {
    for (final platform in platforms ?? [KwSource(), TxSource(), WySource()]) {
      _register(platform);
    }
  }

  void _register(MusicPlatform platform) {
    _platforms[platform.id] = platform;
  }

  MusicPlatform? get(String id) => _platforms[id];

  List<MusicPlatform> get all => _platforms.values.toList();

  List<String> get allIds => _platforms.keys.toList();

  Future<List<MusicItem>> search(String platformId, String keyword,
      {int page = 1, int limit = 20}) async {
    final platform = _platforms[platformId];
    if (platform == null) return [];
    return platform.search(keyword, page: page, limit: limit);
  }

  Future<String?> getMusicUrl(String platformId, MusicItem music,
      {String quality = '320k'}) async {
    final platform = _platforms[platformId];
    if (platform == null) return null;
    return platform.getMusicUrl(music, quality: quality);
  }

  Future<String?> getMusicUrlExact(String platformId, MusicItem music,
      {required String quality}) async {
    final platform = _platforms[platformId];
    if (platform == null) return null;
    return platform.getMusicUrlExact(music, quality: quality);
  }

  Future<ExactPlayUrl?> getMusicUrlExactDetailed(
      String platformId, MusicItem music,
      {required String quality}) async {
    final platform = _platforms[platformId];
    if (platform == null) return null;
    return platform.getMusicUrlExactDetailed(music, quality: quality);
  }

  String? exactAttemptKey(String platformId, String quality) =>
      _platforms[platformId]?.exactAttemptKey(quality);

  Future<String?> getLyric(String platformId, MusicItem music) async {
    final platform = _platforms[platformId];
    if (platform == null) return null;
    return platform.getLyric(music);
  }

  Future<List<LeaderboardCategory>> getLeaderboardCategories(
      String platformId) async {
    final platform = _platforms[platformId];
    if (platform == null) return [];
    return platform.getLeaderboardCategories();
  }

  Future<List<MusicItem>> getLeaderboardSongs(
      String platformId, String leaderboardId,
      {int page = 1, int limit = 100}) async {
    final platform = _platforms[platformId];
    if (platform == null) return [];
    return platform.getLeaderboardSongs(leaderboardId,
        page: page, limit: limit);
  }

  Future<List<LeaderboardCategory>> getAllLeaderboardCategories() async {
    // 并行拉取各平台，避免首屏封面串行过慢
    final results = await Future.wait(
      _platforms.values.map((p) async {
        try {
          return await p
              .getLeaderboardCategories()
              .timeout(const Duration(seconds: 12));
        } catch (_) {
          return <LeaderboardCategory>[];
        }
      }),
    );
    return results.expand((e) => e).toList();
  }

  Future<List<MusicItem>> searchSongLists(String platformId, String keyword,
      {int page = 1, int limit = 20}) async {
    final platform = _platforms[platformId];
    if (platform == null) return [];
    return platform.searchSongLists(keyword, page: page, limit: limit);
  }

  Future<List<MusicItem>> getSongListDetail(
      String platformId, String songListId,
      {int page = 1, int limit = 50}) async {
    final platform = _platforms[platformId];
    if (platform == null) return [];
    return platform.getSongListDetail(songListId, page: page, limit: limit);
  }

  void dispose() {
    for (final platform in _platforms.values) {
      if (platform is KwSource) platform.dispose();
      if (platform is TxSource) platform.dispose();
      if (platform is WySource) platform.dispose();
    }
  }
}
