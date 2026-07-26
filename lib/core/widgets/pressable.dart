import 'package:flutter/material.dart';

/// 按下缩放动效包装器，用于主要可点击控件。
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final Duration duration;
  final BorderRadius? borderRadius;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.92,
    this.duration = const Duration(milliseconds: 110),
    this.borderRadius,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _setPressed(true),
      onTapUp: widget.onTap == null
          ? null
          : (_) {
              _setPressed(false);
              widget.onTap?.call();
            },
      onTapCancel: widget.onTap == null ? null : () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.88 : 1,
          duration: widget.duration,
          child: widget.borderRadius == null
              ? widget.child
              : ClipRRect(borderRadius: widget.borderRadius!, child: widget.child),
        ),
      ),
    );
  }
}
