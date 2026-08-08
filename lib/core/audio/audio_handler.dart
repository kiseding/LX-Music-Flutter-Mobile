import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:rxdart/rxdart.dart';

import '../logging/app_log.dart';
import 'playback_cache_service.dart';
import 'playback_command_coordinator.dart';

late AudioHandler audioHandler;

// 定义一个函数签名，用于动态获取 URL（extras 为该曲目元数据，避免预加载时误用当前曲）
typedef UrlResolver = Future<String?> Function(String mediaId,
    [Map<String, dynamic>? extras]);

typedef LazyQueueLoader = Future<List<MediaItem>> Function(int minimumItems);
typedef LazyQueueShuffleRebuilder = Future<List<MediaItem>> Function(
  MediaItem current,
  bool shuffle,
  int minimumItems,
);

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
  darwinAssetOptions: DarwinAssetOptions(preferPreciseDurationAndTiming: true),
);

AudioSource audioSourceFor(
  String url, {
  MediaItem? tag,
  Map<String, String>? headers,
}) {
  // 未解析曲目用超长静音，避免短 WAV 瞬间 completed 连跳多首
  if (url.isEmpty) {
    return SilenceAudioSource(duration: const Duration(days: 1), tag: tag);
  }
  final uri = playableUri(url);
  // ProgressiveAudioSource 覆盖本地 file / 普通 http 媒体；m3u8/mpd 仍走 uri 工厂
  final path = uri.path.toLowerCase();
  if (path.endsWith('.m3u8') || path.endsWith('.mpd')) {
    return AudioSource.uri(uri, headers: headers, tag: tag);
  }
  return ProgressiveAudioSource(
    uri,
    headers: headers,
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

/// 仅复用本地缓存文件。远程媒体 URL 可能带短期签名，必须重新解析。
bool shouldReuseCachedPlayUrl({
  required String? cachedUrl,
  required String? cachedRequestedQuality,
  required String currentRequestedQuality,
}) {
  if (cachedUrl == null || cachedUrl.isEmpty) return false;
  if (cachedUrl.startsWith('data:')) return false;
  final uri = Uri.tryParse(cachedUrl);
  final isLocal = cachedUrl.startsWith('/') || uri?.scheme == 'file';
  if (!isLocal) return false;
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
  required bool desiredPlayingIntent,
}) {
  var clampedPosition = position.isNegative ? Duration.zero : position;
  if (duration != null &&
      duration >= Duration.zero &&
      clampedPosition > duration) {
    clampedPosition = duration;
  }
  return QualityReloadIntent(clampedPosition, desiredPlayingIntent);
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
    return InterruptionAction.pausePreservingIntent;
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

class _PreloadRequest {
  const _PreloadRequest(this.generation, this.occurrenceId, this.item);

  final int generation;
  final int occurrenceId;
  final MediaItem item;

  String get mediaId => item.id;
}

class _ForegroundResolutionRequest {
  _ForegroundResolutionRequest(this.generation, this.occurrenceId, this.item);

  final int generation;
  final int occurrenceId;
  MediaItem item;

  String get mediaId => item.id;
}

class LxAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  late AudioPlayer _player;
  late final BehaviorSubject<AudioPlayer> _playerSubject;
  late PlaybackCommandCoordinator _commands;
  final AudioPlayer Function()? _replacementPlayerFactory;
  final PrepareForPlayback? _prepareForPlayback;
  final Duration _outputRouteRecoveryTimeout;
  final AudioInterruptionPolicy _interruptionPolicy = AudioInterruptionPolicy();
  final List<MediaItem> _queue = [];
  final List<int> _queueOccurrenceIds = [];
  int _nextQueueOccurrenceId = 0;
  int? _activeOccurrenceId;
  int _currentIndex = 0;

  /// 单调世代：setPlaylist/切歌时递增，取消过期的异步解析/播放
  int _playGeneration = 0;
  int _seekGeneration = 0;
  bool _userWantsPlay = true;
  int _userIntentGeneration = 0;
  int _installedSourceOwnerToken = 0;
  int _installedPlaybackGeneration = -1;
  String? _installedMediaId;
  int? _nativeTransitionSourceToken;
  int _lastHandledCompletionGeneration = -1;
  String? _activeItemId;
  AudioServiceRepeatMode _repeatMode = AudioServiceRepeatMode.none;
  AudioServiceShuffleMode _shuffleMode = AudioServiceShuffleMode.none;
  int _playbackPublicationToken = 0;
  int _interruptionGeneration = 0;
  int _playbackStartBlockGeneration = 0;
  bool _interruptionClosing = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;
  final Set<Future<void>> _inflightOperations = {};
  final Set<Future<void>> _inflightLeaseReleases = {};
  Object? _operationError;
  StackTrace? _operationStackTrace;
  Object? _lateReleaseError;
  StackTrace? _lateReleaseStackTrace;
  static final Object _publicOperationZoneKey = Object();
  StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
  StreamSubscription<ProcessingState>? _processingStateSubscription;
  int? _interruptionSourceGeneration;
  int? _interruptionUserIntentGeneration;
  String? _interruptionMediaId;
  bool _outputRouteRecoveryPending = false;
  Duration? _outputRouteRecoveryPosition;
  int _outputRouteRecoveryGeneration = 0;
  Future<void>? _outputRouteRecoveryValidation;
  int? _outputRouteRecoveryValidationGeneration;
  int? _outputRouteRecoveryValidationUserIntentGeneration;
  Future<void>? _nativePlayerReset;
  static const Duration _outputRouteRecoveryMinimumProgress =
      Duration(milliseconds: 120);

  // 注入 URL 解析器
  UrlResolver? urlResolver;

  /// 当前播放偏好音质（由设置页同步）；用于判断 extras 缓存 url 是否可复用。
  String preferredQuality = '320k';

  // 注入错误回调
  void Function(String message)? onError;

  final PlaybackLeaseSession _leaseSession = PlaybackLeaseSession();
  final Map<int, PlaybackResolution> _pendingResolutions = {};
  final Map<int, _PreloadRequest> _preloadRequests = {};
  _ForegroundResolutionRequest? _foregroundResolutionRequest;
  int _nextPreloadRequestToken = 0;
  Future<PlaybackCachePathClassification> Function(String path)?
      _classifyExistingCache;
  Future<PlaybackCacheLease?> Function(String path)? _acquireExistingCache;
  void Function(String key)? _cancelCacheKey;
  void Function()? _cancelAllTrackedCacheWork;
  String? _foregroundCacheKey;
  LazyQueueLoader? _lazyQueueLoader;
  LazyQueueShuffleRebuilder? _lazyQueueShuffleRebuilder;
  Future<void>? _lazyQueueRefill;
  Future<void>? _lazyQueueRebuild;
  int _lazyQueueEpoch = 0;

  static const _lazyQueueAhead = 8;
  static const _lazyQueueHistory = 4;

  /// 单曲 URL 解析总超时：音源不可用时不会无限等待，超时视为解析失败。
  static const _resolveTimeout = Duration(seconds: 25);

  /// A paged playlist supplies future items in its global playback order.
  /// The handler still owns the short native queue used by lock-screen media
  /// controls, so background next/auto-next follows the same source path.
  void configureLazyQueue({
    required LazyQueueLoader loadMore,
    required LazyQueueShuffleRebuilder rebuildForShuffle,
  }) {
    _lazyQueueLoader = loadMore;
    _lazyQueueShuffleRebuilder = rebuildForShuffle;
  }

  void clearLazyQueue() {
    _lazyQueueLoader = null;
    _lazyQueueShuffleRebuilder = null;
    _lazyQueueRefill = null;
  }

  bool get _usesLazyQueue => _lazyQueueLoader != null;

  /// Production wiring: cancel obsolete cache downloads on track switch.
  void attachPlaybackCache({
    Future<PlaybackCachePathClassification> Function(String path)?
        classifyExisting,
    Future<PlaybackCacheLease?> Function(String path)? acquireExisting,
    void Function(String key)? cancelCacheKey,
    void Function()? cancelAllTrackedCacheWork,
  }) {
    _classifyExistingCache = classifyExisting;
    _acquireExistingCache = acquireExisting;
    _cancelCacheKey = cancelCacheKey;
    _cancelAllTrackedCacheWork = cancelAllTrackedCacheWork;
  }

  /// Atomically accepts metadata and lease ownership for the current playback
  /// request. A late resolver result must never publish queue or media extras.
  bool acceptResolvedPlayback({
    required String mediaId,
    required int generation,
    required PlaybackResolution resolution,
  }) {
    if (_disposed) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    final request = _foregroundResolutionRequest;
    final index =
        request == null ? -1 : _indexOfOccurrence(request.occurrenceId);
    final valid = request != null &&
        request.generation == generation &&
        generation == _playGeneration &&
        request.mediaId == mediaId &&
        request.occurrenceId == _activeOccurrenceId &&
        index >= 0 &&
        index == _currentIndex &&
        identical(_queue[index], request.item) &&
        identical(mediaItem.value, request.item);
    if (!valid) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    if (!patchQueueItemExtrasAt(
      index: index,
      expectedItem: request.item,
      patch: resolution.qualityExtras,
    )) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    // The exact-slot patch creates a new immutable MediaItem; retain it as the
    // request identity so the subsequent source commit targets this occurrence.
    request.item = _queue[index];
    final previous = _pendingResolutions.remove(request.occurrenceId);
    final previousLease = previous?.leaseOrNull;
    if (previousLease != null &&
        !identical(previousLease, resolution.leaseOrNull)) {
      _trackLeaseRelease(previousLease);
    }
    _pendingResolutions[request.occurrenceId] = resolution;
    final lease = resolution.leaseOrNull;
    if (lease != null) {
      _leaseSession.holdPending(lease);
    }
    final key = resolution.qualityExtras['cacheKey']?.toString();
    if (key != null && key.isNotEmpty) {
      _foregroundCacheKey = key;
    }
    return true;
  }

  /// Preloads have separate authority: only their original queue slot and
  /// request generation may receive metadata, and never once the item is live.
  /// Successful preloads keep the cache lease until that occurrence is loaded
  /// or discarded by a generation bump.
  bool acceptPreloadedPlayback({
    required String mediaId,
    required int requestToken,
    required PlaybackResolution resolution,
  }) {
    if (_disposed) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    final request = _preloadRequests[requestToken];
    final index =
        request == null ? -1 : _indexOfOccurrence(request.occurrenceId);
    final valid = request != null &&
        request.generation == _playGeneration &&
        request.mediaId == mediaId &&
        index >= 0 &&
        identical(_queue[index], request.item) &&
        request.occurrenceId != _activeOccurrenceId;
    if (!valid) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    if (!patchQueueItemExtrasAt(
      index: index,
      expectedItem: request.item,
      patch: resolution.qualityExtras,
    )) {
      _trackLeaseRelease(resolution.leaseOrNull);
      return false;
    }
    final previous = _pendingResolutions.remove(request.occurrenceId);
    final previousLease = previous?.leaseOrNull;
    if (previousLease != null &&
        !identical(previousLease, resolution.leaseOrNull)) {
      _trackLeaseRelease(previousLease);
    }
    _pendingResolutions[request.occurrenceId] = resolution;
    return true;
  }

  /// Legacy test seam. Production callers must use [acceptResolvedPlayback].
  void noteResolvedPlayback(
    String mediaId,
    PlaybackResolution resolution, {
    required int generation,
  }) {
    acceptResolvedPlayback(
      mediaId: mediaId,
      generation: generation,
      resolution: resolution,
    );
  }

  void _discardPendingResolution(int occurrenceId) {
    final resolution = _pendingResolutions.remove(occurrenceId);
    final lease = resolution?.leaseOrNull;
    if (lease != null) {
      _trackOperation(() => _leaseSession.discardPending(lease));
    }
  }

  void _discardAllPendingResolutions() {
    final resolutions = _pendingResolutions.values.toList(growable: false);
    _pendingResolutions.clear();
    for (final resolution in resolutions) {
      final lease = resolution.leaseOrNull;
      _trackLeaseRelease(lease);
    }
    _leaseSession.holdPending(null);
  }

  void _cancelForegroundCacheWork() {
    final key = _foregroundCacheKey;
    _foregroundCacheKey = null;
    if (key != null) _cancelCacheKey?.call(key);
    _cancelAllTrackedCacheWork?.call();
  }

  Future<void> _releasePlaybackLeases() async {
    final resolutionLeases = _pendingResolutions.values
        .map((resolution) => resolution.leaseOrNull)
        .whereType<PlaybackCacheLease>()
        .toSet();
    _pendingResolutions.clear();
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> release(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await release(_leaseSession.releaseAll);
    for (final lease in resolutionLeases) {
      await release(lease.release);
    }
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  Future<void> _trackOperation(Future<void> Function() operation) {
    if (_disposed) return Future<void>.value();
    final future = Future<void>.sync(operation);
    final tracked = future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _operationError ??= error;
        _operationStackTrace ??= stackTrace;
      },
    );
    _inflightOperations.add(tracked);
    tracked.whenComplete(() => _inflightOperations.remove(tracked)).ignore();
    return future;
  }

  Future<T> _runPublicOperation<T>(
    Future<T> Function() operation, {
    required T disposedValue,
  }) {
    if (_disposed) return Future<T>.value(disposedValue);
    if (identical(Zone.current[_publicOperationZoneKey], this)) {
      return operation();
    }
    final future = runZoned(
      operation,
      zoneValues: {_publicOperationZoneKey: this},
    );
    final tracked = future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _operationError ??= error;
        _operationStackTrace ??= stackTrace;
      },
    );
    _inflightOperations.add(tracked);
    tracked.whenComplete(() => _inflightOperations.remove(tracked)).ignore();
    return future;
  }

  void _trackLeaseRelease(PlaybackCacheLease? lease) {
    if (lease == null) return;
    final release = Future<void>.sync(lease.release);
    final tracked = release.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        _lateReleaseError ??= error;
        _lateReleaseStackTrace ??= stackTrace;
      },
    );
    _inflightLeaseReleases.add(tracked);
    tracked.whenComplete(() => _inflightLeaseReleases.remove(tracked)).ignore();
  }

  Future<void> _drainTracked(Set<Future<void>> tracked) async {
    while (tracked.isNotEmpty) {
      await Future.wait(tracked.toList(growable: false));
    }
  }

  Future<void> _drainOperations() async {
    await _drainTracked(_inflightOperations);
    if (_operationError case final error?) {
      final stackTrace = _operationStackTrace!;
      _operationError = null;
      _operationStackTrace = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _drainLeaseReleases() async {
    await _drainTracked(_inflightLeaseReleases);
    if (_lateReleaseError case final error?) {
      final stackTrace = _lateReleaseStackTrace!;
      _lateReleaseError = null;
      _lateReleaseStackTrace = null;
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _commitStagedLease({
    required int occurrenceId,
    required int generation,
    required PlaybackCacheLease? lease,
  }) async {
    _pendingResolutions.remove(occurrenceId);
    await _leaseSession.commitIfGeneration(
      generation: generation,
      currentGeneration: () => _playGeneration,
      lease: lease,
    );
  }

  Future<void> _discardStagedLease(
    int occurrenceId,
    PlaybackCacheLease? lease,
  ) async {
    final resolution = _pendingResolutions.remove(occurrenceId);
    final resolvedLease = resolution?.leaseOrNull;
    if (resolvedLease != null) {
      await _leaseSession.discardPending(resolvedLease);
    }
    if (lease != null && !identical(lease, resolvedLease)) {
      await _leaseSession.discardPending(lease);
    }
  }

  bool _leaseMatchesUrl(PlaybackCacheLease lease, String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'file') return false;
    try {
      return uri.toFilePath() == lease.path;
    } on FormatException {
      return false;
    }
  }

  Future<PlaybackCacheLease?> _takePendingLeaseForUrl(
    int occurrenceId,
    String url,
  ) async {
    final lease = _pendingResolutions[occurrenceId]?.leaseOrNull;
    if (lease == null) return null;
    if (!lease.isReleased && _leaseMatchesUrl(lease, url)) return lease;
    await _discardStagedLease(occurrenceId, lease);
    return null;
  }

  Future<PlaybackCachePathClassification> _classifyExistingCachePath(
    String url,
  ) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'file') {
      return const NonCacheLocalPlaybackPath();
    }
    final classify = _classifyExistingCache;
    if (classify != null) {
      try {
        return await classify(uri.toFilePath());
      } on FormatException {
        return const NonCacheLocalPlaybackPath();
      }
    }
    final acquire = _acquireExistingCache;
    if (acquire == null) return const NonCacheLocalPlaybackPath();
    try {
      final lease = await acquire(uri.toFilePath());
      return lease == null
          ? const NonCacheLocalPlaybackPath()
          : LeasedPlaybackCachePath(lease);
    } on FormatException {
      return const NonCacheLocalPlaybackPath();
    }
  }

  LxAudioHandler({
    AudioPlayer? player,
    AudioPlayer Function()? playerFactory,
    PrepareForPlayback? prepareForPlayback,
    Duration outputRouteRecoveryTimeout = const Duration(milliseconds: 1200),
  })  : assert(player == null || playerFactory == null),
        _replacementPlayerFactory =
            player == null ? (playerFactory ?? _createDefaultPlayer) : null,
        _prepareForPlayback = prepareForPlayback,
        _outputRouteRecoveryTimeout = outputRouteRecoveryTimeout {
    _player = player ?? (playerFactory ?? _createDefaultPlayer)();
    _playerSubject = BehaviorSubject<AudioPlayer>.seeded(_player);
    _commands = _createCommandCoordinator(_player);
    _publishPlaybackState();
    _init();
  }

  static AudioPlayer _createDefaultPlayer() => AudioPlayer(
        handleInterruptions: false,
        useProxyForRequestHeaders: false,
      );

  PlaybackCommandCoordinator _createCommandCoordinator(AudioPlayer player) =>
      PlaybackCommandCoordinator(
        player,
        onStateChanged: _publishPlaybackState,
        onError: (operation, error, stackTrace) {
          debugPrint('[AudioHandler] $operation failed: $error');
          AppLog.instance.record(
            'audio.command',
            '$operation failed: $error',
            level: AppLogLevel.error,
            stackTrace: stackTrace,
          );
          if (operation == 'play') {
            _handleAuthoritativePlaybackError(error, stackTrace);
          }
        },
        prepareForPlayback: _prepareForPlayback,
      );

  AudioPlayer get player => _player;

  Stream<AudioPlayer> get playerStream => _playerSubject.stream;

  @visibleForTesting
  Future<void> get debugOutputRouteRecoverySettled =>
      _outputRouteRecoveryValidation ?? Future<void>.value();

  int _newOccurrenceId() => ++_nextQueueOccurrenceId;

  int _occurrenceIdAt(int index) => _queueOccurrenceIds[index];

  int _indexOfOccurrence(int occurrenceId) =>
      _queueOccurrenceIds.indexOf(occurrenceId);

  void _replaceQueuePreservingOccurrences(List<MediaItem> items) {
    final oldItems = List<MediaItem>.of(_queue);
    final oldOccurrences = List<int>.of(_queueOccurrenceIds);
    final claimed = <int>{};
    final nextOccurrences = <int>[];
    for (final item in items) {
      var oldIndex = -1;
      for (var i = 0; i < oldItems.length; i++) {
        if (!claimed.contains(i) && identical(oldItems[i], item)) {
          oldIndex = i;
          break;
        }
      }
      if (oldIndex >= 0) {
        claimed.add(oldIndex);
        nextOccurrences.add(oldOccurrences[oldIndex]);
      } else {
        nextOccurrences.add(_newOccurrenceId());
      }
    }
    _queue
      ..clear()
      ..addAll(items);
    _queueOccurrenceIds
      ..clear()
      ..addAll(nextOccurrences);
  }

  void _replaceQueueItem(int index, MediaItem item) {
    _queue[index] = item;
  }

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

  @visibleForTesting
  int get debugPreloadRequestCount => _preloadRequests.length;

  @visibleForTesting
  void debugSchedulePreload() => _schedulePreload();

  PlaybackStartProvenance _captureStartProvenance() => PlaybackStartProvenance(
        _interruptionGeneration,
        _playbackStartBlockGeneration,
      );

  int _bumpGeneration() {
    _discardAllPendingResolutions();
    _preloadRequests.clear();
    _foregroundResolutionRequest = null;
    return ++_playGeneration;
  }

  bool _isStale(int gen) => gen != _playGeneration;

  int _recordExplicitPlaybackIntent(bool wantsPlay) {
    _userIntentGeneration++;
    _userWantsPlay = wantsPlay;
    return _userIntentGeneration;
  }

  int _recordExplicitPlayIntent() => _recordExplicitPlaybackIntent(true);

  Future<void> _stopPlayerSource() => _commands.stop();

  bool _mayStartAfterInterruption({
    required PlaybackStartProvenance provenance,
  }) =>
      !interruptionActive &&
      provenance.blockGeneration == _playbackStartBlockGeneration &&
      provenance.interruptionGeneration == _interruptionGeneration;

  void _init() {
    _playbackEventSubscription = _player.playbackEventStream.listen(
      (_) => _publishPlaybackState(),
    );

    // 播放完成 → 无缝连播下一首。
    // 锁屏/后台时绝不能先 pause + playing:false：iOS 会结束后台音频会话。
    _processingStateSubscription = _player.processingStateStream.listen((
      state,
    ) {
      if (_disposed) return;
      if (state != ProcessingState.completed) return;
      _onTrackCompleted();
    });
  }

  void _clearOutputRouteRecovery() {
    _outputRouteRecoveryPending = false;
    _outputRouteRecoveryPosition = null;
    _outputRouteRecoveryGeneration++;
  }

  bool _ownsOutputRouteRecovery({
    required int generation,
    required int occurrenceId,
    required String itemId,
    required int userIntentGeneration,
  }) =>
      !_disposed &&
      _outputRouteRecoveryPending &&
      generation == _outputRouteRecoveryGeneration &&
      occurrenceId == _activeOccurrenceId &&
      itemId == _activeItemId &&
      userIntentGeneration == _userIntentGeneration &&
      _userWantsPlay &&
      !interruptionActive;

  Future<bool> _waitForOutputRouteProgress({
    required AudioPlayer player,
    required Duration baseline,
  }) async {
    bool advanced(Duration position) =>
        position - baseline >= _outputRouteRecoveryMinimumProgress;
    if (advanced(player.position)) return true;
    try {
      await player.positionStream
          .firstWhere(advanced)
          .timeout(_outputRouteRecoveryTimeout);
      return true;
    } on TimeoutException {
      return advanced(player.position);
    } catch (error, stackTrace) {
      AppLog.instance.record(
        'audio.recovery',
        'output route progress verification failed: $error',
        level: AppLogLevel.warning,
        stackTrace: stackTrace,
      );
      return advanced(player.position);
    }
  }

  void _validateOutputRouteRecovery(Duration recoveryPosition) {
    if (!_outputRouteRecoveryPending) return;
    final generation = _outputRouteRecoveryGeneration;
    final userIntentGeneration = _userIntentGeneration;
    if (_outputRouteRecoveryValidation != null &&
        _outputRouteRecoveryValidationGeneration == generation &&
        _outputRouteRecoveryValidationUserIntentGeneration ==
            userIntentGeneration) {
      return;
    }
    final occurrenceId = _activeOccurrenceId;
    final itemId = _activeItemId;
    if (occurrenceId == null || itemId == null) return;
    late final Future<void> validation;
    validation = _trackOperation(() async {
      try {
        var observedPlayer = _player;
        if (await _waitForOutputRouteProgress(
          player: observedPlayer,
          baseline: recoveryPosition,
        )) {
          if (_ownsOutputRouteRecovery(
            generation: generation,
            occurrenceId: occurrenceId,
            itemId: itemId,
            userIntentGeneration: userIntentGeneration,
          )) {
            AppLog.instance.record(
              'audio.recovery',
              'output route recovered on the existing player',
            );
            _clearOutputRouteRecovery();
          }
          return;
        }
        if (!_ownsOutputRouteRecovery(
          generation: generation,
          occurrenceId: occurrenceId,
          itemId: itemId,
          userIntentGeneration: userIntentGeneration,
        )) {
          return;
        }
        AppLog.instance.record(
          'audio.recovery',
          'existing player made no progress; reloading current source',
          level: AppLogLevel.warning,
        );
        await _recoverAuthoritativeSource(
          provenance: _captureStartProvenance(),
          initialPosition: recoveryPosition,
        );
        if (!_ownsOutputRouteRecovery(
          generation: generation,
          occurrenceId: occurrenceId,
          itemId: itemId,
          userIntentGeneration: userIntentGeneration,
        )) {
          return;
        }
        observedPlayer = _player;
        if (await _waitForOutputRouteProgress(
          player: observedPlayer,
          baseline: recoveryPosition,
        )) {
          if (_ownsOutputRouteRecovery(
            generation: generation,
            occurrenceId: occurrenceId,
            itemId: itemId,
            userIntentGeneration: userIntentGeneration,
          )) {
            AppLog.instance.record(
              'audio.recovery',
              'output route recovered after reloading the current source',
            );
            _clearOutputRouteRecovery();
          }
          return;
        }
        if (!_ownsOutputRouteRecovery(
          generation: generation,
          occurrenceId: occurrenceId,
          itemId: itemId,
          userIntentGeneration: userIntentGeneration,
        )) {
          return;
        }
        await _rebuildNativePlayerForCurrentItem(
          initialPosition: recoveryPosition,
          provenance: _captureStartProvenance(),
        );
      } catch (error, stackTrace) {
        AppLog.instance.record(
          'audio.recovery',
          'output route recovery failed: $error',
          level: AppLogLevel.error,
          stackTrace: stackTrace,
        );
      }
    }).whenComplete(() {
      if (identical(_outputRouteRecoveryValidation, validation)) {
        _outputRouteRecoveryValidation = null;
        _outputRouteRecoveryValidationGeneration = null;
        _outputRouteRecoveryValidationUserIntentGeneration = null;
      }
    });
    _outputRouteRecoveryValidation = validation;
    _outputRouteRecoveryValidationGeneration = generation;
    _outputRouteRecoveryValidationUserIntentGeneration =
        userIntentGeneration;
    validation.ignore();
  }

  Future<void> _resetNativePlayer() {
    final pending = _nativePlayerReset;
    if (pending != null) return pending;
    late final Future<void> reset;
    reset = _replaceNativePlayer().whenComplete(() {
      if (identical(_nativePlayerReset, reset)) {
        _nativePlayerReset = null;
      }
    });
    _nativePlayerReset = reset;
    return reset;
  }

  Future<void> _replaceNativePlayer() async {
    final replacementFactory = _replacementPlayerFactory;
    if (_disposed || replacementFactory == null) return;
    final oldPlayer = _player;
    final oldCommands = _commands;
    final oldPlaybackEvents = _playbackEventSubscription;
    final oldProcessingStates = _processingStateSubscription;
    AppLog.instance.record('audio.recovery', 'disposing previous native player');
    _playbackEventSubscription = null;
    _processingStateSubscription = null;
    _bumpGeneration();
    _nativeTransitionSourceToken = null;
    _installedSourceOwnerToken++;
    _installedPlaybackGeneration = -1;
    _installedMediaId = null;
    _lastHandledCompletionGeneration = -1;

    Future<void> ignoreFailure(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        debugPrint('[AudioHandler] native player reset failed: $error');
        AppLog.instance.record(
          'audio.recovery',
          'native player reset cleanup failed: $error',
          level: AppLogLevel.warning,
          stackTrace: stackTrace,
        );
      }
    }

    if (oldPlaybackEvents != null) await ignoreFailure(oldPlaybackEvents.cancel);
    if (oldProcessingStates != null) {
      await ignoreFailure(oldProcessingStates.cancel);
    }
    await ignoreFailure(oldCommands.stopAndWait);
    await ignoreFailure(oldPlayer.dispose);
    if (_disposed) return;

    _player = replacementFactory();
    _commands = _createCommandCoordinator(_player);
    _init();
    _playerSubject.add(_player);
    _publishPlaybackState(
      override: AudioProcessingState.idle,
      playingOverride: false,
    );
    AppLog.instance.record('audio.recovery', 'native player reconstruction completed');
  }

  Future<void> _rebuildNativePlayerForCurrentItem({
    required Duration initialPosition,
    required PlaybackStartProvenance provenance,
  }) async {
    final occurrenceId = _activeOccurrenceId;
    final itemId = _activeItemId;
    final index = _currentIndex;
    final userIntentGeneration = _userIntentGeneration;
    if (occurrenceId == null ||
        itemId == null ||
        index < 0 ||
        index >= _queue.length ||
        _occurrenceIdAt(index) != occurrenceId ||
        _queue[index].id != itemId) {
      return;
    }
    if (_replacementPlayerFactory == null) {
      AppLog.instance.record(
        'audio.recovery',
        'native player recovery unavailable for the injected player',
        level: AppLogLevel.warning,
      );
      return;
    }
    AppLog.instance.record(
      'audio.recovery',
      'starting native player reconstruction after playback recovery failed '
          'positionMs=${initialPosition.inMilliseconds}',
      level: AppLogLevel.warning,
    );
    await _resetNativePlayer();
    if (_disposed ||
        _activeOccurrenceId != occurrenceId ||
        _activeItemId != itemId ||
        _currentIndex != index ||
        _userIntentGeneration != userIntentGeneration ||
        !_userWantsPlay ||
        interruptionActive) {
      return;
    }
    await _commands.recordExplicitPlayIntent();
    if (_disposed ||
        _activeOccurrenceId != occurrenceId ||
        _activeItemId != itemId ||
        _currentIndex != index ||
        _userIntentGeneration != userIntentGeneration ||
        !_userWantsPlay ||
        interruptionActive) {
      return;
    }
    await _loadQueueItem(
      index,
      preserveUserIntent: true,
      recoverStaleInstall: false,
      initialPosition: initialPosition,
      provenance: provenance,
    );
    if (_installedPlaybackGeneration == _playGeneration &&
        _installedMediaId == itemId &&
        _player.processingState != ProcessingState.idle) {
      _clearOutputRouteRecovery();
    }
  }

  void _onTrackCompleted() {
    if (_disposed) return;
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
    final expectedOccurrence = _activeOccurrenceId;
    if (expectedId == null ||
        expectedOccurrence == null ||
        expectedIndex < 0 ||
        expectedIndex >= _queue.length ||
        _occurrenceIdAt(expectedIndex) != expectedOccurrence ||
        _queue[expectedIndex].id != expectedId ||
        mediaItem.value?.id != expectedId ||
        _installedMediaId != expectedId) {
      return;
    }
    final expectedIntentGeneration = _userIntentGeneration;
    final provenance = _captureStartProvenance();
    _lastHandledCompletionGeneration = gen;
    debugPrint('[AudioHandler] track completed idx=$expectedIndex');
    Future(() async {
      try {
        await _ensureLazyQueueAhead(1);
        if (_isStale(gen) ||
            !_commands.installedSourceIsAuthoritative ||
            _installedPlaybackGeneration != gen ||
            _installedMediaId != expectedId ||
            _activeItemId != expectedId ||
            _activeOccurrenceId != expectedOccurrence ||
            (_usesLazyQueue
                ? _indexOfOccurrence(expectedOccurrence) != _currentIndex
                : _currentIndex != expectedIndex) ||
            _currentIndex >= _queue.length ||
            _occurrenceIdAt(_currentIndex) != expectedOccurrence ||
            _queue[_currentIndex].id != expectedId ||
            mediaItem.value?.id != expectedId ||
            _userIntentGeneration != expectedIntentGeneration ||
            !_userWantsPlay) {
          return;
        }
        final shuffle = !_usesLazyQueue &&
            (_player.shuffleModeEnabled ||
                playbackState.value.shuffleMode == AudioServiceShuffleMode.all);
        final target = completionQueueIndex(
          currentIndex: _currentIndex,
          queueLength: _queue.length,
          repeatMode: playbackState.value.repeatMode,
          shuffle: shuffle,
        );
        if (target < 0) return;
        await _skipToNextInternal(
          seamless: true,
          provenance: provenance,
          targetIndex: target,
        );
      } catch (e) {
        debugPrint('[AudioHandler] auto-next failed: $e');
      }
    });
  }

  void _handleAuthoritativePlaybackError(Object error, StackTrace stackTrace) {
    if (_disposed) return;
    final generation = _playGeneration;
    final occurrenceId = _activeOccurrenceId;
    final itemId = _activeItemId;
    final routeRecoveryPending = _outputRouteRecoveryPending;
    final recoveryPosition =
        _outputRouteRecoveryPosition ?? _player.position;
    _installedPlaybackGeneration = -1;
    _installedMediaId = null;
    _publishPlaybackState(
      override: AudioProcessingState.idle,
      playingOverride: false,
    );
    onError?.call('播放歌曲失败，正在重新加载');
    Future(() async {
      if (_disposed ||
          generation != _playGeneration ||
          occurrenceId == null ||
          occurrenceId != _activeOccurrenceId ||
          itemId == null ||
          itemId != _activeItemId ||
          !_userWantsPlay) {
        return;
      }
      if (routeRecoveryPending) {
        _validateOutputRouteRecovery(recoveryPosition);
        return;
      }
      try {
        await _recoverAuthoritativeSource(
          provenance: _captureStartProvenance(),
          initialPosition: recoveryPosition,
        );
      } catch (recoveryError) {
        debugPrint('[AudioHandler] playback recovery failed: $recoveryError');
      }
    });
  }

  // 将播放状态广播给系统控制中心
  int _publishPlaybackState({
    AudioProcessingState? override,
    bool? playingOverride,
    Duration? positionOverride,
  }) {
    if (_disposed) return _playbackPublicationToken;
    final transitionToken = _nativeTransitionSourceToken;
    final keepingNativeSession = transitionToken != null &&
        transitionToken == _commands.desiredSourceToken &&
        _commands.desiredPlayingIntent;
    final playing =
        playingOverride ?? (keepingNativeSession ? true : _player.playing);
    final publicationToken = ++_playbackPublicationToken;
    playbackState.add(
      PlaybackState(
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
        processingState: override ??
            (keepingNativeSession
                ? AudioProcessingState.buffering
                : audioProcessingState(_player.processingState)),
        playing: playing,
        updatePosition: positionOverride ?? _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: currentQueueIndex,
        repeatMode: _repeatMode,
        shuffleMode: _shuffleMode,
      ),
    );
    return publicationToken;
  }

  @override
  Future<void> play() => _runPublicOperation<void>(_play, disposedValue: null);

  Future<void> _play() async {
    if (_disposed) return;
    AppLog.instance.record(
      'audio.command',
      'play requested media=${_activeItemId ?? 'none'} '
          'routeRecoveryPending=$_outputRouteRecoveryPending',
    );
    if (_disposed) return;
    _userIntentGeneration++;
    _userWantsPlay = true;
    final currentOccurrenceId = _activeOccurrenceId;
    final pendingOccurrenceId = _commands.desiredSourceOccurrenceId;
    final selectionTransferPending = currentOccurrenceId != null &&
        pendingOccurrenceId != null &&
        pendingOccurrenceId != currentOccurrenceId;
    final hasInstalledCurrentSource = currentOccurrenceId != null &&
        _currentIndex >= 0 &&
        _currentIndex < _queue.length &&
        _installedPlaybackGeneration == _playGeneration &&
        _installedMediaId == _queue[_currentIndex].id;
    final needsSourceReload =
        _player.processingState == ProcessingState.idle ||
            !hasInstalledCurrentSource;
    final routeRecoveryPosition = _outputRouteRecoveryPending
        ? (needsSourceReload
            ? (_outputRouteRecoveryPosition ?? _player.position)
            : _player.position)
        : null;
    if (needsSourceReload) {
      unawaited(_commands.recordExplicitPlayIntent());
      if (selectionTransferPending) return;
      if (currentOccurrenceId != null &&
          _currentIndex >= 0 &&
          _currentIndex < _queue.length) {
        await _loadQueueItem(
          _currentIndex,
          preserveUserIntent: true,
          initialPosition: routeRecoveryPosition ?? Duration.zero,
          provenance: _captureStartProvenance(),
        );
        if (routeRecoveryPosition != null) {
          _validateOutputRouteRecovery(routeRecoveryPosition);
        }
        // _loadQueueItem commits through PlaybackCommandCoordinator, which
        // installs the source and starts it after installation. Calling
        // super.play here races iOS setAudioSource during restored playback.
        return;
      } else {
        await _commands.recoverIdleSource();
      }
    } else {
      await _commands.recordExplicitPlayIntent();
    }
    if (_disposed) return;
    await super.play();
    if (routeRecoveryPosition != null) {
      _validateOutputRouteRecovery(routeRecoveryPosition);
    }
  }

  /// 供测试：模拟当前曲播放完成（锁屏自动下一曲路径）。
  @visibleForTesting
  void debugEmitTrackCompleted() => _onTrackCompleted();

  @override
  Future<void> pause() =>
      _runPublicOperation<void>(_pause, disposedValue: null);

  Future<void> _pause() async {
    if (_disposed) return;
    await pauseInternal(clearIntent: true);
  }

  /// [clearIntent]=false：拖进度条暂停，不取消「还要继续听」意图（自动下一首仍有效）
  Future<PreservingPauseOwner?> pauseInternal({bool clearIntent = true}) =>
      _runPublicOperation<PreservingPauseOwner?>(
        () => _pauseInternal(clearIntent: clearIntent),
        disposedValue: null,
      );

  Future<PreservingPauseOwner?> _pauseInternal({
    bool clearIntent = true,
  }) async {
    if (_disposed) return null;
    if (clearIntent) {
      _userIntentGeneration++;
      _userWantsPlay = false;
    }
    final owner = clearIntent ? null : await _commands.pausePreservingIntent();
    if (_disposed) return null;
    if (clearIntent) await _commands.recordExplicitPauseIntent();
    if (_disposed) return null;
    await super.pause();
    return owner;
  }

  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) =>
      _runPublicOperation<PreservingPauseOwner?>(
        () => _pauseForScrub(
          sourceGeneration: sourceGeneration,
          userIntentGeneration: userIntentGeneration,
          stillOwnsScrub: stillOwnsScrub,
        ),
        disposedValue: null,
      );

  Future<PreservingPauseOwner?> _pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) async {
    if (_disposed) return null;
    final provenance = _captureStartProvenance();
    final owner = await _commands.pausePreservingIntent();
    if (_disposed) return null;
    await super.pause();
    if (_disposed) return null;

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

  Future<void> beginAudioInterruption() =>
      _runPublicOperation<void>(_beginAudioInterruption, disposedValue: null);

  Future<void> _beginAudioInterruption() async {
    if (_disposed) return;
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
    if (_disposed) return;
    if (action == InterruptionAction.pausePreservingIntent &&
        interruptionGeneration == _interruptionGeneration &&
        interruptionActive &&
        sourceGeneration != null &&
        userIntentGeneration != null) {
      await super.pause();
    }
  }

  Future<void> endAudioInterruption({required bool mayResume}) =>
      _runPublicOperation<void>(
        () => _endAudioInterruption(mayResume: mayResume),
        disposedValue: null,
      );

  Future<void> _endAudioInterruption({required bool mayResume}) async {
    if (_disposed) return;
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
    if (_disposed) return;
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

  Future<void> handleBecomingNoisy() =>
      _runPublicOperation<void>(_handleBecomingNoisy, disposedValue: null);

  Future<void> handleAudioOutputRouteChanged() => _runPublicOperation<void>(
        _handleAudioOutputRouteChanged,
        disposedValue: null,
      );

  void _markOutputRouteRecoveryPending(
    String reason, {
    bool force = false,
  }) {
    if (force || !_outputRouteRecoveryPending) {
      _outputRouteRecoveryPosition = _player.position;
      _outputRouteRecoveryGeneration++;
    }
    _outputRouteRecoveryPending = true;
    final recoveryPosition = _outputRouteRecoveryPosition!;
    AppLog.instance.record(
      'audio.route',
      '$reason; recovery marked pending '
          'positionMs=${recoveryPosition.inMilliseconds}',
      level: AppLogLevel.warning,
    );
    if (!force &&
        _userWantsPlay &&
        !interruptionActive &&
        _player.playing &&
        _player.processingState != ProcessingState.idle) {
      _validateOutputRouteRecovery(recoveryPosition);
    }
  }

  Future<void> _handleAudioOutputRouteChanged() {
    _markOutputRouteRecoveryPending('output route changed');
    return Future<void>.value();
  }

  Future<void> _handleBecomingNoisy() async {
    if (_disposed) return;
    _markOutputRouteRecoveryPending('output became noisy', force: true);
    if (_interruptionPolicy.onBecomingNoisy() ==
        InterruptionAction.pausePreservingIntent) {
      final userIntentGeneration = _recordExplicitPlaybackIntent(true);
      ++_interruptionGeneration;
      ++_playbackStartBlockGeneration;
      _interruptionClosing = false;
      _clearInterruptionOwnership();
      await _commands.becomingNoisy();
      if (_disposed) return;
      // 切换输出源（耳机/喇叭）后用户可能立即按播放或切歌，此时已发起新的
      // 播放意图；不要再执行本暂停，否则新操作会被覆盖导致"无法播放"。
      if (userIntentGeneration != _userIntentGeneration) return;
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
  }) =>
      _runPublicOperation<void>(
        () => _releaseAfterScrub(
          owner,
          resumeAfter: resumeAfter,
          sourceGeneration: sourceGeneration,
          userIntentGeneration: userIntentGeneration,
          interruptionGeneration: interruptionGeneration,
          startBlockGeneration: startBlockGeneration,
        ),
        disposedValue: null,
      );

  Future<void> _releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    int? interruptionGeneration,
    int? startBlockGeneration,
  }) async {
    if (_disposed) return;
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
  Future<void> seek(Duration position) =>
      _runPublicOperation<void>(() => _seek(position), disposedValue: null);

  Future<void> _seek(Duration position) async {
    if (_disposed) return;
    await seekConfirmed(position);
  }

  Future<Duration?> seekConfirmed(Duration position) =>
      _runPublicOperation<Duration?>(
        () => _seekConfirmed(position),
        disposedValue: null,
      );

  Future<Duration?> _seekConfirmed(Duration position) async {
    if (_disposed) return null;
    final sourceGeneration = _playGeneration;
    final seekGeneration = ++_seekGeneration;

    bool ownsSeek() =>
        !_disposed &&
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
  Future<void> stop() => _runPublicOperation<void>(_stop, disposedValue: null);

  Future<void> _stop() async {
    if (_disposed) return;
    _userIntentGeneration++;
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    _userWantsPlay = false;
    _bumpGeneration();
    _cancelForegroundCacheWork();
    await _releasePlaybackLeases();
    if (_disposed) return;
    await _stopPlayerSource();
    if (_disposed) return;
    await super.stop();
  }

  @override
  Future<void> skipToNext({bool seamless = false}) => _runPublicOperation<void>(
        () => _skipToNext(seamless: seamless),
        disposedValue: null,
      );

  Future<void> _skipToNext({bool seamless = false}) async {
    if (_disposed) return;
    AppLog.instance.record(
      'audio.command',
      'skip next requested seamless=$seamless '
          'routeRecoveryPending=$_outputRouteRecoveryPending',
    );
    _clearOutputRouteRecovery();
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    _recordExplicitPlayIntent();
    unawaited(_commands.recordExplicitPlayIntent());
    await _skipToNextInternal(seamless: seamless, provenance: provenance);
  }

  Future<void> _skipToNextInternal({
    bool seamless = false,
    PlaybackStartProvenance? provenance,
    int? targetIndex,
  }) async {
    if (_queue.isEmpty) return;
    await _ensureLazyQueueAhead(1);
    if (_queue.isEmpty) return;

    final shuffle = !_usesLazyQueue &&
        (_player.shuffleModeEnabled ||
            playbackState.value.shuffleMode == AudioServiceShuffleMode.all);
    final loop = shuffle ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.all ||
        playbackState.value.repeatMode == AudioServiceRepeatMode.one;
    final nextIndex = targetIndex ??
        nextQueueIndex(
          currentIndex: _currentIndex,
          queueLength: _queue.length,
          shuffle: shuffle,
          loop: loop,
        );
    if (nextIndex < 0) return;
    if (nextIndex >= _queue.length) return;
    final nextOccurrence = _occurrenceIdAt(nextIndex);
    final nextItem = _queue[nextIndex];
    _bumpGeneration();
    _cancelForegroundCacheWork();
    _currentIndex = nextIndex;
    _activeOccurrenceId = nextOccurrence;
    _activeItemId = nextItem.id;
    mediaItem.add(nextItem);
    _publishPlaybackState(
      override: AudioProcessingState.buffering,
      playingOverride: true,
      positionOverride: Duration.zero,
    );
    final sourceCommandToken = _commands.requestSource(
      occurrenceId: nextOccurrence,
      position: Duration.zero,
    );
    _nativeTransitionSourceToken = sourceCommandToken;
    final keepaliveInstalled = await _commands.installTemporarySource(
      sourceCommandToken,
      audioSourceFor('', tag: nextItem),
    );
    if (!keepaliveInstalled &&
        !_commands.ownsSourceRequest(sourceCommandToken, nextOccurrence)) {
      if (_nativeTransitionSourceToken == sourceCommandToken) {
        _nativeTransitionSourceToken = null;
      }
      return;
    }
    if (seamless) _userWantsPlay = true;
    final liveIndex = _indexOfOccurrence(nextOccurrence);
    if (liveIndex < 0 ||
        !_commands.ownsSourceRequest(sourceCommandToken, nextOccurrence)) {
      if (keepaliveInstalled) {
        await _commands.discardTemporarySource(sourceCommandToken);
      }
      if (_nativeTransitionSourceToken == sourceCommandToken) {
        _nativeTransitionSourceToken = null;
      }
      return;
    }
    await _loadQueueItem(
      liveIndex,
      seamless: seamless,
      preserveUserIntent: true,
      provenance: provenance,
      sourceCommandToken: sourceCommandToken,
      keepNativePlayingDuringTransition: true,
    );
  }

  @override
  Future<void> skipToPrevious() =>
      _runPublicOperation<void>(_skipToPrevious, disposedValue: null);

  Future<void> _skipToPrevious() async {
    if (_disposed) return;
    AppLog.instance.record(
      'audio.command',
      'skip previous requested routeRecoveryPending=$_outputRouteRecoveryPending',
    );
    _clearOutputRouteRecovery();
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    _recordExplicitPlayIntent();
    unawaited(_commands.recordExplicitPlayIntent());
    await _skipToPreviousInternal(provenance: provenance);
  }

  Future<void> _skipToPreviousInternal({
    PlaybackStartProvenance? provenance,
  }) async {
    if (_queue.isEmpty) return;

    final shuffle = !_usesLazyQueue &&
        (_player.shuffleModeEnabled ||
            playbackState.value.shuffleMode == AudioServiceShuffleMode.all);
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
    final previousOccurrence = _occurrenceIdAt(prevIndex);
    final previousItem = _queue[prevIndex];
    _bumpGeneration();
    _cancelForegroundCacheWork();
    _currentIndex = prevIndex;
    _activeOccurrenceId = previousOccurrence;
    _activeItemId = previousItem.id;
    mediaItem.add(previousItem);
    _publishPlaybackState(
      override: AudioProcessingState.buffering,
      playingOverride: true,
      positionOverride: Duration.zero,
    );
    final sourceCommandToken = _commands.requestSource(
      occurrenceId: previousOccurrence,
      position: Duration.zero,
    );
    _nativeTransitionSourceToken = sourceCommandToken;
    final keepaliveInstalled = await _commands.installTemporarySource(
      sourceCommandToken,
      audioSourceFor('', tag: previousItem),
    );
    if (!keepaliveInstalled &&
        !_commands.ownsSourceRequest(sourceCommandToken, previousOccurrence)) {
      if (_nativeTransitionSourceToken == sourceCommandToken) {
        _nativeTransitionSourceToken = null;
      }
      return;
    }
    final liveIndex = _indexOfOccurrence(previousOccurrence);
    if (liveIndex < 0 ||
        !_commands.ownsSourceRequest(sourceCommandToken, previousOccurrence)) {
      if (keepaliveInstalled) {
        await _commands.discardTemporarySource(sourceCommandToken);
      }
      if (_nativeTransitionSourceToken == sourceCommandToken) {
        _nativeTransitionSourceToken = null;
      }
      return;
    }
    await _loadQueueItem(
      liveIndex,
      preserveUserIntent: true,
      provenance: provenance,
      sourceCommandToken: sourceCommandToken,
      keepNativePlayingDuringTransition: true,
    );
  }

  /// 立刻停止当前输出；进度归零。
  /// 锁屏/控制中心切歌时必须保持 playing=true，否则 iOS 会结束后台音频会话。
  /// 装源成功后必须尽快 [releasePreservingIntent]，否则 effectivePlaying 一直为 false，
  /// 新曲装完也不会自动 play，表现为锁屏下一首直接停住。
  Future<_PlaybackHalt> _haltCurrentPlayback() async {
    _bumpGeneration();
    _cancelForegroundCacheWork();
    final owner = await _commands.pausePreservingIntent();
    _publishPlaybackState(
      override: AudioProcessingState.buffering,
      playingOverride: true,
      positionOverride: Duration.zero,
    );
    return _PlaybackHalt(owner);
  }

  Future<void> _ensureLazyQueueAhead(int minimumItems) async {
    final loader = _lazyQueueLoader;
    if (loader == null || _disposed || _queue.isEmpty) return;
    final rebuild = _lazyQueueRebuild;
    if (rebuild != null) {
      await rebuild;
      if (_disposed || !identical(loader, _lazyQueueLoader) || _queue.isEmpty) {
        return;
      }
    }
    final available = _queue.length - _currentIndex - 1;
    if (available >= minimumItems) return;
    final existing = _lazyQueueRefill;
    if (existing != null) {
      await existing;
      if (_disposed || !identical(loader, _lazyQueueLoader) || _queue.isEmpty) {
        return;
      }
      final refreshedAvailable = _queue.length - _currentIndex - 1;
      if (refreshedAvailable >= minimumItems) return;
    }

    final needed = minimumItems - (_queue.length - _currentIndex - 1);
    final epoch = _lazyQueueEpoch;
    final refill = () async {
      final List<MediaItem> items;
      try {
        items = await loader(needed);
      } catch (error) {
        debugPrint('[AudioHandler] lazy queue load failed: $error');
        return;
      }
      if (_disposed ||
          !identical(loader, _lazyQueueLoader) ||
          epoch != _lazyQueueEpoch ||
          items.isEmpty) {
        return;
      }
      _queue.addAll(items);
      _queueOccurrenceIds.addAll(
        List<int>.generate(items.length, (_) => _newOccurrenceId()),
      );
      _trimLazyQueueHistory();
      queue.add(List.unmodifiable(_queue));
    }();
    _lazyQueueRefill = refill;
    try {
      await refill;
    } finally {
      if (identical(_lazyQueueRefill, refill)) _lazyQueueRefill = null;
    }
  }

  void _trimLazyQueueHistory() {
    final removable = _currentIndex - _lazyQueueHistory;
    if (removable <= 0) return;
    _queue.removeRange(0, removable);
    _queueOccurrenceIds.removeRange(0, removable);
    _currentIndex -= removable;
  }

  Future<void> _rebuildLazyQueueForShuffle(bool enabled) {
    final rebuild = _lazyQueueShuffleRebuilder;
    final current = mediaItem.value;
    final currentOccurrence = _activeOccurrenceId;
    if (rebuild == null || current == null || currentOccurrence == null) {
      return Future<void>.value();
    }
    _lazyQueueEpoch++;
    final rebuildFuture = _rebuildLazyQueueWithShuffle(
      rebuild,
      current,
      currentOccurrence,
      enabled,
    );
    _lazyQueueRebuild = rebuildFuture;
    return rebuildFuture.whenComplete(() {
      if (identical(_lazyQueueRebuild, rebuildFuture)) {
        _lazyQueueRebuild = null;
      }
    });
  }

  Future<void> _rebuildLazyQueueWithShuffle(
    LazyQueueShuffleRebuilder rebuild,
    MediaItem current,
    int currentOccurrence,
    bool enabled,
  ) async {
    List<MediaItem> following = const [];
    try {
      following = await rebuild(current, enabled, _lazyQueueAhead);
    } catch (error) {
      debugPrint('[AudioHandler] lazy queue shuffle rebuild failed: $error');
    }
    if (_disposed ||
        !identical(rebuild, _lazyQueueShuffleRebuilder) ||
        _activeOccurrenceId != currentOccurrence ||
        !identical(mediaItem.value, current)) {
      return;
    }
    _lazyQueueEpoch++;
    _queue
      ..clear()
      ..add(current)
      ..addAll(following);
    _queueOccurrenceIds
      ..clear()
      ..add(currentOccurrence)
      ..addAll(List<int>.generate(following.length, (_) => _newOccurrenceId()));
    _currentIndex = 0;
    _activeItemId = current.id;
    queue.add(List.unmodifiable(_queue));
    _publishPlaybackState();
  }

  Future<int> _preloadCount() async {
    try {
      final results = await Connectivity().checkConnectivity();
      final wifi = results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
      return wifi ? 3 : 2;
    } catch (_) {
      return 2;
    }
  }

  /// 后台预加载后续曲目（解析+本地缓存），不阻塞当前播放。
  void _schedulePreload() {
    if (_disposed) return;
    final gen = _playGeneration;
    final provenance = _captureStartProvenance();
    final anchorIndex = _currentIndex;
    _trackOperation(() async {
      if (_disposed) return;
      final resolver = urlResolver;
      if (resolver == null || _queue.isEmpty) return;
      if (_isStale(gen)) return;
      await _ensureLazyQueueAhead(_lazyQueueAhead);
      if (_isStale(gen) || _queue.isEmpty) return;
      final count = await _preloadCount();
      final start = anchorIndex + 1;
      for (var i = 0; i < count; i++) {
        if (_isStale(gen)) return;
        final idx = start + i;
        if (idx >= _queue.length) break;
        final item = _queue[idx];
        final occurrenceId = _occurrenceIdAt(idx);
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
        if (_preloadRequests.values.any(
          (request) => request.occurrenceId == occurrenceId,
        )) {
          continue;
        }
        int? requestToken;
        try {
          debugPrint('[AudioHandler] preload idx=$idx title=${item.title}');
          final rawExtras = item.extras == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(item.extras!);
          requestToken = ++_nextPreloadRequestToken;
          _preloadRequests[requestToken] = _PreloadRequest(
            gen,
            occurrenceId,
            item,
          );
          rawExtras['_preloadRequestToken'] = requestToken;
          final url = await resolver(item.id, rawExtras);
          if (url == null || url.isEmpty) continue;
          final request = _preloadRequests[requestToken];
          final liveIndex =
              request == null ? -1 : _indexOfOccurrence(request.occurrenceId);
          if (request == null ||
              request.generation != _playGeneration ||
              request.mediaId != itemId ||
              liveIndex < 0 ||
              !identical(_queue[liveIndex], request.item) ||
              request.occurrenceId == _activeOccurrenceId) {
            continue;
          }
          final extras = Map<String, dynamic>.from(
            _queue[liveIndex].extras ?? {},
          );
          extras['url'] = url;
          _replaceQueueItem(
            liveIndex,
            _queue[liveIndex].copyWith(extras: extras),
          );
          // 若用户已切到这首且仍在等解析，立刻用预加载结果开播
          if (_currentIndex == liveIndex && _userWantsPlay) {
            final curUrl = mediaItem.value?.extras?['url']?.toString() ?? '';
            if (curUrl.isEmpty || curUrl.startsWith('data:')) {
              await _loadQueueItem(
                liveIndex,
                preserveUserIntent: true,
                provenance: provenance,
              );
            }
          }
        } catch (e) {
          debugPrint('[AudioHandler] preload failed idx=$idx: $e');
        } finally {
          if (requestToken != null) {
            _preloadRequests.remove(requestToken);
          }
        }
      }
      if (!_isStale(gen)) queue.add(List.from(_queue));
    });
  }

  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> cleanup(FutureOr<void> Function() action) async {
      try {
        await Future<void>.sync(action);
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    _disposed = true;
    _playGeneration++;
    _preloadRequests.clear();
    _foregroundResolutionRequest = null;
    final foregroundCacheKey = _foregroundCacheKey;
    final cancelCacheKey = _cancelCacheKey;
    final cancelAllTrackedCacheWork = _cancelAllTrackedCacheWork;
    _foregroundCacheKey = null;
    urlResolver = null;
    onError = null;
    _classifyExistingCache = null;
    _acquireExistingCache = null;
    _cancelCacheKey = null;
    _cancelAllTrackedCacheWork = null;
    if (foregroundCacheKey != null && cancelCacheKey != null) {
      await cleanup(() => cancelCacheKey(foregroundCacheKey));
    }
    if (cancelAllTrackedCacheWork != null) {
      await cleanup(cancelAllTrackedCacheWork);
    }

    final playbackEvents = _playbackEventSubscription;
    final processingStates = _processingStateSubscription;
    _playbackEventSubscription = null;
    _processingStateSubscription = null;
    if (playbackEvents != null) await cleanup(playbackEvents.cancel);
    if (processingStates != null) await cleanup(processingStates.cancel);
    await cleanup(_drainOperations);
    await cleanup(_drainLeaseReleases);
    await cleanup(_releasePlaybackLeases);
    await cleanup(_drainLeaseReleases);
    await cleanup(_commands.stopAndWait);
    await cleanup(_player.dispose);
    await cleanup(_playerSubject.close);

    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }

  @override
  Future<void> skipToQueueItem(
    int index, {
    bool seamless = false,
    Duration initialPosition = Duration.zero,
    bool playAfterLoad = true,
  }) =>
      _runPublicOperation<void>(
        () => _skipToQueueItem(
          index,
          seamless: seamless,
          initialPosition: initialPosition,
          playAfterLoad: playAfterLoad,
        ),
        disposedValue: null,
      );

  Future<void> _skipToQueueItem(
    int index, {
    bool seamless = false,
    Duration initialPosition = Duration.zero,
    bool playAfterLoad = true,
  }) async {
    if (_disposed) return;
    _clearOutputRouteRecovery();
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    _recordExplicitPlaybackIntent(playAfterLoad);
    final selectedItem =
        index >= 0 && index < _queue.length ? _queue[index] : null;
    final selectedOccurrenceId =
        selectedItem == null ? null : _occurrenceIdAt(index);
    if (selectedItem == null) return;
    unawaited(
      playAfterLoad
          ? _commands.recordExplicitPlayIntent()
          : _commands.setDesiredPlayingPreservingIntent(false),
    );
    final sourceCommandToken = _commands.requestSource(
      occurrenceId: selectedOccurrenceId!,
      position: initialPosition,
    );
    final halt = seamless ? null : await _haltCurrentPlayback();
    if (_disposed) return;
    final relocatedIndex = _indexOfOccurrence(selectedOccurrenceId);
    if (relocatedIndex < 0 ||
        !identical(_queue[relocatedIndex], selectedItem) ||
        !_commands.ownsSourceRequest(
          sourceCommandToken,
          selectedOccurrenceId,
        )) {
      if (halt != null) {
        await _commands.releasePreservingIntent(halt.owner);
      }
      return;
    }
    await _loadQueueItem(
      relocatedIndex,
      seamless: seamless,
      preserveUserIntent: true,
      initialPosition: initialPosition,
      provenance: provenance,
      sourceCommandToken: sourceCommandToken,
      preservingPauseOwner: halt?.owner,
    );
  }

  Future<void> _loadQueueItem(
    int index, {
    bool seamless = false,
    bool preserveUserIntent = false,
    bool recoverStaleInstall = true,
    Duration initialPosition = Duration.zero,
    PlaybackStartProvenance? provenance,
    int? sourceCommandToken,
    PreservingPauseOwner? preservingPauseOwner,
    bool keepNativePlayingDuringTransition = false,
  }) {
    if (_disposed) return Future<void>.value();
    return _trackOperation(
      () => _loadQueueItemImpl(
        index,
        seamless: seamless,
        preserveUserIntent: preserveUserIntent,
        recoverStaleInstall: recoverStaleInstall,
        initialPosition: initialPosition,
        provenance: provenance,
        sourceCommandToken: sourceCommandToken,
        preservingPauseOwner: preservingPauseOwner,
        keepNativePlayingDuringTransition: keepNativePlayingDuringTransition,
      ),
    );
  }

  Future<void> _loadQueueItemImpl(
    int index, {
    bool seamless = false,
    bool preserveUserIntent = false,
    bool recoverStaleInstall = true,
    Duration initialPosition = Duration.zero,
    PlaybackStartProvenance? provenance,
    int? sourceCommandToken,
    PreservingPauseOwner? preservingPauseOwner,
    bool keepNativePlayingDuringTransition = false,
  }) async {
    try {
      if (index < 0 || index >= _queue.length) return;

      final startProvenance = provenance ?? _captureStartProvenance();
      final occurrenceId = _occurrenceIdAt(index);
      final item = _queue[index];
      final itemId = item.id;
      final commandToken = sourceCommandToken ??
          _commands.requestSource(
            occurrenceId: occurrenceId,
            position: initialPosition,
          );
      if (!_commands.ownsSourceRequest(commandToken, occurrenceId) ||
          index >= _queue.length ||
          _occurrenceIdAt(index) != occurrenceId ||
          !identical(_queue[index], item)) {
        return;
      }
      final gen = _bumpGeneration();
      _cancelForegroundCacheWork();
      if (!preserveUserIntent) _userWantsPlay = true;
      final foregroundRequest = _ForegroundResolutionRequest(
        gen,
        occurrenceId,
        item,
      );
      _foregroundResolutionRequest = foregroundRequest;
      int activeItemIndex() {
        final liveIndex = _indexOfOccurrence(occurrenceId);
        if (_isStale(gen) ||
            !_commands.ownsSourceRequest(commandToken, occurrenceId) ||
            _activeOccurrenceId != occurrenceId ||
            liveIndex < 0 ||
            liveIndex != _currentIndex ||
            !identical(_queue[liveIndex], foregroundRequest.item) ||
            !identical(mediaItem.value, foregroundRequest.item)) {
          return -1;
        }
        foregroundRequest.item = _queue[liveIndex];
        return liveIndex;
      }

      _currentIndex = index;
      _activeOccurrenceId = occurrenceId;
      _activeItemId = itemId;
      // Keep system now-playing session alive during skip (lock screen / Control
      // Center). Publishing playing:false here stops iOS audio and looks stuck.
      final keepPlaying = seamless || _userWantsPlay;
      mediaItem.add(item);
      queue.add(List.unmodifiable(_queue));
      final manualBufferingPublication = _publishPlaybackState(
        override: AudioProcessingState.buffering,
        playingOverride: keepPlaying ? true : false,
        positionOverride: initialPosition,
      );
      final cachedUrl = item.extras?['url']?.toString();
      final cachedQ = item.extras?['requestedQuality']?.toString();
      final canReuse = shouldReuseCachedPlayUrl(
        cachedUrl: cachedUrl,
        cachedRequestedQuality: cachedQ,
        currentRequestedQuality: preferredQuality,
      );
      String? currentUrl = canReuse ? cachedUrl : null;

      var sourceInstallAttempted = false;
      var sourceTransitionFollows = false;
      PlaybackCacheLease? stagedLease;

      try {
        String? url = currentUrl;
        var checkedExistingPath = false;
        var rejectedResolverProducedFile = false;

        if (canReuse && url != null && url.isNotEmpty) {
          stagedLease = await _takePendingLeaseForUrl(occurrenceId, url);
          if (stagedLease == null) {
            checkedExistingPath = true;
            final classification = await _classifyExistingCachePath(url);
            final liveIndex = activeItemIndex();
            if (liveIndex < 0) {
              if (classification is LeasedPlaybackCachePath) {
                await classification.lease.release();
              }
              return;
            }
            if (classification is RejectedPlaybackCachePath) {
              final staleExtras = Map<String, dynamic>.from(
                _queue[liveIndex].extras ?? {},
              );
              staleExtras
                ..remove('url')
                ..remove('remoteUrl')
                ..remove('cacheKey')
                ..remove('actualQuality');
              final clearedItem = _queue[liveIndex].copyWith(
                extras: staleExtras,
              );
              _replaceQueueItem(liveIndex, clearedItem);
              queue.add(List.from(_queue));
              mediaItem.add(clearedItem);
              foregroundRequest.item = clearedItem;
              url = null;
            } else if (classification is LeasedPlaybackCachePath) {
              stagedLease = classification.lease;
            }
          }
        }

        if (url == null || url.isEmpty) {
          if (urlResolver != null) {
            // 强制按当前 preferredQuality 重新解析，忽略过期的 extras.url
            final resolveExtras = item.extras == null
                ? <String, dynamic>{}
                : Map<String, dynamic>.from(item.extras!);
            resolveExtras.remove('url');
            resolveExtras.remove('remoteUrl');
            resolveExtras['requestedQuality'] = preferredQuality;
            resolveExtras['_playbackGeneration'] = gen;
            // 解析总超时：音源不可用时避免无限等待，直接进入失败分支。
            url = await urlResolver!(item.id, resolveExtras).timeout(
              _resolveTimeout,
            );
          }
        }

        var transactionIndex = activeItemIndex();
        if (transactionIndex < 0) {
          await _discardStagedLease(occurrenceId, stagedLease);
          return;
        }
        if (url != null &&
            url.isNotEmpty &&
            stagedLease == null &&
            !checkedExistingPath) {
          stagedLease = await _takePendingLeaseForUrl(occurrenceId, url);
          if (stagedLease == null) {
            final classification = await _classifyExistingCachePath(url);
            transactionIndex = activeItemIndex();
            if (transactionIndex < 0) {
              if (classification is LeasedPlaybackCachePath) {
                await classification.lease.release();
              }
              return;
            }
            if (classification is RejectedPlaybackCachePath) {
              final staleExtras = Map<String, dynamic>.from(
                _queue[transactionIndex].extras ?? {},
              );
              staleExtras
                ..remove('url')
                ..remove('remoteUrl')
                ..remove('cacheKey')
                ..remove('actualQuality');
              final clearedItem = _queue[transactionIndex].copyWith(
                extras: staleExtras,
              );
              _replaceQueueItem(transactionIndex, clearedItem);
              queue.add(List.from(_queue));
              mediaItem.add(clearedItem);
              foregroundRequest.item = clearedItem;
              url = null;
              rejectedResolverProducedFile = true;
            } else if (classification is LeasedPlaybackCachePath) {
              stagedLease = classification.lease;
            }
          }
        }

        if (url == null &&
            rejectedResolverProducedFile &&
            urlResolver != null) {
          final resolveExtras = item.extras == null
              ? <String, dynamic>{}
              : Map<String, dynamic>.from(item.extras!);
          resolveExtras.remove('url');
          resolveExtras.remove('remoteUrl');
          resolveExtras['requestedQuality'] = preferredQuality;
          resolveExtras['_playbackGeneration'] = gen;
          url = await urlResolver!(item.id, resolveExtras).timeout(
            _resolveTimeout,
          );
        }

        if (url == null || url.isEmpty) {
          await _discardStagedLease(occurrenceId, stagedLease);
          if (keepNativePlayingDuringTransition) {
            await _commands.discardTemporarySource(commandToken);
          }
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

        final baseExtras = Map<String, dynamic>.from(
          _queue[transactionIndex].extras ?? {},
        );
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
        final updatedItem = _queue[transactionIndex].copyWith(
          extras: baseExtras,
        );
        _replaceQueueItem(transactionIndex, updatedItem);
        queue.add(List.from(_queue));
        // Publish metadata before source install so lock screen/Dynamic Island
        // show the correct title/art while buffering the new track.
        mediaItem.add(updatedItem);
        _publishPlaybackState(
          override: AudioProcessingState.buffering,
          playingOverride: keepPlaying ? true : false,
          positionOverride: initialPosition,
        );
        foregroundRequest.item = updatedItem;
        _activeItemId = itemId;

        // URL 解析在协调器外；提交结果时必须仍拥有源请求。
        if (_isStale(gen)) {
          await _discardStagedLease(occurrenceId, stagedLease);
          return;
        }
        transactionIndex = activeItemIndex();
        if (transactionIndex < 0 ||
            !_commands.ownsSourceRequest(commandToken, occurrenceId)) {
          await _discardStagedLease(occurrenceId, stagedLease);
          return;
        }
        stagedLease ??= _pendingResolutions[occurrenceId]?.leaseOrNull;
        if (_isStale(gen) ||
            !_commands.ownsSourceRequest(commandToken, occurrenceId) ||
            activeItemIndex() < 0) {
          await _discardStagedLease(occurrenceId, stagedLease);
          return;
        }
        if (stagedLease != null) {
          _leaseSession.holdPending(stagedLease);
        } else if (Uri.tryParse(url)?.scheme != 'file') {
          _leaseSession.holdPending(null);
        }
        sourceInstallAttempted = true;
        final requestHeaders = Uri.tryParse(url)?.scheme == 'http' ||
                Uri.tryParse(url)?.scheme == 'https'
            ? mediaRequestHeaders(
                url,
                updatedItem.extras?['platform']?.toString() ?? '',
              )
            : null;
        final commitResult = await _commands.commitSource(
          commandToken,
          audioSourceFor(url, tag: updatedItem, headers: requestHeaders),
        );
        sourceTransitionFollows = true;
        if (commitResult is SourceCommitStale) {
          await _discardStagedLease(occurrenceId, stagedLease);
          if (commitResult.nativeInstallApplied && recoverStaleInstall) {
            await _recoverAuthoritativeSource(provenance: startProvenance);
          }
          return;
        }
        if (commitResult is SourceCommitFailed) {
          await _discardStagedLease(occurrenceId, stagedLease);
          Error.throwWithStackTrace(
            commitResult.error,
            commitResult.stackTrace,
          );
        }
        await _commitStagedLease(
          occurrenceId: occurrenceId,
          generation: gen,
          lease: stagedLease,
        );
        transactionIndex = activeItemIndex();
        if (_isStale(gen) ||
            !_commands.ownsSourceRequest(commandToken, occurrenceId) ||
            transactionIndex < 0) {
          if (recoverStaleInstall && _playGeneration == gen) {
            await _recoverAuthoritativeSource(provenance: startProvenance);
          }
          return;
        }
        _installedSourceOwnerToken = commandToken;
        _installedPlaybackGeneration = gen;
        _installedMediaId = itemId;
        if (_nativeTransitionSourceToken == commandToken) {
          _nativeTransitionSourceToken = null;
        }
        _adoptInstalledSourceForInterruption(
          sourceGeneration: gen,
          mediaId: itemId,
        );
        // Release skip-halt before publish so effectivePlaying can become true
        // and the coordinator will play the newly installed source. Do not
        // re-record play intent here — quality reload / interruption paths
        // may intentionally stay paused.
        if (preservingPauseOwner != null) {
          await _commands.releasePreservingIntent(preservingPauseOwner);
          preservingPauseOwner = null;
        }
        _publishPlaybackState(
          playingOverride: _commands.effectivePlaying ? true : null,
          positionOverride: initialPosition,
        );
        if (!_isStale(gen)) _schedulePreload();
      } catch (e, stackTrace) {
        debugPrint('[AudioHandler] 播放失败: $e');
        await _discardStagedLease(occurrenceId, stagedLease);
        if (_disposed) Error.throwWithStackTrace(e, stackTrace);
        // Lock-screen navigation keeps the old source alive while resolving.
        // Once resolution/install has failed there is no pending background
        // work to protect, so stop mismatched old audio before fallback.
        if (keepNativePlayingDuringTransition && _player.playing) {
          preservingPauseOwner = await _commands.pausePreservingIntent();
        }
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
        if (keepNativePlayingDuringTransition &&
            _installedSourceOwnerToken != commandToken) {
          await _commands.discardTemporarySource(commandToken);
          if (_nativeTransitionSourceToken == commandToken) {
            _nativeTransitionSourceToken = null;
            _publishPlaybackState();
          }
        }
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
    Duration? initialPosition,
  }) async {
    if (_commands.desiredSourceOccurrenceId != _activeOccurrenceId) return;
    final authoritativeItem = mediaItem.value;
    final authoritativeIndex = _currentIndex;
    if (authoritativeItem == null ||
        _activeItemId != authoritativeItem.id ||
        authoritativeIndex < 0 ||
        authoritativeIndex >= _queue.length ||
        !identical(_queue[authoritativeIndex], authoritativeItem)) {
      return;
    }

    await _loadQueueItem(
      authoritativeIndex,
      preserveUserIntent: true,
      recoverStaleInstall: false,
      initialPosition: initialPosition ?? Duration.zero,
      provenance: provenance,
    );
  }

  // 设置播放列表；playWhenReady=false 时只加载队列，保持暂停
  Future<void> setPlaylist(
    List<MediaItem> items, {
    int initialIndex = 0,
    bool playWhenReady = true,
  }) =>
      _runPublicOperation<void>(
        () => _setPlaylist(
          items,
          initialIndex: initialIndex,
          playWhenReady: playWhenReady,
        ),
        disposedValue: null,
      );

  Future<void> _setPlaylist(
    List<MediaItem> items, {
    int initialIndex = 0,
    bool playWhenReady = true,
  }) async {
    if (_disposed) return;
    _clearOutputRouteRecovery();
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    _recordExplicitPlaybackIntent(playWhenReady);
    unawaited(
      playWhenReady
          ? _commands.recordExplicitPlayIntent()
          : _commands.setDesiredPlayingPreservingIntent(false),
    );
    _bumpGeneration();
    _lazyQueueEpoch++;
    _queue
      ..clear()
      ..addAll(items);
    _queueOccurrenceIds
      ..clear()
      ..addAll(List<int>.generate(items.length, (_) => _newOccurrenceId()));
    queue.add(List.from(_queue));

    if (items.isEmpty) {
      _activeOccurrenceId = null;
      _cancelForegroundCacheWork();
      await _releasePlaybackLeases();
      if (_disposed) return;
      await _stopPlayerSource();
      return;
    }

    final safeIndex = initialIndex.clamp(0, items.length - 1);
    _currentIndex = safeIndex;
    _activeItemId = items[safeIndex].id;
    mediaItem.add(items[safeIndex]);
    if (playWhenReady) {
      unawaited(_commands.clearPreservingPauseOwners());
    }

    // 始终走 skipToQueueItem，统一解析/缓存/预加载
    await _loadQueueItem(
      safeIndex,
      preserveUserIntent: true,
      provenance: provenance,
    );
  }

  @override
  Future<void> updateQueue(List<MediaItem> queue) =>
      _runPublicOperation<void>(() => _updateQueue(queue), disposedValue: null);

  Future<void> _updateQueue(List<MediaItem> queue) async {
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    final activeOccurrence = _activeOccurrenceId;
    _replaceQueuePreservingOccurrences(queue);
    if (_queue.isEmpty) {
      _currentIndex = -1;
      _activeItemId = null;
      _activeOccurrenceId = null;
      _queueOccurrenceIds.clear();
      this.queue.add(const <MediaItem>[]);
      mediaItem.add(null);
      await _stopInternal();
      return;
    }
    final retained =
        activeOccurrence == null ? -1 : _indexOfOccurrence(activeOccurrence);
    _currentIndex = retained >= 0 ? retained : 0;
    _activeItemId = _queue[_currentIndex].id;
    _activeOccurrenceId = _occurrenceIdAt(_currentIndex);
    if (activeOccurrence != null && retained < 0) {
      this.queue.add(List.unmodifiable(_queue));
      unawaited(_loadQueueItem(
        _currentIndex,
        preserveUserIntent: true,
        recoverStaleInstall: false,
        provenance: provenance,
      ));
      return;
    }
    this.queue.add(List.unmodifiable(_queue));
    mediaItem.add(_queue[_currentIndex]);
    _publishPlaybackState();
  }

  @override
  Future<void> addQueueItem(MediaItem mediaItem) => _runPublicOperation<void>(
        () => _addQueueItem(mediaItem),
        disposedValue: null,
      );

  Future<void> _addQueueItem(MediaItem mediaItem) async {
    if (_disposed) return;
    _queue.add(mediaItem);
    _queueOccurrenceIds.add(_newOccurrenceId());
    queue.add(List.from(_queue));
  }

  @override
  Future<void> removeQueueItem(MediaItem mediaItem) =>
      _runPublicOperation<void>(
        () => _removeQueueItem(mediaItem),
        disposedValue: null,
      );

  Future<void> _removeQueueItem(MediaItem mediaItem) async {
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    final targetId = mediaItem.id;
    var index = _queue.indexWhere((item) => identical(item, mediaItem));
    if (index < 0) index = _queue.indexWhere((item) => item.id == targetId);
    if (index != -1) {
      var removedOccurrence = _occurrenceIdAt(index);
      _discardPendingResolution(removedOccurrence);
      final activeOccurrence = _activeOccurrenceId;
      final removedCurrent = activeOccurrence == removedOccurrence;
      final wasPlaying = _player.playing;
      final wantedPlay = _userWantsPlay;
      final intentGeneration = _userIntentGeneration;
      _PlaybackHalt? halt;
      if (removedCurrent && _activeOccurrenceId != removedOccurrence) return;
      if (removedCurrent && wasPlaying) {
        halt = await _haltCurrentPlayback();
        if (_disposed) return;
        index = _indexOfOccurrence(removedOccurrence);
        if (index < 0) {
          await _commands.releasePreservingIntent(halt.owner);
          return;
        }
        _currentIndex = index;
        _activeItemId = targetId;
        _activeOccurrenceId = removedOccurrence;
        this.mediaItem.add(_queue[index]);
      }
      _queue.removeAt(index);
      _queueOccurrenceIds.removeAt(index);

      if (_queue.isEmpty) {
        _currentIndex = -1;
        _activeItemId = null;
        _activeOccurrenceId = null;
        _queueOccurrenceIds.clear();
        queue.add(const <MediaItem>[]);
        this.mediaItem.add(null);
        if (halt != null) {
          await _commands.releasePreservingIntent(halt.owner);
        }
        await _stopInternal();
        return;
      }

      final retainedIndex =
          activeOccurrence == null ? -1 : _indexOfOccurrence(activeOccurrence);
      final replacementIndex = index.clamp(0, _queue.length - 1);
      if (removedCurrent) {
        final replacementOccurrence = _occurrenceIdAt(replacementIndex);
        final sourceCommandToken = _commands.requestSource(
          occurrenceId: replacementOccurrence,
          position: Duration.zero,
        );
        queue.add(List.unmodifiable(_queue));
        final preservingPauseOwner = halt?.owner;
        halt = null;
        await _loadQueueItem(
          replacementIndex,
          preserveUserIntent: true,
          provenance: provenance,
          sourceCommandToken: sourceCommandToken,
          preservingPauseOwner: preservingPauseOwner,
        );
        var relocatedReplacement = _indexOfOccurrence(replacementOccurrence);
        if (relocatedReplacement < 0 ||
            _activeOccurrenceId != replacementOccurrence) {
          return;
        }
        if (_userIntentGeneration == intentGeneration && !wasPlaying) {
          final owner = await pauseInternal(clearIntent: false);
          if (owner != null) await _commands.releasePreservingIntent(owner);
          relocatedReplacement = _indexOfOccurrence(replacementOccurrence);
          if (relocatedReplacement < 0 ||
              _activeOccurrenceId != replacementOccurrence) {
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
      _activeOccurrenceId = _occurrenceIdAt(_currentIndex);
      queue.add(List.unmodifiable(_queue));
      this.mediaItem.add(currentItem);
      _publishPlaybackState();
    }
  }

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) =>
      _runPublicOperation<void>(
        () => _setRepeatMode(repeatMode),
        disposedValue: null,
      );

  Future<void> _setRepeatMode(AudioServiceRepeatMode repeatMode) async {
    if (_disposed) return;
    _repeatMode = repeatMode;
    _publishPlaybackState();
    // Single-source repeat is explicit so every replay emits one completion.
    await _commands.setLoopMode(LoopMode.off);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _runPublicOperation<void>(
        () => _setShuffleMode(shuffleMode),
        disposedValue: null,
      );

  Future<void> _setShuffleMode(AudioServiceShuffleMode shuffleMode) async {
    if (_disposed) return;
    final enabled = shuffleMode == AudioServiceShuffleMode.all;
    _shuffleMode = shuffleMode;
    final rebuildFuture = _usesLazyQueue
        ? _rebuildLazyQueueForShuffle(enabled)
        : Future<void>.value();
    await rebuildFuture;
    _publishPlaybackState();
    await _commands.setShuffleModeEnabled(enabled);
  }

  /// Background artwork warm-up: set local file artUri without reloading audio.
  /// Also writes `extras['artCacheFile']` so iOS lock screen shows the cover:
  /// audio_service reads only a local file path from that key, never a remote
  /// artUri, so without it remote covers (e.g. NetEase) are missing on lock.
  void patchQueueArtUri(String mediaId, Uri artUri) {
    if (_disposed) return;
    final filePath = artUri.scheme == 'file' ? artUri.toFilePath() : null;
    var changed = false;
    for (var i = 0; i < _queue.length; i++) {
      if (_queue[i].id != mediaId) continue;
      if (_queue[i].artUri == artUri) continue;
      final extras = Map<String, dynamic>.from(_queue[i].extras ?? {});
      if (filePath != null) {
        extras['artCacheFile'] = filePath;
      } else {
        extras.remove('artCacheFile');
      }
      _replaceQueueItem(i, _queue[i].copyWith(artUri: artUri, extras: extras));
      changed = true;
    }
    if (!changed) return;
    queue.add(List.unmodifiable(_queue));
    final current = mediaItem.value;
    if (current != null && current.id == mediaId && current.artUri != artUri) {
      final currentExtras = Map<String, dynamic>.from(current.extras ?? {});
      if (filePath != null) {
        currentExtras['artCacheFile'] = filePath;
      } else {
        currentExtras.remove('artCacheFile');
      }
      mediaItem.add(current.copyWith(artUri: artUri, extras: currentExtras));
    }
  }

  /// Applies metadata only if the exact queue occurrence still owns [index].
  /// The legacy ID-based method above remains for callers without an occurrence.
  bool patchQueueItemExtrasAt({
    required int index,
    required MediaItem expectedItem,
    required Map<String, dynamic> patch,
  }) {
    if (_disposed) return false;
    if (index < 0 || index >= _queue.length) return false;
    if (!identical(_queue[index], expectedItem)) return false;
    final extras = Map<String, dynamic>.from(expectedItem.extras ?? {});
    extras.addAll(patch);
    final updatedItem = expectedItem.copyWith(extras: extras);
    _replaceQueueItem(index, updatedItem);
    queue.add(List.from(_queue));
    if (_currentIndex == index && identical(mediaItem.value, expectedItem)) {
      mediaItem.add(updatedItem);
    }
    return true;
  }

  /// 设置页改音质后调用：清掉队列里过期的 url，并让当前曲按新音质重解析。
  Future<void> applyPreferredQuality(String quality) =>
      _runPublicOperation<void>(
        () => _applyPreferredQuality(quality),
        disposedValue: null,
      );

  Future<void> _applyPreferredQuality(String quality) async {
    if (_disposed) return;
    final provenance = _captureStartProvenance();
    final reloadIntent = qualityReloadIntent(
      position: _player.position,
      duration: _player.duration,
      desiredPlayingIntent: _commands.desiredPlayingIntent,
    );
    preferredQuality = quality;
    if (_queue.isEmpty) return;
    for (var i = 0; i < _queue.length; i++) {
      final extras = Map<String, dynamic>.from(_queue[i].extras ?? {});
      final cachedQ = extras['requestedQuality']?.toString();
      if (cachedQ != quality) {
        extras.remove('url');
        extras.remove('remoteUrl');
        extras['requestedQuality'] = quality;
        _replaceQueueItem(i, _queue[i].copyWith(extras: extras));
      }
    }
    queue.add(List.from(_queue));
    final sourceGeneration = _playGeneration;
    final reloadOccurrence = _activeOccurrenceId;
    final initialIndex =
        reloadOccurrence == null ? -1 : _indexOfOccurrence(reloadOccurrence);
    if (initialIndex < 0 || _currentIndex != initialIndex) return;
    final sourceCommandToken = _commands.requestSource(
      occurrenceId: reloadOccurrence!,
      position: reloadIntent.position,
    );
    unawaited(
      _commands.setDesiredPlayingPreservingIntent(
        reloadIntent.resumeAfterReload,
      ),
    );
    var qualityPauseOwner = reloadIntent.resumeAfterReload
        ? await pauseInternal(clearIntent: false)
        : null;
    try {
      if (_disposed) return;
      if (_playGeneration != sourceGeneration) return;

      final idx = _indexOfOccurrence(reloadOccurrence);
      if (idx < 0 ||
          _currentIndex != idx ||
          _activeOccurrenceId != reloadOccurrence) {
        return;
      }
      final owner = qualityPauseOwner;
      qualityPauseOwner = null;
      await _loadQueueItem(
        idx,
        preserveUserIntent: true,
        initialPosition: reloadIntent.position,
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

  const _PlaybackHalt(this.owner);
}
