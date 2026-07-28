import 'package:audio_service/audio_service.dart';
import '../domain/music_item.dart';
import '../../../core/audio/audio_handler.dart';

class PlayerService {
  PlayerService();

  // 获取状态
  Stream<PlaybackState> get playbackStateStream => audioHandler.playbackState;
  Stream<MediaItem?> get mediaItemStream => audioHandler.mediaItem;

  PlaybackState get playbackState => audioHandler.playbackState.value;
  MediaItem? get currentMediaItem => audioHandler.mediaItem.value;
  bool get isPlaying => audioHandler.playbackState.value.playing;

  // 设置队列并播放（兼容老代码）
  Future<void> setQueue(List<MusicItem> songs, {int startIndex = 0}) async {
    await playPlaylist(songs, index: startIndex);
  }

  // 播放单首歌曲
  Future<void> playSong(MusicItem song) async {
    final item = _convertToMediaItem(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      await handler.setPlaylist([item]);
    }
  }

  // 播放歌曲列表
  Future<void> playPlaylist(List<MusicItem> songs, {int index = 0}) async {
    final items = songs.map((s) => _convertToMediaItem(s)).toList();
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      await handler.setPlaylist(items, initialIndex: index);
    }
  }

  // 基础控制
  Future<void> togglePlay() async {
    // 优先从 just_audio 直接读取播放状态，避免 audio_service 状态过时
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      handler.player.playing ? await handler.pause() : await handler.play();
    } else {
      isPlaying ? await audioHandler.pause() : await audioHandler.play();
    }
  }

  // 辅助方法：统一转换模型
  MediaItem _convertToMediaItem(MusicItem song) {
    return MediaItem(
      id: song.id,
      album: song.album,
      title: song.name,
      artist: song.singer,
      duration: song.duration,
      artUri: (song.artwork != null && song.artwork!.isNotEmpty)
          ? Uri.parse(song.artwork!)
          : null,
      extras: song.toJson(), // 核心：将完整数据带入 AudioHandler，供解析器使用
    );
  }

  // 获取队列
  List<MediaItem> get queue {
    if (audioHandler is! LxAudioHandler) return const [];
    final handler = audioHandler as LxAudioHandler;
    return handler.queueItems;
  }

  int get currentIndex {
    if (audioHandler is! LxAudioHandler) return -1;
    final handler = audioHandler as LxAudioHandler;
    return handler.currentQueueIndex;
  }

  // 添加到下一首播放
  Future<void> playNext(MusicItem song) async {
    final item = _convertToMediaItem(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      final items = List<MediaItem>.from(handler.queueItems);
      if (items.isEmpty) {
        await handler.setPlaylist([item]);
        return;
      }
      items.removeWhere((queueItem) => queueItem.id == item.id);
      final insertIndex =
          (handler.currentQueueIndex + 1).clamp(0, items.length);
      items.insert(insertIndex, item);
      await handler.updateQueue(items);
    }
  }

  // 添加到队列末尾
  Future<void> addToQueue(MusicItem song) async {
    final item = _convertToMediaItem(song);
    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      final items = List<MediaItem>.from(handler.queueItems);
      if (items.any((queueItem) => queueItem.id == item.id)) return;
      items.add(item);
      await handler.updateQueue(items);
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
