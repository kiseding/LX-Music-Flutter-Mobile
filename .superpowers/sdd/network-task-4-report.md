# Network Task 4 Report

## Status

Implemented the path-safe, generation-safe playback cache with strict RED/GREEN
TDD, exact idempotent leases, and persisted true LRU access timestamps.

## Implementation

- Added `PlaybackCacheLease(path, playableUri, release())` and
  `acquireOrDownload`. Each acquisition increments the key's lease count once;
  each lease decrements it at most once. The existing `getOrDownload` API is
  preserved for current callers.
- Cache root initialization resolves and canonicalizes the root. Persisted and
  runtime file paths must be lexical children and resolve to files under that
  root. Existing files and destinations are revalidated before return, delete,
  and rename operations.
- Poisoned outside-root, dot-dot, sibling-prefix, missing-file, and symlink
  escape entries are dropped without deleting an outside target.
- Inflight downloads use generation-specific part names and identity-tagged
  cancellation tokens. Cancellation advances the key generation. Late work
  cannot rename, index, return, or detach a replacement generation.
- Concurrent callers for one key share one inflight operation. `cancelKey`
  cancels that operation for all shared callers; there is no individual caller
  cancellation API that could cancel work owned by other callers.
- Leased and inflight keys are excluded from TTL and size eviction.
- `lastAccessedAt` is persisted on creation and every cache hit. TTL and size
  eviction use it, with size eviction selecting the least recently accessed
  unprotected entries.
- Clock, TTL, and maximum byte policy are injectable.
- Index writes are serialized. Each queued write captures its snapshot only
  when it executes, preventing an older delayed snapshot from overwriting newer
  state. A failed write does not poison subsequent queued writes.

## TDD Evidence

- Initial RED failed to compile because `acquireOrDownload`, `clock`, `ttl`, and
  `maxBytes` did not exist.
- Behavioral tests cover idempotent release, exact shared lease refcounts,
  leased/inflight eviction protection, persisted hit timestamps, true LRU,
  every required path escape class, missing files, shared inflight callers,
  late-cancelled commit/token races, and serialized persistence.
- Focused GREEN: 21 tests passed.

## Verification

- `flutter test test/core/audio/playback_cache_service_test.dart`: 21 passed.
- `flutter test`: 440 passed.
- Targeted `flutter analyze` for changed implementation/tests: no issues.
- Full `flutter analyze`: 22 existing unrelated findings (3 warnings and 19
  infos); no findings in the changed files.
- `git diff --check`: clean.

## Concerns

- `getOrDownload` remains intentionally unleased for compatibility. New code
  that needs eviction protection while consuming a file must use
  `acquireOrDownload` and release the lease when playback ownership ends.
- Filesystem checks reduce path and symlink escape risk and are repeated at
  operation boundaries, but Dart does not expose descriptor-relative atomic
  rename/delete APIs; a hostile process with write access to the cache
  directory could still attempt a check-to-operation race.

## Review Fixes

- Downloads now use generation-specific part and final staging paths. Stable
  destination replacement occurs only inside a serialized per-key commit
  section after current-generation checks. Persisted entries include their
  generation identity.
- A stale generation deletes only its unique staging artifacts. Stable-file and
  index rollback is permitted only while the index still identifies that
  generation; replacement generations cannot be removed by late cleanup.
- Every creator and joiner now awaits the same finalized operation future,
  including commit, durable-index, current-generation, and final path checks.
  Lease acquisition additionally verifies the persisted commit generation
  immediately before incrementing ownership.
- `dispose` marks the service disposed synchronously, rejects new operations and
  ordinary writes, cancels current operations, awaits initialization and all
  finalized active futures, then drains the serialized index-write tail until
  no cleanup can enqueue another write. Operation and write errors are
  contained during disposal.
- Download success requires a durable index write. A failed new-entry write
  rolls back the generation-owned index state and stable file, restores any
  prior committed entry, and returns null. A failed cache-hit timestamp write
  restores prior metadata and returns null while retaining the already durable
  file. Later writes remain usable because failures do not poison the queue.
- Regression coverage includes two shared callers cancelled during the
  post-install durable-index gate, token-ignoring downloader disposal,
  generation-owned replacement preservation, durable-write rollback, queue
  recovery, and cache-hit persistence failure.

## Review Verification

- Focused playback-cache suite: 25 passed.
- Full `flutter test`: 444 passed.
- Targeted analysis: no issues.
- Full analysis retains 22 unrelated existing findings.
- `git diff --check`: clean.

## Task 5 Integration Requirement

- Overall playback-cache remediation is not complete until Network Task 5
  migrates the production caller in `lib/main.dart` from `getOrDownload` to
  `acquireOrDownload` and holds/releases the lease for actual playback
  ownership. Task 4 intentionally does not modify `main.dart` or the audio
  handler.

## Final Review Fixes

- `cancelKey` now advances generation and cancels only when the key maps to an
  actual uncancelled inflight operation whose generation is still current.
  Calls after a committed cache hit are true no-ops, so later lease acquisition
  retains the committed generation. Repeated cancellation still targets a
  current replacement operation without weakening stale-generation cleanup.
- Cache-hit access metadata now uses a per-entry in-memory revision. Each hit
  installs a monotonically newer revision before its serialized index write; a
  failed caller restores its prior entry only when compare-and-swap confirms no
  newer revision has replaced it. Overlapping hits therefore preserve and
  persist the newest `lastAccessedAt` without introducing a global metadata
  lock.
