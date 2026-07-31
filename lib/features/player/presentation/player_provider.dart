import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/audio/audio_handler.dart';
import '../../../core/audio/playback_command_coordinator.dart';
import '../../../core/storage/storage_service.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../domain/music_item.dart';
import '../domain/playback_session.dart';
import '../domain/playback_session_store.dart';
import '../domain/player_service.dart';
import 'fire_and_forget_observer.dart';

final playerServiceProvider = Provider<PlayerService>((ref) {
  return PlayerService();
});

final playbackSessionStoreProvider = Provider<PlaybackSessionStore>((ref) {
  return PlaybackSessionStore(() => StorageService.instance);
});

// 监听当前的 MediaItem (来自 audio_service)
final currentMediaItemProvider = StreamProvider<MediaItem?>((ref) {
  return audioHandler.mediaItem;
});

// 转换 MediaItem 为项目通用的 MusicItem
final currentMusicProvider = Provider<MusicItem?>((ref) {
  final mediaItem = ref.watch(currentMediaItemProvider).value;
  if (mediaItem == null) return null;

  // 从 extras 中恢复 MusicItem 对象（含 actualQuality 等扩展字段）
  if (mediaItem.extras != null) {
    final item = MusicItem.fromJson(mediaItem.extras!);
    // 保证 platform 字段可用
    final p = mediaItem.extras!['platform']?.toString();
    if (p != null && p.isNotEmpty && item.platform != p) {
      return item.copyWith(platform: p);
    }
    return item;
  }

  // 如果没有 extras，手动构建
  return MusicItem(
    id: mediaItem.id,
    name: mediaItem.title,
    singer: mediaItem.artist ?? '未知歌手',
    album: mediaItem.album ?? '',
    duration: mediaItem.duration ?? Duration.zero,
    source: 'unknown',
    artwork: mediaItem.artUri?.toString(),
  );
});

// 监听播放状态
final playbackStateProvider = StreamProvider<PlaybackState>((ref) {
  return audioHandler.playbackState;
});

// 实时进度：用 Timer 轮询 just_audio 的 position（比 StreamProvider 更可靠）
final playerPositionProvider =
    StateNotifierProvider<PositionNotifier, Duration>((ref) {
  if (audioHandler is LxAudioHandler) {
    return PositionNotifier((audioHandler as LxAudioHandler).player);
  }
  return PositionNotifier(null);
});

// 适配 MiniPlayer 的别名提供者
final positionProvider = playerPositionProvider;

// 播放状态简化
final isPlayingProvider = Provider<AsyncValue<bool>>((ref) {
  final state = ref.watch(playbackStateProvider);
  return state.whenData((s) => s.playing);
});

// 播放器实际音频时长（从 just_audio 获取）
final audioDurationProvider = StreamProvider<Duration?>((ref) {
  if (audioHandler is LxAudioHandler) {
    return (audioHandler as LxAudioHandler).player.durationStream;
  }
  return Stream.value(null);
});

// 当前歌曲时长：优先使用播放器实际时长，回退到元数据时长
final durationProvider = Provider<AsyncValue<Duration>>((ref) {
  final audioDuration = ref.watch(audioDurationProvider).value;
  if (audioDuration != null && audioDuration > Duration.zero) {
    return AsyncValue.data(audioDuration);
  }
  final music = ref.watch(currentMusicProvider);
  return AsyncValue.data(music?.duration ?? Duration.zero);
});

// 播放模式枚举
enum PlayMode {
  repeatOne, // 单曲循环
  sequential, // 顺序播放
  shuffle, // 随机播放
}

PlayMode playModeFromPlaybackState(PlaybackState state) {
  if (state.shuffleMode == AudioServiceShuffleMode.all) {
    return PlayMode.shuffle;
  }
  if (state.repeatMode == AudioServiceRepeatMode.one) {
    return PlayMode.repeatOne;
  }
  return PlayMode.sequential;
}

