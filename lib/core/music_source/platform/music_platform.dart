import 'package:dio/dio.dart';
import '../../network/app_http_client.dart';
import '../../../features/player/domain/music_item.dart';

class LeaderboardCategory {
  final String id;
  final String name;
  final String? platform;
  final String? coverUrl;
  const LeaderboardCategory({
    required this.id,
    required this.name,
    this.platform,
    this.coverUrl,
  });

  LeaderboardCategory copyWith({
    String? id,
    String? name,
    String? platform,
    String? coverUrl,
  }) {
    return LeaderboardCategory(
      id: id ?? this.id,
      name: name ?? this.name,
      platform: platform ?? this.platform,
      coverUrl: coverUrl ?? this.coverUrl,
    );
  }
}

abstract class MusicPlatform {
  String get id;
  String get name;

  Future<List<MusicItem>> search(String keyword,
      {int page = 1, int limit = 20});
  Future<String?> getMusicUrl(MusicItem music, {String quality = '128k'});

  /// Coordinator-only exact request. Legacy callers continue using getMusicUrl.
  Future<String?> getMusicUrlExact(MusicItem music,
          {required String quality}) async =>
      null;
  Future<ExactPlayUrl?> getMusicUrlExactDetailed(MusicItem music,
      {required String quality}) async {
    final url = await getMusicUrlExact(music, quality: quality);
    return url == null ? null : ExactPlayUrl(url: url, actualQuality: quality);
  }

  String? exactAttemptKey(String quality) => null;
  Future<String?> getLyric(MusicItem music);
  Future<String?> getArtwork(MusicItem music) async => null;

  // 歌单搜索接口（可选实现）
  Future<List<MusicItem>> searchSongLists(String keyword,
          {int page = 1, int limit = 20}) async =>
      [];
  // 歌单详情接口（可选实现）
  Future<List<MusicItem>> getSongListDetail(String songListId,
          {int page = 1, int limit = 50}) async =>
      [];

  // 排行榜接口（可选实现）
  Future<List<LeaderboardCategory>> getLeaderboardCategories() async => [];
  Future<List<MusicItem>> getLeaderboardSongs(String leaderboardId,
          {int page = 1, int limit = 100}) async =>
      [];

  Dio createDio() {
    return AppHttpClient.create(
        options: BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36'
      },
    ));
  }

  Dio createDioForService(
      {Duration? connectTimeout,
      Duration? receiveTimeout,
      Map<String, dynamic>? headers}) {
    return AppHttpClient.create(
        options: BaseOptions(
      connectTimeout: connectTimeout ?? const Duration(seconds: 8),
      receiveTimeout: receiveTimeout ?? const Duration(seconds: 10),
      headers: headers,
    ));
  }

  MusicItem parseItem(Map<String, dynamic> raw, String source);
}

class ExactPlayUrl {
  final String url;
  final String actualQuality;

  const ExactPlayUrl({required this.url, required this.actualQuality});
}
