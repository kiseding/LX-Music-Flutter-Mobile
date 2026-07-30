# iOS Lossless Local Cache Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent remote FLAC/Hi-Res URLs from reaching AVPlayer while preserving lower-quality fallback and validated streaming for lossy audio.

**Architecture:** Keep `PlaybackUrlResolver` as the single quality/cache decision point. Classify lossless qualities as local-cache-only; when their cache lease is unavailable, continue the quality chain. Allow `StreamingPlayback` only for lossy qualities after cache acquisition fails. No player, decoder, or cache storage redesign is needed.

**Tech Stack:** Dart, Flutter, `just_audio`, existing `PlaybackUrlResolver`, `PlaybackCacheLease`, and Flutter tests.

## Global Constraints

- `hires`, `flac24bit`, and `flac` must be installed as local `file://` sources.
- `320k`, `192k`, and `128k` may use validated remote streaming only after cache failure.
- Preserve requested quality metadata and actual selected quality metadata.
- Preserve generation cancellation and late-lease release behavior.
- Do not add an FLAC decoder, ALAC conversion, or second audio player.

---

### Task 1: Add Resolver Regression Coverage

**Files:**
- Modify: `test/core/audio/playback_resolution_test.dart`
- Reference: `lib/core/audio/playback_cache_service.dart:154-291`

**Interfaces:**
- Consumes `PlaybackUrlResolver.resolve`, `PlayUrlResult`, and fake cache lease callbacks.
- Produces tests that define local-only lossless behavior and lossy streaming fallback.

- [ ] **Step 1: Write the failing tests**

Add these cases to the `PlaybackUrlResolver` group:

```dart
test('lossless cache failure continues to a cached lossy candidate', () async {
  final qualities = <String>[];
  final resolver = PlaybackUrlResolver<MusicItem>(
    resolvePlayableUrl: (music, {required preferredQuality}) async {
      qualities.add(preferredQuality);
      return _playResult(
        url: 'https://cdn.example/$preferredQuality.flac',
        quality: preferredQuality,
      );
    },
    acquireOrDownload: ({
      required remoteUrl,
      required platform,
      required songId,
      required quality,
    }) async {
      if (quality == 'flac') return null;
      return _FakeLease('/tmp/$quality.mp3', 'key-$quality', (_) {}).asLease();
    },
    songIdFor: (music) => music.songmid ?? music.id,
  );

  final result = await resolver.resolve(
    _item(),
    preferredQuality: 'flac',
  );

  expect(qualities, ['flac', '320k']);
  expect(result, isA<CachedPlayback>());
  expect(result!.playableUrl, 'file:///tmp/320k.mp3');
});

test('lossless cache failure never streams the lossless URL', () async {
  final resolver = PlaybackUrlResolver<MusicItem>(
    resolvePlayableUrl: (music, {required preferredQuality}) async =>
        _playResult(url: 'https://cdn.example/$preferredQuality.flac', quality: preferredQuality),
    acquireOrDownload: ({
      required remoteUrl,
      required platform,
      required songId,
      required quality,
    }) async => null,
    songIdFor: (music) => music.songmid ?? music.id,
  );

  final result = await resolver.resolve(
    _item(),
    preferredQuality: 'flac',
  );

  expect(result, isNull);
});

test('lossy cache failure may stream the validated remote URL', () async {
  final resolver = PlaybackUrlResolver<MusicItem>(
    resolvePlayableUrl: (music, {required preferredQuality}) async =>
        _playResult(url: 'https://cdn.example/$preferredQuality.mp3', quality: preferredQuality),
    acquireOrDownload: ({
      required remoteUrl,
      required platform,
      required songId,
      required quality,
    }) async => null,
    songIdFor: (music) => music.songmid ?? music.id,
  );

  final result = await resolver.resolve(
    _item(),
    preferredQuality: '320k',
  );

  expect(result, isA<StreamingPlayback>());
  expect(result!.playableUrl, 'https://cdn.example/320k.mp3');
});
```

- [ ] **Step 2: Run the focused tests and verify they fail for the expected reason**

