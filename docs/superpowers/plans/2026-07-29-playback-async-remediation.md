# Playback and Asynchronous State Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate Batch A playback ownership races, cancellable scrub leaks, audio runtime leaks, stale lyric/search publications, and silent sleep-timer pause failures.

**Architecture:** Queue and source operations will prove ownership with a stable per-occurrence integer that survives reorder operations, while lyric and search requests use monotonic generations. Playback selection will pause the installed source before publishing the selected occurrence as buffering, scrub sessions will own an idempotent cancellation path, and one asynchronous runtime disposal chain will close every audio subscription and native resource.

**Tech Stack:** Flutter, Dart 3.2+, Riverpod 2.6, audio_service 0.18, just_audio 0.9, audio_session 0.1, flutter_test

## Global Constraints

- Work only in the extracted `/tmp/opencode/LX2IOS-main` source tree.
- Preserve the behavior of the two excluded playlist-import findings.
- Avoid unrelated refactors and major dependency upgrades.
- Fix root causes rather than masking races with delays or retries.
- Follow existing Riverpod, audio handler, storage, and Worker patterns where they are sound.
- Add focused regression coverage proportional to each change's risk.
- Treat Linux-incompatible Xcode, VoiceOver, Instruments, and App Store checks as explicit manual verification items.
- Every asynchronous result must prove ownership before mutating state.
- Cancellation is expected control flow: release owners without publishing stale errors.
- The source tree has no Git metadata. Do not run `git add`, `git commit`, or any other commit command; every task ends by explicitly recording **Not committed**.
- Do not modify Worker, persistence, download, sync, navigation, accessibility, or iOS project files in this Batch A plan.

---

## File Map

- `lib/core/audio/playback_command_coordinator.dart`: identify desired native sources by stable queue occurrence rather than mutable queue index.
- `lib/core/audio/audio_handler.dart`: own queue occurrence identities, source/UI transaction publication, internal subscriptions, cache leases, and native player disposal.
- `lib/main.dart`: register audio-session subscriptions, resolver cancellation, handler disposal, and cache disposal in dependency-safe order.
- `lib/features/player/presentation/player_provider.dart`: add cancellable scrub sessions and an explicit sleep-timer state machine.
- `lib/features/player/presentation/player_screen.dart`: cancel active full-player scrub work on gesture cancellation and widget disposal.
- `lib/features/player/presentation/widgets/mini_player.dart`: apply the same scrub cancellation contract to the mini player.
- `lib/features/lyric/presentation/lyric_provider.dart`: reject stale lyric results through a notifier-owned request generation.
- `lib/features/search/presentation/search_provider.dart`: store query/source snapshots in state and reject stale first-page and pagination results.
- `lib/features/search/presentation/search_screen.dart`: request pagination from notifier state rather than the mutable text controller.
- `test/core/audio/playback_command_coordinator_test.dart`: verify occurrence-bearing source requests and selection pause ordering.
- `test/core/audio/playback_resolution_test.dart`: preserve active occurrence authority across queue moves, including duplicate media IDs.
- `test/core/audio/playback_state_test.dart`: verify paused-buffering UI/source ownership during URL resolution.
- `test/features/player/presentation/scrub_coordinator_test.dart`: verify cancel/dispose idempotence and preserving-owner release.
- `test/startup_lifecycle_test.dart`: verify audio runtime cleanup order and one-time disposal.
- `test/features/lyric/presentation/lyric_provider_test.dart`: verify stale lyric success and clear results cannot publish.
- `test/features/search/presentation/search_provider_test.dart`: verify stale search results and state-owned pagination snapshots.
- `test/features/player/presentation/sleep_timer_test.dart`: verify pause success and failure states.

### Task 1: Stable Queue Occurrence Identity

**Files:**
- Modify: `lib/core/audio/playback_command_coordinator.dart:100-139,471-484`
- Modify: `lib/core/audio/audio_handler.dart:248-266,272-285,330-409,593-651,1083-1149,1152-1540,1542-1707,1725-1759`
- Test: `test/core/audio/playback_command_coordinator_test.dart`
- Test: `test/core/audio/playback_resolution_test.dart:883-1107`

**Interfaces:**
- Consumes: public queue APIs remain `List<MediaItem> get queueItems`, `Future<void> updateQueue(List<MediaItem>)`, and `Future<void> skipToQueueItem(int, {bool seamless, Duration initialPosition, bool playAfterLoad})`.
- Produces: `int PlaybackCommandCoordinator.requestSource({required String mediaId, required int occurrenceId, required Duration position})`.
- Produces internally: aligned `List<int> _queueOccurrenceIds`, `_PreloadRequest(..., int occurrenceId, MediaItem item)`, and `_ForegroundResolutionRequest(..., int occurrenceId, MediaItem item)`.
- Invariant: `MediaItem.id` identifies media content; the aligned occurrence integer identifies one queue appearance and survives moves and immutable `MediaItem.copyWith` replacements.

- [ ] **Step 1: Change the two move tests to require the active occurrence to remain authoritative**

Replace the moved-occurrence expectations in `test/core/audio/playback_resolution_test.dart` with tests that distinguish move from replacement:

```dart
test('active occurrence moved during resolution still installs once', () async {
  final player = _ReuseAudioPlayer();
  final handler = LxAudioHandler(player: player);
  addTearDown(handler.dispose);
  final started = Completer<void>();
  final release = Completer<void>();
  handler.urlResolver = (id, [extras]) async {
    started.complete();
    await release.future;
    return 'https://cdn.example/active.mp3';
  };
  final first = _cachedItem('duplicate', '/tmp/first.mp3');
  final active = _unresolvedItem('duplicate');

  final loading = handler.setPlaylist([first, active], initialIndex: 1);
  await started.future;
  await handler.updateQueue([active, first]);
  release.complete();
  await loading;

  expect(handler.currentQueueIndex, 0);
  expect(handler.mediaItem.value, same(handler.queueItems[0]));
  expect(player.lastInstalledUri, 'https://cdn.example/active.mp3');
  expect(player.sourceInstallCount, 1);
});

test('replacing an occurrence during resolution rejects its result', () async {
  final player = _ReuseAudioPlayer();
  final handler = LxAudioHandler(player: player);
  addTearDown(handler.dispose);
  final started = Completer<void>();
  final release = Completer<void>();
  handler.urlResolver = (id, [extras]) async {
    started.complete();
    await release.future;
    return 'https://cdn.example/stale.mp3';
  };
  final loading = handler.setPlaylist([_unresolvedItem('duplicate')]);
  await started.future;

  await handler.updateQueue([_unresolvedItem('duplicate')]);
  release.complete();
  await loading;

  expect(player.sourceInstallCount, 0);
  expect(handler.queueItems.single.extras?['url'], isNull);
});
```