// 播放模式只读 handler 已发布的 repeat/shuffle 状态。
final playModeProvider = Provider<PlayMode>((ref) {
  final state = ref.watch(playbackStateProvider).value;
  return state == null ? PlayMode.sequential : playModeFromPlaybackState(state);
});

/// 播放位置唯一真相：just_audio position + seek 不连续事件。
/// 进度条 / 时间 / 歌词全部只读这里，禁止各自维护另一套时钟。
class PositionNotifier extends StateNotifier<Duration>
    implements ScrubPosition {
  final AudioPlayer? _player;
  Timer? _timer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PositionDiscontinuity>? _discSub;
  bool _frozen = false;

  PositionNotifier(this._player) : super(Duration.zero) {
    final player = _player;
    if (player == null) return;
    update(player.position);

    // 官方 positionStream（内部 createPositionStream），seek 后会跟 updatePosition
    _posSub = player.positionStream.listen((p) {
      if (_frozen) return;
      if ((p - state).inMilliseconds.abs() >= 16) update(p);
    });

    // seek 不连续：立刻跳到目标，歌词/进度同步
    _discSub = player.positionDiscontinuityStream.listen((d) {
      if (_frozen) return;
      final p = player.position;
      update(p);
    });

    // 兜底轮询（部分 iOS 场景 stream 间隙）
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_frozen) return;
      final p = player.position;
      if ((p - state).inMilliseconds.abs() >= 30) update(p);
    });
  }

  Duration get position => state;

  void update(Duration next) {
    if (next == state) return;
    state = next;
  }

  @override
  void freeze() {
    _frozen = true;
  }

  @override
  void unfreeze(Duration position) {
    update(position);
    _frozen = false;
  }

  void jumpTo(Duration position) {
    if (_frozen) return;
    update(position);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _posSub?.cancel();
    _discSub?.cancel();
    super.dispose();
  }
}

// 监听当前歌曲变化，保存可恢复的播放会话（歌单/队列 + 歌曲，不含进度）
final playbackSessionRecorderProvider = Provider<void>((ref) {
  final music = ref.watch(currentMusicProvider);
  if (music == null) return;
  final playerService = ref.read(playerServiceProvider);
  final store = ref.read(playbackSessionStoreProvider);
  final mediaItem = audioHandler.mediaItem.value;
  final lazyIndex = mediaItem?.extras?['_lazyPlaylistIndex'];
  final playlistId = playerService.currentLazyPlaylistId;
  final currentIndex = lazyIndex is int
      ? lazyIndex
      : playerService.currentIndex >= 0
          ? playerService.currentIndex
          : 0;
  final fullQueue = <MusicItem>[];
  if (playlistId == null) {
    for (final item in playerService.queue) {
      final extras = item.extras;
      if (extras == null) continue;
      fullQueue.add(MusicItem.fromJson(extras));
    }
  }
  final queue = <MusicItem>[];
  var startIndex = currentIndex;
  if (fullQueue.length > 300) {
    final windowStart = (currentIndex - 150).clamp(0, fullQueue.length - 300).toInt();
    queue.addAll(fullQueue.sublist(windowStart, windowStart + 300));
    startIndex = currentIndex - windowStart;
  } else {
    queue.addAll(fullQueue);
  }
  final session = PlaybackSession(
    playlistId: playlistId,
    startIndex: startIndex,
    song: music,
    queue: List.unmodifiable(queue),
  );
  unawaited(store.save(session));
});