Run:

```bash
flutter test test/core/audio/playback_resolution_test.dart --plain-name "lossless cache failure"
```

Expected: the new tests fail because the current resolver returns `StreamingPlayback` or stops after the first cache failure instead of continuing to `320k`.

### Task 2: Implement Local-Only Lossless Resolution

**Files:**
- Modify: `lib/core/audio/playback_cache_service.dart:154-291`
- Test: `test/core/audio/playback_resolution_test.dart`

**Interfaces:**
- Consumes the existing `PlaybackResolution`, `PlaybackCacheLease`, quality metadata, and generation map.
- Produces the same `PlaybackResolution?` API with candidate iteration and lossless local-only enforcement.

- [ ] **Step 1: Add a single quality predicate**

Inside `PlaybackUrlResolver`, add:

```dart
bool _requiresLocalCache(String quality) {
  final value = quality.toLowerCase();
  return value == 'flac' || value == 'flac24bit' || value == 'hires';
}
```

- [ ] **Step 2: Iterate candidates after cache failure**

Replace the single `resolvePlayableUrl`/`acquireOrDownload` block with a loop over the quality chain. For each candidate:

```dart
for (final candidateQuality in MusicSourceService.qualityChain(preferredQuality)) {
  _throwIfCancelled(cancelToken);
  final result = await resolvePlayableUrl(
    music,
    preferredQuality: candidateQuality,
  );
  _throwIfCancelled(cancelToken);
  if (result == null || !isPlayableUrl(result.url)) continue;

  final keyQuality = result.actualQuality.isNotEmpty
      ? result.actualQuality
      : candidateQuality;
  final key = PlaybackCacheService.cacheKey(
    platform: result.platform,
    songId: songId,
    quality: keyQuality,
  );
  noteCacheKey(gen, key);
  final lease = await acquireOrDownload(
    remoteUrl: result.url,
    platform: result.platform,
    songId: songId,
    quality: keyQuality,
  );
  _throwIfCancelled(cancelToken);

  if (lease == null && _requiresLocalCache(candidateQuality)) continue;

  final extras = <String, dynamic>{
    'remoteUrl': result.url,
    'actualQuality': result.actualQuality,
    'requestedQuality': result.requestedQuality,
    'platform': result.platform,
    'cacheKey': key,
    'songId': songId,
  };
  if (lease != null) {
    extras['url'] = lease.playableUri;
    return CachedPlayback(lease, extras);
  }
  extras['url'] = result.url;
  return StreamingPlayback(result.url, extras);
}
return null;
```

Use the resolver's existing generation ownership checks around every async boundary. A failed lossless candidate must release any late lease and proceed; an obsolete generation must return null immediately and never try another candidate.

- [ ] **Step 3: Run focused tests and verify they pass**

Run:

```bash
flutter test test/core/audio/playback_resolution_test.dart
```

Expected: all resolver and lease-session tests pass, including the three new cases.

### Task 3: Verify Integration and Clean Up

**Files:**
- Verify: `lib/core/audio/audio_handler.dart`
- Verify: `lib/main.dart`
- Verify: `test/core/audio`

- [ ] **Step 1: Confirm no remote lossless fallback remains**

Run:

```bash
rg "StreamingPlayback|requiresLocalCache|flac24bit|hires" lib/core/audio/playback_cache_service.dart test/core/audio/playback_resolution_test.dart
```

Expected: `StreamingPlayback` is reachable only after a lossy candidate, and lossless cases assert local-cache-only behavior.

- [ ] **Step 2: Run the complete audio suite**

Run:

```bash
flutter test test/core/audio
```

Expected: all audio tests pass with zero failures.

- [ ] **Step 3: Run static analysis**

Run:

```bash
flutter analyze
```

Expected: no errors. Existing unrelated info/warning diagnostics may remain.

- [ ] **Step 4: Check the final diff**

Run:

```bash
git diff --check
git status --short
```

Expected: only the resolver implementation, resolver tests, and approved planning/design documents are changed.
