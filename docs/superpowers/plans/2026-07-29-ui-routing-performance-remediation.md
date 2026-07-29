# UI, Routing, And Performance Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make player and playlist navigation restorable and idempotent while limiting high-frequency rebuilds, assigning gestures unambiguously, keeping text-entry UI visible, and bounding artwork transition work.

**Architecture:** Keep routing state in `go_router` URLs, keep transient UI state inside the owning widget, and consume authoritative Riverpod state through the narrowest possible widgets. Playlist and lyric UI consume revision/request-generation contracts delivered by the persistence/state remediation; this plan does not implement storage, cache, network, or service migration behavior.

**Tech Stack:** Flutter 3.x, Dart 3.2+, Riverpod 2.6.1, go_router 14.8.1, flutter_test

## Global Constraints

- Keep the Darwin precise duration and timing option for FLAC playback.
- Do not reintroduce fixed seek delays, optimistic settle polling, or source reloads as timing compensation.
- Preserve imported custom-source compatibility with public HTTPS services.
- Preserve existing playlists and recent-play history through storage migration.
- Implement after the audio/queue contract and persistence/reactive-state contract, in that order.
- Do not edit cache, network, download, storage, or playlist persistence implementations in this workstream.
- Do not add a second playback position clock, play-mode model, playlist revision counter, or lyric request lifecycle.
- Use behavior-focused widget/provider tests; source-text assertions are allowed only for negative architectural invariants that Flutter cannot observe directly.
- Run focused tests after every task and `flutter analyze` plus `flutter test` after integration.
- Do not commit during execution of this plan unless the user separately authorizes commits.

## Required External Contracts

These contracts are prerequisites owned by future persistence/state remediation. Do not create substitutes in this plan.

```dart
// lib/features/playlist/presentation/playlist_provider.dart
final playlistRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).revisions;
});

final playlistByIdProvider = Provider.family<Playlist?, String>((ref, id) {
  ref.watch(playlistRevisionProvider);
  return ref.watch(playlistServiceProvider).getPlaylist(id);
});

// lib/features/lyric/presentation/lyric_provider.dart
class LyricNotifier extends StateNotifier<Lyrics> {
  Future<void> loadLyric(MusicItem music);
}
```

The playlist contract must emit once after every successful mutation and restore system playlists before UI consumption. The lyric contract must reject stale result/error publication by request generation and target ID. If either contract is absent when execution starts, skip only the dependent integration assertions, report the task blocked, and resume it after the owning remediation lands; do not edit `playlist_service.dart`, `storage_service.dart`, `lyric_service.dart`, or network code here.

## File Structure

- Modify `lib/router/app_router.dart`: expose a testable router factory and address playlist details by ID.
- Modify `lib/features/player/presentation/widgets/mini_player.dart`: serialize player opening and localize mini-player position watches.
- Modify `lib/features/playlist/presentation/playlist_screen.dart`: navigate with playlist and optional focus IDs; make playlist dialogs keyboard-safe.
- Modify `lib/features/playlist/presentation/playlist_detail_screen.dart`: accept an ID, derive current data from the revision-backed provider, and remove transient route ownership.
- Modify `lib/features/playlist/presentation/playlist_picker.dart`: make the create flow keyboard-safe on small screens.
- Modify `lib/features/player/presentation/player_screen.dart`: split high-frequency consumers, constrain dismissal ownership, and use bounded artwork transitions.
- Modify `lib/features/lyric/presentation/lyric_view.dart`: move position consumption into the active timed row and move follow-scroll side effects out of `build`.
- Create focused tests under `test/router/`, `test/features/player/presentation/`, `test/features/playlist/presentation/`, and `test/features/lyric/presentation/`.

## Audit Dispositions

| Severity | Finding | Planned disposition | Evidence |
|---|---|---|---|
| Medium | Repeated mini-player taps stack `/player` routes | `fixed` in Task 1 | Two rapid taps leave one player page and one back action returns to the origin. |
| Medium | Playlist detail depends on transient selected-playlist state | `fixed` in Task 2 | `/playlist/:playlistId` restores directly and shows the requested playlist after router recreation. |
| Medium | Full player and mini-player shells watch the 100 ms position clock | `fixed` in Task 3 | Rebuild counters prove only progress/time/current timed lyric consumers rebuild. |
| Medium | Full lyric list rebuilds and schedules callbacks on position ticks | `fixed` in Task 4 | Inactive row counters remain unchanged within one lyric line; exactly one follow-scroll occurs on line transition. |
| Medium | Parent dismissal competes with page, lyric, and scrub gestures; cancellation can retain offset | `fixed` in Task 5 | Horizontal page drag, lyric drag, and progress drag do not translate the player; cancel resets translation. |
| Medium | Playlist text-entry dialogs/sheets can be obscured on small screens | `fixed` in Task 6 | 320x568 widget tests with a 300 px IME inset keep the focused field and primary action visible. |
| Low | Rapid artwork changes retain multiple outgoing switcher children | `fixed` in Task 7 | Rapid key changes render at most current plus one outgoing artwork child and settle to one. |
| Low | Play mode may be duplicated in UI state | `already-correct` in Task 8 | Existing handler mapping test plus a provider source invariant prove `playModeProvider` derives from `playbackStateProvider`; production code is unchanged. |
| Low | Main branch swipe may steal editable-field focus | `already-correct` in Task 8 | Existing `swipe_ime_focus_test.dart` covers editable hit rejection and non-editable branch swipe. |
| Low | Queue/more sheets need keyboard accommodation | `invalid` for non-editable sheets | The player queue/more sheets contain no text input; SafeArea and bounded height are sufficient. No speculative change. |
| Low | Lyric empty-state retry relies on invalidation | `fixed` in Task 4 | The UI invokes `loadLyric(currentMusic)` directly; stale request ownership remains a prerequisite of the future lyric provider contract. |

