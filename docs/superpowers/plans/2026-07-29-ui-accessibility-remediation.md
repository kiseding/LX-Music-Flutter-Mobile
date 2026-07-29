# UI Accessibility Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete approved Batch C by making UI messages and asynchronous dialogs lifecycle-safe, narrowing high-frequency playback rebuilds, restoring route and live-provider identity, and making core controls operable through semantics, focus, and keyboard actions.

**Architecture:** Keep Riverpod services and existing visual layouts intact while moving ownership to stable boundaries: the root `ScaffoldMessenger`, dialog-local state objects, disposable stream subscriptions, route path parameters, and notifier APIs. Isolate the 100 ms playback position signal in small consumer widgets, retain stable playlist occurrence objects across reorder operations, and wrap custom-painted controls in standard Flutter semantics/focus actions without introducing dependencies.

**Tech Stack:** Flutter/Dart 3.2+, Material, flutter_riverpod 2.6, go_router 14.8, flutter_test, shared_preferences test backend.

## Global Constraints

- Implement only approved spec Batch C: UI state, accessibility, navigation, and performance.
- Preserve the behavior of the two excluded playlist-import Worker findings.
- Avoid unrelated refactors and major dependency upgrades.
- Fix root causes rather than masking races with delays or retries.
- Follow existing Riverpod, audio handler, storage, and playlist-service patterns.
- Add focused regression coverage proportional to each change's risk.
- Keep existing Chinese UI copy unless this plan specifies an accessibility label.
- Do not modify Worker, iOS project, production audio-engine, or persistence-repository behavior.
- The source tree has no Git metadata: do not run `git` and do not add commit steps.
- Run every command from `/tmp/opencode/LX2IOS-main`.

---

## File Map

- Create `lib/features/playlist/presentation/playlist_occurrence.dart`: stable per-occurrence identity used by reorderable rows.
- Create `test/app_message_test.dart`: root playback-message delivery and consumption regression.
- Create `test/features/custom_source/presentation/custom_source_screen_test.dart`: disposed-dialog and log-subscription lifecycle regressions.
- Create `test/features/player/presentation/position_rebuild_test.dart`: position publication de-duplication and source-level narrow-observation regression.
- Create `test/features/playlist/presentation/playlist_navigation_test.dart`: stable duplicate occurrence and playlist-ID route regressions.
- Create `test/features/settings/restore_live_state_test.dart`: restore-through-notifier regression.
- Create `test/core/widgets/interactive_controls_accessibility_test.dart`: shared control semantics, focus, Enter, and Space behavior.
- Create `test/features/accessibility/core_screens_semantics_test.dart`: settings, playlist, download, and navigation semantics.
- Create `test/features/accessibility/adjustable_semantics_test.dart`: progress, lyric, and equalizer increase/decrease actions.
- Modify `lib/app.dart`: stable root messenger key and the sole playback-message consumer.
- Modify `lib/features/player/presentation/player_screen.dart`: remove duplicate message consumption; narrow position consumers; semantic playback/progress controls.
- Modify `lib/features/player/presentation/widgets/mini_player.dart`: narrow position/lyric consumers and semantic controls.
- Modify `lib/features/player/presentation/player_provider.dart`: suppress every duplicate effective position publication.
- Modify `lib/features/lyric/presentation/lyric_view.dart`: separate static lyric list from position-sensitive KTV content and add adjustable lyric semantics.
- Modify `lib/features/custom_source/presentation/custom_source_provider.dart`: injectable URL import and event-stream providers for lifecycle ownership and tests.
- Modify `lib/features/custom_source/presentation/custom_source_screen.dart`: mounted-safe async dialogs, deterministic dismissal, subscription/controller disposal.
- Modify `lib/router/app_router.dart`: encode playlist identity in `/playlist/detail/:playlistId`.
- Modify `lib/features/playlist/presentation/playlist_provider.dart`: remove transient selected-playlist route state.
- Modify `lib/features/playlist/presentation/playlist_screen.dart`: push playlist IDs, preserve optional focused song in query, and replace gesture-only play affordances.
- Modify `lib/features/playlist/presentation/playlist_detail_screen.dart`: resolve live repository state by constructor `playlistId` and use stable occurrence rows.
- Modify `lib/features/settings/presentation/settings_provider.dart`: explicit restore APIs that update persisted and live state together.
- Modify `lib/features/search/presentation/search_provider.dart`: `SearchHistoryNotifier.replaceAll` restore API.
- Modify `lib/features/settings/presentation/settings_screen.dart`: restore via notifiers and use semantic Material controls.
- Modify `lib/core/widgets/pressable.dart`: reusable button semantics, focus, and activation actions.
- Modify `lib/core/widgets/play_pulse_button.dart`: stateful play/pause semantics and keyboard activation.
- Modify `lib/features/home/presentation/main_scaffold.dart`: selected bottom-navigation semantics and keyboard-operable items.
- Modify `lib/features/download/presentation/download_screen.dart`: replace gesture-only commands/tabs/tasks with semantic Material controls.
- Modify `lib/features/equalizer/presentation/equalizer_screen.dart`: adjustable frequency-band semantics.

### Task 1: Deliver Global Playback Messages Exactly Once

**Files:**
- Create: `test/app_message_test.dart`
- Modify: `lib/app.dart:9-44`
- Modify: `lib/features/player/presentation/player_screen.dart:55-67`

**Interfaces:**
- Produces: `rootScaffoldMessengerKey: GlobalKey<ScaffoldMessengerState>`.
- Produces: `PlayerMessageListener({required Widget child})`, the only widget that listens to `playerMessageProvider`.
- Consumes: `playerMessageProvider: StateProvider<String?>`.
- Invariant: clear a message only after `ScaffoldMessengerState.showSnackBar` has accepted it; leave it pending when no messenger is mounted.

- [ ] **Step 1: Write the failing root-message widget test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/app.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  testWidgets('root messenger consumes one playback message exactly once',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          scaffoldMessengerKey: rootScaffoldMessengerKey,
          home: const PlayerMessageListener(
            child: Scaffold(body: SizedBox.expand()),
          ),
        ),
      ),
    );

    container.read(playerMessageProvider.notifier).state = '播放失败';
    await tester.pump();

    expect(find.text('播放失败'), findsOneWidget);
    expect(container.read(playerMessageProvider), isNull);

    await tester.pump(const Duration(seconds: 4));
    expect(find.text('播放失败'), findsNothing);
  });

  testWidgets('message remains pending until a messenger exists',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(playerMessageProvider.notifier).state = '稍后显示';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const PlayerMessageListener(child: SizedBox()),
      ),
    );
    await tester.pump();

    expect(container.read(playerMessageProvider), '稍后显示');
  });
}
```

- [ ] **Step 2: Run the focused test and confirm the red state**

Run: `flutter test test/app_message_test.dart`

Expected: compilation fails because `rootScaffoldMessengerKey` and `PlayerMessageListener` are not defined.

- [ ] **Step 3: Add the stable messenger and sole consumer**

In `lib/app.dart`, add the key and listener, pass the key into `MaterialApp.router`, and place the listener below the messenger through `builder`:

```dart
final rootScaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

