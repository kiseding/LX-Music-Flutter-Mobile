# Network Task 5 Report

## Status

Implemented cache-or-stream playback integration with strict RED/GREEN TDD.
Production playback migrates from unleased `getOrDownload` to leased
`acquireOrDownload`, with validated HTTPS streaming fallback and generation-safe
lease transfer around authoritative source commits.

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

## Verification

- `flutter test test/core/audio/playback_resolution_test.dart`: 12 passed.
- `flutter test test/core/audio test/core/network test/features/player/domain/player_service_queue_test.dart`: 345 passed.
- Targeted `flutter analyze` for changed files: no issues.
- `git diff --check`: clean.

## Concerns

- Reused extras `file://` URLs do not re-acquire a lease. A long-idle
  re-play of a previously preloaded path may race with TTL/LRU after all
  leases are released. Foreground exclusive resolve re-acquires a lease when
  extras are cleared (quality change / forced re-resolve).
- Preload still uses the string `urlResolver` path and releases leases
  immediately; durable cache files remain, but concurrent preload of many
  tracks no longer pins them against eviction.
- Handler cancel on generation change cancels all tracked resolver keys plus
  the last foreground cache key. Shared inflight keys between preload and
  foreground still follow `cancelKey` semantics (all shared callers cancel).