- [ ] **Step 2: Run the focused red tests**

Run:

```bash
flutter test test/core/audio/playback_resolution_test.dart --plain-name "active occurrence moved during resolution still installs once"
flutter test test/core/audio/playback_resolution_test.dart --plain-name "replacing an occurrence during resolution rejects its result"
```

Expected: the move test fails because `activeItemIndex()` still requires the old slot and object identity; the replacement test passes and remains a guard against treating equal media IDs as the same occurrence.

- [ ] **Step 3: Carry occurrence identity through source requests**

In `playback_command_coordinator.dart`, replace `queueIndex` with `occurrenceId` in the source request contract and desired source value:

```dart
int requestSource({
  required String mediaId,
  required int occurrenceId,
  required Duration position,
}) {
  final token = ++_sourceToken;
  _desiredSource = _DesiredSource(
    token: token,
    mediaId: mediaId,
    occurrenceId: occurrenceId,
    position: position,
  );
  _failedSourceToken = null;
  _failedSourceCommit = null;
  _stopDesired = false;
  _desiredSeek = null;
  _appliedSeekRevision = _seekRevision;
  _markDirty();
  return token;
}

class _DesiredSource {
  final int token;
  final String mediaId;
  final int occurrenceId;
  final Duration position;
  AudioSource? source;

  _DesiredSource({
    required this.token,
    required this.mediaId,
    required this.occurrenceId,
    required this.position,
  });
}
```

Update every coordinator test request to pass `occurrenceId: 1` (or `2` for the B request). Do not leave any `queueIndex:` argument in this file or its tests.

- [ ] **Step 4: Add stable occurrences beside the existing public MediaItem queue**

In `audio_handler.dart`, retain `_queue` as `List<MediaItem>` for compatibility and add an aligned identity list plus helpers:

```dart
final List<MediaItem> _queue = [];
final List<int> _queueOccurrenceIds = [];
int _nextQueueOccurrenceId = 0;
int? _activeOccurrenceId;

int _newOccurrenceId() => ++_nextQueueOccurrenceId;

int _occurrenceIdAt(int index) => _queueOccurrenceIds[index];

int _indexOfOccurrence(int occurrenceId) =>
    _queueOccurrenceIds.indexOf(occurrenceId);

void _replaceQueuePreservingOccurrences(List<MediaItem> items) {
  final oldItems = List<MediaItem>.of(_queue);
  final oldOccurrences = List<int>.of(_queueOccurrenceIds);
  final claimed = <int>{};
  final nextOccurrences = <int>[];
  for (final item in items) {
    var oldIndex = -1;
    for (var i = 0; i < oldItems.length; i++) {
      if (!claimed.contains(i) && identical(oldItems[i], item)) {
        oldIndex = i;
        break;
      }
    }
    if (oldIndex >= 0) {
      claimed.add(oldIndex);
      nextOccurrences.add(oldOccurrences[oldIndex]);
    } else {
      nextOccurrences.add(_newOccurrenceId());
    }
  }
  _queue
    ..clear()
    ..addAll(items);
  _queueOccurrenceIds
    ..clear()
    ..addAll(nextOccurrences);
}

void _replaceQueueItem(int index, MediaItem item) {
  _queue[index] = item;
}
```

Use `_replaceQueueItem` for every internal `MediaItem.copyWith` replacement so the aligned occurrence ID is intentionally retained. Clear `_queueOccurrenceIds` and `_activeOccurrenceId` whenever the queue is cleared.

For `setPlaylist`, allocate fresh identities for every supplied item:

```dart
_queue
  ..clear()
  ..addAll(items);
_queueOccurrenceIds
  ..clear()
  ..addAll(List<int>.generate(items.length, (_) => _newOccurrenceId()));
```

For `updateQueue`, call `_replaceQueuePreservingOccurrences(queue)`, locate the active entry with `_indexOfOccurrence(_activeOccurrenceId!)`, and only fall back to index `0` when that occurrence is absent. For `addQueueItem` append `_newOccurrenceId()`; for removal remove the item and occurrence ID at the same index.

- [ ] **Step 5: Make every asynchronous ownership check occurrence-based**

Change request records to carry `occurrenceId`, then resolve their current index at publication time:

```dart
class _PreloadRequest {
  const _PreloadRequest(
    this.generation,
    this.occurrenceId,
    this.item,
  );

  final int generation;
  final int occurrenceId;
  final MediaItem item;
  String get mediaId => item.id;
}

class _ForegroundResolutionRequest {
  _ForegroundResolutionRequest(
    this.generation,
    this.occurrenceId,
    this.item,
  );

  final int generation;
  final int occurrenceId;
  MediaItem item;
  String get mediaId => item.id;
}
```

Use the occurrence lookup in `acceptResolvedPlayback`:

```dart
final index = request == null ? -1 : _indexOfOccurrence(request.occurrenceId);
final valid = request != null &&
    request.generation == generation &&
    generation == _playGeneration &&
    request.mediaId == mediaId &&
    request.occurrenceId == _activeOccurrenceId &&
    index >= 0 &&
    index == _currentIndex &&
    identical(_queue[index], request.item) &&
    identical(mediaItem.value, request.item);
```

After `patchQueueItemExtrasAt`, retain `request.item = _queue[index]`. Apply the same pattern to preload requests, but reject when `request.occurrenceId == _activeOccurrenceId`.

Change pending resolution ownership from media ID to occurrence ID:

```dart
final Map<int, PlaybackResolution> _pendingResolutions = {};

void _discardPendingResolution(int occurrenceId) {
  final resolution = _pendingResolutions.remove(occurrenceId);
  final lease = resolution?.leaseOrNull;
  if (lease != null) unawaited(_leaseSession.discardPending(lease));
}
```

Store accepted foreground results as `_pendingResolutions[request.occurrenceId]`, and change `_takePendingLeaseForUrl`, `_commitStagedLease`, and `_discardStagedLease` to accept `int occurrenceId`. This prevents two queue occurrences with the same `MediaItem.id` from replacing or releasing each other's pending lease. Removal must call `_discardPendingResolution(removedOccurrenceId)` after reading the aligned ID and before removing the slot.

