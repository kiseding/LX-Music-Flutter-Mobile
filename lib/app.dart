import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_music_flutter/core/theme/app_theme.dart';
import 'package:lx_music_flutter/core/theme/app_colors.dart';
import 'package:lx_music_flutter/router/app_router.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

class LxMusicApp extends ConsumerWidget {
  const LxMusicApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    ref.watch(recentPlayRecorderProvider);

    ref.listen<String?>(playerMessageProvider, (previous, next) {
      if (next != null) {
        final messenger = ScaffoldMessenger.maybeOf(context);
        if (messenger != null) {
          messenger.showSnackBar(
            SnackBar(
              content: Text(next),
              backgroundColor: AppColors.error,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 3),
            ),
          );
        }
        Future.microtask(() {
          ref.read(playerMessageProvider.notifier).state = null;
        });
      }
    });

    return MaterialApp.router(
      title: 'LX Music',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme(),
      darkTheme: AppTheme.darkTheme(),
      themeMode: themeMode,
      routerConfig: appRouter,
    );
  }
}
