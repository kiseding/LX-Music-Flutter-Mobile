# Network Task 5 Report

## Status

Implemented cache-or-stream playback integration with strict RED/GREEN TDD,
including re-acquisition for cached URL reuse after preload or stop.

## Implementation

- Added `PlaybackCachePathClassification` at the cache boundary. A local path
  is now classified as ordinary non-cache media, a validated cache lease, or a
  rejected cache-shaped candidate. Rejected stable paths include evicted,
  missing, index-invalid, and persistence-rejected cache entries.
- `acquireExisting` delegates to the boundary classifier. Valid reacquisition
  updates and persists `lastAccessedAt` inside the owning key transaction
  before incrementing its lease count; a write failure restores metadata and
  refuses the lease without deleting the durable file.
- The audio handler uses the classifier before installing reused `file://`
  URLs. Ordinary local files remain playable without a lease. A rejected cache
  candidate clears stale cache URL metadata and invokes normal resolution once;
  it is never installed unleased, and the cleared extras prevent a retry loop.
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

- RED: focused cache and handler tests failed to compile because the cache
  boundary classifier and handler injection did not exist.
- GREEN: tests prove an evicted stable-looking cache path is rejected, an
  ordinary local file installs unleased, valid preload/reuse remains leased,
  rejected reuse clears stale extras and resolves once without source install,
  failed source installation releases its staged lease, and `acquireExisting`
  persists LRU access time or refuses the lease when that write fails.
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

- Focused cache and lease-resolution suites: 76 passed.
- Full suite: blocked after 500 passing tests by pre-existing cloud test API errors.
- Targeted analysis of the changed audio files and tests: no issues.
- Full analysis reports 29 diagnostics, including four pre-existing cloud test
  errors and warnings/infos outside this change.
- `git diff --check`: clean.

## Concerns

- Preload still releases its lease immediately after durable cache storage by
  design. Authoritative replay reclassifies before source ownership; if the
  cache file was evicted or otherwise rejected, stale cache metadata is cleared
  and normal resolution gets one chance to recover rather than installing it
  unleased.
- Handler cancellation retains existing shared-key semantics: foreground
  cancellation cancels all callers sharing an inflight key.
