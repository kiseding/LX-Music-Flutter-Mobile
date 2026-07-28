# Audio And Queue Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the audio handler the sole queue/state authority and correct queue updates, completion, repeat, quality reload, scrub, and interruption behavior.

**Architecture:** `LxAudioHandler` owns immutable queue snapshots, logical index, playback intent, and official state publication. `PlayerService` becomes a command facade over those snapshots. Pure policy helpers receive focused tests; native player transactions retain generation checks and are covered structurally where `AudioPlayer` cannot run on Linux.

**Tech Stack:** Flutter 3.x, Dart, Riverpod 2.6, audio_service 0.18, just_audio 0.9, audio_session 0.1, flutter_test

## Global Constraints

- Keep `DarwinAssetOptions(preferPreciseDurationAndTiming: true)`.
- Do not add fixed seek delays, optimistic settle polling, or timing-compensation source reloads.
- Keep the single-source playback architecture.
- Preserve iOS background playback intent during seamless automatic transitions.
- Run focused tests after every task and full `flutter analyze` plus `flutter test` after integration.

## File Structure

- Modify `lib/core/audio/audio_handler.dart`: queue authority, navigation/completion policy, playback-state mapping, quality reload, seek result.
- Modify `lib/features/player/domain/player_service.dart`: command-only facade over handler snapshots.
- Modify `lib/features/player/presentation/player_provider.dart`: handler-derived play mode and scrub confirmation.
- Modify `lib/main.dart`: audio interruption and becoming-noisy coordination.
- Modify player/lyric widgets only where provider interface changes require it.
- Extend tests under `test/core/audio/` and `test/features/player/` with behavior-focused policy coverage.

---

### Task 1: Handler-Owned Queue Snapshots

**Files:**
- Modify: `lib/features/player/domain/player_service.dart`
- Modify: `lib/core/audio/audio_handler.dart`
- Create: `test/features/player/domain/player_service_queue_test.dart`

**Interfaces:**
- Consumes: global `audioHandler` and `LxAudioHandler.queueItems`.
- Produces: `LxAudioHandler.currentQueueIndex`, metadata-only `updateQueue`, and facade getters that delegate to handler state.

- [ ] **Step 1: Write the failing facade and source-architecture tests**

```dart
test('player service has no independently mutable queue', () {
  final source = File('lib/features/player/domain/player_service.dart').readAsStringSync();
  expect(source, isNot(contains('final List<MediaItem> _playQueue')));
  expect(source, isNot(contains('int _currentIndex')));
  expect(source, contains('handler.queueItems'));
  expect(source, contains('handler.currentQueueIndex'));
});

test('queue metadata updates never replace the active audio source', () {
  final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
  final update = source.substring(
    source.indexOf('Future<void> updateQueue('),
    source.indexOf('Future<void> addQueueItem('),
  );
  expect(update, isNot(contains('ConcatenatingAudioSource')));
  expect(update, isNot(contains('setAudioSource')));
});
```

- [ ] **Step 2: Run tests and confirm failure**

Run: `flutter test test/features/player/domain/player_service_queue_test.dart`
Expected: FAIL because `PlayerService` still owns `_playQueue` and `updateQueue` installs a concatenated source.

- [ ] **Step 3: Implement the minimal queue authority change**

```dart
List<MediaItem> get queueItems => List.unmodifiable(_queue);
int get currentQueueIndex => _queue.isEmpty ? -1 : _currentIndex;

@override
Future<void> updateQueue(List<MediaItem> items) async {
  final currentId = mediaItem.value?.id;
  _queue
    ..clear()
    ..addAll(items);
  if (_queue.isEmpty) {
    _currentIndex = -1;
    _activeItemId = null;
    queue.add(const <MediaItem>[]);
    mediaItem.add(null);
    await stop();
    return;
  }
  final retained = currentId == null
      ? -1
      : _queue.indexWhere((item) => item.id == currentId);
  _currentIndex = retained >= 0 ? retained : 0;
  _activeItemId = _queue[_currentIndex].id;
  queue.add(List.unmodifiable(_queue));
  mediaItem.add(_queue[_currentIndex]);
  _publishPlaybackState();
}
```

Rewrite `PlayerService.playSong`, `playPlaylist`, `playNext`, and `addToQueue` to construct new lists from `handler.queueItems`, then invoke handler methods. Its getters return handler snapshots and `currentQueueIndex`.

- [ ] **Step 4: Run focused queue tests**

Run: `flutter test test/features/player/domain/player_service_queue_test.dart test/core/audio/queue_index_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/audio_handler.dart lib/features/player/domain/player_service.dart test/features/player/domain/player_service_queue_test.dart
git commit -m "fix: make audio handler own queue state"
```

