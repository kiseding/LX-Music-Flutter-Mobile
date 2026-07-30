# Lock-Screen Skip Audio Keepalive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep the native iOS audio session alive throughout slow lock-screen next/previous resolution by playing a temporary silence source.

**Architecture:** Add a coordinator operation that installs a temporary source only while a source request token remains current, without marking that token as the authoritative target installation. Next and previous call it with a one-day `SilenceAudioSource` before resolving the target. The existing target commit and generation checks replace or reject it.

**Tech Stack:** Dart, Flutter, `just_audio`, `audio_service`, existing playback coordinator and Flutter tests.

## Global Constraints

- Only next and previous navigation install the keepalive source.
- The keepalive must be genuinely playing while effective playback intent is true.
- A keepalive install may never override a newer source request.
- Pause during target resolution must keep the target paused after installation.
- Stop, interruption, and disposal retain existing coordinator authority.

---

### Task 1: Coordinator Temporary Source Installation

**Files:**
- Modify: `lib/core/audio/playback_command_coordinator.dart`
- Test: `test/core/audio/playback_command_coordinator_test.dart`

**Interfaces:**
- Produce `Future<bool> installTemporarySource(int token, AudioSource source)`.
- Return true only when the token still owns `_desiredSource` after native installation.
- Do not assign `_installedSourceToken`; the final `commitSource` must still install the target.

- [ ] Add a failing test that requests source B, gates temporary installation, requests source C, then confirms B's temporary result is false and cannot own C.
- [ ] Add a failing test that installs a temporary source under current play intent and confirms native playback starts while `installedSourceIsAuthoritative` remains false.
- [ ] Implement serialized temporary installation through the coordinator mutation tail with token checks before and after `setAudioSource`.
- [ ] Run `flutter test test/core/audio/playback_command_coordinator_test.dart`.

### Task 2: Lock-Screen Navigation Keepalive

**Files:**
- Modify: `lib/core/audio/audio_handler.dart`
- Test: `test/core/audio/playback_state_test.dart`

**Interfaces:**
- Next and previous call `installTemporarySource` with `SilenceAudioSource(duration: Duration(days: 1))` after `requestSource` and before `_loadQueueItem`.
- If the request becomes stale, navigation returns without resolving the target.

- [ ] Add a failing gated-resolver test asserting next performs a second native source install for silence before resolution and the player remains playing after an old-track completion signal.
- [ ] Add a failing test asserting pause during gated resolution leaves the final target paused.
- [ ] Install the silence keepalive in next and previous only.
- [ ] Run `flutter test test/core/audio/playback_state_test.dart`.

### Task 3: Regression Verification

**Files:**
- Verify: `test/core/audio`
- Verify: `lib/core/audio/audio_handler.dart`
- Verify: `lib/core/audio/playback_command_coordinator.dart`

- [ ] Run `flutter test test/core/audio` and require zero failures.
- [ ] Run `flutter analyze`; allow only existing unrelated diagnostics.
- [ ] Run `git diff --check` and inspect `git status --short`.
