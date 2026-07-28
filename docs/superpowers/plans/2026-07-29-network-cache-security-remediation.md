# Network Cache Security Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Secure outbound networking, centralize quality resolution, make playback caching cancellation-safe, and enforce reliable download scheduling.

**Architecture:** Shared network policy objects own TLS and custom-source destination validation. `MusicSourceService` owns the quality fallback chain exactly once. Playback cache exposes cancellable leased results with root-safe paths, while `DownloadService` consumes one resolved URL per attempt through an atomic scheduler.

**Tech Stack:** Flutter 3.x, Dart, Dio 5.7, connectivity_plus 6.1, Riverpod 2.6, SharedPreferences, flutter_test

## Global Constraints

- Production clients use platform certificate validation; no release bad-certificate callback remains.
- Custom sources may access public HTTPS hosts, but not cleartext HTTP, URL credentials, loopback, link-local, private, multicast, unspecified, or reserved addresses.
- Every DNS result and redirect target is revalidated before use.
- Existing public-HTTPS custom sources remain compatible.
- Quality fallback is executed by one coordinator and reports actual quality.
- Cache failure falls back to an already validated streaming URL.
- Active cache files are never evicted.
- Preserve the completed serialized audio-command architecture and its tests.

## File Structure

- Create `lib/core/network/app_http_client.dart`: production-safe Dio construction.
- Create `lib/core/network/source_request_policy.dart`: custom-source URL, DNS, header, redirect, and size policy.
- Modify `lib/features/custom_source/domain/custom_source_engine.dart`: enforce injected request policy and bounded responses.
- Modify `lib/core/network/music_source_service.dart`: sole quality-chain resolver.
- Modify `lib/main.dart`: consume one resolution and cache-or-stream result.
- Modify `lib/core/audio/playback_cache_service.dart`: cancellation generations, path validation, leases, and LRU.
- Modify `lib/core/audio/audio_handler.dart`: cancel obsolete cache work and retain/release playback leases through resolver integration.
- Modify `lib/features/download/domain/download_service.dart`: atomic scheduler, Wi-Fi policy, UUID IDs, serialized persistence.
- Modify `lib/features/download/presentation/download_provider.dart`: wire settings and connectivity.

---

### Task 1: Production TLS Policy

**Files:**
- Create: `lib/core/network/app_http_client.dart`
- Modify: `lib/core/music_source/platform/music_platform.dart`
- Modify: `lib/features/playlist/domain/playlist_import_service.dart`
- Modify: `lib/core/audio/playback_cache_service.dart`
- Modify: `lib/features/download/domain/download_service.dart`
- Modify: `ios/Runner/Info.plist`
- Create: `test/core/network/tls_policy_test.dart`

**Interfaces:**
- Produces: `AppHttpClient.create({BaseOptions? options})` with system trust and no implicit debug bypass.

- [ ] **Step 1: Add failing policy tests**

```dart
test('production networking has no bad certificate callback', () {
  for (final path in [
    'lib/core/music_source/platform/music_platform.dart',
    'lib/features/playlist/domain/playlist_import_service.dart',
    'lib/core/audio/playback_cache_service.dart',
    'lib/features/download/domain/download_service.dart',
  ]) {
    expect(File(path).readAsStringSync(), isNot(contains('badCertificateCallback')));
  }
});

test('iOS transport security does not allow arbitrary loads', () {
  final plist = File('ios/Runner/Info.plist').readAsStringSync();
  expect(plist, isNot(contains('<key>NSAllowsArbitraryLoads</key>')));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/network/tls_policy_test.dart`
Expected: FAIL on unconditional platform/import bypass and ATS arbitrary loads.

- [ ] **Step 3: Centralize system-trust clients**

```dart
final class AppHttpClient {
  static Dio create({BaseOptions? options}) => Dio(options ?? BaseOptions());
}
```

