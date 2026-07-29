# Runtime Audit Remediation Design

## Scope

Fix every confirmed runtime audit finding except the following two explicitly excluded Worker issues:

1. Anonymous playlist preview can fan out into unbounded upstream requests.
2. Authenticated playlist import accepts unbounded request bodies and song counts.

The implementation covers the remaining 37 findings across Flutter audio, asynchronous state, persistence, downloads, networking, accessibility, routing, Cloudflare Workers, authentication storage, and the iOS project configuration.

This work will be performed directly in the extracted `/tmp/opencode/LX2IOS-main` source tree. The source tree has no Git metadata, so no commits will be created.

## Constraints

- Preserve the behavior of the two excluded playlist-import findings.
- Avoid unrelated refactors and major dependency upgrades.
- Fix root causes rather than masking races with delays or retries.
- Follow existing Riverpod, audio handler, storage, and Worker patterns where they are sound.
- Add focused regression coverage proportional to each change's risk.
- Treat Linux-incompatible Xcode, VoiceOver, Instruments, and App Store checks as explicit manual verification items.

## Implementation Strategy

Work is divided by runtime ownership boundary. Each batch gets focused regression tests before implementation, domain verification after implementation, and a final full regression pass.

### Batch A: Playback and Asynchronous State

- Give queue entries stable occurrence identity so an active item can move while a source transaction is in flight without becoming stale or loading twice.
- Pause the old source while a newly selected item resolves, and publish buffering/source ownership consistently so audio, artwork, lyrics, and lock-screen metadata cannot disagree.
- Make scrub transactions idempotently cancellable from drag cancellation and widget disposal.
- Add lifecycle ownership for the audio handler, player subscriptions, audio-session subscriptions, cache resolver, and native player.
- Add request generations to lyrics and searches. Search pagination must use the query and source snapshot stored in state, not mutable UI input.
- Observe sleep-timer pause failures and expose a deterministic failure state instead of silently completing.

### Batch B: Persistence, Downloads, Sync, and Network Boundaries

- Validate persisted download records independently. Quarantine malformed records instead of failing startup.
- Canonicalize every persisted download path and require strict ownership by the download root before reading, deleting, or reconciling it.
- Make completed-file and task-index commits recoverable. Startup reconciliation will remove or recover strictly named temporary and orphaned files.
- Treat a `false` result from SharedPreferences writes as a persistence failure at the storage boundary.
- Add initialization/mutation generations to settings and search history so stale initial loads cannot overwrite user changes.
- Fully decode and validate backups before writes. Restore through a snapshot-backed transaction and update live providers only after durable success.
- Reject an entire cloud playlist replacement when any remote song fails validation.
- Add operation/session generations and cancellation to synchronization. Old requests cannot publish after disconnect, server changes, or a newer operation.
- Add connect, send, receive, and total-operation deadlines to synchronization requests.
- Reuse the existing pinned transport and request policy for remote custom-source import. Require HTTPS, validate every redirect, and cap time and bytes.
- Bound local backup and custom-source files by bytes, nesting depth, field sizes, playlists, and songs before expensive parsing or copying.
- Always close artwork clients and cap response duration and bytes before decoding.
- Partition cloud bearer tokens by normalized origin and invalidate the active session atomically when origin changes.
- Remove legacy plaintext tokens after secure migration. Keychain failures must require reauthentication rather than falling back to plaintext.

### Batch C: UI State, Accessibility, Navigation, and Performance

- Route global playback errors through a stable ScaffoldMessenger key and clear them only after successful consumption.
- Guard dialog asynchronous continuations with mounted state and make import dismissal behavior deterministic.
- Cancel custom-source log subscriptions and dispose controllers with the widget.
- Move high-frequency position observation into narrow progress and lyric subtrees. Avoid duplicate timer/stream publications when the effective position has not changed.
- Use stable playlist occurrence keys for reorderable rows.
- Put the playlist ID in the route and resolve the current repository value, allowing deep links and state restoration.
- Restore settings through notifier APIs so durable and in-memory state commit together.
- Replace gesture-only core controls with semantic Flutter controls where possible. Custom controls must expose role, label, selected/toggled state, activation, focus, and keyboard actions.
- Expose adjustable semantics for progress, lyrics, and equalizer controls, including current value and increase/decrease actions.

