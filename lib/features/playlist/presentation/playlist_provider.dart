import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/playlist_repository.dart';
import '../domain/playlist_service.dart';
import '../domain/playlist.dart';
import '../../player/domain/music_item.dart';
import '../../../startup_lifecycle.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  throw StateError('playlistRepositoryProvider must be overridden at startup');
});

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  final service = PlaylistService(
    repository: ref.watch(playlistRepositoryProvider),
  );
  final disposals = ref.read(resourceDisposalTrackerProvider);
  ref.onDispose(() => disposals.track(service.dispose()));
  return service;
});

final playlistRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).revisions;
});

final playlistsProvider = Provider<List<Playlist>>((ref) {
  ref.watch(playlistRevisionProvider);
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.playlists;
});

final currentPlaylistProvider = StateProvider<Playlist?>((ref) {
  return null;
});

/// 打开歌单详情时滚动/高亮的目标歌曲 id
final playlistFocusSongIdProvider = StateProvider<String?>((ref) => null);

final isSongFavoriteProvider = Provider.family<bool, String>((ref, songId) {
  ref.watch(playlistRevisionProvider);
  final playlistService = ref.watch(playlistServiceProvider);
  return playlistService.isSongInPlaylist('favorites', songId);
});

// 切换收藏状态
final toggleFavoriteProvider =
    Provider<Future<void> Function(MusicItem)>((ref) {
  return (MusicItem song) async {
    final playlistService = ref.read(playlistServiceProvider);
    final isFavorite = playlistService.isSongInPlaylist('favorites', song.id);
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
