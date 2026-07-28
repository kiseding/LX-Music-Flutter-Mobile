import 'dart:async';

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

/// 单曲 setAudioSource 架构下，just_audio 的 shuffle/seekToNext 无效。
/// 在应用层从队列索引选下一首（尽量不立刻重复当前曲）。
int nextQueueIndex({
  required int currentIndex,
  required int queueLength,
  required bool shuffle,
  required bool loop,
  int Function(int max)? randomNext,
}) {
  if (queueLength <= 0) return -1;
  if (queueLength == 1) return loop || shuffle ? 0 : -1;

  if (shuffle) {
    final rand =
        randomNext ?? (max) => DateTime.now().microsecondsSinceEpoch % max;
    // 在 [0, length) 中避开 currentIndex
    var pick = rand(queueLength - 1);
    if (pick >= currentIndex) pick += 1;
    return pick.clamp(0, queueLength - 1);
  }

  final next = currentIndex + 1;
  if (next < queueLength) return next;
  return loop ? 0 : -1;
}

int previousQueueIndex({
  required int currentIndex,
  required int queueLength,
  required bool shuffle,
  required bool loop,
  int Function(int max)? randomNext,
}) {
  if (queueLength <= 0) return -1;
  if (queueLength == 1) return loop || shuffle ? 0 : -1;

  if (shuffle) {
    return nextQueueIndex(
      currentIndex: currentIndex,
      queueLength: queueLength,
      shuffle: true,
      loop: loop,
      randomNext: randomNext,
    );
  }

  final prev = currentIndex - 1;
  if (prev >= 0) return prev;
  return loop ? queueLength - 1 : -1;
}

/// 已缓存的播放地址仅在「请求音质一致」时可复用；否则改音质设置会不生效。
bool shouldReuseCachedPlayUrl({
  required String? cachedUrl,
  required String? cachedRequestedQuality,
  required String currentRequestedQuality,
}) {
  if (cachedUrl == null || cachedUrl.isEmpty) return false;
  if (cachedUrl.startsWith('data:')) return false;
  if (cachedRequestedQuality == null || cachedRequestedQuality.isEmpty) {
    return false;
  }
  return cachedRequestedQuality == currentRequestedQuality;
}

/// 与设置页 AudioQualityOption 对齐的音质 token（避免 audio_handler 依赖 settings）。
enum AudioQualityToken { low, high, lossless, lossless24, hires }

String playQualityToken(AudioQualityToken token) {
  switch (token) {
    case AudioQualityToken.low:
      return '128k';
    case AudioQualityToken.high:
      return '320k';
    case AudioQualityToken.lossless:
      return 'flac';
    case AudioQualityToken.lossless24:
      return 'flac24bit';
    case AudioQualityToken.hires:
      return 'hires';
  }
}

bool isLosslessQuality(String? quality) {
  final q = (quality ?? '').toLowerCase();
  return q.contains('flac') ||
      q.contains('hires') ||
      q.contains('ape') ||
      q.contains('wav') ||
      q.contains('alac') ||
      q.contains('dsd') ||
      q.contains('lossless');
}

