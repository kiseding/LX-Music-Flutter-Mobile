import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// 播放/暂停：lx2cf 风格
/// - :active scale 0.82
/// - play-on：0.7→1.12→1 + 绿色光晕
/// - play-off：1→1.08→0.92→1
class PlayPulseButton extends StatefulWidget {
  final bool isPlaying;
  final VoidCallback? onPressed;
  final double size;
  final double iconSize;
  final bool enabled;
  final bool mini;

  const PlayPulseButton({
    super.key,
    required this.isPlaying,
    required this.onPressed,
    this.size = 64,
    this.iconSize = 34,
    this.enabled = true,
    this.mini = false,
  });

  @override
  State<PlayPulseButton> createState() => _PlayPulseButtonState();
}

class _PlayPulseButtonState extends State<PlayPulseButton>
    with TickerProviderStateMixin {
  late final AnimationController _scaleCtrl;
  late final AnimationController _glowCtrl;
  late final AnimationController _pressCtrl;
  Animation<double>? _scaleAnim;
  double _scale = 1.0;

  @override
  void initState() {
    super.initState();
    _scaleCtrl = AnimationController(vsync: this);
    _glowCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 600));
    _pressCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 90));
    _scaleCtrl.addListener(_onScaleTick);
    _pressCtrl.addListener(() {
      if (mounted) setState(() {});
    });
    _glowCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  void _onScaleTick() {
    final a = _scaleAnim;
    if (a != null) _scale = a.value;
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant PlayPulseButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying == widget.isPlaying) return;
    if (widget.isPlaying) {
      _runPlayOn();
    } else {
      _runPlayOff();
    }
  }

  Future<void> _runPlayOn() async {
    _scaleCtrl.stop();
    _scaleCtrl.duration = const Duration(milliseconds: 350);
    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.70, end: 1.12), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.12, end: 1.00), weight: 40),
    ]).animate(CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOutCubic));
    _glowCtrl.forward(from: 0);
    await _scaleCtrl.forward(from: 0);
    _scale = 1.0;
    if (mounted) setState(() {});
  }

  Future<void> _runPlayOff() async {
    _scaleCtrl.stop();
    _scaleCtrl.duration = const Duration(milliseconds: 250);
    _scaleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.00, end: 1.08), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 0.92), weight: 70),
    ]).animate(CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut));
    await _scaleCtrl.forward(from: 0);
    _scaleCtrl.duration = const Duration(milliseconds: 120);
    _scaleAnim = Tween<double>(begin: 0.92, end: 1.0).animate(
      CurvedAnimation(parent: _scaleCtrl, curve: Curves.easeOut),
    );
    await _scaleCtrl.forward(from: 0);
    _scale = 1.0;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _scaleCtrl.removeListener(_onScaleTick);
    _scaleCtrl.dispose();
    _glowCtrl.dispose();
    _pressCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AppColors.accentOf(context);
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    final disabled = !widget.enabled || widget.onPressed == null;
    final bg = disabled ? AppColors.fill2(context) : accent;
    final fg = disabled ? AppColors.mutedText(context) : onAccent;

    final pressT = _pressCtrl.value;
    final displayScale = (1.0 - 0.18 * pressT) * _scale;

    // glow: 0→max at 60%, then fade
    final gT = _glowCtrl.value;
    final gPeak = gT < 0.6 ? (gT / 0.6) : (1 - (gT - 0.6) / 0.4);
    final glowR = (widget.mini ? 11.0 : 14.0) * gPeak;
    final glowA = 0.28 * gPeak;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: disabled ? null : (_) => _pressCtrl.forward(),
      onTapUp: disabled
          ? null
          : (_) {
              _pressCtrl.reverse();
              widget.onPressed?.call();
            },
      onTapCancel: disabled ? null : () => _pressCtrl.reverse(),
      child: Transform.scale(
        scale: displayScale,
        child: Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
            boxShadow: [
              if (glowA > 0.02)
                BoxShadow(
                  color: accent.withValues(alpha: glowA),
                  blurRadius: glowR * 1.4,
                  spreadRadius: glowR * 0.5,
                )
              else if (!disabled)
                BoxShadow(
                  color: accent.withAlpha(48),
                  blurRadius: widget.mini ? 8 : 14,
                  offset: const Offset(0, 3),
                ),
            ],
          ),
          child: Icon(
            widget.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
            size: widget.iconSize,
            color: fg,
          ),
        ),
      ),
    );
  }
}