At `_loadQueueItem` entry capture `final occurrenceId = _occurrenceIdAt(index)`, assign `_activeOccurrenceId = occurrenceId`, create `_ForegroundResolutionRequest(gen, occurrenceId, item)`, and define `activeItemIndex()` from `_indexOfOccurrence(occurrenceId)`. It must require the occurrence to remain active and allow its index to change:

```dart
int activeItemIndex() {
  final liveIndex = _indexOfOccurrence(occurrenceId);
  if (_isStale(gen) ||
      !_commands.ownsSourceRequest(commandToken) ||
      _activeOccurrenceId != occurrenceId ||
      liveIndex < 0 ||
      liveIndex != _currentIndex ||
      !identical(_queue[liveIndex], foregroundRequest.item) ||
      !identical(mediaItem.value, foregroundRequest.item)) {
    return -1;
  }
  foregroundRequest.item = _queue[liveIndex];
  return liveIndex;
}
```

Pass `occurrenceId:` to every `_commands.requestSource` call. Completion checks must compare `_activeOccurrenceId`, `_occurrenceIdAt(expectedIndex)`, and the captured expected occurrence instead of relying only on `MediaItem.id`.

- [ ] **Step 6: Run occurrence and coordinator tests green**

Run:

```bash
flutter test test/core/audio/playback_command_coordinator_test.dart
flutter test test/core/audio/playback_resolution_test.dart
flutter test test/core/audio/lockscreen_autonext_test.dart
```

Expected: all tests pass; the moved occurrence installs exactly once, the replacement remains stale, duplicate IDs still select the exact occurrence, and completion advances once.

- [ ] **Step 7: Record task status without committing**

Record in the execution log: `Task 1 complete; occurrence identity tests pass; Not committed (source tree has no Git metadata).`

### Task 2: Pause Old Source and Publish One Selected Source/UI Transaction

**Files:**
- Modify: `lib/core/audio/audio_handler.dart:653-684,963-1069,1152-1518`
- Modify: `lib/core/audio/playback_command_coordinator.dart:100-139,155-177,314-397`
- Test: `test/core/audio/playback_command_coordinator_test.dart`
- Test: `test/core/audio/playback_state_test.dart`

**Interfaces:**
- Consumes: Task 1 `occurrenceId` source ownership.
- Produces: private `_PlaybackHalt(PreservingPauseOwner owner)` remains the one selection-pause lease; it does not carry playback-state publication ownership.
- Produces internally: `_loadQueueItem` creates the selected occurrence's buffering publication after the halt and retains its publication token for scoped engine-state restoration.
- Produces behavior: non-seamless selection pauses native output before `mediaItem`, queue index, artwork/lyrics identity, and buffering state move to the selected occurrence.
- Produces behavior: while selected URL resolution is pending, playback state is `buffering`, `playing == false`, and `queueIndex`/`mediaItem` both identify the selected occurrence.

- [ ] **Step 1: Add a red source/UI consistency test**

Add to `test/core/audio/playback_state_test.dart`:

```dart
test('selection pauses old source before publishing selected buffering UI',
    () async {
  final player = _PlaybackStateAudioPlayer()
    ..sourceInstallProcessingState = ProcessingState.ready;
  final handler = LxAudioHandler(player: player);
  addTearDown(handler.dispose);
  final selectedResolverStarted = Completer<void>();
  final releaseSelectedResolver = Completer<void>();
  handler.urlResolver = (id, [extras]) async {
    if (id == 'B') {
      selectedResolverStarted.complete();
      await releaseSelectedResolver.future;
    }
    return 'file:///tmp/$id.mp3';
  };
  await handler.setPlaylist(const [
    MediaItem(id: 'A', title: 'A'),
    MediaItem(id: 'B', title: 'B'),
  ]);
  expect(player.playing, isTrue);

  final selection = handler.skipToQueueItem(1);
  await selectedResolverStarted.future;

  expect(player.pauseCalls, 1);
  expect(player.playing, isFalse);
  expect(handler.mediaItem.value?.id, 'B');
  expect(handler.currentQueueIndex, 1);
  expect(handler.playbackState.value.queueIndex, 1);
  expect(
    handler.playbackState.value.processingState,
    AudioProcessingState.buffering,
  );
  expect(handler.playbackState.value.playing, isFalse);

  releaseSelectedResolver.complete();
  await selection;
  expect(player.playing, isTrue);
  expect(handler.playbackState.value.playing, isTrue);
});
```

- [ ] **Step 2: Run the source/UI test red**

Run:

```bash
flutter test test/core/audio/playback_state_test.dart --plain-name "selection pauses old source before publishing selected buffering UI"
```

Expected: FAIL because `skipToQueueItem(..., playAfterLoad: true)` currently leaves A audible while publishing B as the active `mediaItem`.

- [ ] **Step 3: Make non-seamless selection acquire one preserving pause owner**

In `skipToQueueItem`, validate the selected occurrence, request the source, then halt before `_loadQueueItem` publishes it. Re-read the occurrence after the awaited pause:

```dart
final selectedOccurrenceId = _occurrenceIdAt(index);
final sourceCommandToken = _commands.requestSource(
  mediaId: selectedItem.id,
  occurrenceId: selectedOccurrenceId,
  position: initialPosition,
);
final halt = seamless ? null : await _haltCurrentPlayback();
final relocatedIndex = _indexOfOccurrence(selectedOccurrenceId);
if (relocatedIndex < 0 ||
    !identical(_queue[relocatedIndex], selectedItem) ||
    !_commands.ownsSourceRequest(
      sourceCommandToken,
      selectedOccurrenceId,
    )) {
  if (halt != null) {
    await _commands.releasePreservingIntent(halt.owner);
  }
  return;
}
await _loadQueueItem(
  relocatedIndex,
  seamless: seamless,
  preserveUserIntent: true,
  initialPosition: initialPosition,
  provenance: provenance,
  sourceCommandToken: sourceCommandToken,
  preservingPauseOwner: halt?.owner,
);
```

Remove the old `selectionPauseOwner` branch. `_haltCurrentPlayback` remains responsible for bumping source generation, cancelling old foreground cache work, acquiring a preserving pause owner, awaiting native pause through the coordinator, and publishing paused buffering state for the old occurrence. Its return value contains only the owner; selected buffering publication ownership starts inside `_loadQueueItem`.

- [ ] **Step 4: Publish selected metadata only after the halt and keep buffering ownership token-scoped**

