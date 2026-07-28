import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import 'playback_command_coordinator.dart';

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

/// iOS/macOS：开启精确时长与定位，否则 FLAC 等格式 seek 会失败或偏差很大，
/// 而 just_audio 仍乐观更新 position，造成歌词/进度与可听输出脱节。
const _preciseDarwinOptions = ProgressiveAudioSourceOptions(
  darwinAssetOptions: DarwinAssetOptions(
    preferPreciseDurationAndTiming: true,
  ),
);

AudioSource audioSourceFor(String url, {MediaItem? tag}) {
  // 未解析曲目用超长静音，避免短 WAV 瞬间 completed 连跳多首
  if (url.isEmpty) {
    return SilenceAudioSource(duration: const Duration(days: 1), tag: tag);
  }
  final uri = playableUri(url);
  // ProgressiveAudioSource 覆盖本地 file / 普通 http 媒体；m3u8/mpd 仍走 uri 工厂
  final path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
    return AudioSource.uri(uri, tag: tag);
  }
  return ProgressiveAudioSource(
    uri,
    tag: tag,
    options: _preciseDarwinOptions,
  );
}

AudioProcessingState audioProcessingState(ProcessingState state) =>
    switch (state) {
      ProcessingState.idle => AudioProcessingState.idle,
      ProcessingState.loading => AudioProcessingState.loading,
      ProcessingState.buffering => AudioProcessingState.buffering,
      ProcessingState.ready => AudioProcessingState.ready,
      ProcessingState.completed => AudioProcessingState.completed,
    };

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

