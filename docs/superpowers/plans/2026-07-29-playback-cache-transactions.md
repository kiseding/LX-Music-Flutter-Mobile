# Playback Cache Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serialize all playback-cache key ownership transitions and fail closed on uncertain persisted-index integrity.

**Architecture:** Replace commit-only tails with one non-reentrant transaction queue per key and locked private methods. Parse index records independently, carry startup integrity and ambiguous-key protection into orphan cleanup, and preserve one-way key-gate-to-index-write lock ordering.

**Tech Stack:** Dart, Flutter Test, `dart:io`, JSON persisted index store.

## Global Constraints

- Stable ownership remains exact lowercase 40-hex key plus approved extension, direct canonical-root child, regular file, and no symlink following.
- Never enter the same key transaction from a `Locked` method.
- Index-write callbacks never wait for a key transaction.
- Every behavioral change follows RED, GREEN, focused regression, then full verification.

---

### Task 1: Fail-Closed Index Loading

**Files:**
- Modify: `lib/core/audio/playback_cache_service.dart`
- Test: `test/core/audio/playback_cache_service_test.dart`

**Interfaces:**
- Produces: `_loadIntegrity`, `_uncertainLoadKeys`, record-isolated `_loadIndex()` behavior.

- [x] Add tests proving malformed top-level data preserves all stable files, mixed valid/malformed records retain valid entries and potentially owned files, and a later clean load resumes orphan cleanup.
- [x] Run the named tests and verify failures are caused by whole-load exception handling and unconditional startup cleanup.
- [x] Parse top-level and records independently, classify ambiguous claims conservatively, persist repair only after valid top-level decode, and gate startup orphan cleanup on integrity.
- [x] Run the focused cache suite and targeted analysis.

### Task 2: Per-Key Non-Reentrant Transactions

**Files:**
- Modify: `lib/core/audio/playback_cache_service.dart`
- Test: `test/core/audio/playback_cache_service_test.dart`

**Interfaces:**
- Produces: `_withKeyTransaction<T>(String key, Future<T> Function() action)` and non-reentrant `Locked` mutation helpers.

- [x] Add deterministic lease-versus-TTL and lease-versus-size purge tests that pause validation and assert every returned lease references an existing file.
- [x] Run the named tests and verify the validation/delete race.
- [x] Replace commit tails with the key transaction gate; move lease, hit, commit/rollback, removal, purge rechecks, cancellation cleanup, and sibling cleanup into locked helpers.
- [x] Re-run focused tests and targeted analysis.

### Task 3: Deadlock and Mutation Ordering

**Files:**
- Modify: `lib/core/audio/playback_cache_service.dart`
- Test: `test/core/audio/playback_cache_service_test.dart`
- Modify: `.superpowers/sdd/network-task-4-report.md`

**Interfaces:**
- Consumes: per-key gate and global `_pendingIndexWrite` tail.

- [x] Add hit-write-failure-versus-purge and commit-versus-purge tests with controlled index stores.
- [x] Verify RED against mutation paths that are not under one key transaction.
- [x] Split remaining boundary and `Locked` methods to eliminate nested entry and preserve one-way lock ordering.
- [x] Run focused tests and targeted `flutter analyze`; full verification follows before commit.
- [x] Append architecture, TDD evidence, verification counts, and residual concerns to the Task 4 report.
- [ ] Commit the intended files with repository identity.
