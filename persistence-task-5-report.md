# Persistence Task 5 Report

## Scope

- Added the schema-v1 `PlaylistSnapshot` contract and `PlaylistRepository`
  interface in `lib/features/playlist/data/playlist_repository.dart`.
- Added a strict JSON codec for the versioned playlist envelope.
- No file storage, legacy migration, playlist service, or UI wiring changed.

## Contract

- Snapshots accept only schema version `1`, expose immutable playlist and song
  lists, and own recursively immutable copies of every song `meta` graph.
- The codec preserves every `MusicItem` JSON field, including optional fields
  and nested `meta` values.
- Constructor `meta` accepts JSON-compatible scalar values, maps with string
  keys, and lists only. Invalid values fail with a path-specific
  `FormatException`.
- Decoding requires the exact envelope shape, non-empty unique playlist IDs and
  names, integer millisecond timestamps, object song entries, required song
  `id`, `name`, `singer`, and `source`, plus a non-negative integer duration.
- Invalid input throws `FormatException` containing the failing field path.

## TDD Evidence

- RED: `flutter test test/features/playlist/data/playlist_repository_test.dart`
  failed because `playlist_repository.dart`, `PlaylistSnapshot`, and
  `PlaylistSnapshotCodec` did not exist.
- RED: direct-construction meta mutation changed the snapshot before recursive
  defensive copying was added to `PlaylistSnapshot`.
- GREEN: direct construction and decode tests verify source mutation cannot
  change snapshots, and exposed nested maps and lists reject mutation.

## Verification

- `flutter test test/features/playlist/data/playlist_repository_test.dart test/features/player/domain/music_item_test.dart test/features/playlist/domain/playlist_test.dart`
- `flutter analyze lib/features/playlist/data/playlist_repository.dart test/features/playlist/data/playlist_repository_test.dart`
- `git diff --check`

## Remaining Work

- Task 6 will implement file-backed atomic persistence, legacy data migration,
  recovery, and quarantine behind this repository interface.
- Task 7 will migrate `PlaylistService` to durable, serialized revisions.