---

### Task 1: Idempotent Player Route

**Files:**
- Modify: `lib/router/app_router.dart:16-135`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart:26-31,267-298`
- Create: `test/router/player_route_test.dart`

**Interfaces:**
- Produces: `GoRouter createAppRouter({String initialLocation = '/'})` and one `_openPlayer()` transaction per `MiniPlayer` instance.
- Preserves: `/player` as a root-navigator transparent `CustomTransitionPage<void>` and normal back dismissal to the route beneath it.

- [ ] **Step 1: Write the failing rapid-tap routing test**

```dart
testWidgets('two rapid mini-player taps create one player route', (tester) async {
  final router = createAppRouter();
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: playerUiTestOverrides(song: testSong),
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byKey(const Key('mini-player-open')));
  await tester.tap(find.byKey(const Key('mini-player-open')));
  await tester.pumpAndSettle();

  expect(find.byType(PlayerScreen), findsOneWidget);
  expect(
    router.routerDelegate.currentConfiguration.matches
        .where((match) => match.matchedLocation == '/player'),
    hasLength(1),
  );

  router.pop();
  await tester.pumpAndSettle();
  expect(find.byType(PlayerScreen), findsNothing);
  expect(router.routerDelegate.currentConfiguration.uri.path, '/');
});
```

Add `test/support/player_ui_test_overrides.dart` only if existing providers cannot be overridden inline. Its exact output is `List<Override> playerUiTestOverrides({required MusicItem song})`, supplying stable media, playback, duration, position, lyrics, and a no-op `PlayerService` facade for widget tests.

- [ ] **Step 2: Run the test and verify RED**

Run: `flutter test test/router/player_route_test.dart`

Expected: FAIL because `createAppRouter`, `mini-player-open`, and the opening guard do not exist; the current two `context.push('/player')` callbacks can enqueue duplicate pages.

- [ ] **Step 3: Expose the router factory without changing production routing**

```dart
GoRouter createAppRouter({String initialLocation = '/'}) {
  final rootNavigatorKey = GlobalKey<NavigatorState>();
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    routes: buildAppRoutes(rootNavigatorKey),
  );
}

final appRouter = createAppRouter();
```

Define `List<RouteBase> buildAppRoutes(GlobalKey<NavigatorState> rootNavigatorKey)` by moving every existing `RouteBase` entry from the `GoRouter.routes` argument into its return value and replacing each `_rootNavigatorKey` reference with the parameter. Do not change transition duration, opacity, barrier behavior, shell branches, or unrelated paths.

- [ ] **Step 4: Serialize mini-player opening and use one callback**

```dart
bool _openingPlayer = false;

