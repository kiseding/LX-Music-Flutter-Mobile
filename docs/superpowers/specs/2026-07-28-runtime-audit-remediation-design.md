# Runtime Audit Remediation Design

Date: 2026-07-28  
Status: approved for specification review  
Scope: audio, queue, network, custom sources, cache, downloads, persistence, playlists, lyrics, routing, and player UI

## Goal

Resolve every runtime audit item through evidence-driven remediation while preserving existing user data and playback compatibility. An item is complete when it is fixed with regression coverage, proven not to be a defect, or explicitly assigned to an iOS device verification checklist because the behavior cannot be validated in Dart tests.

The work is iOS-first. Shared Dart code must continue to compile for other supported Flutter targets, but Android runtime behavior is not a release gate for this remediation.

## Constraints

- Keep the Darwin precise duration and timing option for FLAC playback.
- Do not reintroduce fixed seek delays, optimistic settle polling, or source reloads as timing compensation.
- Preserve imported custom-source compatibility with public HTTPS services.
- Block custom-source access to cleartext HTTP, loopback, link-local, and private networks.
- Migrate existing cloud tokens without forcing users to sign in again.
- Preserve existing playlists and recent-play history through storage migration.
- Implement and integrate by module, with shared contracts merged in a fixed order.

## Audit Disposition

Maintain a remediation matrix for every Critical, High, Medium, and Low audit item. Each item must finish in exactly one state:

1. `fixed`: the failure chain is reproduced or structurally demonstrated, then covered by a regression test and corrected.
2. `already-correct`: current behavior is proven correct by a focused test or direct API contract evidence.
3. `device-verification`: correctness depends on iOS media-session, AVPlayer, interruption, or background execution behavior unavailable in the Linux environment.
4. `invalid`: the original finding is disproven with code-path evidence.

Low-severity findings are not an instruction to refactor speculative code. They still receive a disposition, but code changes require a demonstrated behavioral or security benefit.

## Architecture

### 1. Audio And Queue

`LxAudioHandler` becomes the single source of truth for:

- immutable queue snapshots;
- current queue index;
- current media item;
- repeat and shuffle mode;
- processing and playing state;
- official playback position.

`PlayerService` may remain as a command facade, but it must not maintain an independently mutable queue or current index. Riverpod and player UI consume handler snapshots. App controls, lock-screen controls, automatic completion, and error skipping all use the same handler command path.

Playback retains the existing single-source architecture. Queue updates change queue metadata only; they must not construct a `ConcatenatingAudioSource` with unresolved or silent placeholder entries. Selecting a queue item resolves and installs exactly that item as the active source.

Repeat-one completion replays the current queue item. Automatic advance is triggered by one authoritative completion signal and guarded by playback generation. Position thresholds may support diagnostics but do not independently advance the queue. Stale completion, resolution, preload, and seek operations cannot mutate a newer playback generation.

Playback-state publication includes the current processing state, playing state, queue index, controls, repeat/shuffle state, speed, buffered position, and an engine-derived update position. Audio-session interruption and route-loss behavior follow `audio_session` events and preserve explicit user intent.

Quality changes re-resolve the current item whether playing or paused, retain the clamped engine position, and resume only if it was previously playing. Scrub operations remain pause, native seek, optional resume, and official-clock unfreeze without timing compensation.

### 2. Network, Custom Sources, Cache, And Downloads

One quality-resolution coordinator owns fallback ordering and returns the resolved URL plus actual quality. `main.dart`, built-in source clients, custom sources, preload, playback, and downloads must not independently repeat the same quality chain.

Production HTTPS clients use platform certificate validation. Debug-only certificate overrides, if retained at all, must be explicit and impossible in release builds.

The custom-source HTTP bridge uses a compatibility-first sandbox:

- allow public HTTPS destinations;
- reject cleartext HTTP;
- reject loopback, link-local, private, multicast, unspecified, and reserved destination addresses for IPv4 and IPv6;
- resolve hostnames and validate every resolved address before connecting;
- revalidate every redirect target;
- reject caller-controlled hop-by-hop headers and sensitive platform headers;
- impose request, response, redirect, and timeout limits;
- surface a stable security error to the source instead of silently bypassing the policy.

Playback cache tasks are cancellable by key and generation. Switching tracks cancels obsolete foreground and preload downloads. A cache lease pins every file currently opened for playback; expiry and LRU eviction exclude leased entries. Cache failure falls back to the already resolved streaming URL. Index loading accepts only normalized paths inside the cache root.

Download concurrency uses an atomic queue/permit mechanism. Wi-Fi-only preferences are enforced before starting and while resuming queued downloads. Task identifiers use collision-resistant IDs. Progress persistence is throttled and flushed at state boundaries rather than on every callback.

### 3. Persistence, Playlists, And Lyrics

Cloud authentication secrets move to an iOS Keychain-backed secure-storage implementation. Migration follows this order:

1. read the legacy SharedPreferences token;
2. write it to secure storage;
3. read it back and compare;
4. mark migration complete and delete the plaintext value only after verification;
5. preserve the plaintext value and retry later if secure storage fails.

Large playlist and recent-play data move from whole-table SharedPreferences writes to versioned JSON files written through temporary-file replacement. Migration validates decoded data before replacing legacy storage and retains a recovery copy until the first successful load from the new format. Small settings and migration flags may remain in SharedPreferences.

