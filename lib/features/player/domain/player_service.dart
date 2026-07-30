import 'dart:async';

import 'package:audio_service/audio_service.dart';
import '../domain/music_item.dart';
import '../../../core/audio/audio_handler.dart';
import '../../../core/network/outbound_url.dart';
import '../../../core/widgets/artwork_disk_cache.dart';

class PlayerService {
  PlayerService({ArtworkDiskCache? artworkCache})
      : _artworkCache = artworkCache ?? ArtworkDiskCache.instance;

  final ArtworkDiskCache _artworkCache;

  Stream<PlaybackState> get playbackStateStream => audioHandler.playbackState;
  Stream<MediaItem?> get mediaItemStream => audioHandler.mediaItem;

  PlaybackState get playbackState => audioHandler.playbackState.value;
  MediaItem? get currentMediaItem => audioHandler.mediaItem.value;
  bool get isPlaying => audioHandler.playbackState.value.playing;

  Future<void> setQueue(List<MusicItem> songs, {int startIndex = 0}) async {
    await playPlaylist(songs, index: startIndex);
  }

  Future<void> playSong(MusicItem song) async {
    final item = _convertToMediaItemSync(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      await handler.setPlaylist([item]);
      unawaited(_warmArtForQueue([song], preferIndex: 0));
    }
  }

  /// Instant start: no await on artwork download.
  Future<void> playPlaylist(List<MusicItem> songs, {int index = 0}) async {
    final items = songs.map(_convertToMediaItemSync).toList();
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      await handler.setPlaylist(items, initialIndex: index);
      unawaited(_warmArtForQueue(songs, preferIndex: index));
    }
  }

  Future<void> togglePlay() async {
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      handler.player.playing ? await handler.pause() : await handler.play();
    } else {
      isPlaying ? await audioHandler.pause() : await audioHandler.play();
    }
  }

  MediaItem _convertToMediaItemSync(MusicItem song) {
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
      extras: song.toJson(),
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
    for (var i = 0; i < songs.length; i++) {
      add(i);
    }

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
        await handler.setPlaylist([item]);
        unawaited(_warmArtForQueue([song], preferIndex: 0));
        return;
      }
      final currentId = handler.mediaItem.value?.id;
      items.removeWhere((queueItem) => queueItem.id == item.id);
      final currentIndex =
          items.indexWhere((queueItem) => queueItem.id == currentId);
      final insertIndex = (currentIndex + 1).clamp(0, items.length);
      items.insert(insertIndex, item);
      await handler.updateQueue(items);
      unawaited(_warmArtForQueue([song], preferIndex: 0));
    }
  }

  Future<void> addToQueue(MusicItem song) async {
    final item = _convertToMediaItemSync(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      final items = List<MediaItem>.from(handler.queueItems);
      if (items.any((queueItem) => queueItem.id == item.id)) return;
      items.add(item);
      await handler.updateQueue(items);
      unawaited(_warmArtForQueue([song], preferIndex: items.length - 1));
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
        enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);
  }
}