Use this factory at all listed call sites. Remove `NSAllowsArbitraryLoads`; normalize known media HTTP URLs to HTTPS instead of weakening ATS.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/core/network/tls_policy_test.dart test/platform_sources_test.dart test/features/playlist/domain/playlist_import_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/network/app_http_client.dart lib/core/music_source/platform/music_platform.dart lib/features/playlist/domain/playlist_import_service.dart lib/core/audio/playback_cache_service.dart lib/features/download/domain/download_service.dart ios/Runner/Info.plist test/core/network/tls_policy_test.dart
git commit -m "fix: enforce production TLS validation"
```

### Task 2: Custom-Source Request Sandbox

**Files:**
- Create: `lib/core/network/source_request_policy.dart`
- Modify: `lib/features/custom_source/domain/custom_source_engine.dart`
- Create: `test/core/network/source_request_policy_test.dart`
- Modify: `test/features/custom_source/domain/custom_source_engine_test.dart`

**Interfaces:**
- Produces: `SourceRequestPolicy.validate(Uri uri, Map<String, dynamic> options)` returning `ValidatedSourceRequest`; `SourceRequestPolicyException(code)`.
- Injects: DNS resolver and maximum response bytes for deterministic tests.

- [ ] **Step 1: Add failing URL/address/header tests**

```dart
test('allows public https and rejects private or cleartext destinations', () async {
  final policy = SourceRequestPolicy(resolve: (_) async => [InternetAddress('93.184.216.34')]);
  expect(await policy.validate(Uri.parse('https://example.com/a'), {}), isA<ValidatedSourceRequest>());
  await expectLater(policy.validate(Uri.parse('http://example.com/a'), {}), throwsA(isA<SourceRequestPolicyException>()));
  await expectLater(policy.validate(Uri.parse('https://127.0.0.1/a'), {}), throwsA(isA<SourceRequestPolicyException>()));
});
```

Cover IPv4/IPv6 loopback, RFC1918, link-local, multicast, unspecified, reserved, URL credentials, dangerous headers, DNS mixed public/private results, redirects, timeout clamping, and response limit.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/network/source_request_policy_test.dart`
Expected: FAIL because policy types do not exist.

- [ ] **Step 3: Implement and inject policy**

Validate scheme/credentials/host, resolve every address, strip hop-by-hop and sensitive platform headers, disable Dio automatic redirects, validate each `Location`, and stream/count response bytes before exposing data to JS. Return one base64 field and alias it in JS to avoid two Dart base64 copies.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart test/features/custom_source/domain/custom_source_host_regression_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/network/source_request_policy.dart lib/features/custom_source/domain/custom_source_engine.dart test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart
git commit -m "fix: sandbox custom source requests"
```

### Task 3: Single Quality Resolution Coordinator

**Files:**
- Modify: `lib/core/network/music_source_service.dart`
- Modify: `lib/main.dart`
- Modify: `lib/features/download/domain/download_service.dart`
- Create: `test/core/network/music_source_resolution_test.dart`
- Modify: `test/core/network/quality_chain_test.dart`

**Interfaces:**
- Produces: `Future<PlayUrlResult?> resolvePlayableUrl(MusicItem music, {required String preferredQuality, CancelToken? cancelToken})`.

- [ ] **Step 1: Add failing call-order tests**

```dart
test('each quality is attempted once and actual downgrade is reported', () async {
  final calls = <String>[];
  final resolver = FakeQualityResolver((quality) async {
    calls.add(quality);
    return quality == '320k' ? playableResult(actual: '320k') : null;
  });
  final result = await resolver.resolvePlayableUrl(item, preferredQuality: 'flac');
  expect(calls, ['flac', '320k']);
  expect(result!.actualQuality, '320k');
});
```

Cover cancellation and retained low-quality result only after preferred candidates fail.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/network/music_source_resolution_test.dart`
Expected: FAIL because the unified API/test seam does not exist.

- [ ] **Step 3: Move fallback ownership into `MusicSourceService`**

Custom and built-in source attempts receive each quality once. `main.dart` calls the unified API once; downloads call it once per expired-link retry, not once per outer quality loop.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/core/network test/features/custom_source/domain/custom_source_quality_test.dart test/features/download/domain/download_task_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/network/music_source_service.dart lib/main.dart lib/features/download/domain/download_service.dart test/core/network/music_source_resolution_test.dart test/core/network/quality_chain_test.dart
git commit -m "fix: centralize play URL quality fallback"
```

### Task 4: Safe Playback Cache And Leases

**Files:**
- Modify: `lib/core/audio/playback_cache_service.dart`
- Modify: `test/core/audio/playback_cache_service_test.dart`

**Interfaces:**
- Produces: `PlaybackCacheLease(path, playableUri, release())`; generation-safe cancellation; injectable `ttl` and `maxBytes`.

- [ ] **Step 1: Add failing cancellation/path/lease/LRU tests**

```dart
test('leased entry survives expiration and size eviction', () async {
  final lease = await cache.acquireOrDownload(
    remoteUrl: 'https://cdn.example.com/song.flac',
    platform: 'tx',
    songId: 'song-1',
    quality: 'flac',
  );
  await cache.purgeExpired();
  expect(File(lease!.path).existsSync(), isTrue);
  await lease.release();
  await cache.purgeExpired();
  expect(File(lease.path).existsSync(), isFalse);
});
```

Cover late cancelled downloader commit, shared inflight callers, true `lastAccessedAt` LRU, poisoned outside-root path, `..`, sibling-prefix, missing file, and symlink escape where supported.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/audio/playback_cache_service_test.dart`
Expected: FAIL because leases/path checks/LRU are absent.

