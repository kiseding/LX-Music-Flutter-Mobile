import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/music_source/platform/music_platform.dart';
import '../../../core/music_source/platform/built_in_source_manager.dart';
import '../../search/presentation/search_provider.dart';
import '../../player/domain/music_item.dart';

final builtInSourcesProvider = Provider<BuiltInSourceManager>((ref) {
  final musicSourceService = ref.watch(musicSourceServiceProvider);
  return musicSourceService.builtInSources;
});

// 排行榜分类列表
final leaderboardCategoriesProvider = FutureProvider<List<LeaderboardCategory>>((ref) async {
  final builtIn = ref.watch(builtInSourcesProvider);
  return builtIn.getAllLeaderboardCategories();
});

// 排行榜歌曲
final leaderboardSongsProvider = FutureProvider.family<List<MusicItem>, String>((ref, leaderboardId) async {
  final builtIn = ref.watch(builtInSourcesProvider);
  // 从 categoryId 中提取平台信息
  // 格式: "platform:id"，如 "kw:93"
  final parts = leaderboardId.split(':');
  if (parts.length != 2) return [];
  final platformId = parts[0];
  final id = parts[1];
  return builtIn.getLeaderboardSongs(platformId, id);
});
