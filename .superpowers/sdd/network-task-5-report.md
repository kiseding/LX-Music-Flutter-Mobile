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

## Important Review Fix

- A resolver-produced cached `file://` URL now adopts a matching pending lease
  before any cache-path classification. This preserves the resolver's already
  validated ownership when a classification-side LRU persistence write would
  fail.
- A mismatched pending lease is discarded before classifying the returned file
  URL. If that file URL is rejected, the handler clears stale metadata and makes
  one fresh resolution attempt; a validated remote result streams explicitly.
- Strict RED: the matching-lease test failed by invoking the classifier and
  reporting its simulated persistence error; the stale-mismatch test failed by
  neither releasing the stale lease nor resolving the remote fallback.
- GREEN: `flutter test test/core/audio/playback_resolution_test.dart` passed 21
  tests. `flutter test test/core/audio test/core/network` passed 330 tests.
  Targeted analysis of the handler and regression test reported no issues.
- Full `flutter analyze` reports 23 existing diagnostics outside this change.

## Pending Resolution Lifecycle Review Fix

- Every resolver callback now carries the handler playback generation through
  resolver extras. `noteResolvedPlayback` accepts a result only for the active
  media item and exact current generation; late cached results release their
  lease immediately and never enter the pending map.
- A generation bump first removes every pending resolution, releases each
  uncommitted cache lease, and clears session pending ownership. This covers
  stop, playlist replacement (including empty playlists), source switches, and
  stale source invalidation. Explicit queue removal also removes/releases that
  item's pending resolution.
- Streaming resolutions replace and discard an earlier pending cached result.
  Committed leases remain in `PlaybackLeaseSession` and are unaffected until
  their normal replacement or stop lifecycle.
- `_takePendingLeaseForUrl` rejects released leases defensively. It discards the
  stale entry and proceeds through the existing cache-path classifier and
  reacquisition path rather than returning a released owner.
- Strict RED: the expanded resolver tests failed to compile because
  `noteResolvedPlayback` had no generation argument. GREEN: the handler now
  propagates and verifies that provenance.

## Pending Resolution Verification

- `flutter test test/core/audio/playback_resolution_test.dart`: 25 passed.
- `flutter test test/core/audio test/core/network`: 334 passed.
- `flutter analyze lib/core/audio/audio_handler.dart lib/core/audio/playback_cache_service.dart lib/main.dart test/core/audio/playback_resolution_test.dart`:
  no issues.

## Pending Resolution Concerns

- Source-install races can legitimately cause a stale native install recovery
  to reacquire the same durable cache path. The final authoritative source owns
  the live replacement lease; intermediate leases are released by existing
  generation-gated source cleanup.

## Resolver Metadata Ownership Fix

- `LxAudioHandler.acceptResolvedPlayback` now owns the foreground resolver
  publication transaction. It verifies the exact playback generation, active
  media identity, and live media item before mutating either queue or media
  extras, staging the resolution, or adopting its cache lease. A rejected
  cached result releases its lease; a rejected streaming result writes no
  metadata.
- `main.dart` preserves the string URL resolver contract and returns the
  resolved URL exactly as before, but delegates all resolver metadata and lease
  handling to the handler before returning. It no longer writes quality extras
  directly.
- Preload uses a separate request authority: each attempt has a unique token
  tied to the scheduling playback generation, original queue index, and media
  identity. Preload metadata can update only that still-queued, non-current
  item. If it becomes current, is moved/replaced, or the generation changes,
  the result is ignored and any cache lease is released. Preloads never adopt a
  foreground playback lease.

## Resolver Metadata TDD

- RED: `playback_resolution_test.dart` failed to compile because
  `acceptResolvedPlayback` did not exist; after the foreground gate was added,
  the preload regression failed to compile because `acceptPreloadedPlayback`
  did not exist.
- GREEN: deterministic late A resolution after switch to B proves no A URL or
  quality extras are published and the A lease releases once. A late streaming
  A result likewise publishes no metadata. A valid current resolution updates
  both media and queue extras and holds its lease until stop. A late preload
  after its queue item becomes current is rejected and releases its cache lease.

## Resolver Metadata Verification

- `flutter test test/core/audio/playback_resolution_test.dart`: 29 passed.
- `flutter test test/core/audio test/core/network test/features/player/domain/player_service_queue_test.dart`: 368 passed.
- `flutter analyze lib/core/audio/audio_handler.dart lib/main.dart test/core/audio/playback_resolution_test.dart`: no issues.
- `flutter test`: 555 passed.
- `flutter analyze`: 22 pre-existing unrelated diagnostics; none in the Task 5
  handler, resolver, or regression-test files.

## Resolver Metadata Concerns

- Preload cache leases remain intentionally short-lived. A preloaded durable
  file is reclassified and re-leased only when an authoritative source request
  installs it, so eviction can require a normal re-resolution before playback.

## Foreground Duplicate Occurrence Fix

- Foreground source transactions now retain the request's exact queue index and
  `MediaItem` identity through metadata acceptance, source installation, and
  commit. The request updates its identity only when its own exact-slot metadata
  patch creates an immutable replacement item.
- Active lookup no longer relocates by media ID. It accepts only the original
  current slot while that tracked occurrence and `mediaItem` identity still
  match, so a second duplicate installs its own resolved source rather than
  being rejected by the first duplicate occurrence.
- Existing source-command ownership, generation checks, lease staging, queue
  metadata targeting, and audio coordinator behavior remain unchanged. External
  replacement or movement of the occurrence still invalidates the request.

## Foreground Duplicate TDD

- RED: the expanded active-duplicate regression failed with
  `sourceInstallCount` equal to `0` after resolution metadata had been accepted,
  proving the ID-based active lookup selected the first duplicate before source
  installation.
- GREEN: the regression proves the second duplicate's resolved URL installs and
  plays, while the first duplicate remains unmodified. Existing replaced and
  moved duplicate cases remain rejected.

## Queue Selection And Recovery Duplicate Fix

- `skipToQueueItem(index)` now captures the exact `MediaItem` at the requested
  queue slot before asynchronous pause work. It loads only that same index when
  the slot still contains the identical object; a moved or replaced occurrence
  is stale and is rejected rather than relocated by ID.
- `_recoverAuthoritativeSource` now captures the live `mediaItem` and current
  queue index as one authoritative occurrence. Recovery reloads only when the
  queue still contains that identical object at the current index; it no longer
  uses `indexWhere` to collapse duplicate IDs to the first occurrence.
- Source-command tokens, generation gates, metadata transaction identity, and
  cache lease staging/commit/release remain on the existing paths.

## Queue Selection And Recovery TDD

- RED: the focused resolver suite failed because direct selection of duplicate
  index 1 loaded index 0, stale native-install recovery also reloaded index 0,
  and moved/replaced duplicate selections installed an unintended source.
- GREEN: regression coverage proves direct `skipToQueueItem(1)` installs the
  second duplicate and leaves the first untouched; stale native-install recovery
  reloads the second occurrence; and moved/replaced occurrences reject rather
  than collapse by ID.

## Queue Selection And Recovery Verification

- `flutter test test/core/audio/playback_resolution_test.dart`: 37 passed.
- `flutter test test/core/audio`: 256 passed.
- `flutter analyze lib/core/audio/audio_handler.dart test/core/audio/playback_resolution_test.dart`:
  no issues.
- `git diff --check`: clean.

## Queue Selection And Recovery Concerns

- The fix intentionally covers the reported direct selection and authoritative
  recovery paths. Other legacy ID-based queue operations remain unchanged where
  their public APIs provide only an ID rather than an occurrence identity.