class PlayerMessageListener extends ConsumerWidget {
  const PlayerMessageListener({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<String?>(playerMessageProvider, (previous, next) {
      if (next == null) return;
      final messenger = rootScaffoldMessengerKey.currentState;
      if (messenger == null) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(next),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      if (ref.read(playerMessageProvider) == next) {
        ref.read(playerMessageProvider.notifier).state = null;
      }
    }, fireImmediately: true);
    return child;
  }
}
```

Replace the old `ref.listen` in `LxMusicApp.build` with these `MaterialApp.router` arguments:

```dart
scaffoldMessengerKey: rootScaffoldMessengerKey,
builder: (context, child) => PlayerMessageListener(
  child: child ?? const SizedBox.shrink(),
),
```

Delete the entire `playerMessageProvider` listener from `PlayerScreen.build`; page routes must never compete with the root consumer.

- [ ] **Step 4: Run the focused test and app analysis**

Run: `flutter test test/app_message_test.dart && flutter analyze lib/app.dart lib/features/player/presentation/player_screen.dart`

Expected: both widget tests pass and analysis reports no diagnostics for the two files.

### Task 2: Make Async Dialogs and Log Streams Lifecycle-Owned

**Files:**
- Create: `test/features/custom_source/presentation/custom_source_screen_test.dart`
- Modify: `lib/features/custom_source/presentation/custom_source_provider.dart:69-79`
- Modify: `lib/features/custom_source/presentation/custom_source_screen.dart:293-437,521-630`
- Modify: `test/features/playlist/presentation/playlist_screen_test.dart:14-33`

**Interfaces:**
- Produces: `importCustomSourceFromUrlProvider: Provider<Future<bool> Function(String)>`.
- Produces: `customSourceEventStreamProvider: ProviderFamily<Stream<Map<String, dynamic>>, String>`.
- `_LogConsoleState` owns `StreamSubscription<Map<String, dynamic>>? _logSubscription` and cancels it before disposing `_scrollController`.
- Dialog rule: after every `await`, check the exact context/state that will be used next; user dismissal while busy produces no `setState`, pop, or SnackBar.

- [ ] **Step 1: Write lifecycle regression tests**

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_provider.dart';
import 'package:lx_music_flutter/features/custom_source/presentation/custom_source_screen.dart';

void main() {
  testWidgets('URL import completion after dismissal does not touch dead dialog',
      (tester) async {
    final completion = Completer<bool>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customSourceServiceProvider.overrideWithValue(_NoopService()),
          importCustomSourceFromUrlProvider
              .overrideWithValue((_) => completion.future),
        ],
        child: const MaterialApp(home: CustomSourceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('通过链接导入'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://example.com/a.js');
    await tester.tap(find.text('导入'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    completion.complete(true);
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('导入成功'), findsNothing);
  });

  testWidgets('closing log dialog cancels its event subscription',
      (tester) async {
    final stream = _TrackingStream<Map<String, dynamic>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          customSourceServiceProvider.overrideWithValue(_NoopService()),
          customSourceEventStreamProvider
              .overrideWith((ref, sourceId) => stream),
        ],
        child: const MaterialApp(home: CustomSourceScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('日志'));
    await tester.pumpAndSettle();
    expect(stream.listenCount, 1);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(stream.cancelCount, 1);
  });
}

class _NoopService extends CustomSourceService {
  @override
  List<CustomSource> get sources => [
        CustomSource(
          id: 'source',
          name: 'Source',
          description: '',
          version: '1',
          author: 'Tester',
          script: '',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ];

  @override
  Future<void> init() async {}
}

class _TrackingStream<T> extends Stream<T> {
  final _controller = StreamController<T>.broadcast();
  int listenCount = 0;
  int cancelCount = 0;

  @override
  StreamSubscription<T> listen(
    void Function(T)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount++;
    final inner = _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
    return _TrackingSubscription<T>(inner, () => cancelCount++);
  }
}

class _TrackingSubscription<T> implements StreamSubscription<T> {
  _TrackingSubscription(this._inner, this._onCancel);
  final StreamSubscription<T> _inner;
  final void Function() _onCancel;
  @override
  Future<void> cancel() { _onCancel(); return _inner.cancel(); }
  @override
  void onData(void Function(T data)? handleData) => _inner.onData(handleData);
  @override
  void onError(Function? handleError) => _inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => _inner.onDone(handleDone);
  @override
  void pause([Future<void>? resumeSignal]) => _inner.pause(resumeSignal);
  @override
  void resume() => _inner.resume();
  @override
  bool get isPaused => _inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => _inner.asFuture(futureValue);
}
```

- [ ] **Step 2: Run the tests and verify the lifecycle failures**

Run: `flutter test test/features/custom_source/presentation/custom_source_screen_test.dart test/features/playlist/presentation/playlist_screen_test.dart`

Expected: compilation fails for the two missing providers; the existing playlist source test remains green.

- [ ] **Step 3: Add injectable operations and deterministic dialog completion**

Append to `custom_source_provider.dart`:

```dart
final importCustomSourceFromUrlProvider =
    Provider<Future<bool> Function(String)>((ref) {
  return ref.read(customSourcesProvider.notifier).importSourceFromUrl;
});

final customSourceEventStreamProvider =
    Provider.family<Stream<Map<String, dynamic>>, String>((ref, sourceId) {
  return ref.read(customSourcesProvider.notifier).getEventStream(sourceId);
});
```

In URL and pasted-script dialogs, capture `final pageContext = context` before `showDialog`, name the builder context `dialogContext`, and dispose each `TextEditingController` with `showDialog(...).whenComplete(controller.dispose)`. In every async callback use this sequence:

```dart
setState(() => isLoading = true);
final success = await ref.read(importCustomSourceFromUrlProvider)(url);
if (!dialogContext.mounted || !pageContext.mounted) return;
setState(() => isLoading = false);
Navigator.pop(dialogContext);
ScaffoldMessenger.of(pageContext).showSnackBar(
  SnackBar(
    content: Text(success ? '导入成功' : '导入失败，请检查链接或脚本格式'),
    backgroundColor: success ? Colors.green : Colors.red,
  ),
);
```

Use the same dialog-context and page-context checks in pasted-script import before `Navigator.pop` and SnackBar. Set `barrierDismissible: false` on both asynchronous custom-source import dialogs; their explicit cancel controls remain enabled only before work starts. Keep playlist import's existing checks and also set its outer dialog `barrierDismissible: false`; a cancelled confirmation sets `busy = false`, while successful creation closes the import dialog exactly once. Route disposal remains valid and is covered by the test above.

- [ ] **Step 4: Own and release the log subscription**

Add `import 'dart:async';`, store the subscription returned by the provider, and dispose in this order:

```dart
StreamSubscription<Map<String, dynamic>>? _logSubscription;

void _listenLogs() {
  _logSubscription = ref
      .read(customSourceEventStreamProvider(widget.source.id))
      .listen((event) {
    if (!mounted) return;
    setState(() {
      _logs.add({...event, 'timestamp': DateTime.now()});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    });
  });
}

@override
void dispose() {
  _logSubscription?.cancel();
  _scrollController.dispose();
  super.dispose();
}
```

- [ ] **Step 5: Run lifecycle tests and async-context analysis**

Run: `flutter test test/features/custom_source/presentation/custom_source_screen_test.dart test/features/playlist/presentation/playlist_screen_test.dart && flutter analyze lib/features/custom_source/presentation lib/features/playlist/presentation/playlist_screen.dart`

Expected: all tests pass; no `use_build_context_synchronously`, subscription, or controller diagnostics remain in modified import flows.

### Task 3: Narrow Position Rebuilds and De-duplicate Publications

**Files:**
- Create: `test/features/player/presentation/position_rebuild_test.dart`
- Modify: `lib/features/player/presentation/player_provider.dart:55-175`
- Modify: `lib/features/player/presentation/player_screen.dart:48-53,154-179,429-667`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart:38-81,103-365`
- Modify: `lib/features/lyric/presentation/lyric_view.dart:101-224,293-339`

**Interfaces:**
- Produces: `PositionNotifier.update(Duration next)`, the single equality gate for stream, discontinuity, timer, seek, and scrub publications.
- Produces private narrow consumers `_PlayerProgress`, `_CurrentLyricLine`, `_MiniProgress`, `_MiniLyricText`, and `_PositionedKtvLyricLine`; none changes public constructors.
- Invariant: `PlayerScreen.build`, `MiniPlayer.build`, and the static lyric list do not directly watch `playerPositionProvider`.

- [ ] **Step 1: Add de-duplication and structural narrow-observation tests**

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  test('PositionNotifier publishes only effective position changes', () {
    final notifier = PositionNotifier(null);
    addTearDown(notifier.dispose);
    var notifications = 0;
    notifier.addListener((_) => notifications++, fireImmediately: false);

    notifier.update(Duration.zero);
    notifier.update(const Duration(seconds: 1));
    notifier.update(const Duration(seconds: 1));

    expect(notifier.state, const Duration(seconds: 1));
    expect(notifications, 1);
  });

  test('high-frequency watches live only in narrow presentation widgets', () {
    final player = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    final lyric = File(
      'lib/features/lyric/presentation/lyric_view.dart',
    ).readAsStringSync();

    expect(player.indexOf('class _PlayerProgress'), isNonNegative);
    expect(player.substring(0, player.indexOf('class _PlayerProgress')),
        isNot(contains('ref.watch(playerPositionProvider)')));
    expect(mini.indexOf('class _MiniProgress'), isNonNegative);
    expect(mini.substring(0, mini.indexOf('class _MiniProgress')),
        isNot(contains('ref.watch(positionProvider)')));
    expect(lyric.indexOf('class _PositionedKtvLyricLine'), isNonNegative);
    expect(lyric.substring(0, lyric.indexOf('class _PositionedKtvLyricLine')),
        isNot(contains('ref.watch(playerPositionProvider)')));
  });
}
```

- [ ] **Step 2: Run the focused test and confirm both red reasons**

Run: `flutter test test/features/player/presentation/position_rebuild_test.dart`

Expected: compilation fails because `PositionNotifier.update` is absent; after that API exists, structural assertions fail until narrow widgets are introduced.

- [ ] **Step 3: Route every position publication through one equality gate**

Add to `PositionNotifier`:

```dart
void update(Duration next) {
  if (next == state) return;
  state = next;
}
```

Replace direct assignments in constructor listeners, discontinuity, timer, `unfreeze`, and `jumpTo` with `update(...)`. Preserve the existing 16 ms and 30 ms noise thresholds before calling `update`; the equality gate prevents discontinuity/seek and timer overlap from publishing the same effective duration.

- [ ] **Step 4: Extract narrow player and mini-player consumers**

Remove `final position = ref.watch(playerPositionProvider);` from `PlayerScreen.build`. Replace `_buildProgressSection(playerService, position, duration)` with:

```dart
_PlayerProgress(
  duration: duration,
  seeking: _seeking,
  seekValue: _seekValue,
  onDragStart: _beginSeek,
  onDragUpdate: _updateSeek,
  onSeekEnd: _finishSeek,
),
```

Implement `_PlayerProgress extends ConsumerWidget` at file scope and move only the existing progress `Row` into it; its `build` begins with `final position = ref.watch(playerPositionProvider);`. Keep seek transaction state/callbacks owned by `_PlayerScreenState`. Move `_buildCurrentLyricLine` into `_CurrentLyricLine extends ConsumerWidget`, where only that widget watches `currentLineIndexProvider`.

In `mini_player.dart`, keep queue metadata and playback buttons in `_MiniPlayerState`, but move the top progress row into `_MiniProgress extends ConsumerWidget` (the only `positionProvider` watcher) and the subtitle into `_MiniLyricText extends ConsumerWidget` (the only `currentLineIndexProvider` watcher). Pass immutable duration/current song and seek callbacks into `_MiniProgress`.

- [ ] **Step 5: Isolate KTV word fill from the lyric list**

Remove `final position = ref.watch(playerPositionProvider);` from `_LyricViewState.build`. For a current timed line render:

```dart
_PositionedKtvLyricLine(
  line: line,
  lineIndex: index,
  lyrics: lyrics,
  activeColor: lineColor,
  dimColor: dimColor,
  fontSize: fontSize,
  fontWeight: weight,
)
```

Define `_PositionedKtvLyricLine extends ConsumerWidget`; it watches `playerPositionProvider` and delegates to the existing pure `_KtvLyricLine(position: position, ...)`. This restricts 100 ms word-fill rebuilds to the active timed line.

- [ ] **Step 6: Run position tests and the existing scrub suite**

Run: `flutter test test/features/player/presentation/position_rebuild_test.dart test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/seek_clamp_test.dart`

Expected: all tests pass; no duplicate notification is observed, and scrub behavior remains green.

### Task 4: Use Stable Playlist Occurrences and Playlist-ID Routes

**Files:**
- Create: `lib/features/playlist/presentation/playlist_occurrence.dart`
- Create: `test/features/playlist/presentation/playlist_navigation_test.dart`
- Modify: `lib/router/app_router.dart:52-61`
- Modify: `lib/features/playlist/presentation/playlist_provider.dart:31-36`
- Modify: `lib/features/playlist/presentation/playlist_screen.dart:285-297`
- Modify: `lib/features/playlist/presentation/playlist_detail_screen.dart:10-35,78-82,255-278`
- Modify: `test/features/playlist/presentation/playlist_detail_favorites_test.dart:38-77`

**Interfaces:**
- Produces: `PlaylistSongOccurrence({required MusicItem song, required String key})`.
- Produces: `buildPlaylistOccurrences(String playlistId, List<MusicItem> songs) -> List<PlaylistSongOccurrence>`; duplicate IDs get monotonically increasing occurrence numbers in input order.
- Produces: `PlaylistDetailScreen({required String playlistId, String? focusSongId})`.
- Route: named `playlistDetail`, path `/playlist/detail/:playlistId`, optional query `focusSongId`.
- Removes: `currentPlaylistProvider`; route identity must not depend on process-local provider state.

- [ ] **Step 1: Write occurrence and deep-link tests**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/playlist/data/playlist_repository.dart';
import 'package:lx_music_flutter/features/playlist/domain/playlist.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_detail_screen.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_occurrence.dart';
import 'package:lx_music_flutter/features/playlist/presentation/playlist_provider.dart';

void main() {
  test('duplicate songs receive stable occurrence keys across reorder', () {
    final song = MusicItem(id: 'same', name: 'Song', singer: 'A', source: 'tx');
    final occurrences = buildPlaylistOccurrences('list', [song, song]);
    final second = occurrences.removeAt(1);
    occurrences.insert(0, second);

    expect(occurrences.map((entry) => entry.key), [
      'list:same:1',
      'list:same:0',
    ]);
  });

  testWidgets('playlist deep link resolves current repository value',
      (tester) async {
    final now = DateTime.utc(2026);
    final repository = _Repository(PlaylistSnapshot(
      schemaVersion: 1,
      playlists: [Playlist(id: 'deep', name: 'Deep', createdAt: now, updatedAt: now)],
    ));
    final router = GoRouter(
      initialLocation: '/playlist/detail/deep',
      routes: [
        GoRoute(
          path: '/playlist/detail/:playlistId',
          builder: (_, state) => PlaylistDetailScreen(
            playlistId: state.pathParameters['playlistId']!,
          ),
        ),
      ],
    );
    final container = ProviderContainer(overrides: [
      playlistRepositoryProvider.overrideWithValue(repository),
    ]);
    addTearDown(container.dispose);
    await container.read(playlistServiceProvider).init();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Deep'), findsOneWidget);
  });
}

class _Repository implements PlaylistRepository {
  _Repository(this.snapshot);
  PlaylistSnapshot snapshot;
  @override
  Future<PlaylistSnapshot> load() async => snapshot;
  @override
  Future<void> save(PlaylistSnapshot value) async => snapshot = value;
}
```

- [ ] **Step 2: Run the test and verify missing occurrence/constructor APIs**

Run: `flutter test test/features/playlist/presentation/playlist_navigation_test.dart`

Expected: compilation fails because `playlist_occurrence.dart` and required `playlistId` constructor are absent.

- [ ] **Step 3: Implement stable occurrence identity**

Create `playlist_occurrence.dart`:

```dart
import '../../player/domain/music_item.dart';

final class PlaylistSongOccurrence {
  const PlaylistSongOccurrence({required this.song, required this.key});
  final MusicItem song;
  final String key;
}

List<PlaylistSongOccurrence> buildPlaylistOccurrences(
  String playlistId,
  List<MusicItem> songs,
) {
  final counts = <String, int>{};
  return songs.map((song) {
    final occurrence = counts.update(song.id, (value) => value + 1,
        ifAbsent: () => 0);
    return PlaylistSongOccurrence(
      song: song,
      key: '$playlistId:${song.id}:$occurrence',
    );
  }).toList();
}
```

Change `_reorderedSongs` to `List<PlaylistSongOccurrence>`. Populate it only when entering editing or when the playlist identity changes, reorder occurrence objects, save `_reorderedSongs.map((entry) => entry.song).toList()`, and key each row with `ValueKey(entry.key)`. Never regenerate wrappers during an in-progress reorder.

- [ ] **Step 4: Move playlist identity into the route**

Change the nested route to:

```dart
GoRoute(
  name: 'playlistDetail',
  path: 'detail/:playlistId',
  parentNavigatorKey: _rootNavigatorKey,
  builder: (context, state) => PlaylistDetailScreen(
    playlistId: state.pathParameters['playlistId']!,
    focusSongId: state.uri.queryParameters['focusSongId'],
  ),
),
```

Change `_openPlaylist` to:

```dart
void _openPlaylist(
  BuildContext context,
  Playlist playlist, {
  String? focusSongId,
}) {
  context.pushNamed(
    'playlistDetail',
    pathParameters: {'playlistId': playlist.id},
    queryParameters: {
      if (focusSongId != null) 'focusSongId': focusSongId,
    },
  );
}
```

`PlaylistDetailScreen._resolvePlaylist` must watch `playlistRevisionProvider` and call `ref.watch(playlistServiceProvider).getPlaylist(widget.playlistId)`. Replace all reads of `playlistFocusSongIdProvider` with `widget.focusSongId`; delete both transient route providers from `playlist_provider.dart` when no consumers remain.

- [ ] **Step 5: Update existing detail tests and run navigation coverage**

Construct `PlaylistDetailScreen(playlistId: selected.id)` in `playlist_detail_favorites_test.dart` and remove its `currentPlaylistProvider` assignment.

Run: `flutter test test/features/playlist/presentation/playlist_navigation_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart test/features/playlist/presentation/playlist_provider_test.dart`

Expected: all tests pass; duplicate rows retain identity after movement, direct deep links render, and repository removal still shows `歌单不存在`.

### Task 5: Restore Settings Through Live Notifier APIs

**Files:**
- Create: `test/features/settings/restore_live_state_test.dart`
- Modify: `lib/features/settings/presentation/settings_provider.dart:53-194`
- Modify: `lib/features/search/presentation/search_provider.dart:137-167`
- Modify: `lib/features/settings/presentation/settings_screen.dart:548-624`

**Interfaces:**
- Produces on each settings notifier: existing setter remains the durable/live mutation API used during restore.
- Produces: `SearchHistoryNotifier.replaceAll(List<String> values) -> Future<void>`.
- Restore mapping: `theme_mode -> ThemeModeNotifier.setThemeMode`, `audio_quality -> AudioQualityNotifier.setQuality`, `download_quality -> DownloadQualityNotifier.setQuality`, `wifi_only_download -> WifiOnlyDownloadNotifier.setWifiOnly`, `search_history -> SearchHistoryNotifier.replaceAll`.
- Invariant: `_restoreData` performs no direct `StorageService.set*` for those five live-provider values.

- [ ] **Step 1: Write the live-state restore test**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restore APIs update live state and durable preferences', () async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await container.read(themeModeProvider.notifier).setThemeMode(ThemeMode.dark);
    await container.read(audioQualityProvider.notifier)
        .setQuality(AudioQualityOption.lossless);
    await container.read(downloadQualityProvider.notifier)
        .setQuality(AudioQualityOption.low);
    await container.read(wifiOnlyDownloadProvider.notifier).setWifiOnly(false);
    await container.read(searchHistoryProvider.notifier)
        .replaceAll(['one', 'two']);

    expect(container.read(themeModeProvider), ThemeMode.dark);
    expect(container.read(audioQualityProvider), AudioQualityOption.lossless);
    expect(container.read(downloadQualityProvider), AudioQualityOption.low);
    expect(container.read(wifiOnlyDownloadProvider), isFalse);
    expect(container.read(searchHistoryProvider), ['one', 'two']);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt('theme_mode'), ThemeMode.dark.index);
    expect(prefs.getStringList('search_history'), ['one', 'two']);
  });
}
```

- [ ] **Step 2: Run the test and confirm the missing history API**

Run: `flutter test test/features/settings/restore_live_state_test.dart`

Expected: compilation fails because `SearchHistoryNotifier.replaceAll` is missing.

- [ ] **Step 3: Add the validated history replacement API**

Add to `SearchHistoryNotifier`:

```dart
Future<void> replaceAll(List<String> values) async {
  final normalized = <String>[];
  for (final value in values) {
    final keyword = value.trim();
    if (keyword.isEmpty || normalized.contains(keyword)) continue;
    normalized.add(keyword);
    if (normalized.length == 20) break;
  }
  final storage = await StorageService.instance;
  await storage.setStringList('search_history', normalized);
  state = normalized;
}
```

For all settings setters, preserve Batch B's durable failure/rollback behavior if it has already landed. The required ordering is: snapshot old state, update state, await durable write, and restore old state before rethrow when persistence fails. Do not add a second restore-only path that bypasses this behavior.

- [ ] **Step 4: Replace raw storage restore writes with notifier calls**

After the backup has been fully decoded and playlist replacement has succeeded, use:

```dart
if (backup['search_history'] case final List<dynamic> values) {
  await ref.read(searchHistoryProvider.notifier).replaceAll(
        values.cast<String>(),
      );
}
if (backup['theme_mode'] case final int index) {
  await ref.read(themeModeProvider.notifier).setThemeMode(
        ThemeMode.values[index.clamp(0, ThemeMode.values.length - 1)],
      );
}
if (backup['audio_quality'] case final int index) {
  await ref.read(audioQualityProvider.notifier).setQuality(
        AudioQualityOption.values[
          index.clamp(0, AudioQualityOption.values.length - 1)
        ],
      );
}
if (backup['download_quality'] case final int index) {
  await ref.read(downloadQualityProvider.notifier).setQuality(
        AudioQualityOption.values[
          index.clamp(0, AudioQualityOption.values.length - 1)
        ],
      );
}
if (backup['wifi_only_download'] case final bool value) {
  await ref.read(wifiOnlyDownloadProvider.notifier).setWifiOnly(value);
}
```

Delete the now-unused `final storage = await StorageService.instance;` from `_restoreData`; `_backupData` still legitimately reads storage.

- [ ] **Step 5: Run restore and compatibility tests**

Run: `flutter test test/features/settings/restore_live_state_test.dart test/features/settings/playlist_backup_compatibility_test.dart test/features/settings/default_quality_test.dart`

Expected: all tests pass and legacy/new playlist backup shapes remain accepted exactly as before.

### Task 6: Make Shared Custom Controls Semantic, Focusable, and Keyboard-Operable

**Files:**
- Create: `test/core/widgets/interactive_controls_accessibility_test.dart`
- Modify: `lib/core/widgets/pressable.dart:4-58`
- Modify: `lib/core/widgets/play_pulse_button.dart:8-168`

**Interfaces:**
- `Pressable` adds optional `semanticLabel`, `selected`, and `tooltip` parameters without changing existing call sites.
- `PlayPulseButton` adds optional `semanticLabel`; default label is `暂停` when playing and `播放` otherwise.
- Both controls expose `Semantics(button: true, enabled: ...)`, participate in traversal through `FocusableActionDetector`, and invoke on Enter/Space through `ActivateIntent`.
- Each state object owns a `FocusNode`; pointer activation requests that focus before invoking the callback, and `dispose` releases the node.

- [ ] **Step 1: Write shared semantics and keyboard tests**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/play_pulse_button.dart';
import 'package:lx_music_flutter/core/widgets/pressable.dart';

void main() {
  testWidgets('Pressable exposes button state and activates from Enter',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Pressable(
      semanticLabel: '下一首',
      onTap: () => taps++,
      child: const Icon(Icons.skip_next),
    ))));

    final semantics = tester.getSemantics(find.bySemanticsLabel('下一首'));
    expect(semantics.hasFlag(SemanticsFlag.isButton), isTrue);
    await tester.tap(find.bySemanticsLabel('下一首'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 2);
  });

  testWidgets('play button reports toggled state and activates from Space',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: PlayPulseButton(
      isPlaying: true,
      onPressed: () => taps++,
    ))));

    final semantics = tester.getSemantics(find.bySemanticsLabel('暂停'));
    expect(semantics.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(semantics.hasFlag(SemanticsFlag.isToggled), isTrue);
    await tester.tap(find.bySemanticsLabel('暂停'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
  });
}
```

- [ ] **Step 2: Run the test and verify missing semantics/focus**

Run: `flutter test test/core/widgets/interactive_controls_accessibility_test.dart`

Expected: compilation fails for new constructor parameters, or semantic label/button assertions fail before implementation.

- [ ] **Step 3: Implement a semantic and focusable activation shell**

Wrap the existing animated child in both controls with this pattern, retaining current pointer animation handlers inside it:

```dart
Semantics(
  label: semanticLabel,
  button: true,
  enabled: onActivate != null,
  selected: selected,
  toggled: toggled,
  onTap: onActivate,
  child: FocusableActionDetector(
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
)
```

Import `package:flutter/services.dart`. In each current `build`, assign its existing `GestureDetector` expression unchanged to `final interactiveChild`, then return the wrapper above. `ExcludeSemantics` prevents duplicate semantic actions while pointer taps still call the same callback once. For `PlayPulseButton`, pass `semanticLabel: widget.semanticLabel ?? (widget.isPlaying ? '暂停' : '播放')`, `toggled: widget.isPlaying`, `selected: null`, and `onActivate: disabled ? null : widget.onPressed`. For `Pressable`, pass `semanticLabel: widget.semanticLabel`, `toggled: null`, `selected: widget.selected`, and `onActivate: widget.onTap`.

Add `final FocusNode _focusNode = FocusNode();` to each state, pass `focusNode: _focusNode` to `FocusableActionDetector`, and call `_focusNode.requestFocus()` in the enabled `onTapDown` before starting the press animation. Dispose `_focusNode` before `super.dispose()`; add a `dispose` override to `_PressableState` and extend the existing `PlayPulseButton.dispose`. This makes the test's pointer-then-Enter/Space sequence deterministic and gives hardware-keyboard users a visible traversal target.

- [ ] **Step 4: Label all existing shared-control call sites**

Provide exact labels where icons have no text: `上一首`, `下一首`, bottom-navigation destination names, and player controls. Pass `selected: isSelected` for bottom navigation. Keep labels out of visible UI.

- [ ] **Step 5: Run shared widget and existing UI tests**

Run: `flutter test test/core/widgets/interactive_controls_accessibility_test.dart test/core/widgets/ui_widgets_test.dart test/features/home/swipe_ime_focus_test.dart`

Expected: all tests pass; swipe behavior and text-field focus remain unchanged.

### Task 7: Replace Gesture-Only Core Screen Controls

**Files:**
- Create: `test/features/accessibility/core_screens_semantics_test.dart`
- Modify: `lib/features/settings/presentation/settings_screen.dart:251-375`
- Modify: `lib/features/playlist/presentation/playlist_screen.dart:367-545`
- Modify: `lib/features/home/presentation/main_scaffold.dart:311-378`
- Modify: `lib/features/download/presentation/download_screen.dart:120-209,222-337,364-400`
- Modify: `lib/features/lyric/presentation/lyric_view.dart:227-285`
- Modify: `lib/features/player/presentation/player_screen.dart:227-267,669-717`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart:262-360`

**Interfaces:**
- Standard binary setting control: `Switch(value:, onChanged:)`; no custom gesture toggle.
- Standard commands: `IconButton`, `TextButton`, `FilledButton`, `InkWell`, or shared semantic `Pressable`.
- Selected controls expose `selected`/`toggled`; all icon-only controls have tooltips/semantic labels; disabled actions expose no activation callback.

- [ ] **Step 1: Write semantics/focus tests for representative core workflows**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/pressable.dart';

void main() {
  testWidgets('selected destination is a keyboard-operable button',
      (tester) async {
    var activated = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Pressable(
      semanticLabel: '歌单',
      selected: true,
      onTap: () => activated++,
      child: const Text('歌单'),
    ))));

    final node = tester.getSemantics(find.bySemanticsLabel('歌单'));
    expect(node.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(node.hasFlag(SemanticsFlag.isSelected), isTrue);
    await tester.tap(find.bySemanticsLabel('歌单'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(activated, 2);
  });

  testWidgets('settings binary control uses native switch semantics',
      (tester) async {
    var value = false;
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) => SwitchListTile(
        title: const Text('仅 WiFi 下载'),
        value: value,
        onChanged: (next) => setState(() => value = next),
      ),
    )));
    final node = tester.getSemantics(find.byType(Switch));
    expect(node.hasFlag(SemanticsFlag.hasToggledState), isTrue);
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(value, isTrue);
  });

  test('core helper bodies no longer contain gesture-only commands', () {
    final checks = <(String, String, String)>[
      (
        'lib/features/settings/presentation/settings_screen.dart',
        'Widget _buildSwitchTile(',
        'String _getQualityName(',
      ),
      (
        'lib/features/playlist/presentation/playlist_screen.dart',
        'Widget _buildFavoritesCard(',
        'Widget _buildPlaylistItem(',
      ),
      (
        'lib/features/download/presentation/download_screen.dart',
        'Widget _buildTabs(',
        'Widget _buildTaskItem(',
      ),
      (
        'lib/features/lyric/presentation/lyric_view.dart',
        'Widget _buildEmptyState(',
        'Future<void> _searchLyric(',
      ),
      (
        'lib/features/player/presentation/player_screen.dart',
        'Widget _buildAppBar(',
        'Widget _buildPageIndicator(',
      ),
    ];

    for (final (path, start, end) in checks) {
      final source = File(path).readAsStringSync();
      final body = source.substring(source.indexOf(start), source.indexOf(end));
      expect(body, isNot(contains('GestureDetector(')), reason: path);
    }
  });
}
```

Extend the `checks` table if helper extraction creates separate `_buildRecentCard`, `_buildStatusWidget`, or mini-player metadata helper boundaries; use each helper's next method declaration as the exact substring end marker. Do not use a whole-file ban because drag surfaces remain legitimate in progress/equalizer controls.

- [ ] **Step 2: Run the test and confirm production structural failures**

Run: `flutter test test/features/accessibility/core_screens_semantics_test.dart`

Expected: representative controls pass, but structural checks fail because production helper bodies still use gesture-only controls.

- [ ] **Step 3: Replace binary and command gestures with Material controls**

Apply these exact substitutions while preserving dimensions/colors:

- `SettingsScreen._buildSwitchTile`: use `Switch(value: value, onChanged: onChanged)` and delete `_buildToggle`.
- Playlist favorites/recent circular play affordance: `IconButton(tooltip: '播放全部', onPressed: playAll, icon: const Icon(Icons.play_arrow_rounded))` inside the same 48x48 decoration; wrap in `Semantics(container: true)` so it is distinct from the card's open action.
- Bottom navigation: shared `Pressable(semanticLabel: label, selected: isSelected, onTap: () => onTap(index), child: destinationContent)`.
- Download pause/clear: `TextButton.icon`; tabs: `InkWell` plus `Semantics(button: true, selected: isActive)`; completed task: `InkWell`; retry: `TextButton`.
- Empty lyric search: `OutlinedButton(onPressed: ..., child: const Text('搜索歌词'))`.
- Player close: `IconButton(tooltip: '收起播放器', onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down))`; previous/next use labeled `Pressable`; mode and queue `IconButton` receive `tooltip` values.
- Mini artwork/title open actions: one `InkWell` around the metadata region with semantic label `打开正在播放`; previous/next use labeled `Pressable`.

Do not wrap already semantic Material controls in a second `Semantics(button: true)` unless selected/toggled state cannot otherwise be represented.

- [ ] **Step 4: Verify pointer, focus, and semantic behavior**

Run: `flutter test test/features/accessibility/core_screens_semantics_test.dart test/features/home/swipe_ime_focus_test.dart test/features/playlist/presentation/playlist_screen_test.dart test/features/equalizer/presentation/equalizer_screen_test.dart`

Expected: all tests pass; keyboard focus is retained, selected state is exposed, and existing screen rendering remains green.

### Task 8: Add Adjustable Playback Progress and Lyric Semantics

**Files:**
- Create: `test/features/accessibility/adjustable_semantics_test.dart`
- Modify: `lib/features/player/presentation/player_screen.dart` in `_PlayerProgress`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart` in `_MiniProgress`
- Modify: `lib/features/lyric/presentation/lyric_view.dart:137-224`