/// 启动时恢复上次播放会话：默认只加载队列并暂停，autoplay 由设置控制。
Future<void> restorePlaybackSession({
  required ProviderContainer container,
  required bool autoplay,
}) async {
  final store = container.read(playbackSessionStoreProvider);
  final session = await store.load();
  if (session == null) return;
  final playerService = container.read(playerServiceProvider);
  final playlistService = container.read(playlistServiceProvider);
  try {
    final playlistId = session.playlistId;
    if (playlistId != null) {
      final songCount =
          playlistService.getPlaylist(playlistId)?.songCount ?? 0;
      if (songCount <= 0) {
        await store.clear();
        return;
      }
      final startIndex = session.startIndex.clamp(0, songCount - 1).toInt();
      await playerService.playPagedPlaylist(
        songCount: songCount,
        startIndex: startIndex,
        playlistId: playlistId,
        autoplay: autoplay,
        loadPage: (offset, limit) async {
          final page = await playlistService.getSongsPage(
            playlistId,
            offset: offset,
            limit: limit,
          );
          return page.songs;
        },
      );
      return;
    }
    final queue = session.queue;
    if (queue.isEmpty) {
      await playerService.playPlaylist(
        [session.song],
        index: 0,
        autoplay: autoplay,
      );
    } else {
      final startIndex = session.startIndex.clamp(0, queue.length - 1).toInt();
      await playerService.playPlaylist(
        queue,
        index: startIndex,
        autoplay: autoplay,
      );
    }
  } catch (_) {
    await store.clear();
  }
}

// 监听当前歌曲变化，自动记录到最近播放
final recentPlayRecorderProvider = Provider<void>((ref) {
  final music = ref.watch(currentMusicProvider);
  if (music != null) {
    final playlistService = ref.read(playlistServiceProvider);
    unawaited(playlistService.addToRecent(music));
  }
});

// 定时停止播放
sealed class SleepTimerState {
  const SleepTimerState();

  DateTime? get endTime => null;
}

final class SleepTimerIdle extends SleepTimerState {
  const SleepTimerIdle();
}

final class SleepTimerRunning extends SleepTimerState {
  const SleepTimerRunning(this.duration, this.scheduledEndTime);

  final Duration duration;
  final DateTime scheduledEndTime;

  @override
  DateTime get endTime => scheduledEndTime;
}

enum SleepTimerFailureReason { pauseFailed }

final class SleepTimerFailed extends SleepTimerState {
  const SleepTimerFailed(this.reason, this.duration);

  final SleepTimerFailureReason reason;
  final Duration duration;
}

class SleepTimerNotifier extends StateNotifier<SleepTimerState> {
  SleepTimerNotifier(this._pause) : super(const SleepTimerIdle());

  final Future<void> Function() _pause;
  Timer? _timer;
  int _generation = 0;

  void startTimer(Duration duration) {
    _timer?.cancel();
    final generation = ++_generation;
    state = SleepTimerRunning(duration, DateTime.now().add(duration));

    _timer = Timer(duration, () async {
      try {
        await _pause();
        if (!mounted || generation != _generation) return;
        _timer = null;
        state = const SleepTimerIdle();
      } catch (_) {
        if (!mounted || generation != _generation) return;
        _timer = null;
        state = SleepTimerFailed(
          SleepTimerFailureReason.pauseFailed,
          duration,
        );
      }
    });
  }

  void retryTimer() {
    if (state case SleepTimerFailed(:final duration)) {
      startTimer(duration);
    }
  }

  void cancelTimer() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    state = const SleepTimerIdle();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

final sleepTimerProvider =
    StateNotifierProvider<SleepTimerNotifier, SleepTimerState>((ref) {
  return SleepTimerNotifier(audioHandler.pause);
});

final sleepTimerEndProvider = Provider<DateTime?>((ref) {
  return ref.watch(sleepTimerProvider).endTime;
});

// 全局播放消息通知（用于展示顶部通知）
final playerMessageProvider = StateProvider<String?>((ref) => null);

abstract interface class ScrubPlayback {
  bool get playing;
  Duration get position;
  int get sourceGeneration;
  int get userIntentGeneration;
  int get interruptionGeneration;
  int get playbackStartBlockGeneration;

  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  });
  Future<Duration?> seekConfirmed(Duration position);
  Future<void> releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    required int interruptionGeneration,
    required int startBlockGeneration,
  });
}

abstract interface class ScrubPosition {
  void freeze();
  void unfreeze(Duration position);
}

class ScrubCoordinator {
  final ScrubPlayback _playback;
  final ScrubPosition _position;
  int _generation = 0;
  final Map<int, _ScrubTransaction> _transactions = {};

  ScrubCoordinator(this._playback, this._position);

