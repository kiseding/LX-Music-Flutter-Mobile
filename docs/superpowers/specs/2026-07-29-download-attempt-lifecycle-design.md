# Download Attempt Lifecycle

Date: 2026-07-29
Status: approved amendment pending implementation

## Goal

Prevent cancelled, retried, policy-paused, and disposed download attempts from
overlapping or mutating newer task state, output, or persistence.

## Ownership Model

- A task has a monotonically increasing `attemptRevision`. Each started
  executor owns one immutable revision, its cancellation token, its future,
  and generation-specific staging paths.
- The active reservation belongs to the executor attempt, not merely the task
  state. It remains occupied until that attempt's `finally` completes, even
  after cancellation or Wi-Fi policy loss.
- Retry, pause, cancel, delete, Wi-Fi policy loss, and disposal advance the
  revision before cancellation. This makes all callbacks from the previous
  executor stale immediately.
- Every progress, status, error, completion, and finalization action checks
  that its revision is still current. A stale attempt cannot update a newer
  task, remove its active reservation, or schedule a replacement.

## Scheduling And Wi-Fi Policy

- Pending tasks start only while a real capacity slot is available. The slot is
  reserved synchronously before starting an executor.
- On Wi-Fi loss, active attempts are cancelled and their tasks become pending
  for policy retry, but their reservations remain active until the executors
  settle.
- When Wi-Fi returns, the regular queue processor runs. It starts replacement
  work only after old executors have finalized and freed capacity.
- The service maintains a connectivity epoch. Every Wi-Fi-only queue check
  captures that epoch before awaiting `currentNetwork`; the result may reserve
  slots only if the service remains live, Wi-Fi-only policy remains enabled,
  and the captured epoch still equals the current epoch. Every non-Wi-Fi
  connectivity event advances the epoch before cancelling active attempts.
  Therefore, a delayed Wi-Fi result received after a mobile event cannot start
  a pending task.

## File Ownership

- Each attempt receives a unique `.part`, staging, and completed destination
  path. The final destination is exactly `<taskId>-<attemptRevision><extension>`;
  `savePath` persists that immutable completed path. Task IDs, not music IDs,
  provide output identity, so deleting and re-adding the same music cannot
  collide with old work.
- Only the current attempt may validate and promote its staging file to its own
  destination. It checks current ownership before and after every awaited file
  operation. Promotion uses only attempt-specific paths and never replaces a
  shared music-ID output.
- An attempt only removes its own part, staging, or final destination. There is
  no music-ID-wide sibling cleanup. Cancellation, retry, delete, stale
  executor cleanup, and stale promotion cannot delete or rewrite a newer task
  or retry output.

## Persistence And Disposal

- Persistence uses a recoverable serialized tail. Every request snapshots the
  current task list and is queued after both successful and failed prior work.
  The caller for a failed write receives that failure, while later writes still
  execute.
- Terminal transitions enqueue persistence immediately. Disposal first marks
  the service disposed, invalidates and cancels active attempts, waits for all
  executor futures and the persistence tail, then closes connectivity, stream,
  and Dio resources.
- No callback may add to the task stream after disposal closes it.

## Verification

- Tests use token-ignoring gated executors to prove capacity remains reserved
  through Wi-Fi cancellation and disposal.
- Deterministic race tests cover stale progress, errors, finalizers, cleanup,
  retry output preservation, persistence-tail recovery, and no post-close
  stream writes.
- Deterministic tests also hold `currentNetwork` behind a gate, emit mobile,
  then return Wi-Fi and prove no slot is reserved. Filesystem races cover
  cancel/delete/re-add of one music ID, retry while an old executor ignores its
  token, and stale promotion/cleanup; each proves the current task's completed
  immutable output remains intact.

## Implementation Notes

- `DownloadTask.attemptRevision` is persisted with a zero default for existing
  saved tasks.
- `DownloadService` keeps a revision-owned attempt record in the active slot
  until its executor future returns. The provider retains the settings-backed
  connectivity subscription and starts asynchronous disposal when Riverpod
  releases the service.
