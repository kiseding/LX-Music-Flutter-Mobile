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