  Future<int> begin() async {
    final previousTransactions = _transactions.values.toList();
    final generation = ++_generation;
    final sourceGeneration = _playback.sourceGeneration;
    final userIntentGeneration = _playback.userIntentGeneration;
    final interruptionGeneration = _playback.interruptionGeneration;
    final startBlockGeneration = _playback.playbackStartBlockGeneration;
    _position.freeze();

    final shouldPause = _playback.playing ||
        previousTransactions.any(
          (transaction) =>
              transaction.pauseRequested && transaction.owns(_playback),
        );
    final pauseFuture = shouldPause
        ? _playback.pauseForScrub(
            sourceGeneration: sourceGeneration,
            userIntentGeneration: userIntentGeneration,
            stillOwnsScrub: () => generation == _generation,
          )
        : Future<PreservingPauseOwner?>.value();
    _transactions[generation] = _ScrubTransaction(
      generation: generation,
      sourceGeneration: sourceGeneration,
      userIntentGeneration: userIntentGeneration,
      interruptionGeneration: interruptionGeneration,
      startBlockGeneration: startBlockGeneration,
      pauseFuture: pauseFuture,
      pauseRequested: shouldPause,
    );
    for (final transaction in previousTransactions) {
      unawaited(
        _releaseTransaction(transaction, resumeAfter: true)
            .catchError((Object _, StackTrace __) {}),
      );
    }
    try {
      await pauseFuture;
    } catch (_) {
      if (generation == _generation) {
        _position.unfreeze(_playback.position);
      }
      _transactions.remove(generation);
      rethrow;
    }
    return generation;
  }

  Future<void> finish(
    int generation,
    Duration position, {
    required bool resumeAfter,
  }) async {
    final transaction = _transactions[generation];
    if (transaction == null) return;
    if (generation != _generation) {
      await _releaseTransaction(transaction, resumeAfter: true);
      return;
    }
    Duration? confirmed;
    try {
      await transaction.pauseFuture;
      if (generation != _generation) return;
      if (!transaction.owns(_playback)) return;
      confirmed = await _playback.seekConfirmed(position);
      if (generation != _generation) return;
    } finally {
      await _releaseTransaction(
        transaction,
        resumeAfter:
            confirmed != null && resumeAfter && transaction.owns(_playback),
      );
      if (generation == _generation) {
        final actual =
            transaction.sourceGeneration == _playback.sourceGeneration
                ? confirmed ?? _playback.position
                : _playback.position;
        _position.unfreeze(actual);
      }
    }
  }

  Future<void> cancel(int generation) async {
    final transaction = _transactions[generation];
    if (transaction == null) return;
    final ownsCurrent = generation == _generation;
    if (ownsCurrent) _generation++;
    await _releaseTransaction(transaction, resumeAfter: true);
    if (ownsCurrent && _generation == generation + 1) {
      _position.unfreeze(_playback.position);
    }
  }

  Future<void> cancelAll() async {
    final transactions = _transactions.values.toList(growable: false);
    if (transactions.isEmpty) return;
    final cancelledGeneration = _generation;
    _generation++;
    await Future.wait(
      transactions.map(
        (transaction) => _releaseTransaction(transaction, resumeAfter: true),
      ),
    );
    if (_generation == cancelledGeneration + 1) {
      _position.unfreeze(_playback.position);
    }
  }

  Future<void> _releaseTransaction(
    _ScrubTransaction transaction, {
    required bool resumeAfter,
  }) {
    return transaction.releaseFuture ??= () async {
      try {
        final owner = await transaction.pauseFuture;
        await _playback.releaseAfterScrub(
          owner,
          resumeAfter: resumeAfter,
          sourceGeneration: transaction.sourceGeneration,
          userIntentGeneration: transaction.userIntentGeneration,
          interruptionGeneration: transaction.interruptionGeneration,
          startBlockGeneration: transaction.startBlockGeneration,
        );
      } finally {
        if (identical(_transactions[transaction.generation], transaction)) {
          _transactions.remove(transaction.generation);
        }
      }
    }();
  }
}

