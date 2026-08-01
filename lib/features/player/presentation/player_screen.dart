import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/pagination/page_range.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/app_notification.dart';
import '../../../core/widgets/artwork_image.dart';
import '../../../core/widgets/page_navigation_bar.dart';
import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/play_pulse_button.dart';
import '../../../core/network/play_url_result.dart';
import '../domain/music_item.dart';
import '../domain/player_service.dart';
import 'player_provider.dart';
import 'scrub_session.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../playlist/presentation/playlist_picker.dart';
import '../../download/presentation/download_provider.dart';
import '../../lyric/presentation/lyric_view.dart';
import '../../lyric/presentation/lyric_provider.dart';

String _formatPlayerDuration(Duration d) {
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class _CurrentLyricLine extends ConsumerWidget {
  const _CurrentLyricLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(currentLyricProvider);
    final currentLineIndex = ref.watch(currentLineIndexProvider);

    String text = ' ';
    String? translation;
    var hasLine = false;
    if (lyrics.isNotEmpty &&
        currentLineIndex >= 0 &&
        currentLineIndex < lyrics.lines.length) {
      final line = lyrics.lines[currentLineIndex];
      text = line.text.isEmpty ? ' ' : line.text;
      translation = line.translation;
      hasLine = true;
    }

    return SizedBox(
      height: 44,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: hasLine
                    ? AppColors.accentOf(context)
                    : AppColors.mutedText(context).withValues(alpha: 0.01),
                fontSize: 14,
                fontWeight: FontWeight.w500,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              translation ?? ' ',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: translation != null
                    ? AppColors.mutedText(context)
                    : AppColors.mutedText(context).withValues(alpha: 0.01),
                fontSize: 11,
                height: 1.2,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _PlayerProgress extends ConsumerWidget {
  final Duration duration;
  final bool seeking;
  final double seekValue;
  final void Function(double value) onDragStart;
  final void Function(double value) onDragUpdate;
  final Future<void> Function(Duration target) onSeekEnd;
  final VoidCallback onSeekCancel;
  final Future<void> Function(double value, Duration target) onTapSeek;

  const _PlayerProgress({
    required this.duration,
    required this.seeking,
    required this.seekValue,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onSeekEnd,
    required this.onSeekCancel,
    required this.onTapSeek,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerPositionProvider);
    final totalMs =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
    final effectivePos = seeking
        ? Duration(milliseconds: (seekValue * totalMs).round())
        : position;
    final ratio = (effectivePos.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final displayPos = effectivePos;

    Duration adjusted(Duration position, int deltaSeconds) {
      final milliseconds = (position.inMilliseconds + deltaSeconds * 1000)
          .clamp(0, duration.inMilliseconds);
      return Duration(milliseconds: milliseconds);
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              _formatPlayerDuration(displayPos),
              style: TextStyle(
                  color: AppColors.mutedText(context),
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
          const SizedBox(width: 5),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final interactiveTrack = GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) {
                    onDragStart((d.localPosition.dx / width).clamp(0.0, 1.0));
                  },
                  onHorizontalDragUpdate: (d) {
                    onDragUpdate((d.localPosition.dx / width).clamp(0.0, 1.0));
                  },
                  onHorizontalDragEnd: (_) {
                    final target =
                        Duration(milliseconds: (seekValue * totalMs).round());
                    onSeekEnd(target);
                  },
                  onHorizontalDragCancel: onSeekCancel,
                  onTapUp: (d) {
                    final v = (d.localPosition.dx / width).clamp(0.0, 1.0);
                    final target =
                        Duration(milliseconds: (v * totalMs).round());
                    onTapSeek(v, target);
                  },
                  child: SizedBox(
                    height: 28,
                    child: Center(
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            height: 10,
                            decoration: BoxDecoration(
                              color: AppColors.cardBorder(context),
                              borderRadius: BorderRadius.circular(5),
                            ),
                          ),
                          FractionallySizedBox(
                            widthFactor: ratio,
                            child: Container(
                              height: 10,
                              decoration: BoxDecoration(
                                color: AppColors.accentOf(context),
                                borderRadius: BorderRadius.circular(5),
                              ),
                            ),
                          ),
                          Positioned(
                            left: (width * ratio - 9).clamp(0.0, width - 18),
                            top: -4,
                            child: Container(
                              width: 18,
                              height: 18,
                              decoration: BoxDecoration(
                                color: AppColors.accentOf(context),
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.accentOf(context)
                                        .withAlpha(120),
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                return Semantics(
                  label: '播放进度',
                  slider: true,
                  enabled: duration > Duration.zero,
                  value:
                      '${_formatPlayerDuration(displayPos)} / ${_formatPlayerDuration(duration)}',
                  increasedValue:
                      _formatPlayerDuration(adjusted(displayPos, 10)),
                  decreasedValue:
                      _formatPlayerDuration(adjusted(displayPos, -10)),
                  onIncrease: duration > Duration.zero
                      ? () => ref.read(seekProvider)(adjusted(displayPos, 10))
                      : null,
                  onDecrease: duration > Duration.zero
                      ? () => ref.read(seekProvider)(adjusted(displayPos, -10))
                      : null,
                  child: ExcludeSemantics(child: interactiveTrack),
                );
              },
            ),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 36,
            child: Text(
              _formatPlayerDuration(duration),
              textAlign: TextAlign.right,
              style: TextStyle(
                  color: AppColors.mutedText(context),
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
  }
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  late bool _seeking;
  double _seekValue = 0; // 0..1 only while finger is down
  bool _wasPlayingBeforeSeek = false;
  late final ScrubSession _scrubSession;
  ScrubOperation? _dragOperation;
  double _dragOffset = 0;
  bool _draggingDown = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _scrubSession = ScrubSession(
      begin: ref.read(beginScrubProvider),
      finish: ref.read(finishScrubProvider),
      cancel: ref.read(cancelScrubProvider),
    );
    _seeking = false;
  }

  void _cancelActiveScrub() {
    final operation = _dragOperation;
    _dragOperation = null;
    final cancelledCurrent =
        operation != null ? _scrubSession.cancel(operation) : false;
    if (cancelledCurrent) _seeking = false;
  }

  @override
  void dispose() {
    _dragOperation = null;
    _scrubSession.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);
    final currentMusic = ref.watch(currentMusicProvider);
    final playbackState = ref.watch(playbackStateProvider).value;
    final playMode = ref.watch(playModeProvider);

    if (currentMusic == null) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.music_note,
                  size: 64, color: AppColors.mutedText(context)),
              SizedBox(height: 16),
              Text('暂无播放内容',
                  style: TextStyle(color: AppColors.mutedText(context))),
            ],
          ),
        ),
      );
    }

    final isPlaying = playbackState?.playing ?? false;
    final duration = ref.watch(durationProvider).value ?? currentMusic.duration;
    final isFavorite =
        ref.watch(isSongFavoriteProvider(currentMusic.id)).valueOrNull ?? false;

    final screenH = MediaQuery.of(context).size.height;
    final dismissThreshold = screenH * 0.4; // 超过 2/5 关闭
    // 下拉时露出下层路由（打开前的界面）
    final revealT = (_dragOffset / (screenH * 0.45)).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 轻遮罩：下拉时淡出，透出上一页
          IgnorePointer(
            child: ColoredBox(
              color: Colors.black.withValues(alpha: 0.28 * (1 - revealT)),
            ),
          ),
          AnimatedContainer(
            duration: _draggingDown
                ? Duration.zero
                : const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            transform: Matrix4.translationValues(0, _dragOffset, 0),
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              elevation: 8,
              shadowColor: Colors.black54,
              child: SafeArea(
                child: GestureDetector(
                  onVerticalDragStart: (_) {
                    setState(() {
                      _draggingDown = true;
                      _dragOffset = 0;
                    });
                  },
                  onVerticalDragUpdate: (d) {
                    if (d.delta.dy > 0 || _dragOffset > 0) {
                      setState(() {
                        _dragOffset =
                            (_dragOffset + d.delta.dy).clamp(0.0, screenH);
                      });
                    }
                  },
                  onVerticalDragEnd: (d) {
                    final shouldClose = _dragOffset > dismissThreshold ||
                        (d.primaryVelocity ?? 0) > 900;
                    if (shouldClose) {
                      Navigator.of(context).maybePop();
                    } else {
                      setState(() {
                        _draggingDown = false;
                        _dragOffset = 0;
                      });
                    }
                  },
                  child: Column(
                    children: [
                      _buildAppBar(context, currentMusic),
                      Expanded(
                        child: PageView(
                          controller: _pageController,
                          onPageChanged: (index) =>
                              setState(() => _currentPage = index),
                          children: [
                            Column(
                              children: [
                                const SizedBox(height: 12),
                                Expanded(
                                  child: _buildArtwork(
                                    currentMusic.artwork,
                                    songId: currentMusic.id,
                                  ),
                                ),
                                _buildSongInfo(currentMusic, isFavorite),
                                const _CurrentLyricLine(),
                                _PlayerProgress(
                                  duration: duration,
                                  seeking: _seeking,
                                  seekValue: _seekValue,
                                  onDragStart: _beginSeek,
                                  onDragUpdate: _updateSeek,
                                  onSeekEnd: _finishSeek,
                                  onSeekCancel: _cancelSeek,
                                  onTapSeek: _tapSeek,
                                ),
                                _buildControls(
                                    playerService, isPlaying, playMode),
                                _buildSourceQualityBar(currentMusic),
                                const SizedBox(height: 12),
                              ],
                            ),
                            Column(
                              children: [
                                const Expanded(
                                    child: LyricView(isFullScreen: true)),
                                _buildLyricMiniBar(
                                    currentMusic, playerService, isPlaying),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceQualityBar(MusicItem music) {
    final media = ref.watch(currentMediaItemProvider).value;
    final extras = media?.extras ?? music.toJson();
    final platform = (extras['platform'] ?? music.platform).toString();
    // 只展示实际播放音质，不用 requestedQuality 冒充
    final actualRaw = extras['actualQuality']?.toString();
    final remote = extras['remoteUrl']?.toString();
    final actual = (actualRaw != null && actualRaw.isNotEmpty)
        ? actualRaw
        : (remote != null && remote.isNotEmpty
            ? correctQualityFromUrl(
                remote,
                extras['requestedQuality']?.toString() ?? '320k',
              )
            : null);
    final qualityText = actual != null ? qualityLabel(actual) : '解析中…';
    // 纯透明底，整体下移 10px；点击收起全屏播放器
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Pressable(
        semanticLabel: '收起播放器',
        scale: 0.94,
        onTap: () => Navigator.pop(context),
        child: Text(
          '${platformLabel(platform)} · $qualityText',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppColors.mutedText(context),
            fontSize: 12,
            letterSpacing: 0.5,
            height: 1.5,
          ),
        ),
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, MusicItem music) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.fill(context),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: AppColors.cardBorder(context)),
            ),
            child: IconButton(
              tooltip: '收起播放器',
              padding: EdgeInsets.zero,
              onPressed: () => Navigator.pop(context),
              icon: Icon(Icons.keyboard_arrow_down,
                  color: AppColors.secondaryText(context), size: 20),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_currentPage == 0 ? '正在播放' : '歌词',
                  style: TextStyle(
                      color: AppColors.mutedText(context),
                      fontSize: 12,
                      letterSpacing: 2)),
              const SizedBox(height: 6),
              _buildPageIndicator(),
            ],
          ),
          IconButton(
            icon:
                Icon(Icons.more_vert, color: AppColors.secondaryText(context)),
            onPressed: () => _showMoreMenu(context, music),
          ),
        ],
      ),
    );
  }

  Widget _buildPageIndicator() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(2, (index) {
        return AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          margin: EdgeInsets.symmetric(horizontal: 4),
          width: _currentPage == index ? 12 : 6,
          height: 4,
          decoration: BoxDecoration(
            color: _currentPage == index
                ? AppColors.accentOf(context)
                : AppColors.mutedText(context).withAlpha(100),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }

  Widget _buildArtwork(String? artwork, {String? songId}) {
    // 与歌名行同宽：左右 32，对齐歌名左侧到心形右侧区域
    return LayoutBuilder(
      builder: (context, constraints) {
        final side = (constraints.maxWidth - 64).clamp(240.0, 420.0);
        final box = side.clamp(0.0, constraints.maxHeight - 8);
        return Center(
          child: Pressable(
            semanticLabel: '打开歌词',
            onTap: _openLyricsPage,
            child: Container(
              width: box,
              height: box,
              margin: const EdgeInsets.symmetric(horizontal: 32),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withAlpha(40),
                    blurRadius: 20,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 420),
                  reverseDuration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  layoutBuilder: (currentChild, previousChildren) {
                    return Stack(
                      fit: StackFit.expand,
                      alignment: Alignment.center,
                      children: <Widget>[
                        ...previousChildren,
                        if (currentChild != null) currentChild,
                      ],
                    );
                  },
                  transitionBuilder: (child, animation) {
                    final scale = Tween<double>(begin: 0.92, end: 1.0).animate(
                      CurvedAnimation(
                        parent: animation,
                        curve: Curves.easeOutCubic,
                      ),
                    );
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: scale, child: child),
                    );
                  },
                  child: KeyedSubtree(
                    key: ValueKey<String>(songId ?? artwork ?? 'empty'),
                    child: artwork != null && artwork.isNotEmpty
                        ? ArtworkImage(
                            artwork,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _defaultArtwork(),
                          )
                        : _defaultArtwork(),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _defaultArtwork() {
    return Container(
      color: AppColors.cardAlt(context),
      child:
          Icon(Icons.music_note, color: AppColors.mutedText(context), size: 80),
    );
  }

  Widget _buildSongInfo(MusicItem music, bool isFavorite) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: 24),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  music.name,
                  style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 22,
                      fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 6),
                Text(
                  music.singer,
                  style: TextStyle(
                      color: AppColors.secondaryText(context), fontSize: 15),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.download,
                color: AppColors.secondaryText(context), size: 24),
            onPressed: () {
              ref.read(downloadSongProvider)(music);
              showAppNotification(
                '已添加到下载队列',
                type: AppNotificationType.success,
                duration: const Duration(seconds: 1),
              );
            },
          ),
          IconButton(
            icon: Icon(
              isFavorite ? Icons.favorite : Icons.favorite_border,
              color: isFavorite
                  ? AppColors.error
                  : AppColors.secondaryText(context),
              size: 28,
            ),
            onPressed: () async {
              try {
                await ref.read(toggleFavoriteProvider)(music);
              } catch (error) {
                if (!mounted) return;
                showAppNotification(
                  '收藏失败: $error',
                  type: AppNotificationType.error,
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// 点击封面切换到全屏歌词页。
  void _openLyricsPage() {
    _pageController.animateToPage(
      1,
      duration: const Duration(milliseconds: 360),
      curve: Curves.easeOutCubic,
    );
  }

  /// 全屏歌词页底部简约栏：歌名/歌手两行 | 播放键（整体下移 10px）
  Widget _buildLyricMiniBar(
      MusicItem music, PlayerService playerService, bool isPlaying) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 20, 20), // 整体下移 10px
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    music.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      height: 1.2,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    music.singer,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.secondaryText(context),
                      fontSize: 15,
                      height: 1.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            PlayPulseButton(
              isPlaying: isPlaying,
              onPressed: playerService.togglePlay,
              size: 64,
              iconSize: 34,
            ),
          ],
        ),
      ),
    );
  }

  void _beginSeek(double value) {
    final playing = ref.read(playbackStateProvider).value?.playing ?? false;
    setState(() {
      _seeking = true;
      _wasPlayingBeforeSeek = playing;
      _seekValue = value;
    });
    _dragOperation = _scrubSession.begin();
  }

  void _updateSeek(double value) {
    setState(() => _seekValue = value);
  }

  Future<void> _finishSeek(Duration target) async {
    final operation = _dragOperation;
    if (operation == null) return;
    final mayClear = await _scrubSession.finish(
      operation,
      target,
      resumeAfter: _wasPlayingBeforeSeek,
    );
    if (mounted && mayClear) {
      if (identical(_dragOperation, operation)) {
        _dragOperation = null;
      }
      setState(() => _seeking = false);
    }
  }

  void _cancelSeek() {
    _cancelActiveScrub();
    if (mounted) setState(() {});
  }

  Future<void> _tapSeek(double value, Duration target) async {
    final playing = ref.read(playbackStateProvider).value?.playing ?? false;
    setState(() {
      _seekValue = value;
      _seeking = true;
      _wasPlayingBeforeSeek = playing;
    });
    final operation = _scrubSession.begin();
    final mayClear = await _scrubSession.finish(
      operation,
      target,
      resumeAfter: playing,
    );
    if (mounted && mayClear) {
      setState(() => _seeking = false);
    }
  }

  Widget _buildControls(
      PlayerService playerService, bool isPlaying, PlayMode playMode) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            tooltip: '播放模式',
            icon: Icon(
              _getPlayModeIcon(playMode),
              color: AppColors.mutedText(context),
              size: 22,
            ),
            onPressed: () {
              final nextMode = _getNextPlayMode(playMode);
              _applyPlayMode(playerService, nextMode);
            },
          ),
          Pressable(
            semanticLabel: '上一首',
            onTap: playerService.previous,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.skip_previous,
                  color: AppColors.onScaffold(context), size: 32),
            ),
          ),
          PlayPulseButton(
            isPlaying: isPlaying,
            onPressed: playerService.togglePlay,
            size: 64,
            iconSize: 34,
          ),
          Pressable(
            semanticLabel: '下一首',
            onTap: playerService.next,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.skip_next,
                  color: AppColors.onScaffold(context), size: 32),
            ),
          ),
          IconButton(
            tooltip: '播放队列',
            icon: Icon(Icons.queue_music,
                color: AppColors.mutedText(context), size: 22),
            onPressed: () => _showPlaylist(context),
          ),
        ],
      ),
    );
  }

  PlayMode _getNextPlayMode(PlayMode current) {
    switch (current) {
      case PlayMode.repeatOne:
        return PlayMode.sequential;
      case PlayMode.sequential:
        return PlayMode.shuffle;
      case PlayMode.shuffle:
        return PlayMode.repeatOne;
    }
  }

  IconData _getPlayModeIcon(PlayMode mode) {
    switch (mode) {
      case PlayMode.repeatOne:
        return Icons.repeat_one;
      case PlayMode.sequential:
        return Icons.trending_flat;
      case PlayMode.shuffle:
        return Icons.shuffle;
    }
  }

  void _applyPlayMode(PlayerService playerService, PlayMode mode) {
    switch (mode) {
      case PlayMode.repeatOne:
        playerService.setRepeatMode(AudioServiceRepeatMode.one);
        playerService.setShuffleMode(false);
        break;
      case PlayMode.sequential:
        playerService.setRepeatMode(AudioServiceRepeatMode.none);
        playerService.setShuffleMode(false);
        break;
      case PlayMode.shuffle:
        playerService.setRepeatMode(AudioServiceRepeatMode.none);
        playerService.setShuffleMode(true);
        break;
    }
  }

  void _showPlaylist(BuildContext context) {
    final playerService = ref.read(playerServiceProvider);
    final queue = playerService.queue;
    final currentIndex = playerService.currentIndex;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.dialogBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => _PlaybackQueueSheet(
        queue: queue,
        currentIndex: currentIndex,
        playerService: playerService,
        lazyPlaylistId: playerService.currentLazyPlaylistId,
      ),
    );
  }

  void _showMoreMenu(BuildContext context, MusicItem music) {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.dialogBg(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 32,
                height: 4,
                margin: EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                    color: AppColors.mutedText(context),
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                          color: AppColors.fill(context),
                          borderRadius: BorderRadius.circular(8)),
                      child: Icon(Icons.music_note,
                          color: AppColors.mutedText(context))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        Text(music.name,
                            style: TextStyle(
                                color: AppColors.onScaffold(context),
                                fontSize: 14,
                                fontWeight: FontWeight.w500),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                        Text(music.singer,
                            style: TextStyle(
                                color: AppColors.mutedText(context),
                                fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)
                      ])),
                ],
              ),
            ),
            Divider(color: AppColors.cardBorder(context), height: 1),
            ListTile(
                leading: Icon(Icons.favorite_border,
                    color: AppColors.onScaffold(context)),
                title: Text('收藏',
                    style: TextStyle(color: AppColors.onScaffold(context))),
                onTap: () async {
                  Navigator.pop(context);
                  try {
                    await ref.read(toggleFavoriteProvider)(music);
                  } catch (error) {
                    if (!mounted) return;
                    showAppNotification(
                      '收藏失败: $error',
                      type: AppNotificationType.error,
                    );
                  }
                }),
            ListTile(
                leading: Icon(Icons.playlist_add,
                    color: AppColors.onScaffold(context)),
                title: Text('添加到歌单',
                    style: TextStyle(color: AppColors.onScaffold(context))),
                onTap: () {
                  Navigator.pop(context);
                  showPlaylistPicker(context: context, ref: ref, song: music);
                }),
            ListTile(
                leading:
                    Icon(Icons.download, color: AppColors.onScaffold(context)),
                title: Text('下载',
                    style: TextStyle(color: AppColors.onScaffold(context))),
                onTap: () {
                  Navigator.pop(context);
                  ref.read(downloadSongProvider)(music);
                  showAppNotification(
                    '已添加到下载队列',
                    type: AppNotificationType.success,
                    duration: const Duration(seconds: 1),
                  );
                }),
          ],
        ),
      ),
    );
  }

}

