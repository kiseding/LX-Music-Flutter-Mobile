# Playback Cache Lease Reacquisition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure every authoritative cached `file://` source owns a validated playback-cache lease through source installation.

**Architecture:** Add a path-based cache lease acquisition API that enters the owning cache key's transaction, proves the supplied path is the indexed exact stable file, and increments the lease count without downloading. Inject that API into the handler; when a reused `file://` URL is about to become authoritative, acquire and hold a replacement lease before source installation, commit it only on installed source success, and discard it on stale or failed installs. Streaming remains unleased and clears pending lease state.

**Tech Stack:** Flutter/Dart, `flutter_test`, `PlaybackCacheService`, `LxAudioHandler`, `PlaybackCommandCoordinator`.

## Global Constraints

- `acquireExisting(path)` must never lease arbitrary `file://` or non-cache paths.
- Exact stable ownership validation and lease-count mutation run under `_withKeyTransaction` for the entry's key.
- No cache download is permitted during path-based reacquisition.
- The old active lease is released only after the replacement source installation commits.
- Tests are strict red-green TDD and use real cache/handler behavior with minimal fakes only at audio-engine and cache injection boundaries.

---

### Task 1: Reacquire Existing Cache Ownership

**Files:**
- Modify: `test/core/audio/playback_cache_service_test.dart`
- Modify: `lib/core/audio/playback_cache_service.dart`

**Interfaces:**
- Produces: `Future<PlaybackCacheLease?> PlaybackCacheService.acquireExisting(String path)`.

- [ ] **Step 1: Write failing cache ownership tests**

```dart
final lease = await cache.acquireExisting(path);
expect(lease?.path, path);
await lease?.release();
expect(await cache.acquireExisting('/tmp/not-owned.mp3'), isNull);
```

- [ ] **Step 2: Run the cache test to verify it fails**

Run: `flutter test test/core/audio/playback_cache_service_test.dart`
Expected: compile failure because `acquireExisting` does not exist.

- [ ] **Step 3: Implement the smallest validated reacquisition API**

```dart
Future<PlaybackCacheLease?> acquireExisting(String path) async {
  await init();
  final normalized = _normalizeAbsolute(path);
  final match = _stableCacheName.firstMatch(File(normalized).uri.pathSegments.last);
  if (match == null) return null;
  final key = match.group(1)!;
  return _withKeyTransaction(key, () => _acquireLeaseLocked(key, normalized));
}
```

The final implementation must also reject paths outside `_root` and paths not exactly equal to the persisted validated entry.

- [ ] **Step 4: Run the cache test to verify it passes**

Run: `flutter test test/core/audio/playback_cache_service_test.dart`
Expected: PASS.

### Task 2: Lease Reuse Across Authoritative Source Installation

**Files:**
- Modify: `test/core/audio/playback_resolution_test.dart`
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `lib/main.dart`

**Interfaces:**
- Consumes: `Future<PlaybackCacheLease?> Function(String path)` injected by `attachPlaybackCache`.
- Produces: handler source installation which stages a lease for reused cache `file://` URLs and commits/discards it through `PlaybackLeaseSession`.

- [ ] **Step 1: Write failing handler lifecycle tests**

```dart
handler.attachPlaybackCache(acquireExisting: acquireExisting);
await handler.setPlaylist([preloadedFileItem]);
expect(acquiredPaths, [cachePath]);
expect(activeLease.releaseCount, 0);
```

Cover preload-style released file reuse, stop then replay, old active release after commit, invalid non-cache URI, source failure release, and streaming pending cleanup.

- [ ] **Step 2: Run the resolution test to verify it fails**

Run: `flutter test test/core/audio/playback_resolution_test.dart`
Expected: assertion failure because reused file URLs are installed with no new lease.

- [ ] **Step 3: Implement staged reacquisition and cleanup**

```dart
final replacement = await _acquireExistingCacheLease(url);
if (replacement != null) _leaseSession.holdPending(replacement);
final commit = await _commands.commitSource(commandToken, audioSourceFor(url));
if (commit is SourceCommitInstalled) {
  await _leaseSession.commitIfGeneration(..., lease: replacement);
} else {
  await _leaseSession.discardPending(replacement);
}
```

For non-file and non-cache paths, leave `replacement` null. Clear superseded pending state before streaming installations.

- [ ] **Step 4: Wire the cache service in main**

```dart
lxHandler.attachPlaybackCache(
  acquireExisting: playbackCache.acquireExisting,
  cancelCacheKey: playbackCache.cancelKey,
  cancelAllTrackedCacheWork: playbackResolver.cancelAllTracked,
);
```

- [ ] **Step 5: Run the resolution test to verify it passes**

Run: `flutter test test/core/audio/playback_resolution_test.dart`
Expected: PASS.

### Task 3: Document and Verify

**Files:**
- Modify: `.superpowers/sdd/network-task-5-report.md`

- [ ] **Step 1: Update the report with the fixed lifecycle and red-green evidence**

- [ ] **Step 2: Run focused and full verification**

Run: `flutter test test/core/audio/playback_cache_service_test.dart test/core/audio/playback_resolution_test.dart`
Expected: PASS.

Run: `flutter test`
Expected: PASS.

Run: `flutter analyze`
Expected: no new diagnostics.

Run: `git diff --check`
Expected: no whitespace errors.

- [ ] **Step 3: Commit the implementation**

```bash
git add lib/core/audio/playback_cache_service.dart lib/core/audio/audio_handler.dart lib/main.dart test/core/audio/playback_cache_service_test.dart test/core/audio/playback_resolution_test.dart .superpowers/sdd/network-task-5-report.md docs/superpowers/plans/2026-07-29-playback-cache-lease-reacquisition.md
```
