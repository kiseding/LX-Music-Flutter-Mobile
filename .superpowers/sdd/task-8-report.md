# Task 8 Report: Repository Wiring And Revision-Driven Consumers

## Status

Implemented and verified.

## TDD Evidence

Added the provider/revision test and production source guard before modifying
production code, and tightened the bulk-favorites source test to require an
awaited mutation.

Initial RED command:

```text
flutter test test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart
```

The run failed as expected because `playlistRepositoryProvider` did not exist,
`PlaylistService` was still constructed without its required repository, and
the bulk-favorites callback was not awaited. The provider test could not compile
until the repository-backed provider graph was implemented.

The same focused command passed after the migration: 4 tests, 0 failures.

## Implementation

- Added overridable `playlistRepositoryProvider` and repository-backed
  `playlistServiceProvider`.
- Added `playlistRevisionProvider` as the sole playlist invalidation source.
- Removed `playlistVersionProvider` and every playlist manual increment.
- Disposes the async playlist service with `unawaited(service.dispose())`.
- Constructs `FilePlaylistRepository` from `SharedPreferences` and the
  application documents directory before creating the startup container.
- Initializes the repository-backed playlist service before `runApp`.
- Left playback-cache construction, initialization, and handler attachment
  unchanged.
- Awaited all user-triggered playlist mutations and surfaced persistence
  failures in the existing screen context.
- Kept recent-play recording intentionally fire-and-forget with
  `unawaited(service.addToRecent(music))`.
- Changed playlist import to one `createPlaylist` call with imported songs.
- Changed picker create-and-add to one `createPlaylist` call with the song.
- Changed cloud pull to construct a complete playlist list and call one
  `replaceAll`.
- Changed settings backup to encode service playlists with
  `PlaylistSnapshotCodec` version 1 and restore to strictly decode that envelope
  before one `replaceAll`.
- Extended source guards to playlist, player, search, sync, and settings
  consumers.

## Verification

Exact Task 8 focused tests:

```text
flutter test test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart
4 tests passed
```

Exact Task 8 broad suite:

```text
flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart
79 tests passed
```

Whole-project analysis:

```text
flutter analyze
0 errors; 22 pre-existing warnings/info findings
```

The remaining findings are outside Task 8: existing theme/custom-source/
equalizer/reorder/settings dead-code and test lint findings. Task 8 introduced
no new analyzer finding.

Additional checks:

- `git diff --check`: passed.
- Production search: no `playlistVersionProvider` or parameterless
  `PlaylistService()` remains.
- Mutation review: all playlist mutations are awaited except the explicitly
  approved recent recorder.
- Playback cache files were not modified.

## Scope

Additional consumers modified beyond the brief's primary file list:

- `lib/features/playlist/presentation/playlist_picker.dart`
- `lib/features/player/presentation/player_screen.dart`
- `lib/features/search/presentation/search_screen.dart`

These were required to complete the requested migration of every playlist
mutation caller. Existing unrelated changes in
`.superpowers/sdd/network-task-4-report.md` and
`docs/superpowers/plans/2026-07-29-playlist-snapshot-meta-immutability.md` were
not modified or staged.

## Review Remediation

### RED Evidence

The focused review command initially failed with the expected missing-helper
compile errors and behavior failures:

```text
flutter test test/features/settings/playlist_backup_compatibility_test.dart test/startup_lifecycle_test.dart test/features/sync/presentation/cloud_playlist_merge_test.dart test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart test/features/playlist/presentation/playlist_screen_test.dart
```

- Backup compatibility, startup lifecycle, and cloud merge seams did not exist.
- A removed selected playlist continued to render from stale provider state.
- Import dialog success/catch paths called local `StateSetter` without checking
  whether the dialog context remained mounted.
- The favorite invalidation test already passed, isolating stale detail state
  from the revision stream.

### GREEN Evidence

- The same focused command passes 16 tests.
- Version 1 backups preserve their outer version and accept either the legacy
  playlist list or the new strict snapshot object. Both shapes pass through
  `PlaylistSnapshotCodec`; malformed payloads remain rejected.
- `OwnedProviderScope` owns the startup container. Partial initialization
  failure disposes it once and awaits tracked playlist/download/cache cleanup.
- Playlist detail resolves selected IDs only from the live service and renders
  a mutation-free missing state after `replaceAll` removes the selection.
- Dialog-local state is guarded after both confirmation and exception awaits.
- Cloud merge performs one `replaceAll`, reports unique accepted playlist IDs,
  and cannot return a success result when persistence fails.

### Final Verification

```text
flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart
88 tests passed

flutter analyze
22 pre-existing findings; no new findings
```

The whole-project test run also completed 645 tests but retained two reproducible
pre-existing failures in `player_service_queue_test.dart` concerning metadata
moves during in-flight source loads. They fail unchanged when that file is run
alone and are outside Task 8; no player queue or playback-cache file was touched.

## Remaining Findings Remediation

### RED Evidence

Lifecycle dependency-order regression:

```text
flutter test test/startup_lifecycle_test.dart
00:00 +2 -1: production provider graph drains async services before dependencies [E]
Expected: a value less than <0>
Actual: <1>
00:00 +2 -1: Some tests failed.
```

