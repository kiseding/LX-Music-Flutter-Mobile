# Audio Task 5 Report

## Status

Implemented the confirmed seek contract on top of the approved source mutation and user-intent generation machinery.

## Commit

- Commit: `59f441b`
- Subject: `fix: publish only confirmed scrub positions`
- Author and committer: `kiseding <236300865+kiseding@users.noreply.github.com>`
- Identity was supplied through `GIT_AUTHOR_*` and `GIT_COMMITTER_*` environment variables.

## Changes

- Added `Future<Duration?> seekConfirmed(Duration position)`; `null` means readiness or transaction ownership prevented the current source from seeking.
- Serialized confirmed seeks through the existing source mutation gate and guarded them with source and seek generations.
- Loading and idle states return `null` after the existing bounded readiness wait without publishing the requested target.
- Successful seeks return and publish the clamped actual engine position after `AudioPlayer.seek` completes.
- `ScrubCoordinator.finish` unfreezes to the confirmed position or current engine position and never optimistically publishes the requested target.
- Resume requires a confirmed seek plus matching scrub, source, and user-intent ownership. Newer scrub, source, and user actions win.
- Preserved `preferPreciseDurationAndTiming: true` for Darwin progressive sources and added no position settle polling or fixed settle delay.

## TDD Evidence

RED:

- The focused suite failed because `LxAudioHandler.seekConfirmed` did not exist.
- Scrub contract tests failed because `finish` called `seek(position)`, resumed without transaction ownership, and used `unfreeze(position)`.

GREEN:

- Confirmed seeks publish the engine-reported position rather than the requested target.
- Loading seek failure returns `null` and leaves the target unpublished.
- A newer source generation invalidates an in-flight seek and retains the newer source and position.
- Structural scrub tests require confirmed fallback, source and user-intent ownership, and post-seek scrub generation validation.

## Verification

- `flutter test test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/seek_clamp_test.dart`
  - PASS: 11 tests.