- TTL and size eviction observe the synchronously installed latest entry state.
  The overlap regression verifies that a failed older write cannot make a
  recently accessed file appear expired after a newer successful hit.

## Final Review Verification

- Focused playback-cache suite: 28 passed.
- Full `flutter test`: 447 passed.
- Targeted analysis: no issues.
- Full analysis retains 22 unrelated existing findings.
- `git diff --check`: clean.

## Stable Sibling Fix

- Stable cache ownership now recognizes only exact lowercase 40-hex cache keys
  followed by an approved audio extension: FLAC, M4A, MP3, AAC, OGG, WAV, or
  APE. Generation-specific part, staging, and backup files are excluded, as are
  filenames that merely share a key prefix.
- Per-key commit keeps the prior indexed file and every old stable sibling until
  the replacement file and generation-bearing index entry are durably written.
  After durability, sibling deletion proceeds only while the index still names
  the committing generation. MP3-to-FLAC and FLAC-to-MP3 transitions therefore
  leave exactly the new stable file.
- A failed format-transition index write removes only the new generation file,
  restores a same-extension backup when applicable, and retains the prior
  different-extension file and index entry.
- Physical stable-file accounting now matches index accounting after format
  transitions, so old siblings cannot silently exceed `maxBytes`.
- Initialization and explicit purge scan for known-pattern stable files left by
  earlier versions. Unindexed files are removed through root-safe deletion;
  indexed paths and leased/inflight keys are preserved. Unknown, staging, part,
  and prefix-related filenames are not treated as cache-owned stable files.

## Stable Sibling Verification

- Focused playback-cache suite: 34 passed.
- Full `flutter test`: 453 passed.
- Targeted analysis: no issues.
- Full analysis retains 22 unrelated existing findings.
- `git diff --check`: clean.

## Persisted Index Hardening

- Persisted and live stable entries now require an exact lowercase 40-hex key,
  an approved audio extension, and a lexical basename equal to
  `<entry.key><extension>`. The normalized path must be a direct child of the
  canonical cache root; nested paths and key-to-other-key mappings are dropped.
- Stable validation uses `FileSystemEntity.type(..., followLinks: false)` and
  accepts only regular files. Same-root and outside-root aliases are rejected.
  An exact recognized in-root symlink may be unlinked lexically, but its target
  is never resolved for return or deletion. Mismatched rejected paths are
  preserved from orphan cleanup so an A-to-B poisoned entry cannot delete B.
- Cache hits, lease acquisition, operation completion, eviction, rollback, and
  stable sibling cleanup revalidate exact stable ownership before returning or
  deleting a path. Commit destinations reject links before replacement and
  verify the installed lexical destination is a regular file afterward.
- Index loading ignores serialized sizes. Each fully validated entry is rebuilt
  with its normalized path and physical `File.length`, unmeasurable entries are
  dropped, and the repaired index is persisted before orphan and capacity
  purging. `maxBytes` therefore operates on measured bytes after restart.

## Persisted Index Verification

- Strict RED covered mismatched ownership, nested paths, invalid keys,
  outside-root and same-root aliases, A-link-to-B target preservation, false
  zero/huge sizes, repaired-index persistence, and physical-size cap eviction.
- Focused playback-cache suite: 43 passed.
- Full `flutter test`: 462 passed.
- Targeted analysis: no issues.
- Full analysis retains 22 unrelated existing findings.
- `git diff --check`: clean.

## Transaction And Integrity Architecture

- The former commit-only tail is replaced by one asynchronous transaction tail
  per cache key. Hit validation and metadata persistence, operation selection,
  lease increment/release, commit and rollback, stable removal, TTL and size
  rechecks, cancellation/disposal cleanup, orphan cleanup, and stable sibling
  cleanup all execute under that key's transaction.
- Boundary methods enter `_withKeyTransaction` once and call `Locked` helpers;
  locked helpers never re-enter the same gate. Downloads and candidate snapshots
  remain outside the gate. A staged download enters only for durable install,
  and committed entries remain inflight-protected while global purge runs.
- Lease acquisition validates the exact current generation and physical file,
  then increments its lease before releasing the key transaction. If purge wins
  before acquisition enters, acquisition retries once and returns only a lease
  whose file still exists.
- TTL and size purge snapshot candidates, then re-evaluate the current generation,
  lease/inflight protection, live expiration, and live aggregate size under each
  candidate's key transaction. Same-generation metadata rollback is rechecked;
  stale candidates cannot delete replacement generations.
- Global index writes remain serialized by `_pendingIndexWrite`. Key transactions
  may await that tail, but its write callback only snapshots and writes `_index`
  and never enters a key transaction, preserving one-way lock ordering.
- Top-level index decode/type failure sets load integrity false, preserves the
  unreadable persisted value, and skips startup purge and orphan deletion. A
  valid top-level list parses records independently, persists valid repaired
  entries, and protects plausible malformed stable key/path claims from orphan
  cleanup. A later clean startup resumes normal orphan migration deletion.

## Transaction And Integrity TDD

- RED reproduced top-level corruption overwriting the index/deleting files,
  whole-list record failure, and lease acquisition returning null after TTL
  purge deleted the shared hit during paused validation.
- Deterministic GREEN coverage includes acquisition versus TTL purge,
  acquisition versus size pressure, failed hit persistence versus purge, commit
  versus purge, malformed top-level preservation, mixed valid/malformed repair,
  ambiguous stable ownership preservation, and later clean-load cleanup.
- Focused playback-cache suite: 51 passed.
- Targeted analysis: no issues.