At `_loadQueueItem` entry, do not publish the selected `mediaItem` before the caller-provided halt has completed. Once occurrence ownership is established, publish these values in this order without an `await` between them:

```dart
_currentIndex = index;
_activeOccurrenceId = occurrenceId;
_activeItemId = itemId;
mediaItem.add(item);
queue.add(List.unmodifiable(_queue));
final manualBufferingPublication = _publishPlaybackState(
  override: AudioProcessingState.buffering,
  playingOverride: seamless ? true : false,
);
```

This publication is created by `_loadQueueItem` only after selected occurrence ownership has been established and the caller-provided halt has completed. When URL resolution begins, reuse it instead of issuing a second contradictory buffering publication. In `finally`, restore the engine state only when `manualBufferingPublication == _playbackPublicationToken`; stale transactions must not clear a newer transaction's buffering state. `_PlaybackHalt` does not carry or transfer this token.

- [ ] **Step 5: Verify pause ordering and complete playback state**

Run:

```bash
flutter test test/core/audio/playback_command_coordinator_test.dart
flutter test test/core/audio/playback_state_test.dart
flutter test test/core/audio/audio_interruption_policy_test.dart
```

Expected: all tests pass; native mutations remain serialized, selected buffering state is paused and internally consistent, seamless completion remains `playing == true`, and interruption ownership tests remain green.

- [ ] **Step 6: Record task status without committing**

Record: `Task 2 complete; old-source pause and selected-source publication tests pass; Not committed.`

### Task 3: Idempotent Scrub Cancel and Widget Disposal

**Files:**
- Modify: `lib/features/player/presentation/player_provider.dart:235-507`
- Modify: `lib/features/player/presentation/player_screen.dart:25-45,522-667`
- Modify: `lib/features/player/presentation/widgets/mini_player.dart:26-31,129-190`
- Test: `test/features/player/presentation/scrub_coordinator_test.dart`

**Interfaces:**
- Consumes: existing `ScrubCoordinator.begin()` and `finish(int, Duration, {required bool resumeAfter})`.
- Produces: `Future<void> ScrubCoordinator.cancel(int generation)` and `Future<void> ScrubCoordinator.cancelAll()`.
- Produces: `Future<void> Function(int) cancelScrubProvider`.
- Invariant: cancellation never seeks, releases a preserving owner at most once, restores the actual engine position only for the current transaction, and is safe after finish or repeated cancel.

- [ ] **Step 1: Add red coordinator cancellation tests**

Add to `scrub_coordinator_test.dart`:

```dart
test('cancel releases preserving pause once without seeking', () async {
  final playback = _FakeScrubPlayback(
    playing: true,
    position: const Duration(seconds: 18),
    seekResult: const Duration(seconds: 50),
  );
  final position = _FakeScrubPosition();
  final coordinator = ScrubCoordinator(playback, position);
  final generation = await coordinator.begin();

  await coordinator.cancel(generation);
  await coordinator.cancel(generation);

  expect(playback.seekCalls, 0);
  expect(playback.releaseCalls, 1);
  expect(playback.resumeCalls, 1);
  expect(position.unfreezes, [const Duration(seconds: 18)]);
});

test('cancelAll releases a pending pause after disposal', () async {
  final pauseGate = _Gate();
  final playback = _FakeScrubPlayback(
    playing: true,
    position: const Duration(seconds: 7),
  )..pauseGate = pauseGate;
  final position = _FakeScrubPosition();
  final coordinator = ScrubCoordinator(playback, position);

  final begin = coordinator.begin();
  await pauseGate.started.future;
  final cancellation = coordinator.cancelAll();
  pauseGate.release.complete();
  await Future.wait([begin, cancellation]);

  expect(playback.seekCalls, 0);
  expect(playback.releaseCalls, 1);
  expect(position.unfreezes, [const Duration(seconds: 7)]);
});
```

Add `int releaseCalls = 0;` to `_FakeScrubPlayback` and increment it at the start of `releaseAfterScrub`.

- [ ] **Step 2: Run scrub cancellation tests red**

Run:

```bash
flutter test test/features/player/presentation/scrub_coordinator_test.dart --plain-name "cancel releases preserving pause once without seeking"
flutter test test/features/player/presentation/scrub_coordinator_test.dart --plain-name "cancelAll releases a pending pause after disposal"
```

Expected: compile failure because `cancel` and `cancelAll` do not exist.

- [ ] **Step 3: Implement idempotent cancellation in the coordinator**

Add these methods before `_releaseTransaction`:

```dart
Future<void> cancel(int generation) async {
  final transaction = _transactions[generation];
  if (transaction == null) return;
  final ownsCurrent = generation == _generation;
  await _releaseTransaction(transaction, resumeAfter: true);
  if (ownsCurrent && generation == _generation) {
    _generation++;
    _position.unfreeze(_playback.position);
  }
}

Future<void> cancelAll() async {
  final transactions = _transactions.values.toList(growable: false);
  if (transactions.isEmpty) return;
  final cancelledGeneration = _generation;
  _generation++;
  await Future.wait(
    transactions.map(
      (transaction) =>
          _releaseTransaction(transaction, resumeAfter: true),
    ),
  );
  if (_generation == cancelledGeneration + 1) {
    _position.unfreeze(_playback.position);
  }
}
```

The existing `releaseFuture ??=` in `_releaseTransaction` is the exactly-once guard. Add the provider:

```dart
final cancelScrubProvider = Provider<Future<void> Function(int)>((ref) {
  return ref.read(scrubCoordinatorProvider).cancel;
});
```

Register coordinator cleanup in its provider:

```dart
final coordinator = ScrubCoordinator(
  _HandlerScrubPlayback(
    handler,
    ref.read(playerServiceProvider),
    position,
  ),
  position,
);
ref.onDispose(() => unawaited(coordinator.cancelAll()));
return coordinator;
```

- [ ] **Step 4: Wire drag cancellation and disposal in both widgets**

Add this method to both `_PlayerScreenState` and `_MiniPlayerState`:

```dart
void _cancelActiveScrub() {
  final future = _scrubFuture;
  final cancel = ref.read(cancelScrubProvider);
  _scrubFuture = Future<int>.value(0);
  unawaited(future.then((generation) {
    if (generation == 0) return;
    return cancel(generation);
  }).catchError((Object _, StackTrace __) {}));
  _seeking = false;
}
```

Add `import 'dart:async';` to both widget files. Capturing `cancel` synchronously is required because the future can complete after the widget's `ref` is invalid. Call `_cancelActiveScrub()` before `super.dispose()` (and before disposing `_pageController` in `PlayerScreen`). Add `onHorizontalDragCancel` to each progress `GestureDetector`:

```dart
onHorizontalDragCancel: () {
  _cancelActiveScrub();
  if (mounted) setState(() {});
},
```

After successful drag end, reset `_scrubFuture = Future<int>.value(0)` before clearing `_seeking`, so later widget disposal is a no-op. The tap path must use the same tracked future rather than a local-only begin:

```dart
_scrubFuture = ref.read(beginScrubProvider)();
final generation = await _scrubFuture;
await ref.read(finishScrubProvider)(
  generation,
  target,
  resumeAfter: isPlayingValue,
);
_scrubFuture = Future<int>.value(0);
if (mounted) setState(() => _seeking = false);
```

Use the existing local `playing` variable instead of `isPlayingValue` in the `PlayerScreen` copy. This ensures route disposal can cancel both drag and tap scrub transactions.

- [ ] **Step 5: Run all scrub tests green and analyze widget wiring**

Run:

```bash
flutter test test/features/player/presentation/scrub_coordinator_test.dart
flutter analyze lib/features/player/presentation/player_provider.dart lib/features/player/presentation/player_screen.dart lib/features/player/presentation/widgets/mini_player.dart
```

Expected: all scrub tests pass; analysis reports `No issues found!`; cancel/dispose performs no seek and releases each owner once.

- [ ] **Step 6: Record task status without committing**

Record: `Task 3 complete; scrub cancel/dispose tests pass; Not committed.`

### Task 4: Audio Runtime Disposal Ownership

**Files:**
- Modify: `lib/core/audio/audio_handler.dart:268-328,526-591,947-960,1833-1840`
- Modify: `lib/main.dart:20-199`
- Test: `test/startup_lifecycle_test.dart`
- Test: `test/core/audio/playback_state_test.dart:421-553`

**Interfaces:**
- Consumes: `ResourceDisposalTracker.register(Future<void> Function())`, `PlaybackCacheService.dispose()`, `PlaybackUrlResolver.cancelAllTracked()`, and `StreamSubscription.cancel()`.
- Produces: idempotent `Future<void> LxAudioHandler.dispose()`.
- Disposal order: audio-session subscriptions, handler internal subscriptions/native player, then playback cache. Handler disposal invokes resolver cancellation before releasing leases and disposing the player.

- [ ] **Step 1: Add red handler disposal test**

Add to `playback_state_test.dart` and add counters to `_PlaybackStateAudioPlayer`:

```dart
test('handler disposal cancels streams and disposes native player once',
    () async {
  final player = _PlaybackStateAudioPlayer();
  final handler = LxAudioHandler(player: player);
  var cacheCancellationCalls = 0;
  handler.attachPlaybackCache(
    cancelAllTrackedCacheWork: () => cacheCancellationCalls++,
  );

  final first = handler.dispose();
  final second = handler.dispose();
  await Future.wait([first, second]);

  expect(identical(first, second), isTrue);
  expect(cacheCancellationCalls, 1);
  expect(player.disposeCalls, 1);
  expect(player.playbackEventListenCancels, 1);
  expect(player.processingStateListenCancels, 1);
});
```

Replace the fake's controller declarations with lazily initialized controllers and increment `disposeCalls` in `dispose()`:

```dart
late final StreamController<PlaybackEvent> _events =
    StreamController<PlaybackEvent>.broadcast(
  onCancel: () => playbackEventListenCancels++,
);
late final StreamController<ProcessingState> _processingStates =
    StreamController<ProcessingState>.broadcast(
  onCancel: () => processingStateListenCancels++,
);
int playbackEventListenCancels = 0;
int processingStateListenCancels = 0;
int disposeCalls = 0;

@override
Future<void> dispose() async {
  disposeCalls++;
  await _events.close();
  await _processingStates.close();
  await super.dispose();
}
```

- [ ] **Step 2: Run the disposal test red**

Run:

```bash
flutter test test/core/audio/playback_state_test.dart --plain-name "handler disposal cancels streams and disposes native player once"
```

Expected: compile failure because `LxAudioHandler.dispose()` and fake disposal counters do not exist.

- [ ] **Step 3: Own handler subscriptions and implement one disposal future**

Add fields:

```dart
StreamSubscription<PlaybackEvent>? _playbackEventSubscription;
StreamSubscription<ProcessingState>? _processingStateSubscription;
Future<void>? _disposeFuture;
bool _disposed = false;
```

Assign both subscriptions in `_init()` instead of discarding `listen()` results. Add:

```dart
Future<void> dispose() => _disposeFuture ??= _dispose();

Future<void> _dispose() async {
  _disposed = true;
  _bumpGeneration();
  _cancelForegroundCacheWork();
  final playbackEvents = _playbackEventSubscription;
  final processingStates = _processingStateSubscription;
  _playbackEventSubscription = null;
  _processingStateSubscription = null;
  await Future.wait([
    if (playbackEvents != null) playbackEvents.cancel(),
    if (processingStates != null) processingStates.cancel(),
  ]);
  await _releasePlaybackLeases();
  await _commands.stop();
  await _player.dispose();
}
```

Guard `_publishPlaybackState`, `_schedulePreload`, and asynchronous completion callbacks with `if (_disposed) return` so events already queued before cancellation cannot publish after teardown.

- [ ] **Step 4: Retain audio-session subscriptions in startup scope**

Add `import 'dart:async';`, declare nullable subscriptions immediately after `final session`, and assign them instead of discarding anonymous `listen()` results:

```dart
StreamSubscription<AudioInterruptionEvent>? interruptionSubscription;
StreamSubscription<void>? noisySubscription;
if (audioHandler is LxAudioHandler) {
  final lxHandler = audioHandler as LxAudioHandler;
  interruptionSubscription = session.interruptionEventStream.listen(
  (event) async {
    if (event.type == AudioInterruptionType.duck) return;
    if (event.begin) {
      await lxHandler.beginAudioInterruption();
    } else {
      await lxHandler.endAudioInterruption(
        mayResume: event.type == AudioInterruptionType.pause,
      );
    }
  },
  );
  noisySubscription = session.becomingNoisyEventStream.listen(
    (_) => lxHandler.handleBecomingNoisy(),
  );
}
```

- [ ] **Step 5: Register runtime resources exactly once in dependency-safe order**

Remove the existing `disposals.register(playbackCache.dispose);` immediately after cache construction. After cache initialization, handler cache/resolver attachment, `urlResolver`, and `onError` setup are complete, register in this exact order because `ResourceDisposalTracker` drains in reverse:

```dart
disposals.register(playbackCache.dispose);
disposals.register(lxHandler.dispose);
if (interruptionSubscription != null) {
  disposals.register(interruptionSubscription.cancel);
}
if (noisySubscription != null) {
  disposals.register(noisySubscription.cancel);
}
```

Do not register `playbackResolver.cancelAllTracked` separately: `lxHandler.dispose()` calls it through `cancelAllTrackedCacheWork`, then releases leases before cache disposal.

- [ ] **Step 6: Add a lifecycle ordering test**

In `startup_lifecycle_test.dart`, add a focused tracker test using real callback shapes:

```dart
test('audio runtime disposes subscriptions before handler before cache',
    () async {
  final events = <String>[];
  final tracker = ResourceDisposalTracker();
  tracker.register(() async => events.add('cache'));
  tracker.register(() async => events.add('handler'));
  tracker.register(() async => events.add('interruption-subscription'));
  tracker.register(() async => events.add('noisy-subscription'));

  await tracker.disposeAndDrain();

  expect(events, [
    'noisy-subscription',
    'interruption-subscription',
    'handler',
    'cache',
  ]);
});
```

- [ ] **Step 7: Run disposal and lifecycle tests green**

Run:

```bash
flutter test test/core/audio/playback_state_test.dart
flutter test test/startup_lifecycle_test.dart
flutter analyze lib/main.dart lib/core/audio/audio_handler.dart lib/startup_lifecycle.dart
```

Expected: tests pass, cleanup order is subscription → handler → cache, repeated handler disposal shares one future, and analysis reports no issues.

- [ ] **Step 8: Record task status without committing**

Record: `Task 4 complete; audio runtime disposal and ordering tests pass; Not committed.`

### Task 5: Lyric Request Generation

**Files:**
- Modify: `lib/features/lyric/presentation/lyric_provider.dart`
- Create: `test/features/lyric/presentation/lyric_provider_test.dart`

**Interfaces:**
- Consumes: `Future<Lyrics> LyricService.fetchLyric(MusicItem)` and `currentMusicProvider`.
- Produces: `typedef LyricLoader = Future<Lyrics> Function(MusicItem music)`.
- Produces: `LyricNotifier(LyricLoader load)` with `Future<void> select(MusicItem? music)`.
- Invariant: each selection, including `null`, increments generation; only the latest generation may publish.

- [ ] **Step 1: Create stale lyric tests**

Create `lyric_provider_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/lyric/domain/lyric.dart';
import 'package:lx_music_flutter/features/lyric/presentation/lyric_provider.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  test('late lyric result cannot overwrite a newer song', () async {
    final first = Completer<Lyrics>();
    final second = Completer<Lyrics>();
    final notifier = LyricNotifier(
      (music) => music.id == 'A' ? first.future : second.future,
    );
    addTearDown(notifier.dispose);

    final loadA = notifier.select(_music('A'));
    final loadB = notifier.select(_music('B'));
    second.complete(_lyrics('B'));
    await loadB;
    first.complete(_lyrics('A'));
    await loadA;

    expect(notifier.state.raw, 'B');
  });

  test('clearing selection invalidates an in-flight lyric request', () async {
    final pending = Completer<Lyrics>();
    final notifier = LyricNotifier((_) => pending.future);
    addTearDown(notifier.dispose);

    final load = notifier.select(_music('A'));
    await notifier.select(null);
    pending.complete(_lyrics('A'));
    await load;

    expect(notifier.state.isEmpty, isTrue);
  });
}

MusicItem _music(String id) => MusicItem(
      id: id,
      name: id,
      singer: 'artist',
      source: 'tx',
      platform: 'tx',
    );

Lyrics _lyrics(String value) => Lyrics(
      raw: value,
      lines: [LyricLine(time: Duration.zero, text: value)],
    );
```

- [ ] **Step 2: Run lyric tests red**

Run:

```bash
flutter test test/features/lyric/presentation/lyric_provider_test.dart
```

Expected: compile failure because the current notifier requires `Ref` and has no `select` method.

- [ ] **Step 3: Refactor provider wiring and add the generation**

Replace notifier construction and implementation with:

```dart
import 'dart:async';

typedef LyricLoader = Future<Lyrics> Function(MusicItem music);

final currentLyricProvider = StateNotifierProvider<LyricNotifier, Lyrics>((ref) {
  final notifier = LyricNotifier(
    ref.read(lyricServiceProvider).fetchLyric,
  );
  ref.listen<MusicItem?>(currentMusicProvider, (_, next) {
    unawaited(notifier.select(next));
  }, fireImmediately: true);
  return notifier;
});

class LyricNotifier extends StateNotifier<Lyrics> {
  LyricNotifier(this._load) : super(Lyrics.empty());

  final LyricLoader _load;
  int _generation = 0;

  Future<void> select(MusicItem? music) async {
    final generation = ++_generation;
    state = Lyrics.empty();
    if (music == null) return;
    final lyrics = await _load(music);
    if (!mounted || generation != _generation) return;
    state = lyrics;
  }
}
```

Remove `_Ref`, `_lastSongId`, and `loadLyric`. Repeated publications of the same current `MusicItem` are naturally avoided by the upstream media stream; correctness does not depend on ID deduplication.

- [ ] **Step 4: Run lyric tests green**

Run:

```bash
flutter test test/features/lyric/presentation/lyric_provider_test.dart
flutter test test/features/lyric/data/lyric_parser_test.dart
flutter analyze lib/features/lyric/presentation/lyric_provider.dart
```

Expected: stale A and cleared A cannot publish, parser regression tests pass, and analysis reports no issues.

- [ ] **Step 5: Record task status without committing**

Record: `Task 5 complete; lyric generation tests pass; Not committed.`

### Task 6: Search Generation and State-Owned Pagination Snapshot

**Files:**
- Modify: `lib/features/search/presentation/search_provider.dart:35-130`
- Modify: `lib/features/search/presentation/search_screen.dart:49-70,121-127`
- Create: `test/features/search/presentation/search_provider_test.dart`

**Interfaces:**
- Produces: `typedef SearchLoader = Future<List<MusicItem>> Function(String query, String sourceId, int page)`.
- Produces: `SearchState.query` and `SearchState.sourceId`, both defaulting to `''`.
- Produces: `Future<void> SearchNotifier.search(String query)` and `Future<void> SearchNotifier.loadMore()`.
- Consumes: `selectedSourceIdProvider` only when starting a new first-page search; pagination consumes `state.query` and `state.sourceId` snapshots.

