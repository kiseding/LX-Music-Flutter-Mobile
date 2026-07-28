# Serialized Playback Command Coordinator Design

## Goal

Replace independent generation-gated `AudioPlayer` futures with one desired-state coordinator while preserving Audio Tasks 1-5 queue, completion, quality, scrub, seek, playback-state, single-source, and Darwin behavior.

## Ownership

`LxAudioHandler` remains authoritative for queue contents, logical index, media metadata, URL resolution, completion policy, and error messages. `PlaybackCommandCoordinator` owns desired native playback state and is the only component allowed to invoke `play`, `pause`, `stop`, `seek`, `setAudioSource`, `setLoopMode`, or `setShuffleModeEnabled`.

The coordinator synchronously records:

- the latest source request token, media id, queue index, position, and resolved source;
- the latest explicit play/pause intent revision;
- opaque preserving-pause owners held in a live-owner set by scrub, quality reload, source replacement, and recovery transactions;
- interruption depth, cycle revision, sticky `mayResume`, and non-resumable resume denial;
- becoming-noisy denial;
- desired loop and shuffle modes.

## Source Flow

Starting a selection records the authoritative source request before any await. Network URL resolution remains outside the coordinator. The resolver result is converted to the existing single `AudioSource` with precise Darwin options and committed with its request token. The coordinator exposes desired and installed source tokens plus `installedSourceIsAuthoritative`. Native completion handling requires that coordinator authority in addition to handler generation and media identity, so requesting a replacement immediately makes old native `completed` state inert.

`commitSource` returns a typed `SourceCommitResult`: installed, stale/cancelled, or authoritative failure carrying the original error and stack. Stale failure/cancellation is silent. A stale successful native install records that the player was physically mutated and may trigger bounded authoritative recovery. Authoritative failure remains under `_loadQueueItem` user error and queue fallback policy, runs exactly once without a fixed delay, and reconciles manual buffering.

The coordinator serially installs an accepted source and reconciles afterward. A source spanning a complete resumable interruption starts after installation when user intent remains play. A non-resumable cycle records a denial at the current explicit-intent revision; the source remains paused until a newer explicit play advances that revision. Explicit play during an older paused selection therefore transfers fresh play authority to that still-authoritative source request.

## Mutation Drain

Every desired-state update increments a command revision and appends reconciliation to one future tail. A command queued behind an active mutation records desired state synchronously; source commit, confirmed seek, and preserving pause may additionally await application. Each reconciliation may apply all currently needed loop, shuffle, stop, source, seek, and playing transitions in that order. Awaited native mutations are strictly serialized.

`just_audio.play()` has a lifecycle future that normally completes only after a later pause, stop, or natural completion. Its invocation is ordered in the drain, but that lifecycle future is observed rather than awaited by the drain. Each invocation captures both its play command token and the installed authoritative source token. Completion or error is current only when the play command token is still active and its captured source token matches both installed and desired source authority. Requesting a replacement source therefore makes the old lifecycle stale immediately, before replacement resolution or installation. Before coordinator-owned pause or stop, the active token records why the lifecycle will end. Natural completion is recognized from `ProcessingState.completed`. Preserving-pause completion remains paused while any owner is live; stop and natural completion do not reconcile/replay the current source. Unknown current lifecycle completion reconciles latest desired state. A stale completion or error cannot report, publish, pause, stop, mutate failure state, or schedule reconciliation attributable to the stale source.

`pausePreservingIntent` returns an opaque `PreservingPauseOwner` carrying the coordinator intent revision and desired source token captured at acquisition. Only `releasePreservingIntent` with that same object removes it, and repeated release is inert. Effective desired play is blocked while any owner remains, regardless of release order or newer explicit play intent. Scrub transactions retain their owner through seek and release it in `finally`. A confirmed `resumeAfter` release reconciles play. An unconfirmed, failed, stale, or non-resuming finish may change coordinator desired play to false only when the handler source/user-intent generations and owner coordinator intent/source revisions still match the scrub's captures. A newer explicit play, pause, source selection, or scrub therefore remains authoritative and reconciles after the exact old owner releases. Quality, navigation, replacement, and recovery transactions transfer or release their owner in `try/finally`, including stale and failed exits. Explicit pause, stop, interruption denial, and noisy denial still win after all owners release.

A seek revision ends in exactly one applied or failed state. A thrown native seek reports `seek`, consumes that revision, and allows the same reconciliation to continue toward current pause/source/play state. Only a newer explicit seek revision retries native seek.

After each native mutation, unknown/pause lifecycle completion, and error, reconciliation targets the newest desired state. Stop and natural-completion lifecycle endings are terminal notifications and deliberately do not reconcile current-source playback. Publication is delegated to one handler callback and occurs only after the coordinator has re-read current desired revision.

## Interruptions And Noisy

The first interruption begin opens a cycle, snapshots the coordinator intent revision, and nested begins increase depth. Any nested `end(false)` makes the cycle non-resumable until final consumption. Active depth blocks effective desired playing without clearing explicit user intent. A fully resumable final end removes the block and reconciles a newer explicit play even if handler begin ownership snapshots differ. Without newer explicit play, automatic resume still requires the handler's old interruption-owned source identity. Explicit pause, stop, noisy, or any `mayResume: false` end remains denied.

Becoming noisy synchronously records desired pause, clears interruption ownership, and queues reconciliation. If explicit play occurs before or during the older queued pause, post-mutation reconciliation observes the newer intent and restores only the current authoritative source.

## Integration

Scrub pause/seek/release, quality pause/reload, completion auto-next, current-item removal, stale-source recovery, idle recovery, stop, repeat, and shuffle all update coordinator desired state. `ScrubCoordinator.begin` keeps every prior acquired or pending transaction until its exact owner is finalized. Superseding a transaction asynchronously starts one idempotent release future; a late pause completion either self-releases through `stillOwnsScrub` or is released by that finalizer. Stale `finish` joins the same release future, while the newest transaction and owner remain untouched. A transferred preserving owner enters `_loadQueueItem` under an outer `try/finally` before index validation, so invalid index, queue shortening/clearing, stale generation, resolver failure, install outcome, and fallback exits release that exact owner once. Callers either retain an owner locally or null their local reference when transferring it. `expectedUserIntentGeneration` remains on load transactions so an older source install cannot revive a newer user pause when releasing its own preserving owner. `PlaybackStartProvenance` and handler source/media generations remain around scrub restoration, resolver results, completion claims, and stale-source recovery because those validate handler-owned asynchronous source identity. They do not override a newer coordinator explicit-play revision at interruption end. Independent native mutation tails are removed.

## Verification

Deterministic completer-gated tests cover native serialization, stale same-source play completion, source-request superseding pending play and native completion, typed source commit outcomes, authoritative failure reporting/fallback, silent stale failure, real-handler null/thrown/stale scrub seeks, explicit play during pending null/stale/error seeks, confirmed scrub resume, acquired-owner replacement, multiple rapid begins with pending owners, queue shortening between halt and load, overlapping quality/scrub owners in both release orders, explicit play waiting for all owners, explicit pause/stop denial, source replacement, interruption before resolve/install, completion, removal, recovery, loop, and shuffle. No interruption test uses fixed delays or polling.
