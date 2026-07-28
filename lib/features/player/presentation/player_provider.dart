import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/audio/audio_handler.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../domain/music_item.dart';
import '../domain/player_service.dart';

final playerServiceProvider = Provider<PlayerService>((ref) {
  return PlayerService();
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

// 播放模式切换 (RepeatOne, Sequential, Shuffle)
final playModeProvider = StateProvider<PlayMode>((ref) {
  return PlayMode.sequential;
});

/// 播放位置唯一真相：just_audio position + seek 不连续事件。
/// 进度条 / 时间 / 歌词全部只读这里，禁止各自维护另一套时钟。
class PositionNotifier extends StateNotifier<Duration> {
  final AudioPlayer? _player;
  Timer? _timer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<PositionDiscontinuity>? _discSub;
  bool _frozen = false;

  PositionNotifier(this._player) : super(Duration.zero) {
    final player = _player;
    if (player == null) return;
    state = player.position;

    // 官方 positionStream（内部 createPositionStream），seek 后会跟 updatePosition
    _posSub = player.positionStream.listen((p) {
      if (_frozen) return;
      if ((p - state).inMilliseconds.abs() >= 16) state = p;
    });

    // seek 不连续：立刻跳到目标，歌词/进度同步
    _discSub = player.positionDiscontinuityStream.listen((d) {
      if (_frozen) return;
      final p = player.position;
      state = p;
    });

    // 兜底轮询（部分 iOS 场景 stream 间隙）
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (_frozen) return;
      final p = player.position;
      if ((p - state).inMilliseconds.abs() >= 30) state = p;
    });
  }

  void freeze() {
    _frozen = true;
  }

  void unfreeze(Duration position) {
    state = position;
    _frozen = false;
  }

  void jumpTo(Duration position) {
    if (_frozen) return;
    state = position;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _posSub?.cancel();
    _discSub?.cancel();
    super.dispose();
  }
}

// 监听当前歌曲变化，自动记录到最近播放
final recentPlayRecorderProvider = Provider<void>((ref) {
  final music = ref.watch(currentMusicProvider);
  if (music != null) {
    final playlistService = ref.read(playlistServiceProvider);
    playlistService.addToRecent(music);
  }
});

// 定时停止播放
class SleepTimerNotifier extends StateNotifier<Duration?> {
  Timer? _timer;
  DateTime? _endTime;

  SleepTimerNotifier() : super(null);

  DateTime? get endTime => _endTime;

  void startTimer(Duration duration) {
    _timer?.cancel();
    _endTime = DateTime.now().add(duration);
    state = duration;

    _timer = Timer(duration, () {
      // 停止播放
      audioHandler.pause();
      state = null;
      _endTime = null;
    });
  }

  void cancelTimer() {
    _timer?.cancel();
    _timer = null;
    state = null;
    _endTime = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final sleepTimerProvider =
    StateNotifierProvider<SleepTimerNotifier, Duration?>((ref) {
  return SleepTimerNotifier();
});

final sleepTimerEndProvider = Provider<DateTime?>((ref) {
  ref.watch(sleepTimerProvider);
  return ref.read(sleepTimerProvider.notifier).endTime;
});

// 全局播放消息通知（用于展示 SnackBar）
final playerMessageProvider = StateProvider<String?>((ref) => null);

class ScrubCoordinator {
  final Ref _ref;
  int _generation = 0;
  Future<void> _pauseFuture = Future<void>.value();

  ScrubCoordinator(this._ref);

  Future<int> begin() async {
    final generation = ++_generation;
    _ref.read(playerPositionProvider.notifier).freeze();

    final h =
        audioHandler is LxAudioHandler ? audioHandler as LxAudioHandler : null;
    _pauseFuture = h != null && h.player.playing
        ? h.pauseInternal(clearIntent: false)
        : Future<void>.value();
    await _pauseFuture;
    return generation;
  }

  Future<void> finish(
    int generation,
    Duration position, {
    required bool resumeAfter,
  }) async {
    if (generation != _generation) return;
    await _pauseFuture;
    if (generation != _generation) return;

    // 屏幕显示时间是权威：先钉在目标，再把引擎往屏幕拉（只 seek 一次）
    final posNotifier = _ref.read(playerPositionProvider.notifier);
    posNotifier.unfreeze(position);
    posNotifier.freeze();

    final h =
        audioHandler is LxAudioHandler ? audioHandler as LxAudioHandler : null;
    if (h != null) {
      final quality = h.mediaItem.value?.extras?['actualQuality']?.toString() ??
          h.mediaItem.value?.extras?['requestedQuality']?.toString() ??
          h.preferredQuality;
      await h.seekToDisplay(
        position,
        budget: seekBudgetForQuality(quality),
      );
    } else {
      await _ref.read(playerServiceProvider).seek(position);
    }
    if (generation != _generation) return;

    // FLAC：起播后再 seek 会打断解码，声音落后 UI；只 play 一次。
    if (resumeAfter && h != null) {
      await h.play();
    }

    if (generation != _generation) return;
    // 最终仍以屏幕目标为准，避免引擎回写把 UI 拉回去
    posNotifier.unfreeze(position);
  }
}

final scrubCoordinatorProvider = Provider<ScrubCoordinator>((ref) {
  return ScrubCoordinator(ref);
});

final beginScrubProvider = Provider<Future<int> Function()>((ref) {
  return ref.read(scrubCoordinatorProvider).begin;
});

final finishScrubProvider =
    Provider<Future<void> Function(int, Duration, {required bool resumeAfter})>(
        (ref) {
  return ref.read(scrubCoordinatorProvider).finish;
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
