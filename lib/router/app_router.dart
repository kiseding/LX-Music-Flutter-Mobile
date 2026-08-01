import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../features/home/presentation/home_screen.dart';
import '../features/home/presentation/main_scaffold.dart';
import '../features/player/presentation/player_screen.dart';
import '../features/search/presentation/search_screen.dart';
import '../features/playlist/presentation/playlist_screen.dart';
import '../features/playlist/presentation/playlist_detail_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/download/presentation/download_screen.dart';
import '../features/custom_source/presentation/custom_source_screen.dart';
import '../features/leaderboard/presentation/leaderboard_screen.dart';
import '../features/sync/presentation/sync_screen.dart';
import '../features/stats/presentation/stats_screen.dart';
import '../features/playlist/presentation/duplicate_screen.dart';
import '../features/recommend/presentation/recommendation_screen.dart';

final GlobalKey<NavigatorState> _rootNavigatorKey = GlobalKey<NavigatorState>();

final appRouter = GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/',
  routes: [
    StatefulShellRoute(
      builder: (context, state, navigationShell) {
        return MainScaffold(navigationShell: navigationShell);
      },
      navigatorContainerBuilder: (context, navigationShell, children) {
        return SwipeBranchContainer(
          currentIndex: navigationShell.currentIndex,
          onSelect: (i) => navigationShell.goBranch(i),
          children: children,
        );
      },
      branches: [
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, state) => const HomeScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/search',
              builder: (context, state) => const SearchScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/playlist',
              builder: (context, state) => const PlaylistScreen(),
              routes: [
                GoRoute(
                  name: 'playlistDetail',
                  path: 'detail/:playlistId',
                  parentNavigatorKey: _rootNavigatorKey,
                  builder: (context, state) => PlaylistDetailScreen(
                    playlistId: state.pathParameters['playlistId']!,
                    focusSongId: state.uri.queryParameters['focusSongId'],
                  ),
                ),
              ],
            ),
          ],
        ),
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: '/settings',
              builder: (context, state) => const SettingsScreen(),
            ),
          ],
        ),
      ],
    ),
    GoRoute(
      path: '/player',
      parentNavigatorKey: _rootNavigatorKey,
      // opaque:false 让下拉关闭时透出打开前的界面
      pageBuilder: (context, state) => CustomTransitionPage<void>(
        key: state.pageKey,
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.transparent,
        transitionDuration: const Duration(milliseconds: 300),
        reverseTransitionDuration: const Duration(milliseconds: 240),
        child: const PlayerScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic,
          );
          return SlideTransition(
            position: Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
                .animate(curved),
            child: child,
          );
        },
      ),
    ),
    GoRoute(
      path: '/download',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const DownloadScreen(),
    ),
    GoRoute(
      path: '/custom-source',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const CustomSourceScreen(),
    ),
    GoRoute(
      path: '/leaderboard',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const LeaderboardScreen(),
    ),
    GoRoute(
      path: '/leaderboard/detail',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) {
        final id = state.uri.queryParameters['id'] ?? '';
        final name = state.uri.queryParameters['name'] ?? '';
        return LeaderboardDetailScreenById(id: id, name: name);
      },
    ),
    GoRoute(
      path: '/sync',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const SyncScreen(),
    ),
    GoRoute(
      path: '/stats',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const StatsScreen(),
    ),
    GoRoute(
      path: '/duplicates',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const DuplicateScreen(),
    ),
    GoRoute(
      path: '/recommend',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const RecommendationScreen(),
    ),
  ],
);