- `flutter test test/core/audio test/features/player/domain/player_service_queue_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 100 tests.
- `flutter analyze lib/core/audio/audio_handler.dart lib/features/player/presentation/player_provider.dart test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/quality_reresolve_test.dart test/core/audio/lockscreen_autonext_test.dart test/features/player/domain/player_service_queue_test.dart`
  - PASS: no issues found.
- `dart format --output=none --set-exit-if-changed ...`
  - PASS: no formatting changes.
- `git diff --check`
  - PASS.
- Structural scan found no `waitForSettledPosition`, `hardSeekTo`, `seekToDisplay`, `seekBudgetForQuality`, or `unfreeze(position)` path.

## Concerns

- Flutter/Linux fakes validate seek confirmation and transaction ownership but cannot prove native iOS decoder positioning or background audio-session behavior; iOS device or CI coverage remains required.
- Dependency resolution continues to report 21 newer versions outside current constraints; this is pre-existing.

## Review Findings Follow-Up

### Status

Resolved all Task 5 review findings with executable coordinator behavior tests and owner-guarded native seek failure handling.

### Changes

- `seekConfirmed` catches native `AudioPlayer.seek` exceptions, returns `null`, and republishes actual engine state only while the same source and seek transaction still owns publication.
- Stale native seek failures cannot publish over a newer source.
- Added explicit `ScrubPlayback` and `ScrubPosition` contracts. Production uses a thin handler/service adapter; tests use deterministic fakes around those contracts.
- `ScrubCoordinator.finish` encloses pause completion, confirmed seek, optional resume, and cleanup in `try/finally`.
- Only the currently owning scrub generation unfreezes. It publishes confirmation for the same source and current engine position for null/error/source-change exits.
- Resume requires a non-null confirmation plus unchanged source and user-intent generations.
- A pause failure during `begin` also unfreezes the owning generation before propagating the unexpected dependency error.
- Removed source-string-only scrub coordinator tests. Executable coverage includes loading, idle, thrown seek, thrown pause, overlapping generations, source changes, newer user pause/play, paused success, and successful resume.
- Preserved Darwin precise timing and added no settle polling or fixed settle delays.

### TDD Evidence

RED:

- Native seek failure escaped `seekConfirmed` as `Bad state: native seek failed`.
- Executable scrub tests failed to compile because `ScrubCoordinator` accepted only `Ref` and exposed no injectable playback/position contracts.
- The owning generation remained frozen when scrub pause threw.

GREEN:

- Native failures return `null` and reconcile actual state only for the owning seek.
- Every requested coordinator scenario now executes against explicit interfaces and verifies observable freeze, unfreeze, and resume behavior.
- Stale scrub generations never unfreeze newer transactions.

### Verification

- `flutter test test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 21 tests.
- `flutter test test/core/audio test/features/player/domain/player_service_queue_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 110 tests.
- `flutter analyze lib/core/audio/audio_handler.dart lib/features/player/presentation/player_provider.dart test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart test/core/audio/quality_reresolve_test.dart test/core/audio/lockscreen_autonext_test.dart test/features/player/domain/player_service_queue_test.dart`
  - PASS: no issues found.
- Formatting and `git diff --check`
  - PASS.

### Concerns

- Native iOS decoder positioning and background audio-session behavior still require iOS device or CI validation.
- Dependency resolution continues to report 21 newer versions outside current constraints; this remains pre-existing.

## Duplicate Queue Occurrence Follow-Up

### Status

Resolved the duplicate-ID metadata publication finding.

### Root Cause

- Foreground and preload resolution acceptance checked a queue slot, then called
  the legacy ID-based `patchQueueItemExtras`. Its `indexWhere` selected the first
  matching ID, so a valid resolution for a later duplicate wrote metadata to the
  wrong occurrence.
- Slot checks compared only IDs, so a same-ID replacement could also receive a
  stale resolution.

### Changes

- Added `patchQueueItemExtrasAt`, which validates both the expected index and
  exact `MediaItem` instance before merging metadata. It updates `mediaItem`
  only when that exact instance is current at the same index.
- Foreground requests now retain generation, index, and item identity.
  Preload requests retain the same occurrence identity. Accepted resolutions
  target only their captured occurrence; moved or replaced occurrences reject
  the result and release any lease.
- Kept `patchQueueItemExtras(String, Map<String, dynamic>)` unchanged for
  existing ID-based callers.

### TDD Evidence

RED:

- The focused resolution suite failed with the first duplicate receiving both a
  foreground resolution and the second preload's metadata.
- A same-ID replacement accepted a stale foreground resolution.

GREEN:

- Foreground resolution updates only the active second duplicate.
- Preload resolution updates exactly the second preloaded duplicate.
- Replaced and moved duplicate occurrences receive no stale metadata write.

### Verification

- `flutter test test/core/audio/playback_resolution_test.dart`
  - PASS: 33 tests.
- `flutter test test/core/audio test/core/network test/features/player/domain/player_service_queue_test.dart`
  - PASS: 372 tests.
- `flutter analyze lib/core/audio/audio_handler.dart test/core/audio/playback_resolution_test.dart`
  - PASS: no issues found.
- `dart format --output=none --set-exit-if-changed lib/core/audio/audio_handler.dart test/core/audio/playback_resolution_test.dart`
  - PASS.
- `git diff --check`
  - PASS.

### Concerns

- The occurrence token intentionally uses in-memory `MediaItem` identity. A
  queue rebuild, replacement, or move therefore rejects an in-flight result
  rather than attempting to relocate it by duplicate ID; a later authoritative
  load resolves the current occurrence.

## Duplicate Queue Occurrence Follow-Up

### Status

Resolved the duplicate-ID metadata publication finding.

### Root Cause

- Foreground and preload resolution acceptance checked a queue slot, then called
  the legacy ID-based `patchQueueItemExtras`. Its `indexWhere` selected the first
  matching ID, so a valid resolution for a later duplicate wrote metadata to the
  wrong occurrence.
- Slot checks compared only IDs, so a same-ID replacement could also receive a
  stale resolution.

### Changes

- Added `patchQueueItemExtrasAt`, which validates both the expected index and
  exact `MediaItem` instance before merging metadata. It updates `mediaItem`
  only when that exact instance is current at the same index.
- Foreground requests now retain generation, index, and item identity.
  Preload requests retain the same occurrence identity. Accepted resolutions
  target only their captured occurrence; moved or replaced occurrences reject
  the result and release any lease.
- Kept `patchQueueItemExtras(String, Map<String, dynamic>)` unchanged for
  existing ID-based callers.

### TDD Evidence

RED:

- The focused resolution suite failed with the first duplicate receiving both a
  foreground resolution and the second preload's metadata.
- A same-ID replacement accepted a stale foreground resolution.

GREEN:

- Foreground resolution updates only the active second duplicate.
- Preload resolution updates exactly the second preloaded duplicate.
- Replaced and moved duplicate occurrences receive no stale metadata write.

### Verification

- `flutter test test/core/audio/playback_resolution_test.dart`
  - PASS: 33 tests.
- `flutter test test/core/audio test/core/network test/features/player/domain/player_service_queue_test.dart`
  - PASS: 372 tests.
- `flutter analyze lib/core/audio/audio_handler.dart test/core/audio/playback_resolution_test.dart`
  - PASS: no issues found.
- `dart format --output=none --set-exit-if-changed lib/core/audio/audio_handler.dart test/core/audio/playback_resolution_test.dart`
  - PASS.
- `git diff --check`
  - PASS.

### Concerns

- The occurrence token intentionally uses in-memory `MediaItem` identity. A
  queue rebuild, replacement, or move therefore rejects an in-flight result
  rather than attempting to relocate it by duplicate ID; a later authoritative
  load resolves the current occurrence.

## Stale Preserving-Pause Investigation

### Trace

- `ScrubCoordinator.begin` snapshots source/user generations, then calls `_HandlerScrubPlayback.pauseForScrub`.
- The adapter currently delegates to `LxAudioHandler.pauseInternal(clearIntent: false)`.
- `pauseInternal(clearIntent: false)` intentionally leaves `_userIntentGeneration` and `_userWantsPlay` unchanged, but directly awaits the shared `AudioPlayer.pause()`.
- Public `play`, `pause`, and `stop` change user intent; queue/source selections also change intent and `_loadQueueItem` changes `_playGeneration` while serializing source installation.
- Coordinator ownership checks run only after the preserving pause returns. They can cancel stale seek/resume, but cannot undo a native pause whose completion occurs after a newer play, source install, or scrub resume.

### Hypothesis

The preserving pause must be a handler-owned transaction, not a plain `pauseInternal` call. It must receive the source/user generations captured by `begin` plus current scrub ownership, then revalidate after native pause returns. If that pause is stale and the latest authoritative intent still requests playback, the handler must restart only the currently installed authoritative source through generation, installed-source, item, index, and user-intent guards. If newer explicit pause or stop owns intent, it must not restart. This removes the late-pause race without fixed delays or coordinator-side guesses about player internals.

### Resolution

- Added `LxAudioHandler.pauseForScrub(...)`, taking begin-captured source/user generations and a current scrub-ownership predicate.
- After native pause returns, the handler detects stale source, intent, or scrub ownership. It restores playback only when latest `_userWantsPlay` remains true.
- Restoration snapshots and validates current source generation, user-intent generation, installed source-owner token, installed playback generation/media identity, active/published item identity, logical index, and queue identity before start and in the asynchronous start failure callback.
- `ScrubCoordinator.begin` threads its original ownership snapshots and scrub-generation predicate through `ScrubPlayback.pauseForScrub`.
- Explicit pause and stop leave `_userWantsPlay` false, so stale pause reconciliation cannot revive them.
- No fixed delay or position-settle polling was added.

### TDD Evidence

RED:

- Focused tests failed to compile because the handler had no ownership-aware `pauseForScrub` transaction and the real-handler scrub adapter path did not exist.

GREEN:

- Explicit play during an old gated scrub pause remains playing after the old pause returns.
- A newer queue selection installs and keeps its source playing after the old pause returns.
- A newer scrub can complete and resume before the older pause returns; older completion restores the authoritative playback instead of defeating it.
- Newer explicit pause and stop remain paused and are never revived.

### Verification

- `flutter test test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 33 tests.
- `flutter test test/core/audio test/features/player/domain/player_service_queue_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 122 tests.
- Targeted `flutter analyze`
  - PASS: no issues found.
- Formatting and `git diff --check`
  - PASS.

### Concerns

- Native iOS decoder positioning, native pause/play completion ordering, and background audio-session behavior still require iOS device or CI validation.
- Dependency resolution continues to report 21 newer versions outside current constraints; this remains pre-existing.

## Transaction Snapshot Follow-Up

### Status

Resolved the remaining Task 5 transaction snapshot and clamped publication findings.

### Changes

- `ScrubCoordinator.begin` now captures source and user-intent generations before initiating the preserving pause and stores them with that scrub generation and pause future.
- `finish` uses only the original transaction snapshots. Source or explicit user actions between begin/finish, during the pause, or during seek invalidate seek/resume as appropriate.
- The internal preserving pause does not increment user-intent generation and therefore does not invalidate its own scrub.
- Stale transactions skip seek entirely and owner-scoped cleanup unfreezes to the current engine position without affecting newer scrub generations.
- Successful confirmed seeks publish through `_publishPlaybackState(positionOverride:)`, so the returned clamped confirmation exactly matches `PlaybackState.updatePosition` even when the raw engine value is negative or beyond duration.

### TDD Evidence

RED:

- Source change, explicit pause, and explicit play between begin and finish each still invoked seek once because ownership snapshots were captured in `finish`.
- Source and intent changes while the begin pause was gated also invoked seek once for the same reason.
- Negative and beyond-duration engine confirmations returned clamped values while playback state published the raw engine values.

GREEN:

- All pre-finish and gated-pause source/user ownership changes now prevent stale seek and resume.
- Existing during-seek ownership tests continue to suppress resume and preserve owner-scoped cleanup.
- Negative confirmation publishes `Duration.zero`; beyond-duration confirmation publishes the duration; both exactly equal the returned value.

### Verification

- `flutter test test/core/audio/seek_clamp_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 28 tests.
- `flutter test test/core/audio test/features/player/domain/player_service_queue_test.dart test/features/player/presentation/scrub_coordinator_test.dart`
  - PASS: 117 tests.
- Targeted `flutter analyze`
  - PASS: no issues found.
- Formatting and `git diff --check`
  - PASS.

### Concerns

- Native iOS decoder positioning and background audio-session behavior still require iOS device or CI validation.
- Dependency resolution continues to report 21 newer versions outside current constraints; this remains pre-existing.
