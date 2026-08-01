import 'dart:math';

import '../../player/domain/music_item.dart';

/// 「猜你喜欢」推荐引擎。
///
/// 参考 [Surprise](https://github.com/NicolasHug/Surprise) 的思路：
/// - 把「收藏列表」视为隐式评分（每首收藏 = 1 分），构建用户画像；
/// - 对候选歌曲用加权余弦/雅可比相似度做「预测」（predict），
///   得到该歌曲相对用户画像的偏好得分；
/// - 按得分降序取 Top-N。
///
/// 单用户场景没有跨用户评分矩阵，因此用基于内容的画像相似度替代
/// Surprise 的 SVD / KNN 协同过滤，保留其「预测 + 相似度 + 排序」结构。
class RecommendationEngine {
  const RecommendationEngine();

  static const int defaultTopN = 30;
  static const int favoriteSampleSize = 100;

  /// 用户画像：从收藏歌曲统计各特征的出现权重（归一化到 0~1）。
  FavoriteProfile buildProfile(List<MusicItem> favorites) {
    final artistCount = <String, int>{};
    final albumCount = <String, int>{};
    final platformCount = <String, int>{};
    for (final song in favorites) {
      final artist = song.singer.trim().toLowerCase();
      if (artist.isNotEmpty) {
        artistCount[artist] = (artistCount[artist] ?? 0) + 1;
      }
      final album = song.album.trim().toLowerCase();
      if (album.isNotEmpty) {
        albumCount[album] = (albumCount[album] ?? 0) + 1;
      }
      final platform = song.platform.toLowerCase();
      if (platform.isNotEmpty) {
        platformCount[platform] = (platformCount[platform] ?? 0) + 1;
      }
    }
    return FavoriteProfile(
      artistWeights: _normalize(artistCount),
      albumWeights: _normalize(albumCount),
      platformWeights: _normalize(platformCount),
    );
  }

  Map<String, double> _normalize(Map<String, int> counts) {
    if (counts.isEmpty) return const {};
    final max = counts.values.reduce((a, b) => a > b ? a : b);
    return {
      for (final entry in counts.entries)
        entry.key: entry.value / max,
    };
  }

  /// 预测某候选歌曲的偏好得分（0~1+）。与 Surprise 的 predict 对应。
  double predict({
    required MusicItem candidate,
    required FavoriteProfile profile,
    Map<String, int>? playCounts,
  }) {
    final artist = candidate.singer.trim().toLowerCase();
    final album = candidate.album.trim().toLowerCase();
    final platform = candidate.platform.toLowerCase();

    final artistScore = profile.artistWeights[artist] ?? 0;
    final albumScore = profile.albumWeights[album] ?? 0;
    final platformScore = profile.platformWeights[platform] ?? 0;

    // 加权相似度：歌手权重最高，专辑次之，平台最低
    var score = artistScore * 0.55 + albumScore * 0.30 + platformScore * 0.15;

    // 播放历史隐含反馈：常听的歌手小幅加成
    final plays = playCounts?[candidate.singer] ?? 0;
    if (plays > 0) {
      score += (plays * 0.02).clamp(0.0, 0.2);
    }
    return score;
  }

  /// 生成推荐：收藏不足 100 首时不生成；否则随机抽取 100 首建立画像，
  /// 排除已收藏歌曲后固定返回 30 首完整推荐。
  List<RecommendedSong> recommend({
    required List<MusicItem> favorites,
    required List<MusicItem> candidates,
    Map<String, int>? playCounts,
    Random? random,
  }) {
    if (favorites.length < favoriteSampleSize) return const [];
    final sampledFavorites = List<MusicItem>.of(favorites)..shuffle(random);
    final profile = buildProfile(
      sampledFavorites.take(favoriteSampleSize).toList(growable: false),
    );
    if (profile.artistWeights.isEmpty &&
        profile.albumWeights.isEmpty &&
        profile.platformWeights.isEmpty) {
      return const [];
    }

    final favoriteIds = favorites.map((s) => s.id).toSet();
    final favoriteKeys = favorites
        .map((s) => '${s.name.trim().toLowerCase()}|${s.singer.trim().toLowerCase()}')
        .toSet();
    final scored = <RecommendedSong>[];
    for (final candidate in candidates) {
      // 已收藏（同 id）或与收藏歌曲同名同歌手（不同平台的同一首歌）都跳过
      if (favoriteIds.contains(candidate.id)) continue;
      final key =
          '${candidate.name.trim().toLowerCase()}|${candidate.singer.trim().toLowerCase()}';
      if (favoriteKeys.contains(key)) continue;
      final score = predict(
        candidate: candidate,
        profile: profile,
        playCounts: playCounts,
      );
      if (score <= 0) continue;
      scored.add(RecommendedSong(
        song: candidate,
        score: score,
        reasons: _reasons(candidate, profile, playCounts),
      ));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    // 候选不足 30 首时返回已有结果（不再返回空），不足时展示实际数量。
    return scored.take(defaultTopN).toList(growable: false);
  }

  List<String> _reasons(
    MusicItem candidate,
    FavoriteProfile profile,
    Map<String, int>? playCounts,
  ) {
    final reasons = <String>[];
    final artist = candidate.singer.trim().toLowerCase();
    if ((profile.artistWeights[artist] ?? 0) >= 1) {
      reasons.add('常听 ${candidate.singer}');
    } else if ((profile.artistWeights[artist] ?? 0) > 0) {
      reasons.add('歌手 ${candidate.singer}');
    }
    final album = candidate.album.trim().toLowerCase();
    if ((profile.albumWeights[album] ?? 0) > 0) {
      reasons.add('专辑 ${candidate.album}');
    }
    final plays = playCounts?[candidate.singer] ?? 0;
    if (plays >= 5) {
      reasons.add('近期常听');
    }
    return reasons;
  }
}

/// 用户画像：各特征空间 → 权重（0~1）。
class FavoriteProfile {
  const FavoriteProfile({
    required this.artistWeights,
    required this.albumWeights,
    required this.platformWeights,
  });

  final Map<String, double> artistWeights;
  final Map<String, double> albumWeights;
  final Map<String, double> platformWeights;
}

/// 推荐结果：歌曲 + 预测得分 + 推荐理由。
class RecommendedSong {
  const RecommendedSong({
    required this.song,
    required this.score,
    required this.reasons,
  });

  final MusicItem song;
  final double score;
  final List<String> reasons;
}