### Batch D: Worker and iOS Boundaries

- Remove schema creation and index reconstruction from request handling. Keep runtime code to readiness checks and provide deployment migration scripts/configuration.
- Make authentication rate-limit infrastructure failure return a controlled unavailable response instead of allowing unlimited requests.
- Replace one-Durable-Object-per-IP-and-username storage with bounded IP-oriented storage, dual account/IP limits, alarms, and deletion when empty.
- Implement custom-source `crypto.randomBytes` with platform cryptographic randomness.
- Stop returning internal exception messages in Worker 500 responses. Return a request ID and log structured details server-side.
- Advance the Worker compatibility date through tests and enable sampled structured logs and traces without logging credentials.
- Add `PrivacyInfo.xcprivacy` to the Runner target resources and verify its project references.

## State and Error Semantics

- Every asynchronous result must prove ownership before mutating state. Ownership is represented by stable occurrence identity for queue entries and monotonically increasing generations for requests and sessions.
- Cancellation is expected control flow. Cancellation must release leases and pause owners but must not publish stale errors.
- Durable operations publish success only after persistence succeeds. A failed transaction restores both persistent and in-memory state.
- Corrupt persisted input is isolated and reported while valid records continue loading.
- Resource limits are enforced before full buffering and again while streaming when content length is absent or untrusted.
- Security-sensitive state is bound to its authority, especially cloud tokens to server origin and download paths to their owning directory.

## Testing Strategy

### Automated Flutter Tests

- Preserve and make green the two currently failing queue-move tests.
- Add deterministic tests for scrub cancellation, source/UI consistency, lyric and search stale-result rejection, lifecycle disposal, and sleep-timer failure.
- Add corruption, path ownership, crash reconciliation, persistence-false, stale initialization, backup rollback, malformed cloud snapshot, sync generation, timeout, and resource-limit tests.
- Add widget tests for global error delivery, disposed-dialog completion, subscription disposal, stable reorder identity, deep-link restoration, and semantic actions.

### Automated Worker Tests and Checks

- Add tests for schema-free request handling, fail-closed rate limiting, bounded limiter cleanup, generic 500 responses, and cryptographic random byte shape.
- Run TypeScript compilation and Worker dry-run validation.
- Confirm the two excluded playlist import behaviors were not modified as part of this work.

### Final Verification

- `flutter test` must complete with zero failures.
- `flutter analyze` must contain no diagnostics introduced by this work and no remaining async-context diagnostics in the modified import flows.
- Worker `npx tsc --noEmit` must pass.
- Worker deployment dry-run must pass.
- Inspect the Xcode project file to confirm the privacy manifest is in Copy Bundle Resources.

### Manual Verification Required on macOS/iOS

- Archive Runner and inspect the app bundle for `PrivacyInfo.xcprivacy`.
- Exercise audio interruptions, route disposal during scrubbing, background playback, and lock-screen metadata on a physical device.
- Run VoiceOver and keyboard/Switch Control checks over navigation, playback, progress, lyrics, settings toggles, and equalizer controls.
- Capture Instruments Swift/Flutter performance traces before and after the position-observation changes.

## Acceptance Criteria

- All 37 in-scope findings have either a regression test or an explicit structural/manual verification check.
- The two excluded Worker playlist-import findings remain out of scope and behaviorally unchanged.
- Existing tests, including the two currently failing queue tests, pass.
- No stale async result can overwrite newer search, lyric, sync, settings, source, or queue state in covered paths.
- Persisted corruption cannot prevent startup or authorize deletion outside an owned download path.
- Token, limiter, Worker error, and schema migration boundaries follow the security behavior described above.
- Core app navigation and playback are operable through accessibility semantics, not touch gestures alone.