- [ ] **Step 1: Create stale-result and pagination snapshot tests**

Create `search_provider_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';

void main() {
  test('late first-page result cannot overwrite a newer query', () async {
    final first = Completer<List<MusicItem>>();
    final second = Completer<List<MusicItem>>();
    var source = 'tx';
    final notifier = SearchNotifier(
      (query, sourceId, page) => query == 'old' ? first.future : second.future,
      () => source,
    );
    addTearDown(notifier.dispose);

    final oldSearch = notifier.search('old');
    source = 'kw';
    final newSearch = notifier.search('new');
    second.complete([_item('new')]);
    await newSearch;
    first.complete([_item('old')]);
    await oldSearch;

    expect(notifier.state.query, 'new');
    expect(notifier.state.sourceId, 'kw');
    expect(notifier.state.items.single.id, 'new');
  });

  test('loadMore uses state query and source snapshots', () async {
    final calls = <({String query, String source, int page})>[];
    var selectedSource = 'tx';
    final notifier = SearchNotifier((query, source, page) async {
      calls.add((query: query, source: source, page: page));
      return List.generate(20, (index) => _item('$query-$page-$index'));
    }, () => selectedSource);
    addTearDown(notifier.dispose);

    await notifier.search('stored');
    selectedSource = 'wy';
    await notifier.loadMore();

    expect(calls, [
      (query: 'stored', source: 'tx', page: 1),
      (query: 'stored', source: 'tx', page: 2),
    ]);
    expect(notifier.state.page, 2);
    expect(notifier.state.items, hasLength(40));
  });
}

MusicItem _item(String id) => MusicItem(
      id: id,
      name: id,
      singer: 'artist',
      source: 'tx',
      platform: 'tx',
    );
```

- [ ] **Step 2: Run search tests red**

Run:

```bash
flutter test test/features/search/presentation/search_provider_test.dart
```

Expected: compile failure because the notifier takes `MusicSourceService`/`Ref`, state lacks snapshots, and `loadMore()` does not exist.

- [ ] **Step 3: Add exact state snapshots and loader interface**

Add fields and copy support:

```dart
final String query;
final String sourceId;

SearchState({
  this.items = const [],
  this.page = 1,
  this.isLoading = false,
  this.hasMore = true,
  this.error,
  this.query = '',
  this.sourceId = '',
});
```

Add `String? query` and `String? sourceId` to `copyWith`, and copy them with `query ?? this.query` / `sourceId ?? this.sourceId`.

Define and wire the loader:

```dart
typedef SearchLoader = Future<List<MusicItem>> Function(
  String query,
  String sourceId,
  int page,
);

final searchStateProvider =
    StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final service = ref.watch(musicSourceServiceProvider);
  return SearchNotifier(
    (query, sourceId, page) => service.search(
      query,
      customSourceId: sourceId,
      page: page,
      type: 'music',
    ),
    () => ref.read(selectedSourceIdProvider),
  );
});
```

- [ ] **Step 4: Implement generation-owned first page and pagination**

Replace `SearchNotifier` with:

```dart
class SearchNotifier extends StateNotifier<SearchState> {
  SearchNotifier(this._load, this._readSelectedSource) : super(SearchState());

  final SearchLoader _load;
  final String Function() _readSelectedSource;
  int _generation = 0;

  Future<void> search(String rawQuery) async {
    final query = rawQuery.trim();
    final generation = ++_generation;
    if (query.isEmpty) {
      state = SearchState();
      return;
    }
    final sourceId = _readSelectedSource();
    state = SearchState(
      isLoading: true,
      query: query,
      sourceId: sourceId,
    );
    await _loadPage(
      generation: generation,
      query: query,
      sourceId: sourceId,
      page: 1,
      append: false,
    );
  }

  Future<void> loadMore() async {
    if (state.isLoading || !state.hasMore || state.query.isEmpty) return;
    final generation = _generation;
    final query = state.query;
    final sourceId = state.sourceId;
    final page = state.page + 1;
    state = state.copyWith(isLoading: true, error: null);
    await _loadPage(
      generation: generation,
      query: query,
      sourceId: sourceId,
      page: page,
      append: true,
    );
  }

  Future<void> _loadPage({
    required int generation,
    required String query,
    required String sourceId,
    required int page,
    required bool append,
  }) async {
    try {
      final results = await _load(query, sourceId, page);
      if (!mounted ||
          generation != _generation ||
          state.query != query ||
          state.sourceId != sourceId) {
        return;
      }
      state = state.copyWith(
        items: append ? [...state.items, ...results] : results,
        page: page,
        isLoading: false,
        hasMore: results.length >= 20,
        error: null,
      );
    } catch (error, stackTrace) {
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted ||
          generation != _generation ||
          state.query != query ||
          state.sourceId != sourceId) {
        return;
      }
      state = state.copyWith(isLoading: false, error: error.toString());
    }
  }

  void reset() {
    _generation++;
    state = SearchState();
  }
}
```

- [ ] **Step 5: Remove mutable text input from pagination**

Replace `_loadMore()` in `search_screen.dart` with:

```dart
void _loadMore() {
  ref.read(searchStateProvider.notifier).loadMore();
}
```

Keep `_onSearch` as `search(query.trim())`. Platform selection still calls `_onSearch` to start a new generation with the newly selected source.

- [ ] **Step 6: Run search tests green**

Run:

```bash
flutter test test/features/search/presentation/search_provider_test.dart
flutter analyze lib/features/search/presentation/search_provider.dart lib/features/search/presentation/search_screen.dart
```

Expected: stale first-page results are inert, page 2 uses the stored `stored`/`tx` snapshot even after mutable source input changes, and analysis reports no issues.

- [ ] **Step 7: Record task status without committing**

Record: `Task 6 complete; search generation and pagination snapshot tests pass; Not committed.`

### Task 7: Deterministic Sleep-Timer Pause Failure State

**Files:**
- Modify: `lib/features/player/presentation/player_provider.dart:186-230`
- Create: `test/features/player/presentation/sleep_timer_test.dart`

**Interfaces:**
- Produces: sealed `SleepTimerState` with `SleepTimerIdle`, `SleepTimerRunning`, and `SleepTimerFailed`.
- Produces: stable, safe `SleepTimerFailureReason`; failed state exposes only the reason and original duration, never the raw pause error or stack trace.
- Produces: `SleepTimerNotifier(Future<void> Function() pause)`.
- Produces: `StateNotifierProvider<SleepTimerNotifier, SleepTimerState> sleepTimerProvider`.
- `sleepTimerEndProvider` returns `state.endTime`; idle and failed states return `null`.

