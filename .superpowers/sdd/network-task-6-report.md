# Network Task 6 Report: Download Attempt Lifecycle

Date: 2026-07-29
Status: completed

## Delivered

- Persisted monotonic `attemptRevision` values on download tasks while keeping
  UUID task IDs unchanged.
- Replaced task-level cancellation ownership with revision-owned attempt
  records. Active capacity remains reserved until the executor future settles.
- Invalidated attempts before retry, pause, cancel, delete, Wi-Fi policy loss,
  cache clear, and disposal cancellation. Progress, completion, failure, and
  finalization mutations require the current attempt identity.
- Assigned each physical executor a revision-specific `.part` path and guarded
  promotion/cleanup so stale work cannot affect a later attempt.
- Made persistence tail recovery independent of previous write failure while
  retaining per-write error delivery and terminal/disposal flushing.
- Made disposal asynchronous: mark disposed, cancel and await attempts and
  persistence, then close Dio and the task stream. No callback can emit after
  disposal begins.
- Retained centralized fresh URL resolution, bounded expired-link retry, UUID
  generation, and settings-backed connectivity wiring.

## Test Evidence

- `flutter test test/features/download/domain/download_service_test.dart`
- `flutter test test/features/download/domain/download_task_test.dart`
- `flutter analyze`

The service test suite uses cancellation-ignoring gated executors to verify
Wi-Fi slot retention, no duplicate executor on Wi-Fi restoration, stale retry
callback isolation, persistence-tail recovery, and disposal stream safety.
