# Network Task 6 Report

## Status

Implemented connectivity-epoch scheduling and task-attempt-owned final output
names.

## Implementation

- Wi-Fi-only scheduling captures a connectivity epoch before awaiting the
  network answer. A non-Wi-Fi event advances the epoch before invalidating and
  cancelling attempts. A delayed answer must still be Wi-Fi, match the captured
  epoch, retain Wi-Fi-only policy, and observe a live service before it can
  reserve a slot.
- Physical `.part` and final output names derive from task ID and persisted
  attempt revision. Final output is exactly `<taskId>-<attemptRevision><extension>`;
  `savePath` stores this immutable path.
- Promotion validates attempt authority across file operations and operates only
  on exact attempt-owned paths. Music-ID-wide sibling cleanup was removed, so
  stale retry, cancellation, deletion, and same-music re-add cannot delete a
  newer output by filename collision.

## TDD And Verification

- RED: a gated `currentNetwork` returned Wi-Fi after a mobile event and started
  a task before the epoch guard. GREEN proves no executor starts and no slot is
  reserved.
- Regression tests cover exact task/revision names, distinct re-add ownership,
  retry revisions, stale callback authority, and retained reservations.
- Focused download suites: 32 passed.
- Full `flutter test`: 559 passed.
- Targeted analysis: no issues.
- Full `flutter analyze`: 22 pre-existing unrelated findings; no findings in
  changed files.
- `git diff --check`: clean.

## Concern

- Injected executors intentionally bypass physical Dio promotion. The
  deterministic token-ignoring tests validate lifecycle authority and immutable
  path derivation; they do not pause a real filesystem rename.