class _PlaybackQueueSheet extends ConsumerStatefulWidget {
  const _PlaybackQueueSheet({
    required this.queue,
    required this.currentIndex,
    required this.playerService,
    this.lazyPlaylistId,
  });

  final List<MediaItem> queue;
  final int currentIndex;
  final PlayerService playerService;

  /// 惰性分页歌单 ID；非空时展示完整歌单的分页列表。
  final String? lazyPlaylistId;

  @override
  ConsumerState<_PlaybackQueueSheet> createState() => _PlaybackQueueSheetState();
}

class _PlaybackQueueSheetState extends ConsumerState<_PlaybackQueueSheet> {
  static const double _queueTileHeight = 56.0;

  late int _pageIndex;
  final ScrollController _queueScrollController = ScrollController();
  int? _focusedPageForScroll;

  @override
  void initState() {
    super.initState();
    _pageIndex = widget.lazyPlaylistId != null
        ? PageRange.pageForItem(index: _lazyCurrentIndex())
        : PageRange.pageForItem(index: widget.currentIndex >= 0 ? widget.currentIndex : 0);
  }

  @override
  void dispose() {
    _queueScrollController.dispose();
    super.dispose();
  }

  int _lazyCurrentIndex() {
    final current = widget.playerService.mediaItem?.extras;
    final lazyIndex = current?['_lazyPlaylistIndex'];
    if (lazyIndex is int) return lazyIndex;
    return widget.currentIndex >= 0 ? widget.currentIndex : 0;
  }