**Interfaces:**
- Progress semantic label: `播放进度`; value: `MM:SS / MM:SS`; increase/decrease step: 10 seconds, clamped to `[Duration.zero, duration]`.
- Lyric viewport semantic label: `歌词`; value: current line text; increase/decrease seek to next/previous lyric line, clamped to valid indices.
- Individual lyric row: semantic button labeled with line text and timestamp; current row has `selected: true`.
- All semantic seek actions call existing `seekProvider`; no second playback clock or direct audio-handler call.

- [ ] **Step 1: Add a test harness for real semantic actions**

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adjustable progress invokes clamped increase and decrease',
      (tester) async {
    var value = const Duration(seconds: 5);
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) => Semantics(
        label: '播放进度',
        slider: true,
        value: '${value.inSeconds}',
        onIncrease: () => setState(() {
          value = Duration(seconds: (value.inSeconds + 10).clamp(0, 20));
        }),
        onDecrease: () => setState(() {
          value = Duration(seconds: (value.inSeconds - 10).clamp(0, 20));
        }),
        child: const SizedBox(width: 100, height: 20),
      ),
    )));

    final finder = find.bySemanticsLabel('播放进度');
    tester.getSemantics(finder).performAction(SemanticsAction.increase);
    await tester.pump();
    expect(value, const Duration(seconds: 15));
    tester.getSemantics(finder).performAction(SemanticsAction.decrease);
    await tester.pump();
    expect(value, const Duration(seconds: 5));
  });

  test('production progress and lyric controls expose adjustable actions', () {
    final player = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    final lyric = File(
      'lib/features/lyric/presentation/lyric_view.dart',
    ).readAsStringSync();
    final playerProgress = player.substring(player.indexOf('class _PlayerProgress'));
    final miniProgress = mini.substring(mini.indexOf('class _MiniProgress'));

    for (final source in [playerProgress, miniProgress]) {
      expect(source, contains("label: '播放进度'"));
      expect(source, contains('onIncrease:'));
      expect(source, contains('onDecrease:'));
      expect(source, contains('seekProvider'));
    }
    expect(lyric, contains("label: '歌词'"));
    expect(lyric, contains('selected: isCurrent'));
    expect(lyric, contains('onIncrease:'));
    expect(lyric, contains('onDecrease:'));
  });
}
```

- [ ] **Step 2: Run the test and verify production semantics are absent**

Run: `flutter test test/features/accessibility/adjustable_semantics_test.dart`

Expected: the harness passes and structural production assertions fail.

- [ ] **Step 3: Wrap both custom progress tracks in adjustable semantics**

In each narrow progress widget calculate:

```dart
Duration adjusted(Duration position, int deltaSeconds) {
  final milliseconds = (position.inMilliseconds + deltaSeconds * 1000)
      .clamp(0, duration.inMilliseconds);
  return Duration(milliseconds: milliseconds);
}
```

Assign the existing progress-track `GestureDetector` expression to `final interactiveTrack`. Wrap only that track, excluding its painted children from duplicate semantics:

```dart
Semantics(
  label: '播放进度',
  slider: true,
  enabled: duration > Duration.zero,
  value: '${format(position)} / ${format(duration)}',
  increasedValue: format(adjusted(position, 10)),
  decreasedValue: format(adjusted(position, -10)),
  onIncrease: duration > Duration.zero
      ? () => ref.read(seekProvider)(adjusted(position, 10))
      : null,
  onDecrease: duration > Duration.zero
      ? () => ref.read(seekProvider)(adjusted(position, -10))
      : null,
  child: ExcludeSemantics(child: interactiveTrack),
)
```

- [ ] **Step 4: Add lyric row and viewport actions**

Assign the current padded text/KTV column to `final lineContent`, then wrap each tappable line with:

```dart
Semantics(
  button: true,
  selected: isCurrent,
  label: line.text,
  value: _formatLyricTime(line.time),
  onTap: () => ref.read(seekProvider)(line.time),
  child: ExcludeSemantics(child: lineContent),
)
```

Assign the current `ShaderMask`/`ListView.builder` expression to `final lyricList`. Wrap it with this adjustable node:

```dart
final currentText = currentLineIndex >= 0 &&
        currentLineIndex < lyrics.lines.length
    ? lyrics.lines[currentLineIndex].text
    : '';
