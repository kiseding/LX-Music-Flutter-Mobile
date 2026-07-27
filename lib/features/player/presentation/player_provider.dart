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

  PositionNotifier(this._player) : super(Duration.zero) {
    final player = _player;
    if (player == null) return;
    state = player.position;

    // 官方 positionStream（内部 createPositionStream），seek 后会跟 updatePosition
    _posSub = player.positionStream.listen((p) {
      if ((p - state).inMilliseconds.abs() >= 16) state = p;
    });

    // seek 不连续：立刻跳到目标，歌词/进度同步
    _discSub = player.positionDiscontinuityStream.listen((d) {
      final p = player.position;
      state = p;
    });

    // 兜底轮询（部分 iOS 场景 stream 间隙）
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      final p = player.position;
      if ((p - state).inMilliseconds.abs() >= 30) state = p;
    });
  }

  void jumpTo(Duration position) {
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

/// 统一 seek：先乐观更新 UI/歌词位置，再等引擎 seek 完成，最后以引擎真实 position 为准。
final seekProvider = Provider<Future<void> Function(Duration)>((ref) {
  return (Duration position) async {
    final posNotifier = ref.read(playerPositionProvider.notifier);
    // 1) 乐观：进度条+歌词立刻对齐用户手指
    posNotifier.jumpTo(position);
    // 2) 引擎 seek（loading 时会等待，避免空操作）
    await ref.read(playerServiceProvider).seek(position);
    // 3) 以引擎为准校正（成功时 ≈ position；失败/忽略时回到真实播放点）
    if (audioHandler is LxAudioHandler) {
      posNotifier.jumpTo((audioHandler as LxAudioHandler).player.position);
    }
  };
});