class _ScrubTransaction {
  final int generation;
  final int sourceGeneration;
  final int userIntentGeneration;
  final int interruptionGeneration;
  final int startBlockGeneration;
  final Future<PreservingPauseOwner?> pauseFuture;
  final bool pauseRequested;
  Future<void>? releaseFuture;

  _ScrubTransaction({
    required this.generation,
    required this.sourceGeneration,
    required this.userIntentGeneration,
    required this.interruptionGeneration,
    required this.startBlockGeneration,
    required this.pauseFuture,
    required this.pauseRequested,
  });

  bool owns(ScrubPlayback playback) =>
      sourceGeneration == playback.sourceGeneration &&
      userIntentGeneration == playback.userIntentGeneration;
}

class _HandlerScrubPlayback implements ScrubPlayback {
  final LxAudioHandler? _handler;
  final PlayerService _fallback;
  final PositionNotifier _position;

  _HandlerScrubPlayback(this._handler, this._fallback, this._position);

  @override
  bool get playing => _handler?.player.playing ?? false;

  @override
  Duration get position => _handler?.player.position ?? _position.position;

  @override
  int get sourceGeneration => _handler?.sourceGeneration ?? 0;

  @override
  int get userIntentGeneration => _handler?.userIntentGeneration ?? 0;

  @override
  int get interruptionGeneration => _handler?.interruptionGeneration ?? 0;

  @override
  int get playbackStartBlockGeneration =>
      _handler?.playbackStartBlockGeneration ?? 0;

  @override
  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) =>
      _handler?.pauseForScrub(
        sourceGeneration: sourceGeneration,
        userIntentGeneration: userIntentGeneration,
        stillOwnsScrub: stillOwnsScrub,
      ) ??
      Future<PreservingPauseOwner?>.value();

  @override
  Future<Duration?> seekConfirmed(Duration position) async {
    final handler = _handler;
    if (handler != null) return handler.seekConfirmed(position);
    await _fallback.seek(position);
    return null;
  }

  @override
  Future<void> releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    required int interruptionGeneration,
    required int startBlockGeneration,
  }) =>
      _handler?.releaseAfterScrub(
        owner,
        resumeAfter: resumeAfter,
        sourceGeneration: sourceGeneration,
        userIntentGeneration: userIntentGeneration,
        interruptionGeneration: interruptionGeneration,
        startBlockGeneration: startBlockGeneration,
      ) ??
      Future<void>.value();
}

final scrubCoordinatorProvider = Provider<ScrubCoordinator>((ref) {
  final observe = FireAndForgetObserver();
  final position = ref.read(playerPositionProvider.notifier);
  final handler =
      audioHandler is LxAudioHandler ? audioHandler as LxAudioHandler : null;
  final coordinator = ScrubCoordinator(
    _HandlerScrubPlayback(
      handler,
      ref.read(playerServiceProvider),
      position,
    ),
    position,
  );
  ref.onDispose(() => observe(coordinator.cancelAll()));
  return coordinator;
});

final beginScrubProvider = Provider<Future<int> Function()>((ref) {
  return ref.read(scrubCoordinatorProvider).begin;
});

final finishScrubProvider =
    Provider<Future<void> Function(int, Duration, {required bool resumeAfter})>(
        (ref) {
  return ref.read(scrubCoordinatorProvider).finish;
});

final cancelScrubProvider = Provider<Future<void> Function(int)>((ref) {
  return ref.read(scrubCoordinatorProvider).cancel;
});

/// 点击歌词行：使用同一 seek 事务，避免另一套时钟。
final seekProvider = Provider<Future<void> Function(Duration)>((ref) {
  return (Duration position) async {
    final h =
        audioHandler is LxAudioHandler ? audioHandler as LxAudioHandler : null;
    final wasPlaying = h?.player.playing ?? false;
    final generation = await ref.read(beginScrubProvider)();
    await ref.read(finishScrubProvider)(
      generation,
      position,
      resumeAfter: wasPlaying,
    );
  };
});
