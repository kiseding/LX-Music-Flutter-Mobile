import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_music_flutter/core/theme/app_theme.dart';
import 'package:lx_music_flutter/core/widgets/app_notification.dart';
import 'package:lx_music_flutter/router/app_router.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';
import 'package:lx_music_flutter/features/stats/presentation/play_history_provider.dart';

class PlayerMessageListener extends ConsumerStatefulWidget {
  const PlayerMessageListener({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<PlayerMessageListener> createState() =>
      _PlayerMessageListenerState();
}

class _PlayerMessageListenerState extends ConsumerState<PlayerMessageListener> {
  @override
  void initState() {
    super.initState();
    ref.listenManual<String?>(
      playerMessageProvider,
      (previous, next) => _deliver(next),
      fireImmediately: true,
    );
  }

  void _deliver(String? next) {
    if (next == null) return;
    final delivered = showAppNotification(
      next,
      type: AppNotificationType.error,
      duration: const Duration(seconds: 3),
    );
    if (delivered && ref.read(playerMessageProvider) == next) {
      ref.read(playerMessageProvider.notifier).state = null;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class LxMusicApp extends ConsumerWidget {
  const LxMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    ref.watch(playbackSessionRecorderProvider);
    ref.watch(recentPlayRecorderProvider);
    ref.watch(playHistoryRecorderProvider);

    return MaterialApp.router(
      title: 'LX Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode,
      routerConfig: appRouter,
      builder: (context, child) => AppNotificationHost(
        child: PlayerMessageListener(
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
  }
}