- [ ] **Step 3: Implement cache ownership**

Persist `lastAccessedAt`; reference-count leases by key; exclude leased/inflight entries from cleanup. Normalize and resolve paths under the cache root before return or deletion. Cancellation increments per-key generation so late completion cannot rename/index a stale part file.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/core/audio/playback_cache_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/core/audio/playback_cache_service.dart test/core/audio/playback_cache_service_test.dart
git commit -m "fix: make playback cache lease safe"
```

### Task 5: Cache-Or-Stream Playback Integration

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `lib/core/audio/playback_cache_service.dart`
- Create: `test/core/audio/playback_resolution_test.dart`

**Interfaces:**
- Produces: sealed `PlaybackResolution` with `CachedPlayback(lease)` and `StreamingPlayback(remoteUrl)`; handler releases the prior lease only after a newer source owns playback.

- [ ] **Step 1: Add failing fallback and lease-transfer tests**

```dart
test('validated remote URL streams when cache write fails', () async {
  final result = await resolver.resolve(item);
  expect(result, isA<StreamingPlayback>());
  expect((result as StreamingPlayback).remoteUrl, 'https://cdn.example/a.mp3');
});
```

Cover invalid remote failure, track switch cancellation, preload cancellation, old lease retained until source commit, and lease release on stop/removal.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/core/audio/playback_resolution_test.dart`
Expected: FAIL because cache-only nullable path is still used.

- [ ] **Step 3: Integrate typed playback resolution**

The resolver resolves quality once, attempts cache, returns a lease-backed file URI or the validated HTTPS URL. Handler generation changes cancel obsolete cache work and transfer/release leases around authoritative source commits.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/core/audio test/core/network test/features/player/domain/player_service_queue_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/main.dart lib/core/audio/audio_handler.dart lib/core/audio/playback_cache_service.dart test/core/audio/playback_resolution_test.dart
git commit -m "fix: fall back to validated audio streaming"
```

### Task 6: Atomic Download Scheduler

**Files:**
- Modify: `lib/features/download/domain/download_service.dart`
- Modify: `lib/features/download/presentation/download_provider.dart`
- Modify: `lib/features/download/domain/download_task.dart`
- Create: `test/features/download/domain/download_service_test.dart`

**Interfaces:**
- `DownloadService` accepts `maxConcurrent`, connectivity stream/current result, `wifiOnly`, `taskIdFactory`, downloader, and storage seam.
- Produces: active task-ID set and serialized persistence tail.

- [ ] **Step 1: Add failing scheduler tests**

```dart
test('never starts more than maxConcurrent downloads', () async {
  final service = testService(maxConcurrent: 2, downloader: gatedDownloader);
  await service.addTasks([a, b, c]);
  expect(gatedDownloader.active, 2);
  gatedDownloader.complete(a.id);
  await service.idle;
  expect(gatedDownloader.started, hasLength(3));
});
```

Cover duplicate starts, UUID/task ID injection, Wi-Fi-only start and loss pause, restart on Wi-Fi, stale persistence ordering, terminal-state flush, throttled progress, and restart demotion without false resumability.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/features/download/domain/download_service_test.dart`
Expected: FAIL because scheduler seams and policy enforcement do not exist.

- [ ] **Step 3: Implement scheduler and provider wiring**

Reserve slots synchronously in an active-ID set before launching futures. Subscribe to connectivity; when Wi-Fi-only is enabled, cancel active transfers to policy-pending state and restart on allowed networks. Use `Uuid.v4`, serialize writes through a future tail, throttle progress persistence, and flush every terminal transition/dispose.

- [ ] **Step 4: Verify subsystem and full suite**

Run: `flutter test test/features/download test/core/network test/core/audio`
Expected: PASS.

Run: `flutter test`
Expected: PASS.

Run: `flutter analyze`
Expected: no new errors or warnings compared with the recorded 35-finding baseline.

- [ ] **Step 5: Commit**

```bash
git add lib/features/download/domain/download_service.dart lib/features/download/presentation/download_provider.dart lib/features/download/domain/download_task.dart test/features/download/domain/download_service_test.dart
git commit -m "fix: serialize download scheduling and persistence"
```
