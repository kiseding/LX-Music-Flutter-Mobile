import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 按下缩放动效包装器，用于主要可点击控件。
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final Duration duration;
  final BorderRadius? borderRadius;
  final String? semanticLabel;
  final bool? selected;
  final String? tooltip;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.92,
    this.duration = const Duration(milliseconds: 110),
    this.borderRadius,
    this.semanticLabel,
    this.selected,
    this.tooltip,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;
  final FocusNode _focusNode = FocusNode();

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onActivate = widget.onTap;
    final interactiveChild = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: onActivate == null
          ? null
          : (_) {
              _focusNode.requestFocus();
              _setPressed(true);
            },
      onTapUp: onActivate == null
          ? null
          : (_) {
              _setPressed(false);
              onActivate.call();
            },
      onTapCancel: onActivate == null ? null : () => _setPressed(false),
      child: AnimatedScale(
        scale: _pressed ? widget.scale : 1,
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        child: AnimatedOpacity(
          opacity: _pressed ? 0.88 : 1,
          duration: widget.duration,
          child: widget.borderRadius == null
              ? widget.child
              : ClipRRect(
                  borderRadius: widget.borderRadius!, child: widget.child),
        ),
      ),
    );

    return Semantics(
      label: widget.semanticLabel,
      button: true,
      enabled: onActivate != null,
      selected: widget.selected,
      tooltip: widget.tooltip,
      onTap: onActivate,
      child: FocusableActionDetector(
        focusNode: _focusNode,
        enabled: onActivate != null,
        mouseCursor: onActivate == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              onActivate?.call();
              return null;
            },
          ),
        },
        child: ExcludeSemantics(child: interactiveChild),
      ),
    );
  }
}
