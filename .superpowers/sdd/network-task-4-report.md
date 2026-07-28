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