- [ ] **Step 1: Create success and failure tests**

Create `sleep_timer_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  testWidgets('timer publishes idle only after pause succeeds', (tester) async {
    var pauseCalls = 0;
    final notifier = SleepTimerNotifier(() async => pauseCalls++);
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    expect(notifier.state, isA<SleepTimerRunning>());
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    expect(pauseCalls, 1);
    expect(notifier.state, isA<SleepTimerIdle>());
  });

  testWidgets('timer exposes pause failure deterministically', (tester) async {
    final notifier = SleepTimerNotifier(
      () async => throw StateError('token=secret https://example.com'),
    );
    addTearDown(notifier.dispose);

    notifier.startTimer(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final state = notifier.state;
    expect(state, isA<SleepTimerFailed>());
    expect(
      (state as SleepTimerFailed).reason,
      SleepTimerFailureReason.pauseFailed,
    );
    expect(state.duration, const Duration(seconds: 1));
    expect(state.endTime, isNull);
    expect(state.toString(), isNot(contains('secret')));
    expect(state.toString(), isNot(contains('example.com')));
  });
}
```

- [ ] **Step 2: Run sleep-timer tests red**

Run:

```bash
flutter test test/features/player/presentation/sleep_timer_test.dart
```

Expected: compile failure because the current notifier has a no-argument constructor and only exposes `Duration?` state.

- [ ] **Step 3: Implement explicit timer states and await pause failure**

Replace the timer section with:

```dart
sealed class SleepTimerState {
  const SleepTimerState();
  DateTime? get endTime => null;
}

final class SleepTimerIdle extends SleepTimerState {
  const SleepTimerIdle();
}

final class SleepTimerRunning extends SleepTimerState {
  const SleepTimerRunning(this.duration, this.scheduledEndTime);

  final Duration duration;
  final DateTime scheduledEndTime;

  @override
  DateTime get endTime => scheduledEndTime;
}

enum SleepTimerFailureReason { pauseFailed }

final class SleepTimerFailed extends SleepTimerState {
  const SleepTimerFailed(this.reason, this.duration);

  final SleepTimerFailureReason reason;
  final Duration duration;
}

class SleepTimerNotifier extends StateNotifier<SleepTimerState> {
  SleepTimerNotifier(this._pause) : super(const SleepTimerIdle());

  final Future<void> Function() _pause;
  Timer? _timer;
  int _generation = 0;

  void startTimer(Duration duration) {
    _timer?.cancel();
    final generation = ++_generation;
    final endTime = DateTime.now().add(duration);
    state = SleepTimerRunning(duration, endTime);
    _timer = Timer(duration, () async {
      try {
        await _pause();
        if (!mounted || generation != _generation) return;
        _timer = null;
        state = const SleepTimerIdle();
      } catch (_) {
        if (!mounted || generation != _generation) return;
        _timer = null;
        state = SleepTimerFailed(
          SleepTimerFailureReason.pauseFailed,
          duration,
        );
      }
    });
  }

  void cancelTimer() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    state = const SleepTimerIdle();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}

final sleepTimerProvider =
    StateNotifierProvider<SleepTimerNotifier, SleepTimerState>((ref) {
  return SleepTimerNotifier(audioHandler.pause);
});

final sleepTimerEndProvider = Provider<DateTime?>((ref) {
  return ref.watch(sleepTimerProvider).endTime;
});
```

The timer does not claim completion until `pause()` completes. Cancellation increments generation so a late pause completion or failure cannot replace a newer timer state.

- [ ] **Step 4: Run sleep-timer tests green**

Run:

```bash
flutter test test/features/player/presentation/sleep_timer_test.dart
flutter analyze lib/features/player/presentation/player_provider.dart
```

Expected: success becomes `SleepTimerIdle`; failure becomes `SleepTimerFailed` with the stable `pauseFailed` reason and original duration; raw error text and stack traces are not exposed through provider state; analysis reports no issues.

- [ ] **Step 5: Record task status without committing**

Record: `Task 7 complete; sleep-timer success/failure tests pass; Not committed.`

## Batch A Verification

- [ ] Run the complete Batch A regression set:

```bash
flutter test test/core/audio/playback_command_coordinator_test.dart \
  test/core/audio/playback_resolution_test.dart \
  test/core/audio/playback_state_test.dart \
  test/core/audio/audio_interruption_policy_test.dart \
  test/core/audio/lockscreen_autonext_test.dart \
  test/core/audio/quality_reresolve_test.dart \
  test/core/audio/seek_clamp_test.dart \
  test/features/player/presentation/scrub_coordinator_test.dart \
  test/features/player/presentation/sleep_timer_test.dart \
  test/features/lyric/presentation/lyric_provider_test.dart \
  test/features/search/presentation/search_provider_test.dart \
  test/startup_lifecycle_test.dart
```

Expected: `All tests passed!` and zero failing tests.

- [ ] Run the full Flutter suite:

```bash
flutter test
```

Expected: `All tests passed!` and zero failures, including the queue move tests that existed before Batch A.

- [ ] Run static analysis:

```bash
flutter analyze
```

Expected: no diagnostics introduced by Batch A and no async-context diagnostics in modified files.

- [ ] Perform the required iOS manual checks on macOS/physical hardware:

```text
1. Start A, select unresolved B, and confirm A becomes inaudible before B artwork/title/lyrics appear as buffering.
2. Reorder B while its URL resolves and confirm B installs once without reverting to A or loading twice.
3. Begin a scrub, cancel the gesture and leave the route during another scrub; confirm playback resumes according to the pre-scrub intent and no preserving pause remains.
4. Exercise interruption begin/end and becoming-noisy while selecting and scrubbing.
5. Tear down the root provider scope and confirm no player/session callbacks publish afterward.
6. Trigger a sleep timer with a controlled pause failure and confirm the failure state is observable instead of reporting timer completion.
```

Expected: audio, artwork, lyric, queue index, and lock-screen metadata always refer to one authoritative occurrence; cancellation and teardown produce no stale publication or leaked playback owner.

- [ ] Record final status without committing:

`Batch A verification complete; Flutter tests/analyze and listed manual checks recorded; Not committed because /tmp/opencode/LX2IOS-main has no Git metadata.`
