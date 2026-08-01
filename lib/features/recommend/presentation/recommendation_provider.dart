import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/domain/music_item.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../stats/presentation/play_history_provider.dart';
import '../domain/recommendation_engine.dart';

/// 猜你喜欢推荐结果。
final recommendationProvider =
    Provider<List<RecommendedSong>>((ref) {
  ref.watch(playlistServiceProvider).revisions;
  ref.watch(playHistoryRevisionProvider).value;

  final playlistService = ref.read(playlistServiceProvider);
  final history = ref.read(playHistoryStoreProvider);
  final favorites = playlistService.favorites?.songs ?? const [];

  // 候选池：所有歌单的歌曲去重（排除已收藏）
  final seen = <String, MusicItem>{};
  for (final playlist in playlistService.playlists) {
    if (playlist.id == 'recent') continue;
    for (final song in playlist.songs) {
      seen[song.id] = song;
    }
  }

  // 播放历史：按歌手聚合次数（隐式反馈）
  final artistPlays = <String, int>{};
  for (final entry in history.entries) {
    if (entry.artistName.isEmpty) continue;
    artistPlays[entry.artistName] =
        (artistPlays[entry.artistName] ?? 0) + 1;
  }

  final engine = const RecommendationEngine();
  return engine.recommend(
    favorites: favorites,
    candidates: seen.values.toList(),
    playCounts: artistPlays,
  );
});
