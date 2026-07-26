import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/widgets/pressable.dart';
import '../../../../core/widgets/play_pulse_button.dart';
import '../../../../core/audio/audio_handler.dart';
import '../player_provider.dart';
import '../../../lyric/presentation/lyric_provider.dart';

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
  bool _seeking = false;
  double _seekValue = 0;
  bool _wasPlaying = false;
  Duration? _pendingSeek;

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(1, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final currentMusic = ref.watch(currentMusicProvider);
    final isPlaying = ref.watch(isPlayingProvider);
    final position = ref.watch(positionProvider);
    final duration = ref.watch(durationProvider);
    final playerService = ref.watch(playerServiceProvider);
    final lyrics = ref.watch(currentLyricProvider);
    final currentLineIndex = ref.watch(currentLineIndexProvider);
    final isDark = AppColors.isDark(context);

    if (currentMusic == null && !widget.alwaysShow) {
      return const SizedBox.shrink();
    }

    final durationValue = duration.value ?? Duration.zero;
    final isPlayingValue = isPlaying.value ?? false;
    final totalMs = durationValue.inMilliseconds.toDouble();
    if (_pendingSeek != null && !_seeking && totalMs > 0) {
      final delta = (position.inMilliseconds - _pendingSeek!.inMilliseconds).abs();
      if (delta < 800) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _pendingSeek != null) setState(() => _pendingSeek = null);
        });
      }
    }
    final effectivePos = _seeking
        ? Duration(milliseconds: (_seekValue * (totalMs > 0 ? totalMs : 0)).round())
        : (_pendingSeek ?? position);
    final progress = totalMs > 0 ? (effectivePos.inMilliseconds / totalMs).clamp(0.0, 1.0) : 0.0;
    final displayPos = effectivePos;

    final titleColor = AppColors.onScaffold(context);
    final subColor = AppColors.secondaryText(context);
    final barBg = AppColors.miniBar(context);
    final surface = AppColors.fill2(context);
    final accent = AppColors.accentOf(context);
    final trackBg = isDark ? const Color(0x33FFFFFF) : const Color(0x33000000);
    final timeColor = AppColors.mutedText(context);
    final canSeek = currentMusic != null && totalMs > 0;

    String title = currentMusic?.name ?? '未在播放';
    String subtitle = currentMusic?.singer ?? '无歌词';
    if (currentMusic != null &&
        lyrics.isNotEmpty &&
        currentLineIndex >= 0 &&
        currentLineIndex < lyrics.lines.length) {
      subtitle = lyrics.lines[currentLineIndex].text;
    }

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
                    color: isDark ? const Color(0x66000000) : const Color(0x1A000000),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            // 时间 | 进度条 | 时间
            SizedBox(
              height: 20,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 28,
                      child: Text(
                        _fmt(displayPos),
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
                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onHorizontalDragStart: !canSeek
                                ? null
                                : (d) async {
                                    final playing = isPlayingValue;
                                    setState(() {
                                      _seeking = true;
                                      _pendingSeek = null;
                                      _wasPlaying = playing;
                                      _seekValue = (d.localPosition.dx / w).clamp(0.0, 1.0);
                                    });
                                    if (playing) await audioHandler.pause();
                                  },
                            onHorizontalDragUpdate: !canSeek
                                ? null
                                : (d) {
                                    setState(() {
                                      _seekValue = (d.localPosition.dx / w).clamp(0.0, 1.0);
                                    });
                                  },
                            onHorizontalDragEnd: !canSeek
                                ? null
                                : (_) async {
                                    final target = Duration(milliseconds: (_seekValue * totalMs).round());
                                    setState(() {
                                      _pendingSeek = target;
                                      _seeking = false;
                                    });
                                    await ref.read(seekProvider)(target);
                                    if (_wasPlaying) {
                                      await audioHandler.play();
                                    }
                                  },
                            onTapDown: !canSeek
                                ? null
                                : (d) async {
                                    final v = (d.localPosition.dx / w).clamp(0.0, 1.0);
                                    final target = Duration(milliseconds: (v * totalMs).round());
                                    setState(() {
                                      _seekValue = v;
                                      _pendingSeek = target;
                                    });
                                    await ref.read(seekProvider)(target);
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
                                  if (currentMusic != null)
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
                                            BoxShadow(color: accent.withAlpha(140), blurRadius: 8),
                                          ],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 28,
                      child: Text(
                        _fmt(durationValue),
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
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 6, 6),
                child: Row(
                  children: [
                    GestureDetector(
                      onTap: currentMusic != null ? () => context.push('/player') : null,
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          color: surface,
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: currentMusic?.artwork != null && currentMusic!.artwork!.isNotEmpty
                            ? Image.network(
                                currentMusic.artwork!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Icon(Icons.music_note, color: subColor, size: 20),
                              )
                            : Icon(Icons.music_note, color: subColor, size: 20),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: currentMusic != null ? () => context.push('/player') : null,
                        behavior: HitTestBehavior.opaque,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: titleColor),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              subtitle,
                              style: TextStyle(fontSize: 11, color: subColor),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 128,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          Pressable(
                            onTap: currentMusic == null ? null : () => playerService.previous(),
                            child: Icon(Icons.skip_previous_rounded, size: 26, color: currentMusic == null ? subColor : titleColor),
                          ),
                          PlayPulseButton(
                            isPlaying: isPlayingValue,
                            onPressed: currentMusic == null ? null : () => playerService.togglePlay(),
                            enabled: currentMusic != null,
                            size: 36,
                            iconSize: 22,
                            mini: true,
                          ),
                          Pressable(
                            onTap: currentMusic == null ? null : () => playerService.next(),
                            child: Icon(Icons.skip_next_rounded, size: 26, color: currentMusic == null ? subColor : titleColor),
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
