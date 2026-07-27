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

/// 播放位置：positionStream 即时更新 + 短周期轮询兜底。
/// seek 期间锁定目标，忽略滞后的旧 position，避免面板跑在真实音频前面。
class PositionNotifier extends StateNotifier<Duration> {
  final AudioPlayer? _player;
  Timer? _timer;
  StreamSubscription<Duration>? _posSub;
  Duration? _seekLockTarget;
  DateTime? _seekLockUntil;

  PositionNotifier(this._player) : super(Duration.zero) {
    final player = _player;
    if (player == null) return;
    state = player.position;
    _posSub = player
        .createPositionStream(
          steps: 1,
          minPeriod: const Duration(milliseconds: 50),
          maxPeriod: const Duration(milliseconds: 200),
        )
        .listen(_onPlayerPosition);
    // 兜底：部分平台 seek 后 stream 瞬时不推
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _onPlayerPosition(player.position);
    });
  }

  bool get _seekLocked {
    final until = _seekLockUntil;
    if (until == null || _seekLockTarget == null) return false;
    if (DateTime.now().isAfter(until)) {
      _seekLockTarget = null;
      _seekLockUntil = null;
      return false;
    }
    return true;
  }

  void _onPlayerPosition(Duration p) {
    if (_seekLocked) {
      final target = _seekLockTarget!;
      final delta = (p - target).inMilliseconds.abs();
      if (delta <= 400) {
        // 已收敛到真实 seek 位置
        _seekLockTarget = null;
        _seekLockUntil = null;
        state = p;
      }
      // 未收敛：保持显示 lock 目标，不吃旧 position
      return;
    }
    if ((p - state).inMilliseconds.abs() >= 20) {
      state = p;
    }
  }

  void jumpTo(Duration position) {
    state = position;
  }

  /// seek 开始：面板钉在 target，直到播放器 position 跟上或超时。
  void beginSeek(Duration target) {
    _seekLockTarget = target;
    _seekLockUntil = DateTime.now().add(const Duration(seconds: 2));
    state = target;
  }

  void endSeek(Duration confirmed) {
    _seekLockTarget = null;
    _seekLockUntil = null;
    state = confirmed;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _posSub?.cancel();
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

/// 统一 seek：锁定 UI 到目标 → 播放器 seek → 用真实 position 解锁。
final seekProvider = Provider<Future<void> Function(Duration)>((ref) {
  return (Duration position) async {
    final posNotifier = ref.read(playerPositionProvider.notifier);
    posNotifier.beginSeek(position);
    try {
      await ref.read(playerServiceProvider).seek(position);
    } finally {
      if (audioHandler is LxAudioHandler) {
        final real = (audioHandler as LxAudioHandler).player.position;
        // 若引擎仍严重滞后，保持 lock 目标，由 PositionNotifier 继续等收敛
        if ((real - position).inMilliseconds.abs() <= 500) {
          posNotifier.endSeek(real);
        } else {
          posNotifier.beginSeek(position);
        }
      } else {
        posNotifier.endSeek(position);
      }
    }
  };
});