int completionQueueIndex({
  required int currentIndex,
  required int queueLength,
  required AudioServiceRepeatMode repeatMode,
  required bool shuffle,
  int Function(int max)? randomNext,
}) {
  if (queueLength <= 0) return -1;
  if (repeatMode == AudioServiceRepeatMode.one) return currentIndex;
  return nextQueueIndex(
    currentIndex: currentIndex,
    queueLength: queueLength,
    shuffle: shuffle,
    loop: repeatMode == AudioServiceRepeatMode.all ||
        repeatMode == AudioServiceRepeatMode.group,
    randomNext: randomNext,
  );
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

class QualityReloadIntent {
  final Duration position;
  final bool resumeAfterReload;

  const QualityReloadIntent(this.position, this.resumeAfterReload);
}

QualityReloadIntent qualityReloadIntent({
  required Duration position,
  required Duration? duration,
  required bool wasPlaying,
}) {
  var clampedPosition = position.isNegative ? Duration.zero : position;
  if (duration != null &&
      duration >= Duration.zero &&
      clampedPosition > duration) {
    clampedPosition = duration;
  }
  return QualityReloadIntent(clampedPosition, wasPlaying);
}

enum InterruptionAction {
  none,
  pausePreservingIntent,
  pauseClearingIntent,
  resume,
}

class AudioInterruptionPolicy {
  int _depth = 0;
  bool _ownsPause = false;
  bool _mayResume = true;

  bool get active => _depth > 0;
  int get depth => _depth;

  InterruptionAction onBegin({required bool wasPlaying}) {
    _depth++;
    if (_depth > 1) return InterruptionAction.none;
    _ownsPause = wasPlaying;
    _mayResume = true;
    return wasPlaying
        ? InterruptionAction.pausePreservingIntent
        : InterruptionAction.none;
  }

  InterruptionAction onEnd({
    required bool userStillWantsPlay,
    required bool mayResume,
  }) {
    if (_depth == 0) return InterruptionAction.none;
    if (!mayResume) _mayResume = false;
    _depth--;
    if (_depth > 0) return InterruptionAction.none;
    final ownsPause = _ownsPause;
    final cycleMayResume = _mayResume;
    _ownsPause = false;
    _mayResume = true;
    return ownsPause && userStillWantsPlay && cycleMayResume
        ? InterruptionAction.resume
        : InterruptionAction.none;
  }

  InterruptionAction onBecomingNoisy() {
    _depth = 0;
    _ownsPause = false;
    _mayResume = true;
    return InterruptionAction.pauseClearingIntent;
  }
}

class PlaybackStartProvenance {
  final int interruptionGeneration;
  final int blockGeneration;

  const PlaybackStartProvenance(
    this.interruptionGeneration,
    this.blockGeneration,
  );
}

class LxAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final AudioPlayer _player;
  late final PlaybackCommandCoordinator _commands;
  final AudioInterruptionPolicy _interruptionPolicy = AudioInterruptionPolicy();
  final List<MediaItem> _queue = [];
  int _currentIndex = 0;

  /// 单调世代：setPlaylist/切歌时递增，取消过期的异步解析/播放
  int _playGeneration = 0;
  int _seekGeneration = 0;
  bool _userWantsPlay = true;
  int _userIntentGeneration = 0;
  int _installedSourceOwnerToken = 0;
  int _installedPlaybackGeneration = -1;
  String? _installedMediaId;
  int _lastHandledCompletionGeneration = -1;
  String? _activeItemId;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  int _playbackPublicationToken = 0;
  int _interruptionGeneration = 0;
  int _playbackStartBlockGeneration = 0;
  bool _interruptionClosing = false;
  int? _interruptionSourceGeneration;
  int? _interruptionUserIntentGeneration;
  String? _interruptionMediaId;

  // 注入 URL 解析器
  UrlResolver? urlResolver;

  /// 当前播放偏好音质（由设置页同步）；用于判断 extras 缓存 url 是否可复用。
  String preferredQuality = '320k';

  // 注入错误回调
  void Function(String message)? onError;

  LxAudioHandler({AudioPlayer? player}) : _player = player ?? AudioPlayer() {
    _commands = PlaybackCommandCoordinator(
      _player,
      onStateChanged: _publishPlaybackState,
      onError: (operation, error, _) {
        debugPrint('[AudioHandler] $operation failed: $error');
      },
    );
    _publishPlaybackState();
    _init();
  }

  AudioPlayer get player => _player;

  /// 当前内部播放队列（供 urlResolver 按 id 查找 extras）
  List<MediaItem> get queueItems => List.unmodifiable(_queue);
  int get currentQueueIndex => _queue.isEmpty ? -1 : _currentIndex;
  int get sourceGeneration => _playGeneration;
  int get userIntentGeneration => _userIntentGeneration;
  bool get interruptionActive =>
      _interruptionPolicy.active || _interruptionClosing;
  int get interruptionDepth => _interruptionPolicy.depth;
  int get interruptionGeneration => _interruptionGeneration;
  int get playbackStartBlockGeneration => _playbackStartBlockGeneration;

  PlaybackStartProvenance _captureStartProvenance() => PlaybackStartProvenance(
        _interruptionGeneration,
        _playbackStartBlockGeneration,
      );

  int _bumpGeneration() => ++_playGeneration;

  bool _isStale(int gen) => gen != _playGeneration;

  int _expressPlaybackIntent(bool wantsPlay) {
    _userIntentGeneration++;
    _userWantsPlay = wantsPlay;
    return _userIntentGeneration;
  }

  int _expressPlayIntent() => _expressPlaybackIntent(true);

  Future<void> _stopPlayerSource() => _commands.stop();

  bool _mayStartAfterInterruption({
    required PlaybackStartProvenance provenance,
  }) =>
      !interruptionActive &&
      provenance.blockGeneration == _playbackStartBlockGeneration &&
      provenance.interruptionGeneration == _interruptionGeneration;

  void _init() {
    _player.playbackEventStream.listen((_) => _publishPlaybackState());

    // 播放完成 → 无缝连播下一首。
    // 锁屏/后台时绝不能先 pause + playing:false：iOS 会结束后台音频会话。
    _player.processingStateStream.listen((state) {
      if (state != ProcessingState.completed) return;
      _onTrackCompleted();
    });
  }

  void _onTrackCompleted() {
    // 自动连播视为用户仍要听：拖进度 pause 不 clearIntent 时仍可连播
    if (!_userWantsPlay) return;
    if (interruptionActive) return;
    if (_queue.isEmpty) return;
    if (!_commands.installedSourceIsAuthoritative) return;
    if (_installedPlaybackGeneration != _playGeneration) return;
    final gen = _installedPlaybackGeneration;
    if (_lastHandledCompletionGeneration == gen) return;
    final expectedId = _activeItemId;
    final expectedIndex = _currentIndex;
    if (expectedId == null ||
        expectedIndex < 0 ||
        expectedIndex >= _queue.length ||
        _queue[expectedIndex].id != expectedId ||
        mediaItem.value?.id != expectedId ||
        _installedMediaId != expectedId) {
      return;
    }
    final expectedIntentGeneration = _userIntentGeneration;
    final provenance = _captureStartProvenance();
    _lastHandledCompletionGeneration = gen;
    final shuffle = _player.shuffleModeEnabled ||
        playbackState.value.shuffleMode == AudioServiceShuffleMode.all;
    final target = completionQueueIndex(
      currentIndex: expectedIndex,
      queueLength: _queue.length,
      repeatMode: playbackState.value.repeatMode,
      shuffle: shuffle,
    );
    if (target < 0) return;
    debugPrint(
        '[AudioHandler] track completed idx=$expectedIndex target=$target');
    Future(() async {
      try {
        if (_isStale(gen) ||
            !_commands.installedSourceIsAuthoritative ||
            _installedPlaybackGeneration != gen ||
            _installedMediaId != expectedId ||
            _activeItemId != expectedId ||
            _currentIndex != expectedIndex ||
            expectedIndex >= _queue.length ||
            _queue[expectedIndex].id != expectedId ||
            mediaItem.value?.id != expectedId ||
            _userIntentGeneration != expectedIntentGeneration ||
            !_userWantsPlay) {
          return;
        }
        await _loadQueueItem(
          target,
          seamless: true,
          preserveUserIntent: true,
          provenance: provenance,
        );
      } catch (e) {
        debugPrint('[AudioHandler] auto-next failed: $e');
      }
    });
  }

  // 将播放状态广播给系统控制中心
  int _publishPlaybackState({
    AudioProcessingState? override,
    bool? playingOverride,
    Duration? positionOverride,
  }) {
    final playing = playingOverride ?? _player.playing;
    final publicationToken = ++_playbackPublicationToken;
    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.stop,
        MediaControl.skipToNext,
      ],
      systemActions: {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      processingState:
          override ?? audioProcessingState(_player.processingState),
      playing: playing,
      updatePosition: positionOverride ?? _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      queueIndex: currentQueueIndex,
      repeatMode: _repeatMode,
      shuffleMode: _shuffleMode,
    ));
    return publicationToken;
  }

  @override
  Future<void> play() async {
    _userIntentGeneration++;
    _userWantsPlay = true;
    if (_player.processingState == ProcessingState.idle) {
      unawaited(_commands.explicitPlay());
      await _commands.recoverIdleSource();
    } else {
      await _commands.explicitPlay();
    }
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
  Future<PreservingPauseOwner?> pauseInternal({bool clearIntent = true}) async {
    if (clearIntent) {
      _userIntentGeneration++;
      _userWantsPlay = false;
    }
    final owner = clearIntent ? null : await _commands.pausePreservingIntent();
    if (clearIntent) await _commands.explicitPause();
    await super.pause();
    return owner;
  }

  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) async {
    final provenance = _captureStartProvenance();
    final owner = await _commands.pausePreservingIntent();
    await super.pause();

    final stale = sourceGeneration != _playGeneration ||
        userIntentGeneration != _userIntentGeneration ||
        !stillOwnsScrub();
    if (stale) {
      await _commands.releasePreservingIntent(owner);
      if (_userWantsPlay) {
        _restoreAuthoritativePlaybackAfterScrubPause(provenance: provenance);
      }
      return null;
    }
    return owner;
  }

  Future<void> beginAudioInterruption() async {
    final firstBegin = !_interruptionPolicy.active;
    if (firstBegin) {
      ++_interruptionGeneration;
      _interruptionClosing = false;
      _interruptionSourceGeneration = _playGeneration;
      _interruptionUserIntentGeneration = _userIntentGeneration;
      _interruptionMediaId = _activeItemId;
    }
    final action = _interruptionPolicy.onBegin(
      wasPlaying: _player.playing || (_userWantsPlay && _activeItemId != null),
    );
    final interruptionGeneration = _interruptionGeneration;
    final sourceGeneration = _interruptionSourceGeneration;
    final userIntentGeneration = _interruptionUserIntentGeneration;

    await _commands.beginInterruption();
    if (action == InterruptionAction.pausePreservingIntent &&
        interruptionGeneration == _interruptionGeneration &&
        interruptionActive &&
        sourceGeneration != null &&
        userIntentGeneration != null) {
      await super.pause();
    }
  }

  Future<void> endAudioInterruption({required bool mayResume}) async {
    final previousDepth = interruptionDepth;
    final interruptionGeneration = _interruptionGeneration;
    final action = _interruptionPolicy.onEnd(
      userStillWantsPlay: _userWantsPlay,
      mayResume: mayResume,
    );
    if (previousDepth == 0) return;
    final finalEnd = interruptionDepth == 0;
    if (finalEnd) _interruptionClosing = true;
    final ownsPlayback = _interruptionSourceGeneration == _playGeneration &&
        _interruptionUserIntentGeneration == _userIntentGeneration &&
        _interruptionMediaId == _activeItemId &&
        _userWantsPlay;
    await _commands.endInterruption(
      mayResume: mayResume,
      allowAutomaticResume: !finalEnd || ownsPlayback,
    );
    if (interruptionGeneration != _interruptionGeneration) return;
    if (!finalEnd || _interruptionPolicy.active) return;
    _interruptionClosing = false;
    if (action == InterruptionAction.resume && ownsPlayback) {
      if (_player.processingState == ProcessingState.completed) {
        _onTrackCompleted();
      }
    } else if (action != InterruptionAction.resume) {
      ++_playbackStartBlockGeneration;
    }
    _clearInterruptionOwnership();
  }

  Future<void> handleBecomingNoisy() async {
    if (_interruptionPolicy.onBecomingNoisy() ==
        InterruptionAction.pauseClearingIntent) {
      ++_interruptionGeneration;
      ++_playbackStartBlockGeneration;
      _interruptionClosing = false;
      _clearInterruptionOwnership();
      _expressPlaybackIntent(false);
      await _commands.becomingNoisy();
      await super.pause();
    }
  }

  void _clearInterruptionOwnership() {
    _interruptionSourceGeneration = null;
    _interruptionUserIntentGeneration = null;
    _interruptionMediaId = null;
  }

  void _adoptInstalledSourceForInterruption({
    required int sourceGeneration,
    required String mediaId,
  }) {
    if (!interruptionActive ||
        _interruptionUserIntentGeneration != _userIntentGeneration ||
        _interruptionMediaId != mediaId) {
      return;
    }
    _interruptionSourceGeneration = sourceGeneration;
  }

  Future<void> releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    int? interruptionGeneration,
    int? startBlockGeneration,
  }) async {
    if (owner == null) return;
    final stopIfStillOwnsIntent = !resumeAfter &&
        sourceGeneration == _playGeneration &&
        userIntentGeneration == _userIntentGeneration;
    final provenance = PlaybackStartProvenance(
      interruptionGeneration ?? _interruptionGeneration,
      startBlockGeneration ?? _playbackStartBlockGeneration,
    );
    if (provenance.blockGeneration != _playbackStartBlockGeneration ||
        (!interruptionActive &&
            provenance.interruptionGeneration != _interruptionGeneration)) {
      await _commands.releasePreservingIntent(
        owner,
        stopIfStillOwnsIntent: stopIfStillOwnsIntent,
      );
      return;
    }
    await _commands.releasePreservingIntent(
      owner,
      stopIfStillOwnsIntent: stopIfStillOwnsIntent,
    );
  }

  void _restoreAuthoritativePlaybackAfterScrubPause({
    PlaybackStartProvenance? provenance,
  }) {
    final startProvenance = provenance ?? _captureStartProvenance();
    final sourceGeneration = _playGeneration;
    final userIntentGeneration = _userIntentGeneration;
    final sourceOwnerToken = _installedSourceOwnerToken;
    final itemId = _activeItemId;
    final index = _currentIndex;

    bool stillOwnsRestore() =>
        _userWantsPlay &&
        _mayStartAfterInterruption(provenance: startProvenance) &&
        !interruptionActive &&
        sourceGeneration == _playGeneration &&
        userIntentGeneration == _userIntentGeneration &&
        sourceOwnerToken == _installedSourceOwnerToken &&
        _installedPlaybackGeneration == sourceGeneration &&
        _installedMediaId == itemId &&
        itemId != null &&
        mediaItem.value?.id == itemId &&
        index == _currentIndex &&
        index >= 0 &&
        index < _queue.length &&
        _queue[index].id == itemId;

    if (!stillOwnsRestore()) return;
    final started = stillOwnsRestore();
    if (started) {
      _publishPlaybackState(playingOverride: true);
    }
  }

  @override
  Future<void> seek(Duration position) async {
    await seekConfirmed(position);
  }

  Future<Duration?> seekConfirmed(Duration position) async {
    final sourceGeneration = _playGeneration;
    final seekGeneration = ++_seekGeneration;

    bool ownsSeek() =>
        sourceGeneration == _playGeneration &&
        seekGeneration == _seekGeneration;
    if (!ownsSeek()) return null;

    final dur = _player.duration;
    var target = position;
    if (target.isNegative) target = Duration.zero;
    if (dur != null && dur > Duration.zero && target > dur) {
      target = dur - const Duration(milliseconds: 80);
      if (target.isNegative) target = Duration.zero;
    }

    // just_audio ignores seeks while loading. Wait only for source readiness,
    // never for the position to settle.
    for (var i = 0; i < 50 && ownsSeek(); i++) {
      final ps = _player.processingState;
      if (ps == ProcessingState.ready ||
          ps == ProcessingState.buffering ||
          ps == ProcessingState.completed) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 40));
    }
    final ps = _player.processingState;
    if (!ownsSeek() ||
        ps == ProcessingState.loading ||
        ps == ProcessingState.idle) {
      debugPrint('[AudioHandler] seek skipped: still $ps');
      return null;
    }

    if (!await _commands.seek(target) || !ownsSeek()) return null;

    var confirmed = _player.position;
    if (confirmed.isNegative) confirmed = Duration.zero;
    final confirmedDuration = _player.duration;
    if (confirmedDuration != null && confirmed > confirmedDuration) {
      confirmed = confirmedDuration;
    }
    _publishPlaybackState(positionOverride: confirmed);
    return confirmed;
  }

  @override
  Future<void> stop() async {
    _userIntentGeneration++;
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    _userWantsPlay = false;
    _bumpGeneration();
    await _stopPlayerSource();
    await super.stop();
  }

  @override
  Future<void> skipToNext({bool seamless = false}) async {
    final provenance = _captureStartProvenance();
    final intentGeneration = _expressPlayIntent();
    unawaited(_commands.setPlayingPreservingIntent(true));
    await _skipToNextInternal(
      seamless: seamless,
      expectedUserIntentGeneration: intentGeneration,
      provenance: provenance,
    );
  }

  Future<void> _skipToNextInternal({
    bool seamless = false,
    int? expectedUserIntentGeneration,
    PlaybackStartProvenance? provenance,
  }) async {
    if (_queue.isEmpty) return;

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
    final sourceCommandToken = _commands.requestSource(
      mediaId: _queue[nextIndex].id,
      queueIndex: nextIndex,
      position: Duration.zero,
    );

    // 用户点「下一首」：立刻停当前曲，避免听感重叠。
    // 自动连播（seamless）：不要 pause/playing:false，否则锁屏下 iOS 会杀会话。
    final halt = seamless ? null : await _haltCurrentPlayback();
    if (seamless) _userWantsPlay = true;
    await _loadQueueItem(
      nextIndex,
      seamless: seamless,
      preserveUserIntent: true,
      bufferingPublication: halt?.publication,
      expectedUserIntentGeneration: expectedUserIntentGeneration,
      provenance: provenance,
      sourceCommandToken: sourceCommandToken,
      preservingPauseOwner: halt?.owner,
    );
  }

  @override
  Future<void> skipToPrevious() async {
    final provenance = _captureStartProvenance();
    final intentGeneration = _expressPlayIntent();
    unawaited(_commands.setPlayingPreservingIntent(true));
    await _skipToPreviousInternal(
      expectedUserIntentGeneration: intentGeneration,
      provenance: provenance,
    );
  }

  Future<void> _skipToPreviousInternal({
    int? expectedUserIntentGeneration,
    PlaybackStartProvenance? provenance,
  }) async {
    if (_queue.isEmpty) return;

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
    final sourceCommandToken = _commands.requestSource(
      mediaId: _queue[prevIndex].id,
      queueIndex: prevIndex,
      position: Duration.zero,
    );
    final halt = await _haltCurrentPlayback();
    await _loadQueueItem(
      prevIndex,
      preserveUserIntent: true,
      bufferingPublication: halt.publication,
      expectedUserIntentGeneration: expectedUserIntentGeneration,
      provenance: provenance,
      sourceCommandToken: sourceCommandToken,
      preservingPauseOwner: halt.owner,
    );
  }

  /// 立刻停止当前输出并广播暂停态，提升手动切歌手感。
  Future<_PlaybackHalt> _haltCurrentPlayback() async {
    _bumpGeneration();
    final owner = await _commands.pausePreservingIntent();
    return _PlaybackHalt(
      owner,
      _publishPlaybackState(override: AudioProcessingState.buffering),
    );
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
    final provenance = _captureStartProvenance();
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
              await _loadQueueItem(
                idx,
                preserveUserIntent: true,
                provenance: provenance,
              );
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
  Future<void> skipToQueueItem(
    int index, {
    bool seamless = false,
    Duration initialPosition = Duration.zero,
    bool playAfterLoad = true,
  }) async {
    final provenance = _captureStartProvenance();
    final intentGeneration = _expressPlaybackIntent(playAfterLoad);
    final selectedItemId =
        index >= 0 && index < _queue.length ? _queue[index].id : null;
    final sourceGeneration = _playGeneration;
    if (selectedItemId == null) return;
    unawaited(playAfterLoad
        ? _commands.setPlayingPreservingIntent(true)
        : _commands.explicitPause());
    final sourceCommandToken = _commands.requestSource(
      mediaId: selectedItemId,
      queueIndex: index,
      position: initialPosition,
    );
    var selectionPauseOwner = !playAfterLoad && _player.playing
        ? await pauseInternal(clearIntent: false)
        : null;
    try {
      if (_playGeneration != sourceGeneration) return;
      final selectedIndex =
          _queue.indexWhere((item) => item.id == selectedItemId);
      if (selectedIndex < 0) return;
      final latestIntentGeneration = _userIntentGeneration;
      final latestPlayAfterLoad = latestIntentGeneration == intentGeneration
          ? playAfterLoad
          : _userWantsPlay;
      final owner = selectionPauseOwner;
      selectionPauseOwner = null;
      await _loadQueueItem(
        selectedIndex,
        seamless: seamless,
        preserveUserIntent: true,
        initialPosition: initialPosition,
        playAfterLoad: latestPlayAfterLoad,
        expectedUserIntentGeneration: latestIntentGeneration,
        provenance: provenance,
        sourceCommandToken: sourceCommandToken,
        preservingPauseOwner: owner,
      );
    } finally {
      final owner = selectionPauseOwner;
      if (owner != null) await _commands.releasePreservingIntent(owner);
    }
  }

  Future<void> _loadQueueItem(
    int index, {
    bool seamless = false,
    bool preserveUserIntent = false,
    bool recoverStaleInstall = true,
    int? bufferingPublication,
    Duration initialPosition = Duration.zero,
    bool? playAfterLoad,
    int? expectedUserIntentGeneration,
    PlaybackStartProvenance? provenance,
    int? sourceCommandToken,
    PreservingPauseOwner? preservingPauseOwner,
  }) async {
    try {
      if (index < 0 || index >= _queue.length) return;

      final startProvenance = provenance ?? _captureStartProvenance();
      final gen = _bumpGeneration();
      if (!preserveUserIntent) _userWantsPlay = true;
      final item = _queue[index];
      final itemId = item.id;
      final commandToken = sourceCommandToken ??
          _commands.requestSource(
            mediaId: itemId,
            queueIndex: index,
            position: initialPosition,
          );
      int activeItemIndex() {
        if (_isStale(gen) ||
            !_commands.ownsSourceRequest(commandToken) ||
            _activeItemId != itemId ||
            mediaItem.value?.id != itemId) {
          return -1;
        }
        final relocated =
            _queue.indexWhere((queueItem) => queueItem.id == itemId);
        return relocated >= 0 && _currentIndex == relocated ? relocated : -1;
      }

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
      var manualBufferingPublication = bufferingPublication;
      var sourceInstallAttempted = false;
      var sourceTransitionFollows = false;

      try {
        String? url = currentUrl;

        if (url == null || url.isEmpty) {
          if (urlResolver != null) {
            // seamless 连播时保持 playing=true，只标 buffering，避免锁屏杀会话
            manualBufferingPublication = _publishPlaybackState(
              override: AudioProcessingState.buffering,
              playingOverride: seamless ? true : null,
            );
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

        var transactionIndex = activeItemIndex();
        if (transactionIndex < 0) return;
        final refreshed = _queue[transactionIndex].extras?['url']?.toString();
        if ((url == null || url.isEmpty) &&
            refreshed != null &&
            refreshed.isNotEmpty &&
            !refreshed.startsWith('data:')) {
          url = refreshed;
        }

        if (url == null || url.isEmpty) {
          if (_player.playing) {
            preservingPauseOwner ??= await _commands.pausePreservingIntent();
          }
          transactionIndex = activeItemIndex();
          if (transactionIndex < 0) return;
          debugPrint('[AudioHandler] 无法获取播放链接: ${item.title} id=${item.id}');
          onError?.call('无法解析歌曲 "${item.title}" 的播放地址（源无效地址或本地缓存失败，已尝试降级音质）');
          if (_queue.length > 1 && _currentIndex == transactionIndex) {
            await Future.delayed(const Duration(seconds: 5));
            transactionIndex = activeItemIndex();
            if (transactionIndex >= 0 && _currentIndex == transactionIndex) {
              await _skipToNextInternal(provenance: startProvenance);
            }
          }
          return;
        }

        final baseExtras =
            Map<String, dynamic>.from(_queue[transactionIndex].extras ?? {});
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
        final updatedItem =
            _queue[transactionIndex].copyWith(extras: baseExtras);
        _queue[transactionIndex] = updatedItem;
        queue.add(List.from(_queue));
        mediaItem.add(updatedItem);
        _activeItemId = itemId;

        // URL 解析在协调器外；提交结果时必须仍拥有源请求。
        if (_isStale(gen)) return;
        var recoverAuthoritative = false;
        transactionIndex = activeItemIndex();
        if (transactionIndex < 0 ||
            !_commands.ownsSourceRequest(commandToken)) {
          return;
        }
        sourceInstallAttempted = true;
        final commitResult = await _commands.commitSource(
          commandToken,
          audioSourceFor(url, tag: updatedItem),
        );
        sourceTransitionFollows = true;
        if (commitResult is SourceCommitStale) {
          if (commitResult.nativeInstallApplied && recoverStaleInstall) {
            await _recoverAuthoritativeSource(provenance: startProvenance);
          }
          return;
        }
        if (commitResult is SourceCommitFailed) {
          Error.throwWithStackTrace(
            commitResult.error,
            commitResult.stackTrace,
          );
        }
        _installedSourceOwnerToken = commandToken;
        transactionIndex = activeItemIndex();
        if (transactionIndex < 0) {
          recoverAuthoritative = recoverStaleInstall && _playGeneration == gen;
        } else {
          _installedPlaybackGeneration = gen;
          _installedMediaId = itemId;
          _adoptInstalledSourceForInterruption(
            sourceGeneration: gen,
            mediaId: itemId,
          );
          _publishPlaybackState(
            playingOverride: _commands.effectivePlaying ? true : null,
          );
          if (!_isStale(gen)) _schedulePreload();
        }
        if (recoverAuthoritative) {
          await _recoverAuthoritativeSource(provenance: startProvenance);
        }
      } catch (e) {
        debugPrint('[AudioHandler] 播放失败: $e');
        var transactionIndex = activeItemIndex();
        if (transactionIndex >= 0 && _currentIndex == transactionIndex) {
          onError?.call('播放歌曲 "${item.title}" 失败: $e');
          if (_queue.length > 1) {
            transactionIndex = activeItemIndex();
            if (transactionIndex >= 0 && _currentIndex == transactionIndex) {
              await _skipToNextInternal(
                seamless: seamless,
                provenance: startProvenance,
              );
            }
          }
        }
      } finally {
        if (!sourceInstallAttempted &&
            !sourceTransitionFollows &&
            manualBufferingPublication == _playbackPublicationToken) {
          _publishPlaybackState();
        }
      }
    } finally {
      if (preservingPauseOwner != null) {
        await _commands.releasePreservingIntent(preservingPauseOwner);
      }
    }
  }

  Future<void> _recoverAuthoritativeSource({
    required PlaybackStartProvenance provenance,
  }) async {
    final authoritativeId = mediaItem.value?.id;
    if (authoritativeId == null || _activeItemId != authoritativeId) return;
    final authoritativeIndex =
        _queue.indexWhere((item) => item.id == authoritativeId);
    if (authoritativeIndex < 0 || _currentIndex != authoritativeIndex) return;

    await _loadQueueItem(
      authoritativeIndex,
      preserveUserIntent: true,
      recoverStaleInstall: false,
      provenance: provenance,
    );
  }

  // 设置播放列表并开始播放
  Future<void> setPlaylist(List<MediaItem> items,
      {int initialIndex = 0}) async {
    final provenance = _captureStartProvenance();
    _expressPlayIntent();
    unawaited(_commands.setPlayingPreservingIntent(true));
    _bumpGeneration();
    _queue
      ..clear()
      ..addAll(items);
    queue.add(List.from(_queue));

    if (items.isEmpty) {
      await _stopPlayerSource();
      return;
    }

    final safeIndex = initialIndex.clamp(0, items.length - 1);
    _currentIndex = safeIndex;
    _activeItemId = items[safeIndex].id;
    mediaItem.add(items[safeIndex]);

    // 始终走 skipToQueueItem，统一解析/缓存/预加载
    await _loadQueueItem(
      safeIndex,
      preserveUserIntent: true,
      provenance: provenance,
    );
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) async {
    final currentId = mediaItem.value?.id;
    _queue
      ..clear()
      ..addAll(queue);
    if (_queue.isEmpty) {
      _currentIndex = -1;
      _activeItemId = null;
      this.queue.add(const <MediaItem>[]);
      mediaItem.add(null);
      await _stopInternal();
      return;
    }
    final retained = currentId == null
        ? -1
        : _queue.indexWhere((item) => item.id == currentId);
    _currentIndex = retained >= 0 ? retained : 0;
    _activeItemId = _queue[_currentIndex].id;
    if (retained < 0) {
      _bumpGeneration();
      _commands.requestSource(
        mediaId: _activeItemId!,
        queueIndex: _currentIndex,
        position: Duration.zero,
      );
    }
    this.queue.add(List.unmodifiable(_queue));
    mediaItem.add(_queue[_currentIndex]);
    _publishPlaybackState();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) async {
    _queue.add(mediaItem);
    queue.add(List.from(_queue));
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) async {
    final provenance = _captureStartProvenance();
    final targetId = mediaItem.id;
    var index = _queue.indexWhere((item) => item.id == targetId);
    if (index != -1) {
      final currentId = this.mediaItem.value?.id;
      final removedCurrent = currentId == targetId;
      final wasPlaying = _player.playing;
      final wantedPlay = _userWantsPlay;
      final intentGeneration = _userIntentGeneration;
      _PlaybackHalt? halt;
      if (removedCurrent && _activeItemId != targetId) return;
      if (removedCurrent && wasPlaying) {
        halt = await _haltCurrentPlayback();
        index = _queue.indexWhere((item) => item.id == targetId);
        if (index < 0) {
          await _commands.releasePreservingIntent(halt.owner);
          return;
        }
        _currentIndex = index;
        _activeItemId = targetId;
        this.mediaItem.add(_queue[index]);
      }
      _queue.removeAt(index);

      if (_queue.isEmpty) {
        _currentIndex = -1;
        _activeItemId = null;
        queue.add(const <MediaItem>[]);
        this.mediaItem.add(null);
        if (halt != null) {
          await _commands.releasePreservingIntent(halt.owner);
        }
        await _stopInternal();
        return;
      }

      final retainedIndex = currentId == null
          ? -1
          : _queue.indexWhere((item) => item.id == currentId);
      final replacementIndex = index.clamp(0, _queue.length - 1);
      if (removedCurrent) {
        final replacementId = _queue[replacementIndex].id;
        final sourceCommandToken = _commands.requestSource(
          mediaId: replacementId,
          queueIndex: replacementIndex,
          position: Duration.zero,
        );
        queue.add(List.unmodifiable(_queue));
        final preservingPauseOwner = halt?.owner;
        final bufferingPublication = halt?.publication;
        halt = null;
        await _loadQueueItem(
          replacementIndex,
          preserveUserIntent: true,
          bufferingPublication: bufferingPublication,
          provenance: provenance,
          sourceCommandToken: sourceCommandToken,
          preservingPauseOwner: preservingPauseOwner,
        );
        var relocatedReplacement =
            _queue.indexWhere((item) => item.id == replacementId);
        if (relocatedReplacement < 0 ||
            this.mediaItem.value?.id != replacementId ||
            _activeItemId != replacementId) {
          return;
        }
        if (_userIntentGeneration == intentGeneration && !wasPlaying) {
          final owner = await pauseInternal(clearIntent: false);
          if (owner != null) await _commands.releasePreservingIntent(owner);
          relocatedReplacement =
              _queue.indexWhere((item) => item.id == replacementId);
          if (relocatedReplacement < 0 ||
              this.mediaItem.value?.id != replacementId ||
              _activeItemId != replacementId) {
            return;
          }
        }
        if (_userIntentGeneration == intentGeneration) {
          _userWantsPlay = wantedPlay;
        }
        return;
      }

      _currentIndex = retainedIndex >= 0
          ? retainedIndex
          : _currentIndex.clamp(0, _queue.length - 1);
      final currentItem = _queue[_currentIndex];
      _activeItemId = currentItem.id;
      queue.add(List.unmodifiable(_queue));
      this.mediaItem.add(currentItem);
      _publishPlaybackState();
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    _repeatMode = repeatMode;
    _publishPlaybackState();
    // Single-source repeat is explicit so every replay emits one completion.
    await _commands.setLoopMode(LoopMode.off);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    _shuffleMode = shuffleMode;
    _publishPlaybackState();
    await _commands.setShuffleModeEnabled(enabled);
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
    final provenance = _captureStartProvenance();
    final reloadIntent = qualityReloadIntent(
      position: _player.position,
      duration: _player.duration,
      wasPlaying: _player.playing,
    );
    preferredQuality = quality;
    if (_queue.isEmpty) return;
    final reloadItemId = mediaItem.value?.id;
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
    final sourceGeneration = _playGeneration;
    final initialIntentGeneration = _userIntentGeneration;
    final initialIndex = reloadItemId == null
        ? -1
        : _queue.indexWhere((item) => item.id == reloadItemId);
    if (initialIndex < 0 || _currentIndex != initialIndex) return;
    final sourceCommandToken = _commands.requestSource(
      mediaId: reloadItemId!,
      queueIndex: initialIndex,
      position: reloadIntent.position,
    );
    unawaited(
      _commands.setPlayingPreservingIntent(reloadIntent.resumeAfterReload),
    );
    var qualityPauseOwner = reloadIntent.resumeAfterReload
        ? await pauseInternal(clearIntent: false)
        : null;
    try {
      if (_playGeneration != sourceGeneration) return;

      final idx = _queue.indexWhere((item) => item.id == reloadItemId);
      if (idx < 0 ||
          _currentIndex != idx ||
          mediaItem.value?.id != reloadItemId ||
          _activeItemId != reloadItemId) {
        return;
      }
      final intentGeneration = _userIntentGeneration;
      final playAfterLoad = intentGeneration == initialIntentGeneration
          ? reloadIntent.resumeAfterReload
          : _userWantsPlay;
      final owner = qualityPauseOwner;
      qualityPauseOwner = null;
      await _loadQueueItem(
        idx,
        preserveUserIntent: true,
        initialPosition: reloadIntent.position,
        playAfterLoad: playAfterLoad,
        expectedUserIntentGeneration: intentGeneration,
        provenance: provenance,
        sourceCommandToken: sourceCommandToken,
        preservingPauseOwner: owner,
      );
    } finally {
      final owner = qualityPauseOwner;
      if (owner != null) await _commands.releasePreservingIntent(owner);
    }
  }
}

class _PlaybackHalt {
  final PreservingPauseOwner owner;
  final int publication;

  const _PlaybackHalt(this.owner, this.publication);
}
