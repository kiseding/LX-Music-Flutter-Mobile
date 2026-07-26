import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

late AudioHandler audioHandler;

// 定义一个函数签名，用于动态获取 URL（extras 为该曲目元数据，避免预加载时误用当前曲）
typedef UrlResolver = Future<String?> Function(
  String mediaId, [
  Map<String, dynamic>? extras,
]);

const _silentPlaceholder =
    'data:audio/wav;base64,UklGRiQAAABXQVZFZm10IBAAAAABAAEARKwAAIhYAQACABAAZGF0YQAAAAA=';

/// 将远程 URL 或本地 file 路径转为 just_audio 可用的 Uri。
Uri playableUri(String url) {
  if (url.isEmpty) return Uri.parse(_silentPlaceholder);
  if (url.startsWith('file://')) return Uri.parse(url);
  if (url.startsWith('/')) return Uri.file(url);
  return Uri.parse(url);
}

AudioSource audioSourceFor(String url, {MediaItem? tag}) {
  // 未解析曲目用超长静音，避免短 WAV 瞬间 completed 连跳多首
  if (url.isEmpty) {
    return SilenceAudioSource(duration: const Duration(days: 1), tag: tag);
  }
  return AudioSource.uri(playableUri(url), tag: tag);
}

class LxAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final List<MediaItem> _queue = [];
  int _currentIndex = 0;
  /// 单调世代：setPlaylist/切歌时递增，取消过期的异步解析/播放
  int _playGeneration = 0;
  bool _userWantsPlay = true;
  bool _handlingCompleted = false;
  /// >0 时忽略 completed / currentIndex 自动推进（换源、点选切歌期间）
  int _suppressAutoAdvance = 0;
  String? _activeItemId;

  // 注入 URL 解析器
  UrlResolver? urlResolver;
  
  // 注入错误回调
  void Function(String message)? onError;

  LxAudioHandler() {
    // 初始化 playbackState，避免 value 访问时抛异常
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      playing: false,
      updatePosition: Duration.zero,
      bufferedPosition: Duration.zero,
      speed: 1.0,
    ));
    _init();
  }

  AudioPlayer get player => _player;

  /// 当前内部播放队列（供 urlResolver 按 id 查找 extras）
  List<MediaItem> get queueItems => List.unmodifiable(_queue);

  int _bumpGeneration() => ++_playGeneration;

  bool _isStale(int gen) => gen != _playGeneration;

  void _init() {
    _player.playbackEventStream.listen(_broadcastState);
    
    // 监听播放完成：防重入；换源/点选切歌时抑制，避免“点 A 却播 A+1”
    _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      if (_handlingCompleted || _suppressAutoAdvance > 0) return;
      if (!_userWantsPlay) return;
      _handlingCompleted = true;
      final gen = _playGeneration;
      final expectedId = _activeItemId;
      Future(() async {
        try {
          // 等一帧，让 setAudioSource 触发的伪 completed 被抑制窗吃掉
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (_isStale(gen) || _suppressAutoAdvance > 0) return;
          if (!_userWantsPlay) return;
          if (_player.processingState != ProcessingState.completed) return;
          // 必须仍是当时那一首播完，防止切歌后旧 completed 把新索引再 +1
          if (expectedId != null && mediaItem.value?.id != expectedId) return;
          if (_currentIndex < _queue.length &&
              _queue[_currentIndex].id != expectedId) {
            return;
          }
          await skipToNext();
        } finally {
          _handlingCompleted = false;
        }
      });
    });

    // 自然切到下一索引时同步 UI；点选/setSource 期间不跟
    _player.currentIndexStream.listen((index) async {
      if (_suppressAutoAdvance > 0) return;
      if (index == null || index == _currentIndex) return;
      if (index < 0 || index >= _queue.length) return;
      final gen = _playGeneration;
      _currentIndex = index;
      final item = _queue[index];
      mediaItem.add(item);
      final url = item.extras?['url']?.toString() ?? '';
      if (url.isEmpty || url.startsWith('data:')) {
        if (!_isStale(gen)) await skipToQueueItem(index);
      }
    });
  }

  Future<T> _withAutoAdvanceSuppressed<T>(Future<T> Function() op) async {
    _suppressAutoAdvance++;
    try {
      return await op();
    } finally {
      // 延后解除，吞掉 setAudioSource 尾随的 completed/index 事件
      Future<void>.delayed(const Duration(milliseconds: 120), () {
        if (_suppressAutoAdvance > 0) _suppressAutoAdvance--;
      });
    }
  }

  // 将播放状态广播给系统控制中心
  void _broadcastState(PlaybackEvent event) {
    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        if (_player.playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      playing: _player.playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: _currentIndex,
    ));
  }

  @override
  Future<void> play() async {
    _userWantsPlay = true;
    // 如果播放器处于空闲/错误状态，先重置再播放
    if (_player.processingState == ProcessingState.idle) {
      await _player.stop();
      if (_player.currentIndex != null) {
        await _player.seek(Duration.zero, index: _player.currentIndex);
      }
    }
    try {
      await _player.play();
    } catch (e) {
      debugPrint('[AudioHandler] play() 失败: $e');
    }
    await super.play();
  }

  @override
  Future<void> pause() async {
    _userWantsPlay = false;
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[AudioHandler] pause() 失败: $e');
    }
    await super.pause();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> stop() async {
    _userWantsPlay = false;
    _bumpGeneration();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() async {
    if (_queue.isEmpty) return;

    // 立刻停掉当前曲，避免“点了下一首还在播这一首”
    await _haltCurrentPlayback();
    _userWantsPlay = true;

    if (_player.shuffleModeEnabled) {
      await _player.seekToNext();
      final idx = _player.currentIndex ?? _currentIndex;
      await skipToQueueItem(idx);
      return;
    }

    int nextIndex = _currentIndex + 1;
    if (nextIndex >= _queue.length) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all ||
          playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
        nextIndex = 0;
      } else {
        return;
      }
    }

    await skipToQueueItem(nextIndex);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;

    await _haltCurrentPlayback();
    _userWantsPlay = true;

    if (_player.shuffleModeEnabled) {
      await _player.seekToPrevious();
      final idx = _player.currentIndex ?? _currentIndex;
      await skipToQueueItem(idx);
      return;
    }

    int prevIndex = _currentIndex - 1;
    if (prevIndex < 0) {
      if (playbackState.value.repeatMode == AudioServiceRepeatMode.all ||
          playbackState.value.repeatMode == AudioServiceRepeatMode.one) {
        prevIndex = _queue.length - 1;
      } else {
        return;
      }
    }

    await skipToQueueItem(prevIndex);
  }

  /// 立即停止当前输出并广播暂停态，提升切歌手感。
  Future<void> _haltCurrentPlayback() async {
    _bumpGeneration();
    try {
      if (_player.playing) {
        await _player.pause();
      }
    } catch (e) {
      debugPrint('[AudioHandler] halt pause failed: $e');
    }
    playbackState.add(playbackState.value.copyWith(
      playing: false,
      processingState: AudioProcessingState.buffering,
    ));
  }

  Future<int> _preloadCount() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final wifi = results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
      return wifi ? 5 : 2;
    } catch (_) {
      return 2;
    }
  }

  /// 后台预加载后续曲目（解析+本地缓存），不阻塞当前播放。
  void _schedulePreload() {
    final gen = _playGeneration;
    final anchorIndex = _currentIndex;
    Future(() async {
      final resolver = urlResolver;
      if (resolver == null || _queue.isEmpty) return;
      if (_isStale(gen)) return;
      final count = await _preloadCount();
      final start = anchorIndex + 1;
      for (var i = 0; i < count; i++) {
        if (_isStale(gen)) return;
        final idx = start + i;
        if (idx >= _queue.length) break;
        final item = _queue[idx];
        final itemId = item.id;
        final existing = item.extras?['url']?.toString() ?? '';
        if (existing.isNotEmpty &&
            (existing.startsWith('file://') || existing.startsWith('/'))) {
          continue;
        }
        try {
          debugPrint('[AudioHandler] preload idx=$idx title=${item.title}');
          final rawExtras = item.extras == null
              ? null
              : Map<String, dynamic>.from(item.extras!);
          final url = await resolver(item.id, rawExtras);
          if (url == null || url.isEmpty) continue;
          if (_isStale(gen)) return;
          if (idx >= _queue.length || _queue[idx].id != itemId) continue;
          final extras = Map<String, dynamic>.from(_queue[idx].extras ?? {});
          extras['url'] = url;
          _queue[idx] = _queue[idx].copyWith(extras: extras);
          // 若用户已切到这首且仍在等解析，立刻用预加载结果开播
          if (_currentIndex == idx && _userWantsPlay) {
            final curUrl = mediaItem.value?.extras?['url']?.toString() ?? '';
            if (curUrl.isEmpty || curUrl.startsWith('data:')) {
              await skipToQueueItem(idx);
            }
          }
        } catch (e) {
          debugPrint('[AudioHandler] preload failed idx=$idx: $e');
        }
      }
      if (!_isStale(gen)) queue.add(List.from(_queue));
    });
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _queue.length) return;

    final gen = _bumpGeneration();
    _userWantsPlay = true;
    final item = _queue[index];
    final itemId = item.id;
    _activeItemId = itemId;
    String? currentUrl = item.extras?['url']?.toString();
    if (currentUrl != null && currentUrl.startsWith('data:')) {
      currentUrl = null;
    }

    _currentIndex = index;
    mediaItem.add(item);

    await _withAutoAdvanceSuppressed(() async {
      try {
        String? url = currentUrl;

        if (url == null || url.isEmpty) {
          if (urlResolver != null) {
            playbackState.add(playbackState.value.copyWith(
              processingState: AudioProcessingState.buffering,
            ));
            url = await urlResolver!(
              item.id,
              item.extras == null
                  ? null
                  : Map<String, dynamic>.from(item.extras!),
            );
          }
        }

        if (_isStale(gen)) return;
        if (index >= _queue.length || _queue[index].id != itemId) return;
        final refreshed = _queue[index].extras?['url']?.toString();
        if ((url == null || url.isEmpty) &&
            refreshed != null &&
            refreshed.isNotEmpty &&
            !refreshed.startsWith('data:')) {
          url = refreshed;
        }

        if (url == null || url.isEmpty) {
          if (_player.playing) {
            await _player.pause();
          }
          debugPrint(
              '[AudioHandler] 无法获取播放链接: ${item.title} id=${item.id}');
          onError?.call(
              '无法解析歌曲 "${item.title}" 的播放地址（源无效地址或本地缓存失败，已尝试降级音质）');
          if (_queue.length > 1 && !_isStale(gen) && _currentIndex == index) {
            await Future.delayed(const Duration(seconds: 5));
            if (!_isStale(gen) && _currentIndex == index) {
              await skipToNext();
            }
          }
          return;
        }

        final baseExtras =
            Map<String, dynamic>.from(_queue[index].extras ?? {});
        baseExtras['url'] = url;
        final updatedItem = _queue[index].copyWith(extras: baseExtras);
        _queue[index] = updatedItem;
        queue.add(List.from(_queue));
        mediaItem.add(updatedItem);
        _activeItemId = itemId;

        // 只加载当前曲，避免 concat 静音轨 completed 连跳
        if (_isStale(gen)) return;
        await _player.setAudioSource(
          audioSourceFor(url, tag: updatedItem),
          initialPosition: Duration.zero,
        );
        if (_isStale(gen)) return;
        if (_userWantsPlay) {
          await _player.play();
        }
        if (!_isStale(gen)) _schedulePreload();
      } catch (e) {
        debugPrint('[AudioHandler] 播放失败: $e');
        if (!_isStale(gen) && _currentIndex == index) {
          onError?.call('播放歌曲 "${item.title}" 失败: $e');
          if (_queue.length > 1) {
            await Future.delayed(const Duration(seconds: 5));
            if (!_isStale(gen) && _currentIndex == index) {
              await skipToNext();
            }
          }
        }
      }
    });
  }

  // 设置播放列表并开始播放
  Future<void> setPlaylist(List<MediaItem> items, {int initialIndex = 0}) async {
    _bumpGeneration();
    _userWantsPlay = true;
    _queue
      ..clear()
      ..addAll(items);
    queue.add(List.from(_queue));

    if (items.isEmpty) {
      await _player.stop();
      return;
    }

    final safeIndex = initialIndex.clamp(0, items.length - 1);
    _currentIndex = safeIndex;
    _activeItemId = items[safeIndex].id;
    mediaItem.add(items[safeIndex]);

    // 始终走 skipToQueueItem，统一解析/缓存/预加载
    await skipToQueueItem(safeIndex);
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    final gen = _bumpGeneration();
    final String? currentId = mediaItem.value?.id;
    final pos = _player.position;
    final newQueue = queue;

    _queue
      ..clear()
      ..addAll(newQueue);
    this.queue.add(List.from(_queue));

    if (newQueue.isEmpty) {
      await _player.stop();
      return;
    }

    var newIndex = 0;
    if (currentId != null) {
      final found = newQueue.indexWhere((item) => item.id == currentId);
      if (found != -1) newIndex = found;
    }
    _currentIndex = newIndex;
    mediaItem.add(newQueue[newIndex]);

    final children = newQueue.map((item) {
      final url = item.extras?['url']?.toString() ?? '';
      return audioSourceFor(url.startsWith('data:') ? '' : url, tag: item);
    }).toList();
    if (_isStale(gen)) return;
    await _player.setAudioSource(
      ConcatenatingAudioSource(children: children),
      initialIndex: newIndex,
      initialPosition: pos,
    );
    if (_isStale(gen)) return;
    if (_userWantsPlay) {
      try {
        await _player.play();
      } catch (_) {}
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _queue.add(mediaItem);
    queue.add(List.from(_queue));

    if (_player.audioSource is ConcatenatingAudioSource) {
      final source = _player.audioSource as ConcatenatingAudioSource;
      final url = mediaItem.extras?['url']?.toString() ?? '';
      await source.add(audioSourceFor(url.startsWith('data:') ? '' : url, tag: mediaItem));
    }
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final index = _queue.indexWhere((item) => item.id == mediaItem.id);
    if (index != -1) {
      _queue.removeAt(index);
      queue.add(List.from(_queue));
      
      if (_player.audioSource is ConcatenatingAudioSource) {
        final source = _player.audioSource as ConcatenatingAudioSource;
        if (index < source.length) {
          await source.removeAt(index);
        }
      }
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    playbackState.add(playbackState.value.copyWith(repeatMode: repeatMode));
    switch (repeatMode) {
      case AudioServiceRepeatMode.none:
        await _player.setLoopMode(LoopMode.off);
        break;
      case AudioServiceRepeatMode.all:
      case AudioServiceRepeatMode.group:
        await _player.setLoopMode(LoopMode.all);
        break;
      case AudioServiceRepeatMode.one:
        await _player.setLoopMode(LoopMode.one);
        break;
    }
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    playbackState.add(playbackState.value.copyWith(shuffleMode: shuffleMode));
    await _player.setShuffleModeEnabled(enabled);
  }
}
