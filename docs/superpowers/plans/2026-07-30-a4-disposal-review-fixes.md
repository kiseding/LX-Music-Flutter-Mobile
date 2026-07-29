# A4 Disposal Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make audio runtime teardown await all native mutations and started callbacks, continue cleanup after failures, and clean resources created before startup failures.

**Architecture:** `PlaybackCommandCoordinator.stopAndWait()` is the native mutation barrier. `LxAudioHandler` performs first-error teardown across callbacks, subscriptions, leases, coordinator, and player. A focused `AudioRuntime` owns cache, handler, AudioSession subscriptions, and started callback futures, and is registered immediately as startup resources become available.

**Tech Stack:** Dart, Flutter, audio_service, audio_session, just_audio, flutter_test.

## Global Constraints

- Preserve A1-A3 behavior and do not fix the known duplicate-source baseline failure.
- Do not modify Worker files.
- Use strict red-green TDD for every production behavior change.
- `ResourceDisposalTracker` drains sequentially in reverse registration order.
- No Git operations; this workspace has no Git repository.

---

### Task 1: Coordinator Stop Barrier

**Files:**
- Modify: `lib/core/audio/playback_command_coordinator.dart`
- Test: `test/core/audio/playback_command_coordinator_test.dart`
- Test: `test/core/audio/playback_state_test.dart`

**Interfaces:**
- Produces: `Future<void> PlaybackCommandCoordinator.stopAndWait()`.
- Guarantees: all previously queued reconciliations and the authoritative stop reconciliation complete before return.

- [ ] Add tests that gate a queued source install and queued pause, start handler disposal, and assert native player disposal cannot begin until the gate releases and stop completes.
- [ ] Run focused tests and confirm they fail because disposal currently calls non-barrier `stop()`.
- [ ] Implement `stopAndWait()` by setting stop intent and awaiting the queued stop application plus the stable coordinator tail.
- [ ] Change handler disposal to use `stopAndWait()` and run focused tests green.

### Task 2: Failure-Resilient Handler and Lease Teardown

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Modify: `lib/core/audio/playback_cache_service.dart`
- Test: `test/core/audio/playback_state_test.dart`
- Test: `test/core/audio/playback_resolution_test.dart`

**Interfaces:**
- `LxAudioHandler.dispose()` returns one shared future, attempts every cleanup step exactly once, and rethrows the first error with its stack.
- `PlaybackLeaseSession.releaseAll()` attempts pending and active release independently and rethrows the first failure after both.

- [ ] Add injected failures for callback cancellation, each player subscription, pending lease, current lease, stop barrier, and native player disposal; assert later steps still run and the first exact error is rethrown.
- [ ] Run focused tests red against fail-fast cleanup.
- [ ] Add a local first-error capture pattern to handler teardown and lease session release.
- [ ] Run focused tests green and preserve idempotent future identity/player disposal count.

### Task 3: Audio Runtime Callback Ownership

**Files:**
- Create: `lib/core/audio/audio_runtime.dart`
- Test: `test/core/audio/audio_runtime_test.dart`

**Interfaces:**
- Produces: `AudioRuntime`, which immediately owns handler and cache, attaches AudioSession streams, tracks each started callback future, and exposes idempotent `Future<void> dispose()`.
- Disposal order: cancel subscriptions, drain started callbacks, dispose handler, dispose cache; continue after failures and rethrow first error.

- [ ] Add a test with an interruption/noisy callback blocked behind a gate; disposal must cancel subscriptions but remain incomplete until the callback drains, then dispose handler before cache.
- [ ] Run focused test red because `AudioRuntime` does not exist.
- [ ] Implement callback tracking without allowing newly received events after disposal begins.
- [ ] Add failure aggregation tests for subscription cancel, callback future, handler, and cache; run green.

### Task 4: Immediate Startup Ownership and Real Wiring

**Files:**
- Modify: `lib/main.dart`
- Modify: `lib/core/audio/audio_runtime.dart`
- Test: `test/core/audio/audio_runtime_test.dart`

**Interfaces:**
- Produces a testable startup helper that creates/initializes cache, immediately registers runtime cleanup, then wires resolver/callbacks and AudioSession listeners.
- On any later initialization failure, the registered runtime owns every successfully created audio resource.

- [ ] Add real wiring tests with fake cache/session dependencies: fail after cache creation and after listener attachment, then assert all already-created resources are cleaned in dependency order.
- [ ] Run focused tests red against current `main.dart` late registration.
- [ ] Extract the smallest injectable audio runtime setup helper and use it from `main.dart`; register cleanup immediately after runtime construction.
- [ ] Run wiring tests green and verify LIFO tracker interaction with the real runtime disposer.

### Task 5: Verification and Report

**Files:**
- Update: `.superpowers/sdd/A4-report.md`
- Delete: `A4-report.md`

- [ ] Run all covering audio runtime, coordinator, playback state/resolution, startup lifecycle tests.
- [ ] Run analyzer on all changed production/test files.
- [ ] Record each red failure and green command, including the unchanged baseline duplicate-source failure if encountered.
- [ ] Synchronize the final report under `.superpowers/sdd/A4-report.md` and remove the root duplicate.