This proved the production playlist/download provider graph closed its async
service streams only after synchronous `CustomSourceService` disposal.

Version 1 restore regression:

```text
flutter test test/features/settings/playlist_backup_compatibility_test.dart
Error: Method not found: 'restoreBackupPlaylists'.
00:00 +0 -1: Some tests failed.
```

The missing helper was the intended RED: restore had no seam that required
strict playlist decoding followed by exactly one replacement.

### GREEN Evidence

```text
flutter test test/startup_lifecycle_test.dart
3 tests passed

flutter test test/features/settings/playlist_backup_compatibility_test.dart
6 tests passed

flutter test test/features/settings/playlist_backup_compatibility_test.dart test/startup_lifecycle_test.dart test/features/sync/presentation/cloud_playlist_merge_test.dart test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart test/features/playlist/presentation/playlist_screen_test.dart
19 tests passed

flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart
90 tests passed

flutter analyze
22 pre-existing findings; no new findings

dart format --output=none --set-exit-if-changed lib/startup_lifecycle.dart lib/features/playlist/presentation/playlist_provider.dart lib/features/download/presentation/download_provider.dart lib/features/settings/domain/playlist_backup.dart lib/features/settings/presentation/settings_screen.dart test/startup_lifecycle_test.dart test/features/settings/playlist_backup_compatibility_test.dart
Formatted 7 files (0 changed)

git diff --check
passed
```

Registered playlist, download, and playback-cache cleanup now drains before
`ProviderContainer.dispose`; provider teardown reuses each registered disposal
future and a final drain captures callback-started cleanup. Missing or null
version 1 `playlists` is rejected, while both supported playlist shapes are
strictly decoded and passed to one `replaceAll`. Playback-cache implementation
files remain unchanged.

## Final Disposal Tracker Remediation

### RED Evidence

```text
flutter test test/startup_lifecycle_test.dart
00:00 +0 -1: dispose drains resources registered synchronously by a disposer [E]
Concurrent modification during iteration: ReversedListIterable<_TrackedDisposal>
00:00 +0 -2: dispose reaches a fixed point before and after container teardown [E]
Actual post-container events omitted post-container-resource
00:00 +0 -3: synchronous disposer failure does not stop remaining cleanup [E]
Actual events omitted later-resource
00:00 +0 -4: asynchronous disposer failure does not stop callback-started cleanup [E]
Actual callback-started events were empty
00:00 +0 -5: repeated dispose shares one drain and reports failure after cleanup [E]
The disposal future completed before blocked cleanup
00:00 +0 -6: owned provider scope reports asynchronous cleanup failure [E]
The unawaited disposal error reached the test zone unhandled
```

These failures reproduced list mutation dropping disposer-time registration,
failure-short-circuited cleanup, incomplete post-container draining, premature
error completion, and the unhandled root teardown error.

### GREEN Evidence

```text
flutter test test/startup_lifecycle_test.dart
9 tests passed

flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart
90 tests passed

flutter analyze
22 pre-existing findings; no new findings

dart format --output=none --set-exit-if-changed lib/startup_lifecycle.dart test/startup_lifecycle_test.dart
Formatted 2 files (0 changed)

git diff --check
passed
```

The tracker now removes registered resources in reverse dependency order and
drains snapshots of pending futures until both queues remain empty. Each
resource is invoked once, including synchronous throws, and each async failure
is observed independently so later and callback-started cleanup still runs.
`StartupLifecycle.dispose` remains one cached future, retains the first cleanup
error and original stack, disposes the container, completes the post-container
fixed point, then reports failure. Root widget teardown catches that future and
reports it through `FlutterError`; awaited startup-failure cleanup continues to
surface disposal failures to its caller.

## Final Tracker Concurrency Remediation

### RED Evidence

```text
flutter test test/startup_lifecycle_test.dart
00:00 +0 -1: registered resources dispose sequentially in reverse order [E]
Expected: ['dependent-start']
Actual: ['dependent-start', 'dependency-start']
00:00 +0 -2: overlapping direct drains share completion failure and allow reuse [E]
Expected: true
Actual: <false>
00:00 +9 -2: Some tests failed.
```

The first failure proved that reverse invocation was still concurrent: the
earlier dependency started before the later dependent's future completed. The
second proved that overlapping direct tracker drains returned different futures
and could split the queue and cleanup outcome.

### GREEN Evidence

```text
flutter test test/startup_lifecycle_test.dart
11 tests passed

flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart
90 tests passed

flutter analyze
22 pre-existing findings; no new findings

dart format --output=none --set-exit-if-changed lib/startup_lifecycle.dart test/startup_lifecycle_test.dart
Formatted 2 files (0 changed)

git diff --check
passed
```

Registered resources now dispose strictly one at a time in reverse registration
order. A failed disposer is retained as the first error while remaining and
dynamically registered resources continue to the fixed point. Pending callback
futures are still snapshot-drained and independently observed. Concurrent direct
`disposeAndDrain` calls receive the same memoized future and therefore the same
completion and failure after all cleanup. The memoized future is cleared only
after completion, allowing the startup lifecycle's post-container drain and
later registrations without permanently closing the tracker.