### Task 2: Completion And Repeat Policy

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `test/core/audio/queue_index_test.dart`
- Modify: `test/core/audio/lockscreen_autonext_test.dart`

**Interfaces:**
- Consumes: handler queue/index/repeat/shuffle snapshot from Task 1.
- Produces: `completionQueueIndex(...)` and one completed-event path per playback generation.

- [ ] **Step 1: Add failing pure policy tests**

```dart
test('repeat one completion keeps the current queue item', () {
  expect(completionQueueIndex(
    currentIndex: 1,
    queueLength: 3,
    repeatMode: AudioServiceRepeatMode.one,
    shuffle: false,
  ), 1);
});

test('repeat all wraps while no-repeat stops', () {
  expect(completionQueueIndex(
    currentIndex: 2,
    queueLength: 3,
    repeatMode: AudioServiceRepeatMode.all,
    shuffle: false,
  ), 0);
  expect(completionQueueIndex(
    currentIndex: 2,
    queueLength: 3,
    repeatMode: AudioServiceRepeatMode.none,
    shuffle: false,
  ), -1);
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `flutter test test/core/audio/queue_index_test.dart test/core/audio/lockscreen_autonext_test.dart`
Expected: FAIL because `completionQueueIndex` does not exist and source still has the position-end trigger.

- [ ] **Step 3: Implement completion policy and deduplication**

```dart
int completionQueueIndex({
  required int currentIndex,
  required int queueLength,
  required AudioServiceRepeatMode repeatMode,
  required bool shuffle,
  int Function(int max)? randomNext,
}) {
  if (queueLength <= 0) return -1;
  if (repeatMode == AudioServiceRepeatMode.one) return currentIndex;
  return nextQueueIndex(
    currentIndex: currentIndex,
    queueLength: queueLength,
    shuffle: shuffle,
    loop: repeatMode == AudioServiceRepeatMode.all ||
        repeatMode == AudioServiceRepeatMode.group,
    randomNext: randomNext,
  );
}
```

Remove position-threshold advancement and native current-index interpretation. Track the last handled completion generation. On completion, require both active ID and logical index to still match, choose with `completionQueueIndex`, and call `skipToQueueItem(target, seamless: true)`; repeat-one reloads the same item.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/core/audio/queue_index_test.dart test/core/audio/lockscreen_autonext_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/audio_handler.dart test/core/audio/queue_index_test.dart test/core/audio/lockscreen_autonext_test.dart
git commit -m "fix: make track completion generation-safe"
```

### Task 3: Unified Playback-State Publication

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Create: `test/core/audio/playback_state_test.dart`

**Interfaces:**
- Produces: `audioProcessingState(ProcessingState)` and `_publishPlaybackState({AudioProcessingState? override})`.

- [ ] **Step 1: Add failing mapping tests**

```dart
test('just_audio processing states map to audio_service states', () {
  expect(audioProcessingState(ProcessingState.idle), AudioProcessingState.idle);
  expect(audioProcessingState(ProcessingState.loading), AudioProcessingState.loading);
  expect(audioProcessingState(ProcessingState.buffering), AudioProcessingState.buffering);
  expect(audioProcessingState(ProcessingState.ready), AudioProcessingState.ready);
  expect(audioProcessingState(ProcessingState.completed), AudioProcessingState.completed);
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `flutter test test/core/audio/playback_state_test.dart`
Expected: FAIL because the mapper does not exist.

- [ ] **Step 3: Implement mapper and publisher**

```dart
AudioProcessingState audioProcessingState(ProcessingState state) => switch (state) {
  ProcessingState.idle => AudioProcessingState.idle,
  ProcessingState.loading => AudioProcessingState.loading,
  ProcessingState.buffering => AudioProcessingState.buffering,
  ProcessingState.ready => AudioProcessingState.ready,
  ProcessingState.completed => AudioProcessingState.completed,
};
```

Replace `_broadcastState` and direct partial state writes with `_publishPlaybackState`, always publishing processing state, playing, engine position, buffered position, speed, logical queue index, controls, repeat, and shuffle.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/core/audio/playback_state_test.dart test/core/audio/lockscreen_autonext_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/audio_handler.dart test/core/audio/playback_state_test.dart
git commit -m "fix: publish complete audio service state"
```

### Task 4: Position-Preserving Quality Reload

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `test/core/audio/quality_reresolve_test.dart`

**Interfaces:**
- Produces: `QualityReloadIntent(position, resumeAfterReload)` and `skipToQueueItem(..., initialPosition, playAfterLoad)`.

- [ ] **Step 1: Add failing intent tests**

