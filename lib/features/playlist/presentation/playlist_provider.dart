import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/playlist_service.dart';
import '../domain/playlist.dart';
import '../../player/domain/music_item.dart';

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  return PlaylistService();
});

// 版本号，用于触发 UI 刷新
final playlistVersionProvider = StateProvider<int>((ref) => 0);

final playlistsProvider = Provider<List<Playlist>>((ref) {
  ref.watch(playlistVersionProvider); // 依赖版本号，变更时重建
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.playlists;
});

final currentPlaylistProvider = StateProvider<Playlist?>((ref) {
  return null;
});

/// 打开歌单详情时滚动/高亮的目标歌曲 id
final playlistFocusSongIdProvider = StateProvider<String?>((ref) => null);

final isSongFavoriteProvider = Provider.family<bool, String>((ref, songId) {
  ref.watch(playlistVersionProvider); // 依赖版本号，变更时重建
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.isSongInPlaylist('favorites', songId);
});

// 切换收藏状态
final toggleFavoriteProvider = Provider<Future<void> Function(MusicItem)>((ref) {
  return (MusicItem song) async {
    final playlistService = ref.read(playlistServiceProvider);
    final isFavorite = playlistService.isSongInPlaylist('favorites', song.id);
    if (isFavorite) {
      playlistService.removeSongFromPlaylist('favorites', song.id);
    } else {
      playlistService.addSongToPlaylist('favorites', song);
    }
    ref.read(playlistVersionProvider.notifier).state++;
  };
});

// 添加歌曲到指定歌单
final addSongToPlaylistProvider = Provider<Future<void> Function(String playlistId, MusicItem)>((ref) {
  return (String playlistId, MusicItem song) async {
    final playlistService = ref.read(playlistServiceProvider);
    playlistService.addSongToPlaylist(playlistId, song);
    ref.read(playlistVersionProvider.notifier).state++;
  };
});

// 创建新歌单
final createPlaylistProvider = Provider<Future<void> Function(String name, {String? description})>((ref) {
  return (String name, {String? description}) async {
    final playlistService = ref.read(playlistServiceProvider);
    playlistService.createPlaylist(name: name, description: description);
    ref.read(playlistVersionProvider.notifier).state++;
  };
});
