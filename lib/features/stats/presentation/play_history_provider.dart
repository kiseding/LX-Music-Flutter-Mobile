import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:audio_service/audio_service.dart';

import '../../../core/audio/audio_handler.dart';
import '../../../core/storage/storage_service.dart';
import '../../player/domain/music_item.dart';
import '../data/play_history_store.dart';

final playHistoryStoreProvider = Provider<PlayHistoryStore>((ref) {
  final store = PlayHistoryStore(() => StorageService.instance);
  unawaited(store.load());
  ref.onDispose(() => unawaited(store.disposeAsync()));
  return store;
});

/// 播放历史 revision 流，供 UI 订阅刷新。
final playHistoryRevisionProvider = StreamProvider<int>((ref) {
  final store = ref.watch(playHistoryStoreProvider);
  return store.stream.map((_) => 1);
});

/// 自动记录播放历史：定时读取当前歌曲 + 进度，驱动三段式 session。
final playHistoryRecorderProvider = Provider<void>((ref) {
  final store = ref.read(playHistoryStoreProvider);
  final timer = Timer.periodic(const Duration(seconds: 1), (_) {
    final mediaItem = audioHandler.mediaItem.value;
    if (mediaItem == null) {
      store.endSession();
      return;
    }
    final music = _musicFromMedia(mediaItem);
    final position = audioHandler is LxAudioHandler
        ? (audioHandler as LxAudioHandler).player.position
        : Duration.zero;
    if (music.id != store.currentSongId) {
      store.beginSession(
        songId: music.id,
        songTitle: music.name,
        artistName: music.singer,
        albumTitle: music.album,
        source: music.source,
      );
    }
    store.tick(position);
  });
  ref.onDispose(() {
    timer.cancel();
    store.endSession();
  });
});

MusicItem _musicFromMedia(MediaItem mediaItem) {
  if (mediaItem.extras != null) {
    return MusicItem.fromJson(Map<String, dynamic>.from(mediaItem.extras!));
  }
  return MusicItem(
    id: mediaItem.id,
    name: mediaItem.title,
    singer: mediaItem.artist ?? '未知歌手',
    album: mediaItem.album ?? '',
    duration: mediaItem.duration ?? Duration.zero,
    source: 'unknown',
    artwork: mediaItem.artUri?.toString(),
  );
}
