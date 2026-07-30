import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/artwork_image.dart';
import '../../../../core/widgets/pressable.dart';
import '../../../../core/widgets/play_pulse_button.dart';
import '../player_provider.dart';
import '../scrub_session.dart';
import '../../../lyric/presentation/lyric_provider.dart';

String _fmtMini(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$m:$s';
}

class _MiniProgress extends ConsumerWidget {
  final Duration duration;
  final bool seeking;
  final double seekValue;
  final bool canSeek;
  final bool showThumb;
  final Color accent;
  final Color trackBg;
  final Color timeColor;
  final void Function(double value) onDragStart;
  final void Function(double value) onDragUpdate;
  final Future<void> Function(Duration target) onSeekEnd;
  final VoidCallback onSeekCancel;
  final Future<void> Function(double value, Duration target) onTapSeek;

  const _MiniProgress({
    required this.duration,
    required this.seeking,
    required this.seekValue,
    required this.canSeek,
    required this.showThumb,
    required this.accent,
    required this.trackBg,
    required this.timeColor,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onSeekEnd,
    required this.onSeekCancel,
    required this.onTapSeek,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionProvider);
    final totalMs = duration.inMilliseconds.toDouble();
    final effectivePos = seeking
        ? Duration(
            milliseconds: (seekValue * (totalMs > 0 ? totalMs : 0)).round())
        : position;
    final progress = totalMs > 0
        ? (effectivePos.inMilliseconds / totalMs).clamp(0.0, 1.0)
        : 0.0;
    final displayPos = effectivePos;

    Duration adjusted(Duration position, int deltaSeconds) {
      final milliseconds = (position.inMilliseconds + deltaSeconds * 1000)
          .clamp(0, duration.inMilliseconds);
      return Duration(milliseconds: milliseconds);
    }

    String format(Duration d) {
      final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return '$minutes:$seconds';
    }

    return SizedBox(
      height: 20,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Text(
                _fmtMini(displayPos),
                style: TextStyle(
                  color: timeColor,
                  fontSize: 10,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final fillW = (w * progress).clamp(0.0, w);
                  final interactiveTrack = GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onHorizontalDragStart: !canSeek
                        ? null
                        : (d) {
                            onDragStart(
                                (d.localPosition.dx / w).clamp(0.0, 1.0));
                          },
                    onHorizontalDragUpdate: !canSeek
                        ? null
                        : (d) {
                            onDragUpdate(
                                (d.localPosition.dx / w).clamp(0.0, 1.0));
                          },
                    onHorizontalDragEnd: !canSeek
                        ? null
                        : (_) {
                            final target = Duration(
                                milliseconds: (seekValue * totalMs).round());
                            onSeekEnd(target);
                          },
                    onHorizontalDragCancel: !canSeek ? null : onSeekCancel,
                    onTapUp: !canSeek
                        ? null
                        : (d) {
                            final v = (d.localPosition.dx / w).clamp(0.0, 1.0);
                            final target =
                                Duration(milliseconds: (v * totalMs).round());
                            onTapSeek(v, target);
                          },
                    child: SizedBox(
                      height: 16,
                      child: Stack(
                        alignment: Alignment.centerLeft,
                        clipBehavior: Clip.none,
                        children: [
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 6.5,
                            child: Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color: trackBg,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          Positioned(
                            left: 0,
                            top: 6.5,
                            child: Container(
                              width: fillW,
                              height: 3,
                              decoration: BoxDecoration(
                                color: accent,
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                          if (showThumb)
                            Positioned(
                              left: (fillW - 6).clamp(0.0, w - 12),
                              top: 2,
                              child: Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: accent,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                        color: accent.withAlpha(140),
                                        blurRadius: 8),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                  return Semantics(
                    label: '播放进度',
                    slider: true,
                    enabled: duration > Duration.zero,
                    value: '${format(displayPos)} / ${format(duration)}',
                    increasedValue: format(adjusted(displayPos, 10)),
                    decreasedValue: format(adjusted(displayPos, -10)),
                    onIncrease: duration > Duration.zero
                        ? () => ref.read(seekProvider)(adjusted(displayPos, 10))
                        : null,
                    onDecrease: duration > Duration.zero
                        ? () =>
                            ref.read(seekProvider)(adjusted(displayPos, -10))
                        : null,
                    child: ExcludeSemantics(child: interactiveTrack),
                  );
                },
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 28,
              child: Text(
                _fmtMini(duration),
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: timeColor,
                  fontSize: 10,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniLyricText extends ConsumerWidget {
  final bool hasSong;
  final String fallback;
  final Color color;

  const _MiniLyricText({
    required this.hasSong,
    required this.fallback,
    required this.color,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lyrics = ref.watch(currentLyricProvider);
    final currentLineIndex = ref.watch(currentLineIndexProvider);

    var subtitle = fallback;
    if (hasSong &&
        lyrics.isNotEmpty &&
        currentLineIndex >= 0 &&
        currentLineIndex < lyrics.lines.length) {
      subtitle = lyrics.lines[currentLineIndex].text;
    }

    return Text(
      subtitle,
      style: TextStyle(fontSize: 11, color: color),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 迷你播放条：顶部时间 + 进度条（与全屏同逻辑）

class MiniPlayer extends ConsumerStatefulWidget {
  final bool floating;
  final bool alwaysShow;

  const MiniPlayer({
    super.key,
    this.floating = false,
    this.alwaysShow = false,
  });

  @override
  ConsumerState<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<MiniPlayer> {
  late bool _seeking;
  double _seekValue = 0;
  bool _wasPlayingBeforeSeek = false;
  late final ScrubSession _scrubSession;
  ScrubOperation? _dragOperation;

  @override
  void initState() {
    super.initState();
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
    super.dispose();
  }

  void _beginSeek(double value, bool isPlayingValue) {
    setState(() {
      _seeking = true;
      _wasPlayingBeforeSeek = isPlayingValue;
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

  Future<void> _tapSeek(
      double value, Duration target, bool isPlayingValue) async {
    setState(() {
      _seekValue = value;
      _seeking = true;
      _wasPlayingBeforeSeek = isPlayingValue;
    });
    final operation = _scrubSession.begin();
    final mayClear = await _scrubSession.finish(
      operation,
      target,
      resumeAfter: isPlayingValue,
    );
    if (mounted && mayClear) {
      setState(() => _seeking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentMusic = ref.watch(currentMusicProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final duration = ref.watch(durationProvider);
    final playerService = ref.watch(playerServiceProvider);
    final isDark = AppColors.isDark(context);

    if (currentMusic == null && !widget.alwaysShow) {
      return const SizedBox.shrink();
    }

    final durationValue = duration.value ?? Duration.zero;
    final isPlayingValue = isPlaying.value ?? false;
    final totalMs = durationValue.inMilliseconds.toDouble();
    final canSeek = currentMusic != null && totalMs > 0;

    final titleColor = AppColors.onScaffold(context);
    final subColor = AppColors.secondaryText(context);
    final barBg = AppColors.miniBar(context);
    final surface = AppColors.fill2(context);
    final accent = AppColors.accentOf(context);
    final trackBg = isDark ? const Color(0x33FFFFFF) : const Color(0x33000000);
    final timeColor = AppColors.mutedText(context);

    final title = currentMusic?.name ?? '未在播放';
    final fallbackSubtitle = currentMusic?.singer ?? '无歌词';

    return Material(
      color: Colors.transparent,
      child: Container(
        height: 78,
        decoration: BoxDecoration(
          color: barBg,
          borderRadius: BorderRadius.circular(16),
          boxShadow: widget.floating
              ? [
                  BoxShadow(
                    color: isDark
                        ? const Color(0x66000000)
                        : const Color(0x1A000000),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            _MiniProgress(
              duration: durationValue,
              seeking: _seeking,
              seekValue: _seekValue,
              canSeek: canSeek,
              showThumb: currentMusic != null,
              accent: accent,
              trackBg: trackBg,
              timeColor: timeColor,
              onDragStart: (v) => _beginSeek(v, isPlayingValue),
              onDragUpdate: _updateSeek,
              onSeekEnd: _finishSeek,
              onSeekCancel: _cancelSeek,
              onTapSeek: (v, t) => _tapSeek(v, t, isPlayingValue),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        label: '打开正在播放',
                        button: true,
                        enabled: currentMusic != null,
                        child: InkWell(
                          onTap: currentMusic != null
                              ? () => context.push('/player')
                              : null,
                          borderRadius: BorderRadius.circular(10),
                          child: Row(
                            children: [
                              Container(
                                width: 42,
                                height: 42,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  color: surface,
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: currentMusic?.artwork != null &&
                                        currentMusic!.artwork!.isNotEmpty
                                    ? ArtworkImage(
                                        currentMusic.artwork!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(
                                            Icons.music_note,
                                            color: subColor,
                                            size: 20),
                                      )
                                    : Icon(Icons.music_note,
                                        color: subColor, size: 20),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      title,
                                      style: TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: titleColor),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    _MiniLyricText(
                                      hasSong: currentMusic != null,
                                      fallback: fallbackSubtitle,
                                      color: subColor,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 128,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Pressable(
                            semanticLabel: '上一首',
                            onTap: currentMusic == null
                                ? null
                                : () => playerService.previous(),
                            child: Icon(Icons.skip_previous_rounded,
                                size: 26,
                                color: currentMusic == null
                                    ? subColor
                                    : titleColor),
                          ),
                          PlayPulseButton(
                            isPlaying: isPlayingValue,
                            onPressed: currentMusic == null
                                ? null
                                : () => playerService.togglePlay(),
                            enabled: currentMusic != null,
                            size: 36,
                            iconSize: 22,
                            mini: true,
                          ),
                          Pressable(
                            semanticLabel: '下一首',
                            onTap: currentMusic == null
                                ? null
                                : () => playerService.next(),
                            child: Icon(Icons.skip_next_rounded,
                                size: 26,
                                color: currentMusic == null
                                    ? subColor
                                    : titleColor),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
