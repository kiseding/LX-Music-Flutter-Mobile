import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

enum AppNotificationType { info, success, error }

class AppNotification {
  const AppNotification({
    required this.message,
    this.type = AppNotificationType.info,
    this.duration = const Duration(milliseconds: 2600),
  });

  final String message;
  final AppNotificationType type;
  final Duration duration;
}

bool showAppNotification(
  String message, {
  AppNotificationType type = AppNotificationType.info,
  Duration? duration,
}) {
  return AppNotificationHost.show(
    AppNotification(
      message: message,
      type: type,
      duration: duration ?? const Duration(milliseconds: 2600),
    ),
  );
}

class AppNotificationHost extends StatefulWidget {
  const AppNotificationHost({super.key, required this.child});

  final Widget child;

  static _AppNotificationHostState? _state;

  static bool show(AppNotification notification) {
    return _state?.show(notification) ?? false;
  }

  @override
  State<AppNotificationHost> createState() => _AppNotificationHostState();
}

class _AppNotificationHostState extends State<AppNotificationHost>
    with SingleTickerProviderStateMixin {
  final List<AppNotification> _queue = [];
  AppNotification? _current;
  late final AnimationController _controller;
  late final Animation<Offset> _slideAnimation;
  late final Animation<double> _fadeAnimation;
  Timer? _hideTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    AppNotificationHost._state = this;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 240),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, -1.15),
      end: Offset.zero,
    ).animate(curve);
    _fadeAnimation = Tween<double>(begin: 0, end: 1).animate(curve);
  }

  @override
  void dispose() {
    AppNotificationHost._state = null;
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  bool show(AppNotification notification) {
    _hideTimer?.cancel();
    if (_current == null && !_dismissing) {
      _showNow(notification);
    } else {
      _queue.add(notification);
    }
    return true;
  }

  void _showNow(AppNotification notification) {
    _dismissing = false;
    setState(() => _current = notification);
    _controller.forward(from: 0);
    _hideTimer = Timer(
      notification.duration + const Duration(milliseconds: 160),
      _dismissCurrent,
    );
  }

  void _dismissCurrent() {
    if (_current == null || _dismissing) return;
    _dismissing = true;
    _hideTimer?.cancel();
    _controller.reverse().whenComplete(() {
      if (!mounted) return;
      setState(() => _current = null);
      _dismissing = false;
      if (_queue.isNotEmpty) {
        _showNow(_queue.removeAt(0));
      }
    });
  }

  void _handleTap() => _dismissCurrent();

  @override
  Widget build(BuildContext context) {
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        if (_current != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: Center(
                child: GestureDetector(
                  onTap: _handleTap,
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: _AppNotificationBanner(notification: _current!),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _AppNotificationBanner extends StatelessWidget {
  const _AppNotificationBanner({required this.notification});

  final AppNotification notification;

  @override
  Widget build(BuildContext context) {
    final accent = switch (notification.type) {
      AppNotificationType.info => AppColors.info,
      AppNotificationType.success => AppColors.success,
      AppNotificationType.error => AppColors.error,
    };
    final icon = switch (notification.type) {
      AppNotificationType.info => Icons.info_outline_rounded,
      AppNotificationType.success => Icons.check_circle_outline_rounded,
      AppNotificationType.error => Icons.error_outline_rounded,
    };
    final dark = AppColors.isDark(context);
    final baseColor = dark ? const Color(0xFF1C1C1E) : Colors.white;
    final shadowColor = Colors.black.withValues(alpha: dark ? 0.42 : 0.16);

    return Container(
      margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      constraints: const BoxConstraints(maxWidth: 380),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                accent.withValues(alpha: dark ? 0.10 : 0.06),
                baseColor.withValues(alpha: dark ? 0.86 : 0.92),
              ),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 15, color: accent),
                ),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(
                    notification.message,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.onScaffold(context),
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      height: 1.25,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
