# Serialized Playback Command Coordinator Design

## Goal

Replace independent generation-gated `AudioPlayer` futures with one desired-state coordinator while preserving Audio Tasks 1-5 queue, completion, quality, scrub, seek, playback-state, single-source, and Darwin behavior.

## Ownership

`LxAudioHandler` remains authoritative for queue contents, logical index, media metadata, URL resolution, completion policy, and error messages. `PlaybackCommandCoordinator` owns desired native playback state and is the only component allowed to invoke `play`, `pause`, `stop`, `seek`, `setAudioSource`, `setLoopMode`, or `setShuffleModeEnabled`.

The coordinator synchronously records:

- the latest source request token, media id, queue index, position, and resolved source;
- the latest explicit play/pause intent revision;
- durable preserving-pause state used by scrub, quality reload, and source replacement until an owning preserving-resume command clears it;
- interruption depth, cycle revision, sticky `mayResume`, and non-resumable resume denial;
- becoming-noisy denial;
- desired loop and shuffle modes.

## Source Flow

Starting a selection records the authoritative source request before any await. Network URL resolution remains outside the coordinator. The resolver result is converted to the existing single `AudioSource` with precise Darwin options and committed with its request token. A stale result is rejected without mutating the player.

The coordinator serially installs an accepted source and reconciles afterward. A source spanning a complete resumable interruption starts after installation when user intent remains play. A non-resumable cycle records a denial at the current explicit-intent revision; the source remains paused until a newer explicit play advances that revision. Explicit play during an older paused selection therefore transfers fresh play authority to that still-authoritative source request.

## Mutation Drain

Every desired-state update increments a command revision and appends reconciliation to one future tail. A command queued behind an active mutation records desired state synchronously; source commit, confirmed seek, and preserving pause may additionally await application. Each reconciliation may apply all currently needed loop, shuffle, stop, source, seek, and playing transitions in that order. Awaited native mutations are strictly serialized.

`just_audio.play()` has a lifecycle future that normally completes only after a later pause, stop, or natural completion. Its invocation is ordered in the drain, but that lifecycle future is observed by command token rather than awaited by the drain. Before coordinator-owned pause or stop, the active token records why the lifecycle will end. Natural completion is recognized from `ProcessingState.completed`. Preserving-pause completion remains paused until `resumePreservingIntent`; stop and natural completion do not reconcile/replay the current source. Unknown current-token completion reconciles latest desired state. Stale completion or error cannot publish, pause, stop, or change failure state for a newer token.

A seek revision ends in exactly one applied or failed state. A thrown native seek reports `seek`, consumes that revision, and allows the same reconciliation to continue toward current pause/source/play state. Only a newer explicit seek revision retries native seek.

After each native mutation, unknown/pause lifecycle completion, and error, reconciliation targets the newest desired state. Stop and natural-completion lifecycle endings are terminal notifications and deliberately do not reconcile current-source playback. Publication is delegated to one handler callback and occurs only after the coordinator has re-read current desired revision.

## Interruptions And Noisy

The first interruption begin opens a cycle, snapshots the coordinator intent revision, and nested begins increase depth. Any nested `end(false)` makes the cycle non-resumable until final consumption. Active depth blocks effective desired playing without clearing explicit user intent. A fully resumable final end removes the block and reconciles a newer explicit play even if handler begin ownership snapshots differ. Without newer explicit play, automatic resume still requires the handler's old interruption-owned source identity. Explicit pause, stop, noisy, or any `mayResume: false` end remains denied.

Becoming noisy synchronously records desired pause, clears interruption ownership, and queues reconciliation. If explicit play occurs before or during the older queued pause, post-mutation reconciliation observes the newer intent and restores only the current authoritative source.

## Integration

Scrub pause/seek/resume, quality pause/reload, completion auto-next, current-item removal, stale-source recovery, idle recovery, stop, repeat, and shuffle all update coordinator desired state. `expectedUserIntentGeneration` remains on load transactions so an older source install cannot clear a newer user pause when releasing preserving pause. `PlaybackStartProvenance` and handler source/media generations remain around scrub restoration, resolver results, completion claims, and stale-source recovery because those validate handler-owned asynchronous source identity. They do not override a newer coordinator explicit-play revision at interruption end. Independent native mutation tails are removed.

## Verification

Deterministic completer-gated tests cover native serialization, stale same-source play completion, source replacement, interruption before resolve/install, resumable and non-resumable cycles, explicit authority transfer, nested sticky denial, noisy versus newer play, scrub, quality, completion, removal, recovery, loop, and shuffle. No interruption test uses fixed delays or polling.