final previousIndex = lyrics.isEmpty
    ? -1
    : (currentLineIndex - 1).clamp(0, lyrics.lines.length - 1);
final nextIndex = lyrics.isEmpty
    ? -1
    : (currentLineIndex + 1).clamp(0, lyrics.lines.length - 1);

return Semantics(
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
);
```

Omit increase/decrease actions when lyrics are empty.

- [ ] **Step 5: Run semantics and lyric regressions**

Run: `flutter test test/features/accessibility/adjustable_semantics_test.dart test/features/lyric/data/lyric_parser_test.dart test/features/player/presentation/scrub_coordinator_test.dart`

Expected: all tests pass; semantics actions use the same scrub/seek transaction as touch interaction.

### Task 9: Add Adjustable Equalizer Semantics

**Files:**
- Modify: `test/features/equalizer/presentation/equalizer_screen_test.dart:7-25`
- Modify: `lib/features/equalizer/presentation/equalizer_screen.dart:290-381`

**Interfaces:**
- Each frequency band exposes slider semantics with label `${freqLabels[index]} Hz`, value `${gain > 0 ? '+' : ''}$gain dB`, range `-12..12`, step `1 dB`.
- `onIncrease`/`onDecrease` call `EqualizerNotifier.setBandGain(index, clampedGain)` only when equalizer is enabled.
- Disabled bands retain readable label/value but expose `enabled: false` and no adjustable actions.

- [ ] **Step 1: Extend the equalizer widget test with semantic actions**

Add this test to `equalizer_screen_test.dart`:

```dart
testWidgets('enabled frequency band exposes adjustable dB semantics',
    (tester) async {
  await tester.pumpWidget(
    const ProviderScope(
      child: MaterialApp(home: EqualizerScreen()),
    ),
  );

  await tester.tap(find.byType(Switch));
  await tester.pump();
  final band = find.bySemanticsLabel('32 Hz');
  final before = tester.getSemantics(band).value;

  tester.getSemantics(band).performAction(SemanticsAction.increase);
  await tester.pump();

  expect(before, '0 dB');
  expect(tester.getSemantics(band).value, '+1 dB');
  expect(tester.getSemantics(band).hasFlag(SemanticsFlag.isSlider), isTrue);
});
```

- [ ] **Step 2: Run the equalizer test and confirm no semantic node exists**

Run: `flutter test test/features/equalizer/presentation/equalizer_screen_test.dart`

Expected: fails because no semantics node is labeled `32 Hz`.

- [ ] **Step 3: Wrap each custom frequency fader in adjustable semantics**

In `_buildFrequencyBand`, assign the existing `GestureDetector` expression to `final fader`, compute a `valueLabel`, and return:

```dart
final valueLabel = '${gain > 0 ? '+' : ''}$gain dB';
return Semantics(
  label: '${freqLabels[index]} Hz',
  slider: true,
  enabled: enabled,
  value: valueLabel,
  increasedValue: '${(gain + 1).clamp(-12, 12) > 0 ? '+' : ''}'
      '${(gain + 1).clamp(-12, 12)} dB',
  decreasedValue: '${(gain - 1).clamp(-12, 12) > 0 ? '+' : ''}'
      '${(gain - 1).clamp(-12, 12)} dB',
  onIncrease: enabled
      ? () => ref.read(equalizerProvider.notifier)
          .setBandGain(index, (gain + 1).clamp(-12, 12))
      : null,
  onDecrease: enabled
      ? () => ref.read(equalizerProvider.notifier)
          .setBandGain(index, (gain - 1).clamp(-12, 12))
      : null,
  child: ExcludeSemantics(child: fader),
);
```

Keep vertical drag mapping unchanged. At `+12`/`-12`, actions may remain present but must clamp and produce no out-of-range state.

- [ ] **Step 4: Run equalizer and all accessibility tests**

Run: `flutter test test/features/equalizer/presentation/equalizer_screen_test.dart test/features/accessibility test/core/widgets/interactive_controls_accessibility_test.dart`

Expected: all tests pass; each enabled band is an adjustable slider and disabled bands are read-only.

### Task 10: Final Batch C Verification

**Files:**
- Verify only; do not create or modify additional files.

**Interfaces:**
- Confirms all Batch C interfaces and route paths introduced by Tasks 1-9.
- Confirms no production/test code outside the listed Batch C files was changed during implementation.

- [ ] **Step 1: Format exactly the modified Dart files**

Run:

```bash
dart format \
  lib/app.dart \
  lib/core/widgets/pressable.dart \
  lib/core/widgets/play_pulse_button.dart \
  lib/router/app_router.dart \
  lib/features/custom_source/presentation/custom_source_provider.dart \
  lib/features/custom_source/presentation/custom_source_screen.dart \
  lib/features/download/presentation/download_screen.dart \
  lib/features/equalizer/presentation/equalizer_screen.dart \
  lib/features/home/presentation/main_scaffold.dart \
  lib/features/lyric/presentation/lyric_view.dart \
  lib/features/player/presentation/player_provider.dart \
  lib/features/player/presentation/player_screen.dart \
  lib/features/player/presentation/widgets/mini_player.dart \
  lib/features/playlist/presentation/playlist_detail_screen.dart \
  lib/features/playlist/presentation/playlist_occurrence.dart \
  lib/features/playlist/presentation/playlist_provider.dart \
  lib/features/playlist/presentation/playlist_screen.dart \
  lib/features/search/presentation/search_provider.dart \
  lib/features/settings/presentation/settings_provider.dart \
  lib/features/settings/presentation/settings_screen.dart \
  test/app_message_test.dart \
  test/core/widgets/interactive_controls_accessibility_test.dart \
  test/features/accessibility/adjustable_semantics_test.dart \
  test/features/accessibility/core_screens_semantics_test.dart \
  test/features/custom_source/presentation/custom_source_screen_test.dart \
  test/features/equalizer/presentation/equalizer_screen_test.dart \
  test/features/player/presentation/position_rebuild_test.dart \
  test/features/playlist/presentation/playlist_detail_favorites_test.dart \
  test/features/playlist/presentation/playlist_navigation_test.dart \
  test/features/playlist/presentation/playlist_screen_test.dart \
  test/features/settings/restore_live_state_test.dart
