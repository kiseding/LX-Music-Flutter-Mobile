import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/widgets/artwork_image.dart';
import '../../../core/widgets/pressable.dart';
import '../../../core/widgets/play_pulse_button.dart';
import '../../../core/network/play_url_result.dart';
import '../domain/music_item.dart';
import '../domain/player_service.dart';
import 'player_provider.dart';
import '../../playlist/presentation/playlist_provider.dart';
import '../../playlist/presentation/playlist_picker.dart';
import '../../download/presentation/download_provider.dart';
import '../../lyric/presentation/lyric_view.dart';
import '../../lyric/presentation/lyric_provider.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({super.key});

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  bool _seeking = false;
  double _seekValue = 0; // 0..1 only while finger is down
  bool _wasPlayingBeforeSeek = false;
  Future<int> _scrubFuture = Future<int>.value(0);
  double _dragOffset = 0;
  bool _draggingDown = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playerService = ref.watch(playerServiceProvider);
    final currentMusic = ref.watch(currentMusicProvider);
    final playbackState = ref.watch(playbackStateProvider).value;
    final position = ref.watch(playerPositionProvider);
    final playMode = ref.watch(playModeProvider);

    // 监听全局播放器消息（PlayerScreen 内部也可以监听以确保及时弹出）
    ref.listen<String?>(playerMessageProvider, (previous, next) {
      if (next != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(next),
            backgroundColor: AppColors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        ref.read(playerMessageProvider.notifier).state = null;
      }
    });

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
    final isFavorite = ref.watch(isSongFavoriteProvider(currentMusic.id));

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
                                _buildCurrentLyricLine(),
                                _buildProgressSection(
                                    playerService, position, duration),
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
    // 纯透明底，整体下移 10px
    return Padding(
      padding: EdgeInsets.only(top: 14, bottom: 4),
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
    );
  }

  Widget _buildAppBar(BuildContext context, MusicItem music) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.fill(context),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.cardBorder(context)),
              ),
              child: Icon(Icons.keyboard_arrow_down,
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text('已添加到下载队列'), duration: Duration(seconds: 1)),
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
            onPressed: () => ref.read(toggleFavoriteProvider)(music),
          ),
        ],
      ),
    );
  }

  /// 固定高度占位，避免无歌词→有歌词时整页跳动
  Widget _buildCurrentLyricLine() {
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

  /// 全屏歌词页底部简约栏：歌名-歌手 | 播放键（下移 10px，字号加大）
  Widget _buildLyricMiniBar(
      MusicItem music, PlayerService playerService, bool isPlaying) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 20, 30), // bottom +10
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${music.name} - ${music.singer}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppColors.onScaffold(context),
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
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

  Widget _buildProgressSection(
      PlayerService playerService, Duration position, Duration duration) {
    final totalMs =
        duration.inMilliseconds > 0 ? duration.inMilliseconds.toDouble() : 1.0;
    // 仅拖动时用本地值；松手后立刻跟 playerPositionProvider（唯一时钟）
    final effectivePos = _seeking
        ? Duration(milliseconds: (_seekValue * totalMs).round())
        : position;
    final ratio = (effectivePos.inMilliseconds / totalMs).clamp(0.0, 1.0);
    final displayPos = effectivePos;

    return Padding(
      // 进度条两侧各再缩 5px（时间与条间距加大）
      padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 36,
            child: Text(
              _formatDuration(displayPos),
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
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (d) async {
                    final playing =
                        ref.read(playbackStateProvider).value?.playing ?? false;
                    setState(() {
                      _seeking = true;
                      _wasPlayingBeforeSeek = playing;
                      _seekValue = (d.localPosition.dx / width).clamp(0.0, 1.0);
                    });
                    _scrubFuture = ref.read(beginScrubProvider)();
                  },
                  onHorizontalDragUpdate: (d) {
                    setState(() {
                      _seekValue = (d.localPosition.dx / width).clamp(0.0, 1.0);
                    });
                  },
                  onHorizontalDragEnd: (_) async {
                    final target =
                        Duration(milliseconds: (_seekValue * totalMs).round());
                    final generation = await _scrubFuture;
                    await ref.read(finishScrubProvider)(
                      generation,
                      target,
                      resumeAfter: _wasPlayingBeforeSeek,
                    );
                    if (mounted) setState(() => _seeking = false);
                  },
                  onTapUp: (d) async {
                    final playing =
                        ref.read(playbackStateProvider).value?.playing ?? false;
                    final v = (d.localPosition.dx / width).clamp(0.0, 1.0);
                    final target =
                        Duration(milliseconds: (v * totalMs).round());
                    setState(() {
                      _seekValue = v;
                      _seeking = true;
                      _wasPlayingBeforeSeek = playing;
                    });
                    final generation = await ref.read(beginScrubProvider)();
                    await ref.read(finishScrubProvider)(
                      generation,
                      target,
                      resumeAfter: playing,
                    );
                    if (mounted) setState(() => _seeking = false);
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
                          // 圆点
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
              },
            ),
          ),
          const SizedBox(width: 5),
          SizedBox(
            width: 36,
            child: Text(
              _formatDuration(duration),
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

  Widget _buildControls(
      PlayerService playerService, bool isPlaying, PlayMode playMode) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(
              _getPlayModeIcon(playMode),
              color: AppColors.mutedText(context),
              size: 22,
            ),
            onPressed: () {
              final nextMode = _getNextPlayMode(playMode);
              ref.read(playModeProvider.notifier).state = nextMode;
              _applyPlayMode(playerService, nextMode);
            },
          ),
          Pressable(
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
            onTap: playerService.next,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.skip_next,
                  color: AppColors.onScaffold(context), size: 32),
            ),
          ),
          IconButton(
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
      backgroundColor: AppColors.dialogBg(context),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
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
                  Icon(Icons.queue_music,
                      color: AppColors.accentOf(context), size: 20),
                  const SizedBox(width: 8),
                  Text('播放列表 (${queue.length})',
                      style: TextStyle(
                          color: AppColors.onScaffold(context),
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            Divider(color: AppColors.cardBorder(context), height: 1),
            if (queue.isEmpty)
              Padding(
                padding: EdgeInsets.all(32),
                child: Text('播放列表为空',
                    style: TextStyle(
                        color: AppColors.mutedText(context), fontSize: 14)),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.6),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: queue.length,
                  itemBuilder: (context, index) {
                    final item = queue[index];
                    final isPlaying = index == currentIndex;

                    return ListTile(
                      leading: isPlaying
                          ? Icon(Icons.play_arrow,
                              color: AppColors.accentOf(context))
                          : Text('${index + 1}',
                              style: TextStyle(
                                  color: AppColors.mutedText(context),
                                  fontSize: 14)),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          color: isPlaying
                              ? AppColors.accentOf(context)
                              : AppColors.onScaffold(context),
                          fontSize: 14,
                          fontWeight:
                              isPlaying ? FontWeight.w600 : FontWeight.normal,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.artist ?? '',
                        style: TextStyle(
                            color: AppColors.mutedText(context), fontSize: 12),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        playerService.setQueue(
                            queue
                                .map((e) => MusicItem.fromJson(e.extras ?? {}))
                                .toList(),
                            startIndex: index);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
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
                onTap: () {
                  Navigator.pop(context);
                  ref.read(toggleFavoriteProvider)(music);
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
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('已添加到下载队列'),
                      duration: Duration(seconds: 1)));
                }),
          ],
        ),
      ),
    );
  }
}