/// FLAC/无损 seek 更慢；给更长 settle 窗口。
Duration seekBudgetForQuality(String? quality) {
  if (isLosslessQuality(quality)) {
    return const Duration(milliseconds: 1200);
  }
  return const Duration(milliseconds: 500);
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

  /// 当前播放偏好音质（由设置页同步）；用于判断 extras 缓存 url 是否可复用。
  String preferredQuality = '320k';

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

  void _startPlayer() {
    unawaited(_player.play().catchError((Object e, StackTrace stack) {
      debugPrint('[AudioHandler] play() 失败: $e');
    }));
  }

  void _init() {
    _player.playbackEventStream.listen(_broadcastState);

    // 播放完成 → 无缝连播下一首。
    // 锁屏/后台时绝不能先 pause + playing:false：iOS 会结束后台音频会话。
    _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      _onTrackCompleted('processingState');
    });

    // 锁屏兜底：仅在「已到/超过时长」时触发，避免提前 400ms 切歌造成竞态
    _player.positionStream.listen((pos) {
      if (_handlingCompleted || _suppressAutoAdvance > 0) return;
      if (!_userWantsPlay) return;
      final dur = _player.duration;
      if (dur == null || dur < const Duration(seconds: 2)) return;
      if (pos >= dur - const Duration(milliseconds: 80)) {
        _onTrackCompleted('position-end');
      }
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

  void _onTrackCompleted([String reason = '']) {
    if (_handlingCompleted || _suppressAutoAdvance > 0) return;
    // 自动连播视为用户仍要听：拖进度 pause 不 clearIntent 时仍可连播
    if (!_userWantsPlay && reason != 'force') return;
    if (_queue.isEmpty) return;
    if (_queue.length <= 1 &&
        playbackState.value.repeatMode == AudioServiceRepeatMode.none &&
        playbackState.value.repeatMode != AudioServiceRepeatMode.one &&
        !_player.shuffleModeEnabled &&
        playbackState.value.shuffleMode != AudioServiceShuffleMode.all) {
      return;
    }
    _handlingCompleted = true;
    final gen = _playGeneration;
    final expectedId = _activeItemId;
    final expectedIndex = _currentIndex;
    debugPrint('[AudioHandler] track completed ($reason) idx=$expectedIndex');
    Future(() async {
      try {
        if (_isStale(gen) || _suppressAutoAdvance > 0) return;
        if (expectedId != null &&
            _activeItemId != null &&
            _activeItemId != expectedId &&
            _currentIndex != expectedIndex) {
          return;
        }
        _userWantsPlay = true; // 自动下一首：恢复意图
        await skipToNext(seamless: true);
      } catch (e) {
        debugPrint('[AudioHandler] auto-next failed: $e');
      } finally {
        _handlingCompleted = false;
      }
    });
  }

  Future<T> _withAutoAdvanceSuppressed<T>(Future<T> Function() op) async {
    _suppressAutoAdvance++;
    try {
      return await op();
    } finally {
      // 延后解除：setAudioSource 后 completed 尾随更长，锁屏下更明显
      Future<void>.delayed(const Duration(milliseconds: 450), () {
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
    // just_audio 的 Future 要到暂停/停止/播完才完成，不能在这里等待。
    _startPlayer();
    await super.play();
  }

  /// 供测试：模拟当前曲播放完成（锁屏自动下一曲路径）。
  @visibleForTesting
  void debugEmitTrackCompleted() => _onTrackCompleted();

  @override
  Future<void> pause() async {
    await pauseInternal(clearIntent: true);
  }

  /// [clearIntent]=false：拖进度条暂停，不取消「还要继续听」意图（自动下一首仍有效）
  Future<void> pauseInternal({bool clearIntent = true}) async {
    if (clearIntent) _userWantsPlay = false;
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[AudioHandler] pause() 失败: $e');
    }
    await super.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    final dur = _player.duration;
    var target = position;
    if (target.isNegative) target = Duration.zero;
    if (dur != null && dur > Duration.zero && target > dur) {
      target = dur - const Duration(milliseconds: 80);
      if (target.isNegative) target = Duration.zero;
    }

    // just_audio：loading 时 seek 会被直接忽略
    for (var i = 0; i < 50; i++) {
      final ps = _player.processingState;
      if (ps == ProcessingState.ready ||
          ps == ProcessingState.buffering ||
          ps == ProcessingState.completed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    final ps = _player.processingState;
    if (ps == ProcessingState.loading || ps == ProcessingState.idle) {
      debugPrint('[AudioHandler] seek skipped: still $ps');
      return;
    }

    // completed 后需先回到可播状态再 seek
    if (ps == ProcessingState.completed) {
      try {
        await _player.seek(target);
        _broadcastState(_player.playbackEvent);
        return;
      } catch (e) {
        debugPrint('[AudioHandler] seek from completed: $e');
      }
    }

    await _player.seek(target);
    _broadcastState(_player.playbackEvent);
  }

  String? get _currentPlayUrl {
    final extras = mediaItem.value?.extras;
    final url = extras?['url']?.toString();
    if (url != null && url.isNotEmpty && !url.startsWith('data:')) return url;
    return null;
  }

  String get _currentQualityLabel =>
      mediaItem.value?.extras?['actualQuality']?.toString() ??
      mediaItem.value?.extras?['requestedQuality']?.toString() ??
      preferredQuality;

  /// FLAC 等无损：just_audio 的 seek 会乐观改 updatePosition，但原生 AVPlayer
  /// 可能未真正 seek，导致 UI 到目标、音频还在旧位置（差十几秒）。
  /// 用 setAudioSource(initialPosition:) 强制按字节定位重载。
  Future<Duration> hardSeekTo(Duration displayPosition) async {
    final url = _currentPlayUrl;
    final tag = mediaItem.value;
    if (url == null || tag == null) {
      await seek(displayPosition);
      return _player.position;
    }

    var target = displayPosition;
    if (target.isNegative) target = Duration.zero;
    final dur = _player.duration;
    if (dur != null && dur > Duration.zero && target > dur) {
      target = dur - const Duration(milliseconds: 80);
      if (target.isNegative) target = Duration.zero;
    }

    // 不自动 play：由 scrub finish 的 resumeAfter 决定，避免 pause 拖动后误起播
    await _withAutoAdvanceSuppressed(() async {
      await _player.setAudioSource(
        audioSourceFor(url, tag: tag),
        initialPosition: target,
      );
      // setAudioSource 把事件 position 设为 initialPosition（原生已按字节定位）
      _broadcastState(_player.playbackEvent);
    });
    return _player.position;
  }

  /// 有损：普通 seek 一次；无损：hard seek 重载，再等待 position 稳定。
  Future<Duration> seekToDisplay(
    Duration displayPosition, {
    Duration? budget,
    Duration tolerance = const Duration(milliseconds: 150),
    int stableHits = 3,
  }) async {
    var target = displayPosition;
    if (target.isNegative) target = Duration.zero;

    if (isLosslessQuality(_currentQualityLabel)) {
      await hardSeekTo(target);
    } else {
      await seek(target);
    }
    return waitForSettledPosition(
      target,
      budget: budget,
      tolerance: tolerance,
      stableHits: stableHits,
      requirePlaying: false,
    );
  }

  /// 不起 seek，只在 [budget] 内轮询，直到 position 连续稳定在目标附近。
  /// FLAC 起播后禁止再 seek，否则解码重启、声音落后 UI。
  Future<Duration> waitForSettledPosition(
    Duration target, {
    Duration? budget,
    Duration tolerance = const Duration(milliseconds: 150),
    int stableHits = 3,
    bool requirePlaying = false,
  }) async {
    final quality = mediaItem.value?.extras?['actualQuality']?.toString() ??
        mediaItem.value?.extras?['requestedQuality']?.toString() ??
        preferredQuality;
    final settleBudget = budget ?? seekBudgetForQuality(quality);
    final deadline = DateTime.now().add(settleBudget);
    if (target.isNegative) target = Duration.zero;

    var hits = 0;
    Duration last = _player.position;
    while (DateTime.now().isBefore(deadline)) {
      final p = _player.position;
      final near =
          (p - target).inMilliseconds.abs() <= tolerance.inMilliseconds;
      final ready = _player.processingState == ProcessingState.ready ||
          _player.processingState == ProcessingState.buffering;
      final playingOk = !requirePlaying || _player.playing;
      if (near && ready && playingOk) {
        hits += 1;
        last = p;
        if (hits >= stableHits) {
          _broadcastState(_player.playbackEvent);
          return p;
        }
      } else {
        hits = 0;
        last = p;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }

    _broadcastState(_player.playbackEvent);
    return last;
  }

  @override
  Future<void> stop() async {
    _userWantsPlay = false;
    _bumpGeneration();
    await _player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext({bool seamless = false}) async {
    if (_queue.isEmpty) return;

    // 用户点「下一首」：立刻停当前曲，避免听感重叠。
    // 自动连播（seamless）：不要 pause/playing:false，否则锁屏下 iOS 会杀会话。
    if (!seamless) {
      await _haltCurrentPlayback();
    }
    _userWantsPlay = true;

    final shuffle = _player.shuffleModeEnabled ||
        playbackState.value.shuffleMode == AudioServiceShuffleMode.all;
    final loop = shuffle ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.all ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.one;
    final nextIndex = nextQueueIndex(
      currentIndex: _currentIndex,
      queueLength: _queue.length,
      shuffle: shuffle,
      loop: loop,
    );
    if (nextIndex < 0) return;
    await skipToQueueItem(nextIndex, seamless: seamless);
  }

  @override
  Future<void> skipToPrevious() async {
    if (_queue.isEmpty) return;

    await _haltCurrentPlayback();
    _userWantsPlay = true;

    final shuffle = _player.shuffleModeEnabled ||
        playbackState.value.shuffleMode == AudioServiceShuffleMode.all;
    final loop = shuffle ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.all ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.one;
    final prevIndex = previousQueueIndex(
      currentIndex: _currentIndex,
      queueLength: _queue.length,
      shuffle: shuffle,
      loop: loop,
    );
    if (prevIndex < 0) return;
    await skipToQueueItem(prevIndex);
  }

  /// 立刻停止当前输出并广播暂停态，提升手动切歌手感。
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
        final existingQ = item.extras?['requestedQuality']?.toString();
        if (shouldReuseCachedPlayUrl(
          cachedUrl: existing,
          cachedRequestedQuality: existingQ,
          currentRequestedQuality: preferredQuality,
        )) {
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
  Future<void> skipToQueueItem(int index, {bool seamless = false}) async {
    if (index < 0 || index >= _queue.length) return;

    final gen = _bumpGeneration();
    _userWantsPlay = true;
    final item = _queue[index];
    final itemId = item.id;
    _activeItemId = itemId;
    final cachedUrl = item.extras?['url']?.toString();
    final cachedQ = item.extras?['requestedQuality']?.toString();
    final canReuse = shouldReuseCachedPlayUrl(
      cachedUrl: cachedUrl,
      cachedRequestedQuality: cachedQ,
      currentRequestedQuality: preferredQuality,
    );
    String? currentUrl = canReuse ? cachedUrl : null;

    _currentIndex = index;
    mediaItem.add(item);

    await _withAutoAdvanceSuppressed(() async {
      try {
        String? url = currentUrl;

        if (url == null || url.isEmpty) {
          if (urlResolver != null) {
            // seamless 连播时保持 playing=true，只标 buffering，避免锁屏杀会话
            playbackState.add(playbackState.value.copyWith(
              processingState: AudioProcessingState.buffering,
              playing: seamless ? true : playbackState.value.playing,
            ));
            // 强制按当前 preferredQuality 重新解析，忽略过期的 extras.url
            final resolveExtras = item.extras == null
                ? <String, dynamic>{}
                : Map<String, dynamic>.from(item.extras!);
            resolveExtras.remove('url');
            resolveExtras.remove('remoteUrl');
            resolveExtras['requestedQuality'] = preferredQuality;
            url = await urlResolver!(item.id, resolveExtras);
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
          debugPrint('[AudioHandler] 无法获取播放链接: ${item.title} id=${item.id}');
          onError?.call('无法解析歌曲 "${item.title}" 的播放地址（源无效地址或本地缓存失败，已尝试降级音质）');
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
        baseExtras['requestedQuality'] =
            baseExtras['requestedQuality']?.toString() ?? preferredQuality;
        // urlResolver 可能已把 actualQuality/remoteUrl 写到 mediaItem，合并回来
        // 避免被队列 extras 覆盖后播放器只能显示请求音质。
        final live = mediaItem.value;
        if (live != null && live.id == itemId && live.extras != null) {
          final le = live.extras!;
          final aq = le['actualQuality']?.toString();
          final remote = le['remoteUrl']?.toString();
          final rq = le['requestedQuality']?.toString();
          final plat = le['platform']?.toString();
          if (aq != null && aq.isNotEmpty) baseExtras['actualQuality'] = aq;
          if (remote != null && remote.isNotEmpty) {
            baseExtras['remoteUrl'] = remote;
          }
          if (rq != null && rq.isNotEmpty) {
            baseExtras['requestedQuality'] = rq;
          }
          if (plat != null && plat.isNotEmpty) baseExtras['platform'] = plat;
        }
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
        // seamless 自动下一首必须 play，即使 completed 后 playing 已是 false
        if (_userWantsPlay || seamless) {
          _userWantsPlay = true;
          _startPlayer();
        }
        if (!_isStale(gen)) _schedulePreload();
      } catch (e) {
        debugPrint('[AudioHandler] 播放失败: $e');
        if (!_isStale(gen) && _currentIndex == index) {
          onError?.call('播放歌曲 "${item.title}" 失败: $e');
          if (_queue.length > 1) {
            await Future.delayed(const Duration(seconds: 2));
            if (!_isStale(gen) && _currentIndex == index) {
              await skipToNext(seamless: seamless);
            }
          }
        }
      }
    });
  }

  // 设置播放列表并开始播放
  Future<void> setPlaylist(List<MediaItem> items,
      {int initialIndex = 0}) async {
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
      _startPlayer();
    }
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _queue.add(mediaItem);
    queue.add(List.from(_queue));

    if (_player.audioSource is ConcatenatingAudioSource) {
      final source = _player.audioSource as ConcatenatingAudioSource;
      final url = mediaItem.extras?['url']?.toString() ?? '';
      await source.add(
          audioSourceFor(url.startsWith('data:') ? '' : url, tag: mediaItem));
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

  /// 合并 extras 到队列中指定 id 的项（不切换当前曲）。
  void patchQueueItemExtras(String mediaId, Map<String, dynamic> patch) {
    final idx = _queue.indexWhere((m) => m.id == mediaId);
    if (idx < 0) return;
    final extras = Map<String, dynamic>.from(_queue[idx].extras ?? {});
    extras.addAll(patch);
    _queue[idx] = _queue[idx].copyWith(extras: extras);
    queue.add(List.from(_queue));
    final current = mediaItem.value;
    if (current != null && current.id == mediaId) {
      final curExtras = Map<String, dynamic>.from(current.extras ?? {});
      curExtras.addAll(patch);
      mediaItem.add(current.copyWith(extras: curExtras));
    }
  }

  /// 设置页改音质后调用：清掉队列里过期的 url，并让当前曲按新音质重解析。
  Future<void> applyPreferredQuality(String quality) async {
    preferredQuality = quality;
    if (_queue.isEmpty) return;
    for (var i = 0; i < _queue.length; i++) {
      final extras = Map<String, dynamic>.from(_queue[i].extras ?? {});
      final cachedQ = extras['requestedQuality']?.toString();
      if (cachedQ != quality) {
        extras.remove('url');
        extras.remove('remoteUrl');
        extras['requestedQuality'] = quality;
        _queue[i] = _queue[i].copyWith(extras: extras);
      }
    }
    queue.add(List.from(_queue));
    final idx = _currentIndex;
    if (idx >= 0 && idx < _queue.length && _userWantsPlay) {
      await skipToQueueItem(idx);
    }
  }
}
