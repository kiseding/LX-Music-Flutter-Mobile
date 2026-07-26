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
    _playQueue.clear();
    _playQueue.add(item);
    _currentIndex = 0;
    if (audioHandler is LxAudioHandler) {
      await (audioHandler as LxAudioHandler).setPlaylist([item]);
    }
  }

  // 播放歌曲列表
  Future<void> playPlaylist(List<MusicItem> songs, {int index = 0}) async {
    final items = songs.map((s) => _convertToMediaItem(s)).toList();
    _playQueue.clear();
    _playQueue.addAll(items);
    _currentIndex = index;
    if (audioHandler is LxAudioHandler) {
      await (audioHandler as LxAudioHandler).setPlaylist(items, initialIndex: index);
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
      artUri: (song.artwork != null && song.artwork!.isNotEmpty) ? Uri.parse(song.artwork!) : null,
      extras: song.toJson(), // 核心：将完整数据带入 AudioHandler，供解析器使用
    );
  }

  // 播放队列
  final List<MediaItem> _playQueue = [];
  int _currentIndex = -1;

  // 获取队列
  List<MediaItem> get queue => List.unmodifiable(_playQueue);
  int get currentIndex => _currentIndex;

  // 添加到下一首播放
  Future<void> playNext(MusicItem song) async {
    final item = _convertToMediaItem(song);

    if (_playQueue.isEmpty) {
      await playSong(song);
      return;
    }

    if (audioHandler is LxAudioHandler) {
      final handler = audioHandler as LxAudioHandler;
      // 与 handler 内部队列对齐
      final live = handler.queueItems;
      _playQueue
        ..clear()
        ..addAll(live);
      _currentIndex = handler.queueItems.isEmpty
          ? -1
          : handler.queueItems
              .indexWhere((m) => m.id == handler.mediaItem.value?.id)
              .clamp(-1, handler.queueItems.length);
      if (_currentIndex < 0) _currentIndex = 0;

      _playQueue.removeWhere((i) => i.id == item.id);
      final insertIndex = (_currentIndex + 1).clamp(0, _playQueue.length);
      _playQueue.insert(insertIndex, item);
      await handler.updateQueue(List<MediaItem>.from(_playQueue));
    } else {
      _playQueue.removeWhere((i) => i.id == item.id);
      final insertIndex = _currentIndex + 1;
      _playQueue.insert(insertIndex, item);
    }
  }

  // 添加到队列末尾
  Future<void> addToQueue(MusicItem song) async {
    final item = _convertToMediaItem(song);
    if (_playQueue.any((i) => i.id == item.id)) return;

    _playQueue.add(item);
    if (audioHandler is LxAudioHandler) {
      await (audioHandler as LxAudioHandler).addQueueItem(item);
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
    await audioHandler.setShuffleMode(enabled ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none);
  }
}
