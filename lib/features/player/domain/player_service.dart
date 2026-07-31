import 'dart:async';

import 'package:audio_service/audio_service.dart';
import '../domain/music_item.dart';
import '../../../core/audio/audio_handler.dart';
import '../../../core/network/outbound_url.dart';
import '../../../core/widgets/artwork_disk_cache.dart';
import 'lazy_playlist_order.dart';

class PlayerService {
  PlayerService({ArtworkDiskCache? artworkCache})
    : _artworkCache = artworkCache ?? ArtworkDiskCache.instance;

  final ArtworkDiskCache _artworkCache;

  /// 当前惰性分页歌单 ID；播放列表弹窗据此展示完整分页列表。
  String? currentLazyPlaylistId;

  /// 当前惰性分页歌单的总歌曲数。
  int currentLazyPlaylistSongCount = 0;

  PlaybackState get playbackState => audioHandler.playbackState.value;
  bool get isPlaying => audioHandler.playbackState.value.playing;
  MediaItem? get mediaItem => audioHandler.mediaItem.value;

  Future<void> setQueue(List<MusicItem> songs, {int startIndex = 0}) async {
    await playPlaylist(songs, index: startIndex);
  }

  /// Instant start: no await on artwork download.
  Future<void> playPlaylist(List<MusicItem> songs, {int index = 0}) async {
    currentLazyPlaylistId = null;
    currentLazyPlaylistSongCount = 0;
    final items = songs.map(_convertToMediaItemSync).toList();
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      handler.clearLazyQueue();
      await handler.setPlaylist(items, initialIndex: index);
      unawaited(_warmArtForQueue(songs, preferIndex: index));
    }
  }

  /// Starts a large playlist without converting every saved song into a native
  /// media queue. The shuffled order covers every global index exactly once.
  Future<void> playPagedPlaylist({
    required int songCount,
    required int startIndex,
    required Future<List<MusicItem>> Function(int offset, int limit) loadPage,
    String? playlistId,
  }) async {
    currentLazyPlaylistId = playlistId;
    currentLazyPlaylistSongCount = songCount;
    if (songCount <= 0 || audioHandler is! LxAudioHandler) return;
    final handler = audioHandler as LxAudioHandler;
    final shuffle =
        handler.playbackState.value.shuffleMode == AudioServiceShuffleMode.all;
    var shuffleEnabled = shuffle;
    final window = LazyPlaylistWindow(
      length: songCount,
      initialIndex: startIndex,
      shuffle: shuffle,
      loadPage: loadPage,
    );

    List<MediaItem> mediaItems(List<LazyPlaylistEntry> entries) => [
      for (final entry in entries)
        _convertToMediaItemSync(entry.song, lazyPlaylistIndex: entry.index),
    ];

    final initialEntries = await window.takeEntries(9);
    if (initialEntries.isEmpty) return;
    handler.configureLazyQueue(
      loadMore: (minimumItems) async {
        var entries = await window.takeEntries(minimumItems);
        if (entries.isEmpty &&
            handler.playbackState.value.repeatMode !=
                AudioServiceRepeatMode.none &&
            handler.playbackState.value.repeatMode !=
                AudioServiceRepeatMode.one) {
          entries = await window.restartFromBeginning(
            shuffle: shuffleEnabled,
            count: minimumItems,
          );
        }
        return mediaItems(entries);
      },
      rebuildForShuffle: (current, enabled, minimumItems) async {
        shuffleEnabled = enabled;
        final index = current.extras?['_lazyPlaylistIndex'];
        if (index is! int) return const [];
        return mediaItems(
          await window.restartEntriesAfterCurrent(
            currentIndex: index,
            shuffle: enabled,
            count: minimumItems,
          ),
        );
      },
    );
    await handler.setPlaylist(mediaItems(initialEntries));
    unawaited(
      _warmArtForQueue(
        initialEntries.map((entry) => entry.song).toList(growable: false),
        preferIndex: 0,
      ),
    );
  }

  Future<void> togglePlay() async {
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      handler.player.playing ? await handler.pause() : await handler.play();
    } else {
      isPlaying ? await audioHandler.pause() : await audioHandler.play();
    }
  }

  MediaItem _convertToMediaItemSync(MusicItem song, {int? lazyPlaylistIndex}) {
    final art = song.artwork;
    return MediaItem(
      id: song.id,
      album: song.album,
      title: song.name,
      artist: song.singer,
      duration: song.duration,
      artUri: (art != null && art.isNotEmpty)
          ? Uri.tryParse(normalizeOutboundUrl(art))
          : null,
      extras: {
        ...song.toJson(),
        if (lazyPlaylistIndex != null) '_lazyPlaylistIndex': lazyPlaylistIndex,
      },
    );
  }

  /// Download covers in background; patch file:// artUri for lock screen.
  Future<void> _warmArtForQueue(
    List<MusicItem> songs, {
    required int preferIndex,
  }) async {
    if (songs.isEmpty || audioHandler is! LxAudioHandler) return;
    final handler = audioHandler as LxAudioHandler;
    final order = <int>[];
    void add(int i) {
      if (i >= 0 && i < songs.length && !order.contains(i)) order.add(i);
    }

    add(preferIndex);
    add(preferIndex + 1);
    add(preferIndex - 1);
    for (final i in order) {
      final song = songs[i];
      final remote = song.artwork;
      if (remote == null || remote.isEmpty) continue;
      try {
        final local = await _artworkCache.localArtUri(remote);
        if (local == null || local.scheme != 'file') continue;
        if (audioHandler is! LxAudioHandler) return;
        handler.patchQueueArtUri(song.id, local);
      } catch (_) {}
    }
  }

  List<MediaItem> get queue {
    if (audioHandler is! LxAudioHandler) return const [];
    return (audioHandler as LxAudioHandler).queueItems;
  }

  int get currentIndex {
    if (audioHandler is! LxAudioHandler) return -1;
    return (audioHandler as LxAudioHandler).currentQueueIndex;
  }

  Future<void> playNext(MusicItem song) async {
    final item = _convertToMediaItemSync(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      final items = List<MediaItem>.from(handler.queueItems);
      if (items.isEmpty) {
        handler.clearLazyQueue();
        await handler.setPlaylist([item]);
        unawaited(_warmArtForQueue([song], preferIndex: 0));
        return;
      }
      final currentId = handler.mediaItem.value?.id;
      items.removeWhere((queueItem) => queueItem.id == item.id);
      final currentIndex = items.indexWhere(
        (queueItem) => queueItem.id == currentId,
      );
      final insertIndex = (currentIndex + 1).clamp(0, items.length);
      items.insert(insertIndex, item);
      await handler.updateQueue(items);
      unawaited(_warmArtForQueue([song], preferIndex: 0));
    }
  }

  Future<void> next() => audioHandler.skipToNext();
  Future<void> previous() => audioHandler.skipToPrevious();
  Future<void> seek(Duration position) => audioHandler.seek(position);
  Future<void> stop() => audioHandler.stop();

  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    await audioHandler.setRepeatMode(repeatMode);
  }

  Future<void> setShuffleMode(bool enabled) async {
    await audioHandler.setShuffleMode(
      enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
    );
  }
}