`PlaylistService` publishes one revision stream after every successful mutation. Riverpod derives playlist views from that stream. Callers do not manually increment a separate version provider. System playlists are restored when missing or corrupt, and service-level rules prevent invalid deletion.

Lyrics, search, import, and other asynchronous state use monotonically increasing request generations tied to the target identifier. A result or error is published only when both generation and target still match. Retrying lyric search invokes the actual load command rather than relying on invalidation side effects.

### 4. UI, Routing, And Performance

Opening the full-screen player is idempotent: repeated taps do not stack duplicate player routes. Playlist detail routes carry a playlist identifier and support restoration and deep links.

High-frequency position state is watched only by progress, time, and lyric-current-line widgets. The full player shell, artwork, queue, and controls rebuild only for state they render. Lyric scrolling avoids rebuilding the entire list for every position tick.

Gesture ownership is explicit. Horizontal page changes, vertical lyric scrolling, progress dragging, and downward dismissal each claim a gesture only after direction and hit-region thresholds identify the intended control. A failed or cancelled dismissal always resets its visual offset.

Dialogs and sheets respect keyboard insets and small screens. Artwork transitions retain bounded outgoing children during rapid track changes. UI state such as play mode is derived from handler state rather than a second local model.

## Integration Strategy

Analysis, failing tests, and implementation can proceed independently by module. Shared contracts are integrated in this order:

1. audio and queue state contract;
2. URL resolution, cache, and download contract;
3. persistence and reactive business state;
4. UI and routing consumers.

Changes that touch a shared contract are not merged out of order. Each module is kept runnable and testable before the next integration step. Existing unrelated worktree changes must not be reverted.

## Error Handling

- A blocked custom-source request returns a distinct policy error with the rejected category, without exposing sensitive network details.
- A failed URL or quality resolution records the attempted quality chain and advances according to queue policy without terminating the background audio session unnecessarily.
- A cache write failure falls back to streaming and removes partial files.
- A storage migration failure leaves the old data untouched and retries on a later startup.
- Corrupt playlist files are quarantined, then recovered from the validated legacy or recovery copy when available.
- Stale async completions are discarded without publishing transient errors for the current item.
- User-visible errors are actionable and avoid presenting security-policy failures as generic network outages.

## Testing

### Audio And Queue

- queue snapshot and current index remain aligned after app, lock-screen, and automatic navigation commands;
- repeat-one replays the current item;
- completion is handled once per playback generation;
- queue metadata updates do not install concatenated silent sources;
- stale resolution, preload, completion, and scrub operations cannot affect a newer item;
- paused and playing quality changes preserve position and intent;
- loading/idle seek does not publish a false target position;
- playback-state broadcasts contain accurate processing and position fields.

### Network, Cache, And Downloads

- release clients reject invalid TLS certificates;
- sandbox address classification covers IPv4, IPv6, DNS results, and redirects;
- unsafe headers, cleartext URLs, oversized responses, excessive redirects, and timeouts are rejected;
- quality fallback executes once and reports actual quality;
- cancelled cache tasks cannot commit late results;
- leased files survive expiry and LRU cleanup;
- cache failure falls back to streaming;
- download permits enforce configured concurrency and Wi-Fi-only behavior.

### Persistence And State

- token migration success deletes plaintext only after read-back verification;
- migration failure preserves the legacy token and retries;
- playlist migration is atomic and recovers from corrupt files;
- every playlist mutation emits one revision;
- system playlists are restored and protected;
- stale lyric, search, and import results cannot overwrite current state;
- lyric retry starts a new request.

### UI And Routing

- repeated mini-player taps produce one player route;
- playlist deep links restore the requested ID;
- playlist edits refresh all consumers;
- keyboard insets keep import inputs reachable;
- gesture cancellation resets offsets and does not steal progress or lyric gestures;
- high-frequency position updates do not rebuild the full player shell.

### Verification Commands

Run focused tests while developing, then run:

```bash
flutter analyze
flutter test
flutter build ios --release --no-codesign
```

The iOS build command requires macOS/Xcode and is not expected to run in the current Linux environment. Its result must therefore remain unverified until CI or a macOS host executes it.

## iOS Device Acceptance

Verify on a physical iOS device:

1. lock-screen next, previous, seek, pause, resume, repeat-one, and queue metadata;
2. uninterrupted background auto-advance across several tracks and resolution failures;
3. incoming call, Siri, alarm, headphone removal, Bluetooth route changes, and app suspension;
4. FLAC seek while playing and paused without audio/lyric divergence;
5. quality changes while playing and paused with position preservation;
6. cache eviction pressure while the current file is playing;
7. token and playlist migration from an installed pre-remediation build.

## Completion Criteria

- Every audit item has a documented disposition and evidence.
- All fixed items have focused regression coverage unless they are native-only device checks.
- `flutter analyze` and `flutter test` pass after integration.
- No production TLS bypass or plaintext cloud token remains after successful migration.
- Queue, index, media item, play mode, and official position have one authoritative state source.
- Existing playlist data and custom public-HTTPS sources remain usable within the documented security policy.
- Native-only checks are reported as pending until actually run; they are never represented as passing based on Dart tests alone.
