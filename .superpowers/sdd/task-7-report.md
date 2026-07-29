# Task 7 Report: Serialized Playlist Mutations, System Lists, And Revision Stream

## Status

DONE_WITH_CONCERNS

## Commit

- Hash: `9177663`
- Subject: `fix: serialize playlist revisions`
- Author: `kiseding <236300865+kiseding@users.noreply.github.com>`

## RED

Command:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart
```

Result: failed as expected before production changes (`+0 -1`). The service test
could not compile because the existing synchronous service had no
`PlaylistService(repository: ..., clock: ..., createId: ...)` constructor. The
compiler reported `No named parameter with the name 'repository'` for each new
durability test, confirming that the repository-backed Task 7 contract was
absent.

## GREEN

Initial focused service command:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart
```

Result after implementation and one generic type correction: `+8: All tests
passed!`.

Exact focused verification from the brief:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart test/features/playlist/domain/playlist_test.dart test/features/playlist/domain/playlist_import_service_test.dart
```

Result before commit: `+13: All tests passed!`.

Fresh result after commit: `+13: All tests passed!`.

Additional checks:

```bash
flutter analyze lib/features/playlist/domain/playlist_service.dart test/features/playlist/domain/playlist_service_test.dart
git diff --check
git diff --cached --check
```

Results: analyzer reported `No issues found`; both diff checks exited cleanly.

## Decisions

- Replaced direct `StorageService` persistence with the approved
  `PlaylistRepository` and `PlaylistSnapshot` contract. No repository file was
  modified.
- Serialized all mutation operations through one `_tail` future. Each queued
  callback catches and completes its caller's error internally, so `_tail`
  remains successful and later invocations continue in original call order
  after a failed save or rejected operation.
- Constructed and saved the repaired immutable snapshot before publishing it to
  `_playlists`; only then is one revision incremented and emitted.
- Kept failed, protected, and no-op operations free of saves, publication, and
  revision emissions. Protected system-list deletion is rejected before queue
  entry.
- Used the injected clock for generated system playlists and mutation
  timestamps, and the injected ID factory unless `createPlaylist` receives an
  explicit ID.
- Preserved existing `favorites` and `recent` content, appending deterministic
  replacements only when missing. `init` repairs both through one save and one
  revision; a valid snapshot causes neither.
- Made `recent` newest-first, duplicate-free by song ID, and capped at 100.
- Made `replaceAll` a single queued durable replacement whose snapshot repairs
  missing system lists before one publication/revision.
- Added `dispose()` for the broadcast revision controller.

## Tests Added

- Durable save completes before in-memory publication and exactly one revision.
- Failed save, protected deletion, and no-op mutation emit no revision.
- A mutation after a failed save still executes, proving queue-tail recovery.
- Concurrent mutations save and publish in invocation order.
- Missing system playlists are repaired and durably saved during init.
- Valid system playlists cause no init save or revision.
- Recent history is durably capped at 100 in newest-first order.
- `replaceAll` repairs system lists before one save and one revision.
- Representative mutation methods report changes/no-ops without extra saves or
  revisions.

## Changed Files

- `lib/features/playlist/domain/playlist_service.dart`
- `test/features/playlist/domain/playlist_service_test.dart`

The report itself is written after the requested code commit at
`.superpowers/sdd/task-7-report.md`.

## Self-Review

- Confirmed repository files are untouched.
- Confirmed the commit contains only the two intended Task 7 code/test files.
- Confirmed save failure leaves in-memory state and revision unchanged.
- Confirmed the queue continues after save failure.
- Confirmed no-op methods avoid calling the repository.
- Confirmed all required async signatures and revision APIs are present.

## Concerns

- Existing presentation/sync/player callers still construct `PlaylistService`
  without a repository and do not consistently await its now-async methods.
  The brief explicitly assigns consumer migration to Task 8, so those files
  were not changed and full-app analysis/build was not used as a Task 7 gate.
- The mandatory report was created after the requested Task 7 code commit and
  is therefore not part of commit `9177663`.
- Unrelated pre-existing worktree changes in
  `.superpowers/sdd/network-task-4-report.md` and
  `docs/superpowers/plans/2026-07-29-playlist-snapshot-meta-immutability.md`
  were left untouched.

## Review Findings Follow-up

### RED

Added focused regressions before changing `PlaylistService`, then ran:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart
```

Result: `+8 -9`. All nine new behavior groups failed for the expected reasons:

- Loaded empty/duplicate playlist IDs were accepted.
- Explicit, generated, existing, and protected playlist ID collisions were
  accepted by `createPlaylist`.
- Duplicate `replaceAll` input was saved and published.
- Same-ID changed song metadata was treated as unchanged by `updatePlaylist`.
- Deeply equivalent `replaceAll` input still saved and incremented revision.
- `dispose` completed before a pending save and publication.
- A mutation invoked after disposal started still saved.
- Concurrent `init` calls issued two repository loads.
- `addToRecent` ignored refreshed same-ID song content.

### GREEN

After the production fix, the focused service suite passed `+18`:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart
```

The exact Task 7 verification passed `+23`:

```bash
flutter test test/features/playlist/domain/playlist_service_test.dart test/features/playlist/domain/playlist_test.dart test/features/playlist/domain/playlist_import_service_test.dart
```

Targeted checks also passed:

```bash
flutter analyze lib/features/playlist/domain/playlist_service.dart test/features/playlist/domain/playlist_service_test.dart
dart format --output=none --set-exit-if-changed lib/features/playlist/domain/playlist_service.dart test/features/playlist/domain/playlist_service_test.dart
git diff --check
```

Analyzer result: `No issues found`. Formatter reported zero changed files. Diff
check exited cleanly.

### Fixes

- Validated unique, non-empty playlist IDs at load/repair, create, and
  replacement boundaries. Invalid loaded state raises `StateError`; invalid
  caller/create-ID input raises `ArgumentError`. Rejections do not save or
  revise state, and IDs are never rewritten.
- Added complete semantic comparison for playlists and every `MusicItem` field,
  including recursively compared JSON metadata. The ID-only order helper
  remains limited to sort no-op detection.
- Made deeply equivalent `replaceAll` calls no-ops and retained one repaired
  save/revision for actual replacements.
- Made disposal idempotent and asynchronous: disposal begins synchronously,
  rejects new mutations, waits for the accepted mutation tail to finish durable
  save/publication/revision, then closes the revision stream.
- Coalesced concurrent initialization around one retryable future. Failed loads
  clear the in-flight future so a later call can load, repair, save, and publish
  once.
- Updated recent history when same-ID song content changes; only a truly equal
  newest song is a no-op.
- Added representative successful removal, manual reorder, artist sort,
  duration sort, deletion, save-count, revision, and timestamp coverage.

### Follow-up Concerns

- Task 8 callers may invoke async `dispose` from `ref.onDispose` without awaiting
  it; the synchronous disposed flag still prevents new work immediately, while
  accepted work finishes asynchronously as required.
- Task 8 consumer/repository files were intentionally not modified.
