# Serialized Playback Command Coordinator Design

## Goal

Replace independent generation-gated `AudioPlayer` futures with one desired-state coordinator while preserving Audio Tasks 1-5 queue, completion, quality, scrub, seek, playback-state, single-source, and Darwin behavior.

## Ownership

`LxAudioHandler` remains authoritative for queue contents, logical index, media metadata, URL resolution, completion policy, and error messages. `PlaybackCommandCoordinator` owns desired native playback state and is the only component allowed to invoke `play`, `pause`, `stop`, `seek`, `setAudioSource`, `setLoopMode`, or `setShuffleModeEnabled`.

The coordinator synchronously records:

- the latest source request token, media id, queue index, position, and resolved source;
- the latest explicit play/pause intent revision;
- interruption depth, cycle revision, sticky `mayResume`, and non-resumable resume denial;
- becoming-noisy denial;
- desired loop and shuffle modes.

## Source Flow

Starting a selection records the authoritative source request before any await. Network URL resolution remains outside the coordinator. The resolver result is converted to the existing single `AudioSource` with precise Darwin options and committed with its request token. A stale result is rejected without mutating the player.

The coordinator serially installs an accepted source and reconciles afterward. A source spanning a complete resumable interruption starts after installation when user intent remains play. A non-resumable cycle records a denial at the current explicit-intent revision; the source remains paused until a newer explicit play advances that revision. Explicit play during an older paused selection therefore transfers fresh play authority to that still-authoritative source request.

## Mutation Drain

Every desired-state update increments a command revision and schedules one drain. The drain compares desired and applied source, position, playing state, loop mode, and shuffle mode, then executes at most one required native mutation before reconciling again. Awaited mutations are strictly serialized.

`just_audio.play()` has a lifecycle future that normally completes only after a later pause, stop, or completion. Its invocation is ordered in the drain, but that lifecycle future is observed by command token rather than awaited by the drain. A completion or error only schedules reconciliation; it never directly pauses, stops, or publishes state. This permits the serialized pause/stop needed to complete the play lifecycle and makes stale same-source and newer-source completions side-effect free.

After every mutation, completion, or error, reconciliation targets the newest desired state. Publication is delegated to one handler callback and occurs only after the coordinator has re-read current desired revision.

## Interruptions And Noisy

The first interruption begin opens a cycle and nested begins increase depth. Any nested `end(false)` makes the cycle non-resumable until final consumption. Active depth blocks effective desired playing without clearing explicit user intent. A fully resumable final end removes the block and reconciles either the installed source or a source installed later. A non-resumable final end denies automatic resume until newer explicit play.

Becoming noisy synchronously records desired pause, clears interruption ownership, and queues reconciliation. If explicit play occurs before or during the older queued pause, post-mutation reconciliation observes the newer intent and restores only the current authoritative source.

## Integration

Scrub pause/seek/resume, quality pause/reload, completion auto-next, current-item removal, stale-source recovery, idle recovery, stop, repeat, and shuffle all update coordinator desired state. Existing queue/source generations remain only where they validate asynchronous resolver and queue identity; interruption/start block generations and independent mutation tails are removed once their tests are covered by coordinator tokens.

## Verification

Deterministic completer-gated tests cover native serialization, stale same-source play completion, source replacement, interruption before resolve/install, resumable and non-resumable cycles, explicit authority transfer, nested sticky denial, noisy versus newer play, scrub, quality, completion, removal, recovery, loop, and shuffle. No interruption test uses fixed delays or polling.
