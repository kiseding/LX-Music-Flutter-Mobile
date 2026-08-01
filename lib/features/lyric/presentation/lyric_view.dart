import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../domain/lyric.dart';
import '../presentation/lyric_provider.dart';
import '../presentation/lyrics_translation_provider.dart';
import '../../player/presentation/player_provider.dart';
import '../../player/domain/music_item.dart';

String _formatLyricTime(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

class LyricView extends ConsumerStatefulWidget {
  final bool isFullScreen;

  const LyricView({super.key, this.isFullScreen = false});

  @override
  ConsumerState<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends ConsumerState<LyricView> {
  final ScrollController _scrollController = ScrollController();
  int _lastScrolledIndex = -1;
  String _lyricsIdentity = '';
  bool _isUserScrolling = false;
  bool _scrollListenerAttached = false;
  bool _programmaticScroll = false;
  Timer? _resumeFollowTimer;

  double get _itemExtent => widget.isFullScreen ? 56.0 : 44.0;
  double get _verticalPadding => widget.isFullScreen ? 150.0 : 80.0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _scrollToCurrent(force: true));
  }

  void _attachScrollListener() {
    if (_scrollListenerAttached || !_scrollController.hasClients) return;
    _scrollListenerAttached = true;
    _scrollController.position.isScrollingNotifier.addListener(() {
      if (_programmaticScroll) return;
      if (_scrollController.position.isScrollingNotifier.value) {
        _isUserScrolling = true;
        _resumeFollowTimer?.cancel();
      } else {
        _resumeFollowTimer?.cancel();
        _resumeFollowTimer = Timer(const Duration(seconds: 5), () {
          if (!mounted) return;
          setState(() => _isUserScrolling = false);
          _lastScrolledIndex = -1;
          _scrollToCurrent(force: true);
        });
      }
    });
  }

  @override
  void dispose() {
    _resumeFollowTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToCurrent({bool force = false}) {
    if (!mounted) return;
    final idx = ref.read(currentLineIndexProvider);
    final lyrics = ref.read(currentLyricProvider);
    if (lyrics.isEmpty || idx < 0) return;
    if (!force && (_isUserScrolling || idx == _lastScrolledIndex)) return;
    _lastScrolledIndex = idx;
    _scrollToLine(idx);
  }

  void _scrollToLine(int index) {
    if (!_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToLine(index);
      });
      return;
    }
    _attachScrollListener();
    final position = _scrollController.position;
    final viewport = position.viewportDimension;
    // 固定行高估算：ListView.builder 未构建的行 ensureVisible 会失败
    final rawOffset = _verticalPadding + index * _itemExtent - viewport * 0.38;
    final target = rawOffset.clamp(0.0, position.maxScrollExtent);

    _programmaticScroll = true;
    _scrollController
        .animateTo(
      target,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    )
        .whenComplete(() {
      _programmaticScroll = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final loadState = ref.watch(currentLyricLoadProvider);
    final lyrics = loadState.lyrics;
    final currentLineIndex = ref.watch(currentLineIndexProvider);
    final currentMusic = ref.watch(currentMusicProvider);

    final primary = AppColors.onScaffold(context);
    final secondary = AppColors.secondaryText(context);
    final muted = AppColors.mutedText(context);
    final accent = AppColors.accentOf(context);

    final translationEnabled = ref.watch(lyricsTranslationEnabledProvider);
    final translations = ref.watch(lyricsTranslationsProvider);

    // 换歌/重载歌词时强制滚到当前行
    final identity = '${currentMusic?.id ?? ''}:${lyrics.raw.hashCode}';
    if (identity != _lyricsIdentity) {
      _lyricsIdentity = identity;
      _lastScrolledIndex = -1;
      _isUserScrolling = false;
      if (translationEnabled && lyrics.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ref.read(lyricsTranslationsProvider.notifier).reset();
          ref.read(lyricsTranslationsProvider.notifier).ensureForCurrent();
        });
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrent(force: true);
      });
    } else if (currentLineIndex != _lastScrolledIndex &&
        currentLineIndex >= 0 &&
        !_isUserScrolling) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToCurrent();
      });
    } else {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _attachScrollListener());
    }

    if (loadState.isLoading) {
      return _buildStatusState(
        icon: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: accent,
        ),
        title: '正在加载歌词',
        message: currentMusic == null
            ? '正在获取歌词内容'
            : '${currentMusic.name} - ${currentMusic.singer}',
        primary: primary,
        muted: muted,
        secondary: secondary,
      );
    }

    if (loadState.error != null) {
      return _buildStatusState(
        icon: Icon(Icons.error_outline, size: 34, color: muted),
        title: '歌词加载失败',
        message: '请检查网络连接后重试',
        actionLabel: '重试',
        onAction: () => _retryLyric(currentMusic),
        primary: primary,
        muted: muted,
        secondary: secondary,
      );
    }

    if (lyrics.isEmpty) {
      return _buildStatusState(
        icon: Icon(Icons.music_note, size: 34, color: muted),
        title: '暂无歌词',
        message: currentMusic != null
            ? '${currentMusic.name} - ${currentMusic.singer}'
            : '该歌曲暂时没有可用的歌词文件',
        actionLabel: '搜索歌词',
        onAction: () => _retryLyric(currentMusic),
        primary: primary,
        muted: muted,
        secondary: secondary,
      );
    }

    final lyricList = ShaderMask(
      shaderCallback: (Rect bounds) {
        return const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.white,
            Colors.white,
            Colors.transparent
          ],
          stops: [0.0, 0.1, 0.9, 1.0],
        ).createShader(bounds);
      },
      blendMode: BlendMode.dstIn,
      child: ListView.builder(
        controller: _scrollController,
        padding: EdgeInsets.symmetric(vertical: _verticalPadding),
        itemExtent: _itemExtent,
        itemCount: lyrics.lines.length,
        itemBuilder: (context, index) {
          final line = lyrics.lines[index];
          final isCurrent = index == currentLineIndex;

          final lineColor = isCurrent
              ? (widget.isFullScreen ? primary : accent)
              : (widget.isFullScreen ? primary.withValues(alpha: 0.35) : muted);
          final dimColor =
              isCurrent ? lineColor.withValues(alpha: 0.35) : lineColor;
          final transColor =
              isCurrent ? secondary : muted.withValues(alpha: 0.55);

          final fontSize = isCurrent
              ? (widget.isFullScreen ? 20.0 : 16.0)
              : (widget.isFullScreen ? 16.0 : 14.0);
          final weight = isCurrent ? FontWeight.bold : FontWeight.normal;

          final lineContent = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isCurrent && line.hasWordTiming)
                  _PositionedKtvLyricLine(
                    line: line,
                    lineIndex: index,
                    lyrics: lyrics,
                    activeColor: accent,
                    dimColor: dimColor,
                    fontSize: fontSize,
                    fontWeight: weight,
                  )
                else
                  Text(
                    line.text,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: lineColor,
                      fontSize: fontSize,
                      fontWeight: weight,
                    ),
                  ),
                if (line.translation != null)
                  Text(
                    line.translation!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: transColor,
                      fontSize: isCurrent
                          ? (widget.isFullScreen ? 13 : 11)
                          : (widget.isFullScreen ? 11 : 10),
                    ),
                  )
                else if (translationEnabled)
                  Builder(builder: (context) {
                    final online = translations[line.text.trim()];
                    if (online == null || online.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    return Text(
                      online,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: transColor,
                        fontSize: isCurrent
                            ? (widget.isFullScreen ? 13 : 11)
                            : (widget.isFullScreen ? 11 : 10),
                      ),
                    );
                  }),
              ],
            ),
          );

          return GestureDetector(
            onTap: () => ref.read(seekProvider)(line.time),
            behavior: HitTestBehavior.opaque,
            child: Semantics(
              button: true,
              selected: isCurrent,
              label: line.text,
              value: _formatLyricTime(line.time),
              onTap: () => ref.read(seekProvider)(line.time),
              child: ExcludeSemantics(child: lineContent),
            ),
          );
        },
      ),
    );

    final currentText =
        currentLineIndex >= 0 && currentLineIndex < lyrics.lines.length
            ? lyrics.lines[currentLineIndex].text
            : '';
    final previousIndex = lyrics.isEmpty
        ? -1
        : (currentLineIndex - 1).clamp(0, lyrics.lines.length - 1);
    final nextIndex = lyrics.isEmpty
        ? -1
        : (currentLineIndex + 1).clamp(0, lyrics.lines.length - 1);

    return Stack(
      children: [
        Positioned.fill(
          child: Semantics(
            label: '歌词',
            value: currentText,
            decreasedValue:
                previousIndex < 0 ? null : lyrics.lines[previousIndex].text,
            increasedValue: nextIndex < 0 ? null : lyrics.lines[nextIndex].text,
            onDecrease: previousIndex < 0
                ? null
                : () => ref.read(seekProvider)(lyrics.lines[previousIndex].time),
            onIncrease: nextIndex < 0
                ? null
                : () => ref.read(seekProvider)(lyrics.lines[nextIndex].time),
            child: lyricList,
          ),
        ),
        Positioned(
          top: 8,
          right: 12,
          child: _TranslationToggle(enabled: translationEnabled),
        ),
      ],
    );
  }

  Widget _TranslationToggle({required bool enabled}) {
    return GestureDetector(
      onTap: () {
        final next = !enabled;
        ref.read(lyricsTranslationEnabledProvider.notifier).setEnabled(next);
        if (next) {
          ref.read(lyricsTranslationsProvider.notifier).ensureForCurrent();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: enabled
              ? AppColors.accentOf(context).withValues(alpha: 0.18)
              : AppColors.fill(context).withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: enabled
                ? AppColors.accentOf(context).withValues(alpha: 0.5)
                : AppColors.cardBorder(context),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.translate,
              size: 13,
              color: enabled
                  ? AppColors.accentOf(context)
                  : AppColors.mutedText(context),
            ),
            const SizedBox(width: 4),
            Text(
              enabled ? '翻译中' : '翻译',
              style: TextStyle(
                fontSize: 11,
                color: enabled
                    ? AppColors.accentOf(context)
                    : AppColors.mutedText(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusState({
    required Widget icon,
    required String title,
    required String message,
    required Color primary,
    required Color muted,
    required Color secondary,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppColors.fill(context),
                shape: BoxShape.circle,
                border: Border.all(color: AppColors.cardBorder(context)),
              ),
              child: Center(child: icon),
            ),
            const SizedBox(height: 16),
            Text(title,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: primary)),
            const SizedBox(height: 6),
            Text(
              message,
              style: TextStyle(fontSize: 12, color: muted),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: onAction,
                style: OutlinedButton.styleFrom(
                  backgroundColor: AppColors.fill(context),
                  foregroundColor: secondary,
                  side: BorderSide(color: AppColors.cardBorder(context)),
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 38),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                ),
                child: Text(actionLabel,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: secondary)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _retryLyric(MusicItem? music) async {
    if (music == null) return;
    await ref.read(currentLyricLoadProvider.notifier).retry();
  }
}

class _PositionedKtvLyricLine extends ConsumerWidget {
  final LyricLine line;
  final int lineIndex;
  final Lyrics lyrics;
  final Color activeColor;
  final Color dimColor;
  final double fontSize;
  final FontWeight fontWeight;

  const _PositionedKtvLyricLine({
    required this.line,
    required this.lineIndex,
    required this.lyrics,
    required this.activeColor,
    required this.dimColor,
    required this.fontSize,
    required this.fontWeight,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(playerPositionProvider);
    return _KtvLyricLine(
      line: line,
      lineIndex: lineIndex,
      lyrics: lyrics,
      position: position,
      activeColor: activeColor,
      dimColor: dimColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
    );
  }
}

/// KTV 流式：已唱完的字全亮，当前字按进度裁剪填充，未唱暗色。
class _KtvLyricLine extends StatelessWidget {
  final LyricLine line;
  final int lineIndex;
  final Lyrics lyrics;
  final Duration position;
  final Color activeColor;
  final Color dimColor;
  final double fontSize;
  final FontWeight fontWeight;

  const _KtvLyricLine({
    required this.line,
    required this.lineIndex,
    required this.lyrics,
    required this.position,
    required this.activeColor,
    required this.dimColor,
    required this.fontSize,
    required this.fontWeight,
  });

  @override
  Widget build(BuildContext context) {
    final words = line.words!;
    final activeWord = lyrics.getCurrentWordIndex(position, lineIndex);

    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var i = 0; i < words.length; i++)
          _KtvWord(
            text: words[i].text,
            fill: i < activeWord
                ? 1.0
                : i == activeWord
                    ? lyrics.getWordFillProgress(position, lineIndex, i)
                    : 0.0,
            activeColor: activeColor,
            dimColor: dimColor,
            fontSize: fontSize,
            fontWeight: fontWeight,
          ),
      ],
    );
  }
}

class _KtvWord extends StatelessWidget {
  final String text;
  final double fill;
  final Color activeColor;
  final Color dimColor;
  final double fontSize;
  final FontWeight fontWeight;

  const _KtvWord({
    required this.text,
    required this.fill,
    required this.activeColor,
    required this.dimColor,
    required this.fontSize,
    required this.fontWeight,
  });

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: fontWeight,
      height: 1.15,
    );

    if (fill <= 0) {
      return Text(text, style: style.copyWith(color: dimColor));
    }
    if (fill >= 1) {
      return Text(text, style: style.copyWith(color: activeColor));
    }

    return Stack(
      children: [
        Text(text, style: style.copyWith(color: dimColor)),
        ClipRect(
          clipper: _FractionClipper(fill),
          child: Text(text, style: style.copyWith(color: activeColor)),
        ),
      ],
    );
  }
}

class _FractionClipper extends CustomClipper<Rect> {
  final double fraction;
  _FractionClipper(this.fraction);

  @override
  Rect getClip(Size size) {
    final w = size.width * fraction.clamp(0.0, 1.0);
    return Rect.fromLTWH(0, 0, w, size.height);
  }

  @override
  bool shouldReclip(covariant _FractionClipper oldClipper) =>
      oldClipper.fraction != fraction;
}
