# Network Task 5 Report

## Status

Implemented cache-or-stream playback integration with strict RED/GREEN TDD,
including re-acquisition for cached URL reuse after preload or stop.

## Implementation

- Added sealed `PlaybackResolution` with `CachedPlayback(lease)` and
  `StreamingPlayback(remoteUrl)`, both exposing `playableUrl` and quality
  extras for queue metadata.
- Added `PlaybackUrlResolver<T>`: resolves quality once via injected
  `resolvePlayableUrl`, attempts `acquireOrDownload`, returns a lease-backed
  file URI or the already-validated remote HTTPS URL. Invalid/null remotes
  never stream. Per-resolution generations track cache keys; exclusive
  foreground resolves cancel prior tracked work; non-exclusive preloads do not
  cancel siblings.
- Added `PlaybackLeaseSession` for pending/active lease ownership: retain the
  prior active lease until a newer source commit, release on stop/removal,
  discard stale pending leases once, and generation-gated commits.
- `lib/main.dart` wires `PlaybackUrlResolver` with
  `MusicSourceService.resolvePlayableUrl` and `PlaybackCacheService.acquireOrDownload`.
  Cache miss falls back to streaming; only the current media item retains a
  lease (preload releases immediately after storing the durable URL).
- `LxAudioHandler` owns the active lease session: notes resolutions from the
  production resolver, commits after authoritative source install, discards on
  stale/failure paths, cancels foreground/tracked cache keys on generation
  change, and releases all leases on stop/empty playlist.
- Added `PlaybackCacheService.acquireExisting(path)`. It initializes the cache,
  rejects non-root/non-stable paths, derives the candidate key only from an
  exact stable basename, then enters that key's transaction gate. The existing
  locked validator proves the path is the indexed exact stable file and current
  generation before incrementing the lease count; it never downloads.
- `LxAudioHandler` receives `acquireExisting` from `main.dart`. Before every
  authoritative reused `file://` source install, it re-acquires and holds a
  validated cache lease. The lease is committed only after source installation;
  stale or failed installs discard it. The prior active lease remains until the
  replacement commits. Streaming clears unrelated pending ownership before it
  becomes authoritative.
- Existing string `UrlResolver` tests remain unchanged.

## TDD Evidence

- RED: `playback_resolution_test.dart` failed to compile because
  `PlaybackResolution`, `PlaybackUrlResolver`, `PlaybackLeaseSession`, and
  `PlaybackCacheLease.test` did not exist.
- GREEN: pure unit tests with fakes cover streaming fallback, invalid remote
  failure, null resolution failure, cached lease URI, exclusive track-switch
  cancel, preload cancel, non-exclusive sibling work, lease transfer/release,
  stop/removal release, no double release, stale pending discard, streaming
  commit release, and generation races.
- RED: cache reacquisition tests failed because `PlaybackCacheService` had no
  `acquireExisting`; handler reuse tests failed because `attachPlaybackCache`
  had no re-acquisition callback. The streaming-pending regression initially
  showed that a pending lease remained after a streaming commit.
- GREEN: cache tests prove an indexed stable path can be re-leased without a
  second download and an unrelated local path is refused. Handler tests cover
  preload-style persisted file URL reuse, stop then replay re-leasing, delayed
  old-active release after source commit, local path rejection by the injected
  cache boundary, failed source-install release, and streaming pending cleanup.

## Verification

- Focused cache and lease-resolution suites: 70 passed.
- Full suite: 505 passed.
- Targeted analysis of the five changed Dart files: no issues.
- Full analysis retains 23 existing diagnostics, including an unrelated
  `cloud_provider.dart` invalid assignment.
- `git diff --check`: clean.

## Concerns

- Preload still releases its lease immediately after durable cache storage by
  design. Authoritative replay now re-acquires before source ownership, but an
  entry can still be evicted during the idle preload-to-replay interval; in
  that case the cache rejects the path and the handler continues without a
  lease rather than leasing an arbitrary local file.
- Handler cancellation retains existing shared-key semantics: foreground
  cancellation cancels all callers sharing an inflight key.
