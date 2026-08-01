import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/playlist_repository.dart';
import '../domain/playlist_service.dart';
import '../domain/playlist.dart';
import '../../player/domain/music_item.dart';
import '../../../startup_lifecycle.dart';
import '../../../core/pagination/page_range.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  throw StateError('playlistRepositoryProvider must be overridden at startup');
});

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  final service = PlaylistService(
    repository: ref.watch(playlistRepositoryProvider),
  );
  final disposals = ref.read(resourceDisposalTrackerProvider);
  ref.onDispose(disposals.register(service.dispose));
  return service;
});

final playlistRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).revisions;
});

final playlistPageRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).pageRevisions;
});

final playlistRecentRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).recentRevisions;
});

final playlistsProvider = Provider<List<Playlist>>((ref) {
  ref.watch(playlistRevisionProvider);
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.playlists;
});

final class PlaylistSongsPageRequest {
  const PlaylistSongsPageRequest({
    required this.playlistId,
    required this.pageIndex,
  });

  final String playlistId;
  final int pageIndex;

  int get offset => pageIndex * PageRange.defaultPageSize;

  @override
  bool operator ==(Object other) =>
      other is PlaylistSongsPageRequest &&
      other.playlistId == playlistId &&
      other.pageIndex == pageIndex;

  @override
  int get hashCode => Object.hash(playlistId, pageIndex);
}

final playlistSongsPageProvider = FutureProvider.autoDispose
    .family<PlaylistSongPage, PlaylistSongsPageRequest>((ref, request) {
  ref.watch(playlistPageRevisionProvider);
  if (request.playlistId == 'recent') {
    ref.watch(playlistRecentRevisionProvider);
  }
  return ref.read(playlistServiceProvider).getSongsPage(
        request.playlistId,
        offset: request.offset,
        limit: PageRange.defaultPageSize,
      );
});

final playlistSongSearchProvider = FutureProvider.autoDispose
    .family<List<PlaylistSongMatch>, String>((ref, query) {
  ref.watch(playlistRevisionProvider);
  return ref.read(playlistServiceProvider).searchSongs(query);
});

/// 完整加载的歌单列表（内存中的惰性摘要不含歌曲，需 hydrate 后使用）。
final hydratedPlaylistsProvider = FutureProvider<List<Playlist>>((ref) {
  ref.watch(playlistRevisionProvider);
  return ref.read(playlistServiceProvider).getAllPlaylists();
});

final isSongFavoriteProvider = FutureProvider.family<bool, String>((ref, songId) async {
  ref.watch(playlistRevisionProvider);
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.isSongInPlaylist('favorites', songId);
});

// 切换收藏状态
final toggleFavoriteProvider =
    Provider<Future<void> Function(MusicItem)>((ref) {
  return (MusicItem song) async {
    final playlistService = ref.read(playlistServiceProvider);
    final isFavorite =
        await playlistService.isSongInPlaylist('favorites', song.id);
    if (isFavorite) {
      await playlistService.removeSongFromPlaylist('favorites', song.id);
    } else {
      await playlistService.addSongToPlaylist('favorites', song);
    }
  };
});

// 添加歌曲到指定歌单
final addSongToPlaylistProvider =
    Provider<Future<void> Function(String playlistId, MusicItem)>((ref) {
  return (String playlistId, MusicItem song) async {
    final playlistService = ref.read(playlistServiceProvider);
    await playlistService.addSongToPlaylist(playlistId, song);
  };
});

// 创建新歌单
final createPlaylistProvider =
    Provider<Future<void> Function(String name, {String? description})>((ref) {
  return (String name, {String? description}) async {
    final playlistService = ref.read(playlistServiceProvider);
    await playlistService.createPlaylist(name: name, description: description);
  };
});
