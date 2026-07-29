# Download Attempt Lifecycle

Date: 2026-07-29
Status: approved

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

## File Ownership

- Each attempt receives a unique `.part` path and, for physical downloads, a
  unique staging path derived from its task ID and revision.
- Only the current attempt may validate and promote its staging file to the
  stable completed path.
- An attempt only removes paths it owns. Cancellation, retry, delete, and
  stale cleanup cannot delete a newer attempt's staging file or completed
  output.

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