```

Expected: exits `0`; a second run reports no formatting changes.

- [ ] **Step 2: Run the complete focused Batch C suite**

Run:

```bash
flutter test \
  test/app_message_test.dart \
  test/core/widgets/interactive_controls_accessibility_test.dart \
  test/features/accessibility \
  test/features/custom_source/presentation/custom_source_screen_test.dart \
  test/features/equalizer/presentation/equalizer_screen_test.dart \
  test/features/home/swipe_ime_focus_test.dart \
  test/features/player/presentation/position_rebuild_test.dart \
  test/features/player/presentation/scrub_coordinator_test.dart \
  test/features/playlist/presentation/playlist_detail_favorites_test.dart \
  test/features/playlist/presentation/playlist_navigation_test.dart \
  test/features/playlist/presentation/playlist_provider_test.dart \
  test/features/playlist/presentation/playlist_screen_test.dart \
  test/features/settings/restore_live_state_test.dart
```

Expected: exits `0` with `All tests passed!` and no uncaught post-disposal Flutter errors.

- [ ] **Step 3: Run complete Flutter regression and static analysis**

Run: `flutter test && flutter analyze`

Expected: `flutter test` exits `0` with zero failures. `flutter analyze` exits `0`, with no diagnostics introduced by Batch C and no async-context diagnostics in modified import flows.

- [ ] **Step 4: Perform required manual accessibility and performance verification on macOS/iOS**

On a physical iOS device or simulator with a hardware keyboard:

1. Trigger a playback resolution failure from home and player routes; verify one SnackBar appears and a route transition does not duplicate or lose it.
2. Start custom-source URL and pasted-script imports, dismiss/navigate away at each await boundary, and verify no exception, late SnackBar, or second pop occurs.
3. Open/close the custom-source log repeatedly and verify events are not duplicated.
4. Deep-link to `/playlist/detail/<percent-encoded-id>` after cold launch and state restoration; verify repository updates and deletion are reflected live.
5. Reorder two occurrences of the same song and verify the dragged row, focus, and content remain attached to that occurrence.
6. Traverse bottom navigation, player, mini player, playlist, download, settings, lyrics, and equalizer with Tab/Shift-Tab; activate every core action with Enter and Space.
7. Enable VoiceOver/Switch Control; verify button, selected/toggled, current value, and disabled state announcements. Use swipe up/down on playback progress, lyrics, and all equalizer bands.
8. Capture Flutter DevTools/Instruments rebuild traces while a song plays. Verify `PlayerScreen`, static mini-player metadata, and the full lyric list no longer rebuild at the 100 ms position cadence; only progress/current lyric/KTV word subtrees do.

Expected: all eight checks pass. Record any platform-only failure before declaring Batch C complete; do not mask it by weakening automated assertions.