```dart
test('quality reload retains engine position and actual play state', () {
  final paused = qualityReloadIntent(
    position: const Duration(seconds: 42),
    duration: const Duration(minutes: 3),
    wasPlaying: false,
  );
  expect(paused.position, const Duration(seconds: 42));
  expect(paused.resumeAfterReload, isFalse);
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `flutter test test/core/audio/quality_reresolve_test.dart`
Expected: FAIL because reload intent does not exist.

- [ ] **Step 3: Implement reload transaction**

Capture `_player.position`, `_player.duration`, and `_player.playing` before invalidating URLs. Extend `skipToQueueItem` with optional initial position and explicit play intent. Re-resolve while paused, install at the clamped position, and resume only when `wasPlaying` is true.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/core/audio/quality_reresolve_test.dart test/core/audio/seek_clamp_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/audio_handler.dart test/core/audio/quality_reresolve_test.dart
git commit -m "fix: preserve playback state across quality changes"
```

### Task 5: Confirmed Seek Contract

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `lib/features/player/presentation/player_provider.dart`
- Modify: `test/core/audio/seek_clamp_test.dart`
- Create: `test/features/player/presentation/scrub_coordinator_test.dart`

**Interfaces:**
- Produces: `Future<Duration?> seekConfirmed(Duration position)`; `null` means the current source could not seek.

- [ ] **Step 1: Add failing scrub contract tests**

```dart
test('scrub publishes confirmed engine position, not requested target', () {
  final source = File('lib/features/player/presentation/player_provider.dart').readAsStringSync();
  expect(source, contains('final confirmed = await h.seekConfirmed(position)'));
  expect(source, contains('unfreeze(confirmed ?? h.player.position)'));
  expect(source, isNot(contains('unfreeze(position)')));
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `flutter test test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/seek_clamp_test.dart`
Expected: FAIL because scrub unfreezes to the requested target.

- [ ] **Step 3: Implement confirmed seek**

Return `null` while loading/idle after bounded readiness wait. After `_player.seek(target)`, return the clamped engine position and publish it. `ScrubCoordinator.finish` unfreezes to confirmed or actual position and resumes only after a confirmed seek when the transaction still owns the source generation.

- [ ] **Step 4: Run focused tests**

Run: `flutter test test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/seek_clamp_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/audio_handler.dart lib/features/player/presentation/player_provider.dart test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart
git commit -m "fix: publish only confirmed scrub positions"
```

### Task 6: Audio Interruption Policy And Integration

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/core/audio/audio_handler.dart`
- Create: `test/core/audio/audio_interruption_policy_test.dart`
- Modify: `lib/features/player/presentation/player_provider.dart`
- Modify: `lib/features/player/presentation/player_screen.dart`

**Interfaces:**
- Produces: `AudioInterruptionPolicy` with `onBegin`, `onEnd`, `onBecomingNoisy`; handler-derived play mode provider.

- [ ] **Step 1: Add failing interruption-policy tests**

```dart
test('interruption resumes only playback paused by that interruption', () {
  final policy = AudioInterruptionPolicy();
  expect(policy.onBegin(wasPlaying: true), InterruptionAction.pausePreservingIntent);
  expect(policy.onEnd(userStillWantsPlay: true, mayResume: true), InterruptionAction.resume);
  expect(policy.onEnd(userStillWantsPlay: false, mayResume: true), InterruptionAction.none);
});

test('becoming noisy pauses and clears resume intent', () {
  final policy = AudioInterruptionPolicy();
  expect(policy.onBecomingNoisy(), InterruptionAction.pauseClearingIntent);
});
```

- [ ] **Step 2: Run and confirm failure**

Run: `flutter test test/core/audio/audio_interruption_policy_test.dart`
Expected: FAIL because the policy does not exist.

- [ ] **Step 3: Implement and wire policy**

Instantiate the handler before registering audio-session listeners. On interruption begin, pause preserving intent and remember ownership. On resumable end, resume only if no explicit user action invalidated the intent. On becoming noisy, call normal pause. Derive play mode from handler repeat/shuffle state and remove independent mutable mode state.

- [ ] **Step 4: Run audio suite and analysis**

Run: `flutter test test/core/audio test/features/player/domain/player_service_queue_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
Expected: PASS.

Run: `flutter analyze`
Expected: no errors.

- [ ] **Step 5: Run full Flutter suite**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/main.dart lib/core/audio/audio_handler.dart lib/features/player/presentation/player_provider.dart lib/features/player/presentation/player_screen.dart test/core/audio/audio_interruption_policy_test.dart
git commit -m "fix: handle audio interruptions and route loss"
```

## Native Verification

After Dart verification, keep these pending for iOS hardware/CI:

- lock-screen queue/index and repeat-one;
- background auto-advance through several tracks and one resolution failure;
- calls, Siri, alarms, headphone removal, and Bluetooth route changes;
- paused and playing FLAC seek;
- paused and playing quality changes preserving position.