Future<void> _openPlayer() async {
  if (_openingPlayer || !mounted) return;
  final router = GoRouter.of(context);
  if (router.routerDelegate.currentConfiguration.uri.path == '/player') return;
  _openingPlayer = true;
  try {
    await router.push<void>('/player');
  } finally {
    _openingPlayer = false;
  }
}
```

Assign `key: const Key('mini-player-open')` to the single `Expanded` tap region containing artwork and title, remove the two separate route callbacks, and leave scrub and playback controls outside that region.

- [ ] **Step 5: Verify GREEN and route semantics**

Run: `flutter test test/router/player_route_test.dart`

Expected: PASS; two taps yield one match and one pop restores `/`.

Run: `flutter analyze lib/router/app_router.dart lib/features/player/presentation/widgets/mini_player.dart test/router/player_route_test.dart`

Expected: no issues.

### Task 2: ID-Addressed Playlist Detail And Deep-Link Restoration

**Files:**
- Modify: `lib/router/app_router.dart:52-61`
- Modify: `lib/features/playlist/presentation/playlist_screen.dart:285-297`
- Modify: `lib/features/playlist/presentation/playlist_detail_screen.dart:10-84`
- Create: `test/router/playlist_detail_route_test.dart`
- Create: `test/features/playlist/presentation/playlist_detail_revision_test.dart`

**Interfaces:**
- Consumes: external `playlistByIdProvider(String id)` revision-backed contract.
- Produces: `PlaylistDetailScreen({required String playlistId, String? focusSongId})` and canonical `/playlist/:playlistId?focusSongId=:songId` URLs.
- Removes from route ownership: `currentPlaylistProvider` and `playlistFocusSongIdProvider`; remove them only after repository search confirms no non-routing owner remains.

- [ ] **Step 1: Write failing direct-location and restoration tests**

```dart
testWidgets('playlist deep link restores requested ID', (tester) async {
  final service = FakePlaylistService([playlist(id: 'road', name: 'Road')]);
  final router = createAppRouter(
    initialLocation: '/playlist/road?focusSongId=song-2',
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [playlistServiceProvider.overrideWithValue(service)],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();

  expect(find.text('Road（2首）'), findsOneWidget);
  expect(find.byKey(const ValueKey('playlist-focus-song-2')), findsOneWidget);
});

testWidgets('unknown playlist ID renders stable not-found state', (tester) async {
  final router = createAppRouter(initialLocation: '/playlist/missing');
  addTearDown(router.dispose);
  await pumpPlaylistRouter(tester, router, FakePlaylistService(const []));
  expect(find.text('歌单不存在'), findsOneWidget);
  expect(find.byType(PlaylistDetailScreen), findsOneWidget);
});
```

Use a fake service implementing the same public lookup/revision surface as the prerequisite contract; do not initialize `StorageService` in these tests.

- [ ] **Step 2: Run route tests and verify RED**

Run: `flutter test test/router/playlist_detail_route_test.dart`

Expected: FAIL because `/playlist/road` is unmatched and detail construction has no ID.

- [ ] **Step 3: Make the route and call sites URL-addressed**

```dart
GoRoute(
  path: ':playlistId',
  parentNavigatorKey: rootNavigatorKey,
  builder: (context, state) => PlaylistDetailScreen(
    playlistId: state.pathParameters['playlistId']!,
    focusSongId: state.uri.queryParameters['focusSongId'],
  ),
),
```

```dart
void _openPlaylist(
  BuildContext context,
  Playlist playlist, {
  String? focusSongId,
}) {
  final id = Uri.encodeComponent(playlist.id);
  final query = focusSongId == null
      ? ''
      : '?focusSongId=${Uri.encodeQueryComponent(focusSongId)}';
  context.push('/playlist/$id$query');
}
```

Remove writes to transient selected/focus providers. The detail screen watches `playlistByIdProvider(widget.playlistId)` and uses `widget.focusSongId` for one-time scrolling/highlighting.

- [ ] **Step 4: Write the failing revision-consumer test**

```dart
testWidgets('detail refreshes from service revision without manual counter',
    (tester) async {
  final service = FakeRevisionPlaylistService(playlist(id: 'road', name: 'Road'));
  await pumpDetail(tester, service, const PlaylistDetailScreen(playlistId: 'road'));
  expect(find.text('Road（0首）'), findsOneWidget);

  service.replace(playlist(id: 'road', name: 'Road Updated', songs: [testSong]));
  await tester.pump();

  expect(find.text('Road Updated（1首）'), findsOneWidget);
  expect(find.text(testSong.name), findsOneWidget);
});
```

- [ ] **Step 5: Remove manual revision and stale-object reads from detail UI**

Replace every `playlistVersionProvider.notifier.state++` in `playlist_detail_screen.dart` with the service mutation only. After each awaited mutation, rely on the external revision stream. Keep `_reorderedSongs` synchronized in `didUpdateWidget`/a `ref.listen` for the addressed playlist only when not editing; never reset an in-progress reorder from an unrelated revision.

- [ ] **Step 6: Verify route restoration and reactive detail**

Run: `flutter test test/router/playlist_detail_route_test.dart test/features/playlist/presentation/playlist_detail_revision_test.dart`

Expected: PASS.

Run: `flutter analyze lib/router/app_router.dart lib/features/playlist/presentation/playlist_screen.dart lib/features/playlist/presentation/playlist_detail_screen.dart`

Expected: no issues and no references to `currentPlaylistProvider` or `playlistFocusSongIdProvider` remain.

### Task 3: Localize High-Frequency Position Watches

**Files:**
- Modify: `lib/features/player/presentation/player_screen.dart:48-53,145-180,420-658`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart:38-63,103-260`
- Create: `test/features/player/presentation/player_rebuild_scope_test.dart`

**Interfaces:**
- Produces: `PlayerProgressSection`, `CurrentLyricLine`, `PlayerPlaybackControls`, and `MiniPlayerProgress` as narrow `ConsumerWidget`/`ConsumerStatefulWidget` boundaries.
- Consumes: the existing authoritative `playerPositionProvider`; no derived timer or local clock is allowed.

- [ ] **Step 1: Write failing rebuild-boundary tests**

```dart
testWidgets('position ticks do not rebuild full player shell', (tester) async {
  final position = PositionNotifier(null);
  addTearDown(position.dispose);
  var shellBuilds = 0;
  var progressBuilds = 0;

  await pumpPlayerHarness(
    tester,
    position: position,
    shellProbe: () => shellBuilds++,
    progressProbe: () => progressBuilds++,
  );
  final initialShell = shellBuilds;
  final initialProgress = progressBuilds;

  position.jumpTo(const Duration(seconds: 1));
  await tester.pump();

  expect(shellBuilds, initialShell);
  expect(progressBuilds, greaterThan(initialProgress));
});

testWidgets('mini-player position tick rebuilds progress but not chrome',
    (tester) async {
  final counts = await pumpMiniPlayerRebuildHarness(tester);
  counts.position.jumpTo(const Duration(seconds: 2));
  await tester.pump();
  expect(counts.chrome, 1);
  expect(counts.progress, 2);
});
```

Expose optional `@visibleForTesting VoidCallback? onBuild` only on the extracted shell/progress widgets; invoke it at the start of `build`. Do not add production global counters or debug prints.

- [ ] **Step 2: Run and verify RED**

Run: `flutter test test/features/player/presentation/player_rebuild_scope_test.dart`

Expected: FAIL because both root `build` methods watch position.

- [ ] **Step 3: Split full-player consumers**

At the `PlayerScreen` root, retain only state needed to select the empty/content shell and page identity. Move watches as follows:

```dart
class PlayerProgressSection extends ConsumerStatefulWidget {
  const PlayerProgressSection({super.key, this.onBuild});
  final VoidCallback? onBuild;
  // Owns scrub preview state and watches position + duration only.
}

class CurrentLyricLine extends ConsumerWidget {
  const CurrentLyricLine({super.key});
  // Watches lyrics + currentLineIndex only.
}

class PlayerPlaybackControls extends ConsumerWidget {
  const PlayerPlaybackControls({super.key});
  // Watches playing + handler-derived playMode only.
}
```

Read `playerServiceProvider` in callbacks (`ref.read`) instead of watching it. Artwork/song metadata watch only `currentMusicProvider`; quality watches only `currentMediaItemProvider`.

- [ ] **Step 4: Split mini-player progress and lyric subtitle**

`MiniPlayerProgress` owns scrub preview state and watches position/duration. The mini-player chrome watches current song and playback state. A `MiniPlayerLyricSubtitle` watches `currentLyricProvider` and `currentLineIndexProvider`, so it rebuilds once per line rather than every position tick.

- [ ] **Step 5: Verify GREEN and architectural invariant**

Run: `flutter test test/features/player/presentation/player_rebuild_scope_test.dart test/features/player/presentation/scrub_coordinator_test.dart`

Expected: PASS; existing scrub behavior remains green.

Add this narrow source invariant to the rebuild test:

```dart
expect(playerScreenRootBuild, isNot(contains('watch(playerPositionProvider)')));
expect(miniPlayerRootBuild, isNot(contains('watch(positionProvider)')));
```

Run: `flutter analyze lib/features/player/presentation/player_screen.dart lib/features/player/presentation/widgets/mini_player.dart`

Expected: no issues.

### Task 4: Isolate Lyric Ticks And Scroll Side Effects

**Files:**
- Modify: `lib/features/lyric/presentation/lyric_view.dart:19-224,287-399`
- Create: `test/features/lyric/presentation/lyric_view_performance_test.dart`
- Create: `test/features/lyric/presentation/lyric_retry_test.dart`

**Interfaces:**
- Consumes: `currentLineIndexProvider`, authoritative `playerPositionProvider`, and external generation-safe `LyricNotifier.loadLyric(MusicItem)`.
- Produces: `LyricLineTile` where only the active word-timed line watches position; one scroll-follow action per line-index transition.

- [ ] **Step 1: Write failing inactive-row and scroll-follow tests**

```dart
testWidgets('position tick rebuilds active timed row but not inactive rows',
    (tester) async {
  final counts = <int, int>{};
  final harness = await pumpTimedLyrics(
    tester,
    onLineBuild: (index) => counts[index] = (counts[index] ?? 0) + 1,
  );
  final inactiveBefore = counts[1];

  harness.position.jumpTo(const Duration(milliseconds: 250));
  await tester.pump();

  expect(counts[0], greaterThan(1));
  expect(counts[1], inactiveBefore);
});

testWidgets('line transition schedules one follow scroll', (tester) async {
  final observer = TestScrollObserver();
  final harness = await pumpLyrics(tester, scrollObserver: observer);
  harness.position.jumpTo(const Duration(seconds: 3));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 220));
  expect(observer.followRequests, 1);
});
```

- [ ] **Step 2: Run and verify RED**

Run: `flutter test test/features/lyric/presentation/lyric_view_performance_test.dart`

Expected: FAIL because `LyricView.build` watches position and schedules post-frame callbacks from `build`.

- [ ] **Step 3: Move follow behavior into provider listeners**

Use `ref.listenManual` subscriptions stored in state and closed in `dispose`:

```dart
late final ProviderSubscription<int> _lineSubscription;
late final ProviderSubscription<Lyrics> _lyricsSubscription;

@override
void initState() {
  super.initState();
  _lineSubscription = ref.listenManual<int>(
    currentLineIndexProvider,
    (previous, next) {
      if (next >= 0 && next != previous && !_isUserScrolling) {
        _scheduleScrollTo(next);
      }
    },
  );
  _lyricsSubscription = ref.listenManual<Lyrics>(
    currentLyricProvider,
    (previous, next) {
      if (!identical(previous, next)) _resetAndFollow();
    },
  );
}

@override
void dispose() {
  _lineSubscription.close();
  _lyricsSubscription.close();
  _resumeFollowTimer?.cancel();
  _scrollController.dispose();
  super.dispose();
}
```

`_scheduleScrollTo` must coalesce to one pending post-frame callback by storing the latest requested index and a `_scrollScheduled` flag. Cancel the resume timer and reset user-scroll state when lyrics identity changes. Remove all `addPostFrameCallback` branches from `build`.

- [ ] **Step 4: Isolate active KTV position consumption**

```dart
class LyricLineTile extends ConsumerWidget {
  const LyricLineTile({
    super.key,
    required this.line,
    required this.index,
    required this.isCurrent,
    required this.lyrics,
    this.onBuild,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    onBuild?.call(index);
    if (isCurrent && line.hasWordTiming) {
      final position = ref.watch(playerPositionProvider);
      return KtvLyricLine(
        line: line,
        lineIndex: index,
        lyrics: lyrics,
        position: position,
      );
    }
    return Text(line.text, maxLines: 1, overflow: TextOverflow.ellipsis);
  }
}
```

Preserve existing colors, typography, translation, tap-to-seek, item extent, and five-second resume-follow behavior.

- [ ] **Step 5: Write the failing explicit retry-command test**

```dart
testWidgets('search lyrics invokes load command for current song',
    (tester) async {
  final notifier = RecordingLyricNotifier();
  await pumpEmptyLyrics(tester, notifier: notifier, song: testSong);
  await tester.tap(find.text('搜索歌词'));
  await tester.pump();
  expect(notifier.loadedIds, [testSong.id]);
});
```

Replace `ref.invalidate(currentLyricProvider)` with:

```dart
await ref.read(currentLyricProvider.notifier).loadLyric(music);
```

Do not add request IDs in the view or edit `lyric_service.dart`; stale-result rejection belongs to the prerequisite notifier revision.

- [ ] **Step 6: Verify lyric behavior and performance**

Run: `flutter test test/features/lyric/presentation/lyric_view_performance_test.dart test/features/lyric/presentation/lyric_retry_test.dart test/features/lyric/data/lyric_parser_test.dart`

Expected: PASS.

Run: `flutter analyze lib/features/lyric/presentation/lyric_view.dart`

Expected: no issues and no root `ref.watch(playerPositionProvider)` remains in `LyricView.build`.

### Task 5: Gesture Ownership And Dismissal Reset

**Files:**
- Modify: `lib/features/player/presentation/player_screen.dart:25-34,96-189,513-658`
- Create: `test/features/player/presentation/player_gesture_ownership_test.dart`

**Interfaces:**
- Produces: an artwork-page dismissal region that accepts downward vertical intent only after touch slop; lyric page and progress hit regions never own dismissal.
- Preserves: horizontal `PageView`, vertical lyric scrolling, horizontal scrub, velocity/40% dismissal thresholds, and transparent route reveal.

- [ ] **Step 1: Write failing ownership tests**

```dart
testWidgets('progress drag seeks without translating player', (tester) async {
  await pumpPlayer(tester);
  await tester.drag(find.byKey(const Key('player-progress')), const Offset(140, 4));
  await tester.pump();
  expect(playerTranslationY(tester), 0);
});

testWidgets('lyric vertical drag scrolls without dismiss translation',
    (tester) async {
  await pumpPlayerOnLyricsPage(tester);
  final before = lyricScrollOffset(tester);
  await tester.drag(find.byKey(const Key('lyric-list')), const Offset(2, -120));
  await tester.pump();
  expect(lyricScrollOffset(tester), greaterThan(before));
  expect(playerTranslationY(tester), 0);
});

testWidgets('cancelled downward dismissal resets visual offset',
    (tester) async {
  await pumpPlayer(tester);
  final gesture = await tester.startGesture(tester.getCenter(find.byKey(const Key('player-dismiss-region'))));
  await gesture.moveBy(const Offset(0, 90));
  await tester.pump();
  expect(playerTranslationY(tester), greaterThan(0));
  await gesture.cancel();
  await tester.pumpAndSettle();
  expect(playerTranslationY(tester), 0);
});
```

Also test a horizontal 120 px drag on the dismissal region changes `PageView` page and leaves translation at zero.

- [ ] **Step 2: Run and verify RED**

Run: `flutter test test/features/player/presentation/player_gesture_ownership_test.dart`

Expected: FAIL because the parent vertical detector wraps lyric and scrub controls and has no cancel reset.

- [ ] **Step 3: Restrict and threshold dismissal ownership**

Remove the full-screen vertical `GestureDetector`. Add `key: const Key('player-dismiss-region')` around the app bar/artwork portion of page zero only. Track pending delta until vertical intent exceeds `kTouchSlop` and dominates horizontal movement:

```dart
void _updateDismissIntent(DragUpdateDetails details) {
  _pendingDrag += details.delta;
  if (!_draggingDown) {
    if (_pendingDrag.distance < kTouchSlop) return;
    if (_pendingDrag.dy <= 0 || _pendingDrag.dy.abs() <= _pendingDrag.dx.abs()) {
      _resetDismiss();
      return;
    }
    _draggingDown = true;
  }
  setState(() => _dragOffset = (_dragOffset + details.delta.dy).clamp(0, screenH));
}

void _resetDismiss() {
  if (!mounted) return;
  setState(() {
    _pendingDrag = Offset.zero;
    _draggingDown = false;
    _dragOffset = 0;
  });
}
```

Wire `onVerticalDragCancel: _resetDismiss`; call `_resetDismiss` after every failed end. On successful end, await `Navigator.maybePop` and reset if it returns `false`. Add stable keys `player-surface`, `player-progress`, and `lyric-list` for behavior tests.

- [ ] **Step 4: Verify gesture matrix**

Run: `flutter test test/features/player/presentation/player_gesture_ownership_test.dart test/features/home/swipe_ime_focus_test.dart test/features/player/presentation/scrub_coordinator_test.dart`

Expected: PASS; branch swipe and scrub regressions remain green.

Run: `flutter analyze lib/features/player/presentation/player_screen.dart lib/features/lyric/presentation/lyric_view.dart`

Expected: no issues.

### Task 6: Keyboard-Safe Playlist Dialogs And Sheets

**Files:**
- Modify: `lib/features/playlist/presentation/playlist_screen.dart:630-785,875-1148`
- Modify: `lib/features/playlist/presentation/playlist_detail_screen.dart:361-412`
- Modify: `lib/features/playlist/presentation/playlist_picker.dart:9-130`
- Create: `test/features/playlist/presentation/playlist_keyboard_insets_test.dart`

**Interfaces:**
- Produces: keyboard-inset-aware create/edit/import dialogs and playlist picker; no business-service changes.
- Preserves: current validation, platform selection, import confirmation, and mutation commands.

- [ ] **Step 1: Write failing small-screen IME tests**

```dart
testWidgets('playlist picker keeps create field and action above IME',
    (tester) async {
  tester.view.physicalSize = const Size(320, 568);
  tester.view.devicePixelRatio = 1;
  tester.view.viewInsets = const FakeViewPadding(bottom: 300);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
  });

  await pumpPlaylistPicker(tester);
  await tester.tap(find.byIcon(Icons.add));
  await tester.pumpAndSettle();

  expect(tester.getBottomRight(find.text('创建')).dy, lessThanOrEqualTo(268));
  expect(tester.takeException(), isNull);
});
```

Repeat the assertion for the import input/`解析歌单` button and create/edit dialog save button. Use `tester.ensureVisible` before geometry assertions only when the UI intentionally scrolls.

- [ ] **Step 2: Run and verify RED**

Run: `flutter test test/features/playlist/presentation/playlist_keyboard_insets_test.dart`

Expected: FAIL with obscured geometry or overflow in at least the picker/current fixed-height dialog.

- [ ] **Step 3: Make picker and dialogs inset-aware**

For the picker, set `isScrollControlled: true`, `useSafeArea: true`, and wrap content as follows:

```dart
AnimatedPadding(
  duration: const Duration(milliseconds: 180),
  curve: Curves.easeOut,
  padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
  child: ConstrainedBox(
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * .82,
    ),
    child: _PlaylistPickerContent(song: song),
  ),
)
```

Inside picker content, replace mapped list children with:

```dart
Flexible(
  child: ListView.builder(
    shrinkWrap: true,
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    itemCount: userPlaylists.length,
    itemBuilder: (context, index) {
      final playlist = userPlaylists[index];
      return ListTile(
        leading: Icon(
          playlist.id == 'favorites' ? Icons.favorite : Icons.queue_music,
          color: playlist.id == 'favorites'
              ? AppColors.error
              : AppColors.textSecondary,
        ),
        title: Text(
          playlist.name,
          style: TextStyle(color: AppColors.onScaffold(context)),
        ),
        subtitle: Text(
          '${playlist.songCount} 首',
          style: TextStyle(
            color: AppColors.secondaryText(context),
            fontSize: 12,
          ),
        ),
        onTap: () => _addToPlaylist(playlist.id),
      );
    },
  ),
)
```

For create/edit dialogs, put fields in `SingleChildScrollView` and cap content height using `MediaQuery.sizeOf(ctx).height - MediaQuery.viewInsetsOf(ctx).bottom - 96`.

For import, compute available height from the dialog context and keyboard inset:

```dart
final media = MediaQuery.of(ctx);
final availableHeight = media.size.height - media.viewInsets.bottom - 48;
return AnimatedPadding(
  padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
  duration: const Duration(milliseconds: 180),
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: 440, maxHeight: availableHeight),
    child: importDialogBody,
  ),
);
```

Dispose every locally created `TextEditingController` in a `try/finally` after `await showDialog`; do not move import networking or playlist persistence into a widget helper.

- [ ] **Step 4: Verify all keyboard configurations**

Run: `flutter test test/features/playlist/presentation/playlist_keyboard_insets_test.dart test/features/playlist/presentation/playlist_screen_test.dart`

Expected: PASS at 320x568 with 300 px inset and at 390x844 with zero inset.

Run: `flutter analyze lib/features/playlist/presentation/playlist_screen.dart lib/features/playlist/presentation/playlist_detail_screen.dart lib/features/playlist/presentation/playlist_picker.dart`

Expected: no issues.

### Task 7: Bounded Artwork Switcher

**Files:**
- Modify: `lib/features/player/presentation/player_screen.dart:289-355`
- Create: `lib/features/player/presentation/widgets/bounded_artwork_switcher.dart`
- Create: `test/features/player/presentation/bounded_artwork_switcher_test.dart`

**Interfaces:**
- Produces: `BoundedArtworkSwitcher({required Object childKey, required Widget child, Duration duration = const Duration(milliseconds: 420)})` and public `ArtworkTransitionSlot` wrappers used by the count test.
- Guarantees: during transition, at most one outgoing and one current child are mounted; after settling, only current remains.

- [ ] **Step 1: Write the failing rapid-switch test**

```dart
testWidgets('rapid artwork changes retain at most one outgoing child',
    (tester) async {
  final key = ValueNotifier<int>(0);
  addTearDown(key.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: key,
        builder: (_, value, __) => BoundedArtworkSwitcher(
          childKey: value,
          child: ColoredBox(
            key: ValueKey('artwork-$value'),
            color: Colors.primaries[value % Colors.primaries.length],
          ),
        ),
      ),
    ),
  );

  for (var i = 1; i <= 8; i++) {
    key.value = i;
    await tester.pump(const Duration(milliseconds: 30));
    expect(find.byType(ArtworkTransitionSlot), findsAtMostNWidgets(2));
  }
  await tester.pumpAndSettle();
  expect(find.byType(ArtworkTransitionSlot), findsOneWidget);
  expect(find.byKey(const ValueKey('artwork-8')), findsOneWidget);
});
```

- [ ] **Step 2: Run and verify RED**

Run: `flutter test test/features/player/presentation/bounded_artwork_switcher_test.dart`

Expected: FAIL because `BoundedArtworkSwitcher` does not exist.

- [ ] **Step 3: Implement a two-slot transition**

Use one `AnimationController`, `_current`, and nullable `_outgoing`. On a new key, assign the previous current to outgoing, assign the new current, reset/forward the controller, and discard any older outgoing immediately. Render both slots in a `Stack`; outgoing uses `ReverseAnimation`, current uses the forward animation. On `AnimationStatus.completed`, clear `_outgoing` in `setState`. Preserve the existing fade, 0.92-to-1.0 scale, curves, clipping, shadow, and song-ID key semantics.

The mounted slot wrapper must give sibling slots distinct keys while exposing one countable widget type:

```dart
class ArtworkTransitionSlot extends StatelessWidget {
  const ArtworkTransitionSlot({
    super.key,
    required this.child,
  });

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

ArtworkTransitionSlot(
  key: ValueKey<Object>(slotKey),
  child: keyedArtworkChild,
)
```

Handle `didUpdateWidget` with identical keys as an in-place child update, and dispose the controller.

- [ ] **Step 4: Replace only the artwork transition primitive**

In `_buildArtwork`, replace `AnimatedSwitcher` with:

```dart
BoundedArtworkSwitcher(
  childKey: songId ?? artwork ?? 'empty',
  child: artwork != null && artwork.isNotEmpty
      ? ArtworkImage(
          artwork,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _defaultArtwork(),
        )
      : _defaultArtwork(),
)
```

Do not change artwork URL resolution, `ArtworkImage`, fallback rendering, dimensions, or decoration.

- [ ] **Step 5: Verify bounded behavior**

Run: `flutter test test/features/player/presentation/bounded_artwork_switcher_test.dart test/core/widgets/artwork_image_test.dart`

Expected: PASS; every intermediate frame has one or two slots and settled state has one.

Run: `flutter analyze lib/features/player/presentation/widgets/bounded_artwork_switcher.dart lib/features/player/presentation/player_screen.dart`

Expected: no issues.

### Task 8: Already-Satisfied Proofs, Audit Closure, And Integration Verification

**Files:**
- Modify: `test/core/audio/audio_interruption_policy_test.dart:858-875` only if provider-level proof is absent
- Modify: `test/features/home/swipe_ime_focus_test.dart` only if existing assertions no longer cover the final gesture tree
- Modify: `docs/superpowers/plans/2026-07-29-ui-routing-performance-remediation.md` to record execution evidence when authorized

**Interfaces:**
- Consumes: all prior task outputs and the external playlist/lyric provider contracts.
- Produces: final evidence for every UI audit disposition; no production behavior.

- [ ] **Step 1: Prove handler-derived play mode without production edits**

Keep the existing `playModeFromPlaybackState` assertions. Add only this source invariant if it is not already covered:

```dart
test('play mode provider has no local mutable state', () {
  final source = File(
    'lib/features/player/presentation/player_provider.dart',
  ).readAsStringSync();
  final provider = source.substring(
    source.indexOf('final playModeProvider'),
    source.indexOf('class PositionNotifier'),
  );
  expect(provider, contains('ref.watch(playbackStateProvider)'));
  expect(provider, contains('playModeFromPlaybackState'));
  expect(provider, isNot(contains('StateProvider<PlayMode>')));
  expect(provider, isNot(contains('StateNotifierProvider')));
});
```

Run: `flutter test test/core/audio/audio_interruption_policy_test.dart`

Expected: PASS. Mark play mode `already-correct`; do not edit `player_provider.dart`.

- [ ] **Step 2: Re-run the existing branch-swipe proof**

Run: `flutter test test/features/home/swipe_ime_focus_test.dart`

Expected: PASS for editable focus retention and non-editable horizontal navigation. Mark branch swipe `already-correct`; do not refactor `main_scaffold.dart` unless a prior task demonstrably regressed it.

- [ ] **Step 3: Run the focused UI remediation suite**

Run:

```bash
flutter test \
  test/router/player_route_test.dart \
  test/router/playlist_detail_route_test.dart \
  test/features/player/presentation/player_rebuild_scope_test.dart \
  test/features/player/presentation/player_gesture_ownership_test.dart \
  test/features/player/presentation/bounded_artwork_switcher_test.dart \
  test/features/lyric/presentation/lyric_view_performance_test.dart \
  test/features/lyric/presentation/lyric_retry_test.dart \
  test/features/playlist/presentation/playlist_detail_revision_test.dart \
  test/features/playlist/presentation/playlist_keyboard_insets_test.dart \
  test/features/home/swipe_ime_focus_test.dart
```

Expected: all tests pass.

- [ ] **Step 4: Run repository-wide static and test verification**

Run: `flutter analyze`

Expected: no errors or warnings introduced by this remediation.

Run: `flutter test`

Expected: all tests pass.

- [ ] **Step 5: Attempt the release build only on a macOS/Xcode host**

Run: `flutter build ios --release --no-codesign`

Expected on macOS: successful unsigned iOS release build. On Linux, record `not run: requires macOS/Xcode`; never report it as passing.

- [ ] **Step 6: Close the audit matrix with concrete evidence**

For each row in `Audit Dispositions`, append the exact passing test name and command output date. Leave playlist revision and lyric generation rows blocked until their external providers exist and their dependent tests pass. Confirm these final repository searches:

```bash
git grep -n -E "context\.push\('/player'" -- lib/features/player
git grep -n -E "currentPlaylistProvider|playlistFocusSongIdProvider|playlistVersionProvider" -- lib/features/playlist/presentation
git grep -n -E "watch\((playerPositionProvider|positionProvider)" -- lib/features/player/presentation lib/features/lyric/presentation
```

Expected:

- no direct player pushes outside the guarded `_openPlayer` transaction;
- no transient playlist route providers or manual version increments in UI consumers;
- position watches occur only in progress/time, current-line derivation, and active word-timing widgets.

Do not commit the plan or implementation unless the user issues a separate commit request.