  void _scrollToCurrentIfNeeded(int pageIndex, int currentIndex, int pageStart) {
    if (currentIndex < pageStart || _focusedPageForScroll == pageIndex) return;
    final offsetInPage = currentIndex - pageStart;
    _focusedPageForScroll = pageIndex;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_queueScrollController.hasClients) {
        _focusedPageForScroll = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (!_queueScrollController.hasClients) return;
          final position = _queueScrollController.position;
          final target = (offsetInPage * _queueTileHeight -
                  (position.viewportDimension - _queueTileHeight) / 2)
              .clamp(0.0, position.maxScrollExtent);
          _queueScrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
          );
        });
        return;
      }
      final position = _queueScrollController.position;
      final target = (offsetInPage * _queueTileHeight -
          (position.viewportDimension - _queueTileHeight) / 2)
          .clamp(0.0, position.maxScrollExtent);
      _queueScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _playAt(int globalIndex) async {
    final playlistId = widget.lazyPlaylistId;
    if (playlistId == null) {
      await widget.playerService.setQueue(
        widget.queue.map((e) => MusicItem.fromJson(e.extras ?? {})).toList(),
        startIndex: globalIndex,
        manualPlayName:
            globalIndex >= 0 && globalIndex < widget.queue.length
            ? widget.queue[globalIndex].title
            : null,
      );
      return;
    }
    await widget.playerService.playPagedPlaylist(
      songCount:
          widget.playerService.currentLazyPlaylistSongCount > 0
          ? widget.playerService.currentLazyPlaylistSongCount
          : widget.queue.length,
      startIndex: globalIndex,
      playlistId: playlistId,
      manual: true,
      loadPage: (offset, limit) async {
        final page = await ref
            .read(playlistServiceProvider)
            .getSongsPage(playlistId, offset: offset, limit: limit);
        return page.songs;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playlistId = widget.lazyPlaylistId;
    final currentIndex = playlistId != null ? _lazyCurrentIndex() : widget.currentIndex;
    final screenHeight = MediaQuery.of(context).size.height;

    if (playlistId != null) {
      final lazySongCount = widget.playerService.currentLazyPlaylistSongCount;
      final range = PageRange(
        itemCount: lazySongCount > 0 ? lazySongCount : widget.queue.length,
        pageIndex: _pageIndex,
      );
      final songsPage = ref.watch(
        playlistSongsPageProvider(
          PlaylistSongsPageRequest(playlistId: playlistId, pageIndex: range.pageIndex),
        ),
      );

      return SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: AppColors.mutedText(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.queue_music, color: AppColors.accentOf(context), size: 20),
                  const SizedBox(width: 8),
                  Text(
                    '播放列表 (${range.itemCount})',
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: AppColors.cardBorder(context), height: 1),
            songsPage.when(
              skipLoadingOnRefresh: true,
              loading: () => const SizedBox(
                height: 160,
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, stackTrace) => _buildShortQueue(
                context,
                currentIndex,
                screenHeight,
                fallbackReason: error.toString(),
              ),
              data: (page) {
                if (page.songs.isEmpty) {
                  return _buildShortQueue(context, currentIndex, screenHeight);
                }
                final queueItems = page.songs;
                _scrollToCurrentIfNeeded(range.pageIndex, currentIndex, range.start);
                final contentHeight = (queueItems.length * _queueTileHeight)
                    .clamp(0.0, screenHeight * 2 / 3)
                    .toDouble();
                return SizedBox(
                  height: contentHeight,
                  child: Column(
                    children: [
                      Expanded(
                        child: ListView.builder(
                          itemCount: queueItems.length,
                          itemExtent: _queueTileHeight,
                          itemBuilder: (context, index) {
                            final item = queueItems[index];
                            final globalIndex = range.start + index;
                            final isPlaying = globalIndex == currentIndex;
                            return ListTile(
                              dense: true,
                              minTileHeight: _queueTileHeight,
                              leading: isPlaying
                                  ? Icon(Icons.play_arrow, color: AppColors.accentOf(context))
                                  : Text(
                                      '${globalIndex + 1}',
                                      style: TextStyle(
                                        color: AppColors.mutedText(context),
                                        fontSize: 14,
                                      ),
                                    ),
                              title: Text(
                                item.name,
                                style: TextStyle(
                                  color: isPlaying
                                      ? AppColors.accentOf(context)
                                      : AppColors.onScaffold(context),
                                  fontSize: 14,
                                  fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                item.singer,
                                style: TextStyle(
                                  color: AppColors.mutedText(context),
                                  fontSize: 12,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () async {
                                await _playAt(globalIndex);
                                if (context.mounted) Navigator.pop(context);
                              },
                            );
                          },
                        ),
                      ),
                      PageNavigationBar(
                        pageIndex: range.pageIndex,
                        pageCount: range.pageCount,
                        onPageChanged: (pageIndex) {
                          _focusedPageForScroll = null;
                          setState(() => _pageIndex = pageIndex);
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      );
    }

    return _buildShortQueue(context, currentIndex, screenHeight);
  }

  Widget _buildShortQueue(
    BuildContext context,
    int currentIndex,
    double screenHeight, {
    String? fallbackReason,
  }) {
    final range = PageRange(
      itemCount: widget.queue.length,
      pageIndex: _pageIndex,
    );
    final queue = pageSlice(widget.queue, range);
    _scrollToCurrentIfNeeded(range.pageIndex, currentIndex, range.start);
    final hasMultiplePages = range.pageCount > 1;
    final contentHeight = (queue.length * _queueTileHeight + (hasMultiplePages ? 24.0 : 0.0))
        .clamp(0.0, screenHeight * 2 / 3)
        .toDouble();

    return SafeArea(
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32,
            height: 4,
            margin: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.mutedText(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Icon(Icons.queue_music, color: AppColors.accentOf(context), size: 20),
                const SizedBox(width: 8),
                Text(
                  '播放列表 (${widget.queue.length})',
                  style: TextStyle(
                    color: AppColors.onScaffold(context),
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Divider(color: AppColors.cardBorder(context), height: 1),
          if (widget.queue.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text(
                fallbackReason == null ? '播放列表为空' : '完整列表加载失败，显示当前队列',
                style: TextStyle(color: AppColors.mutedText(context), fontSize: 14),
              ),
            )
          else
            SizedBox(
              height: contentHeight,
              child: Column(
                children: [
                  Expanded(
                    child: ListView.builder(
                      itemCount: queue.length,
                      itemExtent: _queueTileHeight,
                      itemBuilder: (context, index) {
                        final item = queue[index];
                        final queueIndex = range.start + index;
                        final isPlaying = queueIndex == currentIndex;
                        return ListTile(
                          dense: true,
                          minTileHeight: _queueTileHeight,
                          leading: isPlaying
                              ? Icon(Icons.play_arrow, color: AppColors.accentOf(context))
                              : Text(
                                  '${queueIndex + 1}',
                                  style: TextStyle(
                                    color: AppColors.mutedText(context),
                                    fontSize: 14,
                                  ),
                                ),
                          title: Text(
                            item.title,
                            style: TextStyle(
                              color: isPlaying
                                  ? AppColors.accentOf(context)
                                  : AppColors.onScaffold(context),
                              fontSize: 14,
                              fontWeight: isPlaying ? FontWeight.w600 : FontWeight.normal,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.artist ?? '',
                            style: TextStyle(
                              color: AppColors.mutedText(context),
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () async {
                            await _playAt(queueIndex);
                            if (context.mounted) Navigator.pop(context);
                          },
                        );
                      },
                    ),
                  ),
                  PageNavigationBar(
                    pageIndex: range.pageIndex,
                    pageCount: range.pageCount,
                    onPageChanged: (pageIndex) {
                      _focusedPageForScroll = null;
                      setState(() => _pageIndex = pageIndex);
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
