# Scrub Audio Sync Design

Date: 2026-07-27  
Status: approved for planning  
Scope: full-screen player, mini player, lyric tap seek

## Problem

Dragging the progress bar can make lyrics and the official progress clock lead the audible audio.

Root cause:

1. UI uses local preview values while dragging.
2. On release, `just_audio` seek returns after the engine media clock moves.
3. `PositionNotifier` immediately consumes:
   - `positionDiscontinuityStream`
   - `positionStream`
   - 100ms polling of `player.position`
4. iOS can report the new media position before audible output has resumed at that position.

Previous fixes removed optimistic UI jumps and delayed resume by 500ms, but they did not gate the global display clock against premature native position updates.

## Goal

- While the finger is down: audio pauses; progress bar and lyrics may preview the finger position.
- On release: pause completes, seek completes, wait 500ms, then resume if the user was playing.
- Lyrics and the official progress clock must not advance to the target until audible playback has resumed at the seeked position.
- One scrub transaction owns pause, seek, resume, and clock unfreeze.
- Lyric tap uses the same transaction path so there is only one clock.

## Non-Goals

- Changing lock-screen auto-next behavior.
- Changing quality resolution, queue management, or source selection.
- Measuring true hardware output latency beyond native player readiness signals.
- Redesigning the player UI layout.

## Chosen Approach

**Player-owned scrub gate** in `LxAudioHandler`, with display position published only after the gate allows it.

Rejected alternatives:

- Provider-only interception: easier, but pause/seek/resume remain split across UI, provider, and handler; other call sites can bypass the gate.
- Larger fixed delays: network and buffering vary; too short still leads, too long feels laggy.

## Architecture

### Components

1. `LxAudioHandler`
   - Owns scrub transaction state.
   - Serializes pause → seek → optional 500ms delay → play.
   - Publishes confirmed display position.

2. `PositionNotifier`
   - Becomes a consumer of confirmed display position only.
   - Stops independently listening to discontinuity / raw position polling as the source of truth.
   - Lyrics and progress UI continue reading `playerPositionProvider`.

3. Full-screen player / mini player
   - Keep local `_seeking` / `_seekValue` for finger preview only.
   - Call `beginScrub()` on drag start.
   - Call `finishScrub(target, resumeAfter: wasPlaying)` on release.
   - Do not call raw pause/seek/play themselves during scrub.

4. Lyric tap
   - Uses the same finish path as scrub release so it cannot create a second clock.

### Scrub Transaction

Each scrub has a monotonic id.

States:

- `idle`
- `previewing` — finger down, audio paused or pause requested, display clock frozen
- `seeking` — release received, waiting for native seek confirmation
- `resuming` — optional 500ms wait + play requested
- `armed` — waiting for first post-play confirmed position near target
- `idle` again after unfreeze

Rules:

1. `beginScrub(id)`
   - Capture whether playback should resume later.
   - Freeze display clock at the last confirmed position.
   - Pause without clearing “user still wants to listen” intent.
   - Store the pause future so release can await it.

2. While `previewing`
   - UI may update local preview values.
   - Global lyrics/official progress stay frozen.
   - Incoming native position updates are ignored for display publication.

3. `finishScrub(id, target, resumeAfter)`
   - Ignore stale ids.
   - Await the begin-scrub pause future.
   - Seek to clamped target.
   - Wait until native seek reports a position near target, or seek fails.
   - If `resumeAfter`:
     - wait 500ms
     - call play
     - remain frozen until first confirmed post-play position is near target
     - then unfreeze and publish that position
   - If not `resumeAfter`:
     - after seek confirmation, publish the seeked position once and remain paused

4. Concurrent scrub
   - A newer `beginScrub` invalidates older ids.
   - Late futures from older transactions no-op.

### Display Clock Contract

- Official display position is the only input to:
  - progress bar when not finger-dragging
  - time labels when not finger-dragging
  - lyric current line index
- During preview, UI may locally override rendering with finger position.
- Local preview must never write into the official display clock.
- After release and before unfreeze, UI follows the frozen official clock, not the finger value and not raw native position.

### Error / Cancel Behavior

- If seek is skipped because the player is still loading/idle: keep freeze, show no false jump, leave audio paused if resume was intended until a later successful play path.
- If user starts another scrub during finish: cancel previous finish effects via id check.
- If user manually pauses/plays outside scrub while a transaction is active: bump generation / invalidate scrub id and re-sync from handler playing state.

## Data Flow

```text
Finger down
  UI local preview = finger
  Handler beginScrub
    pauseInternal(clearIntent:false)
    freeze official clock

Finger move
  UI local preview only
  Lyrics/official progress frozen

Finger up
  UI clear local preview ownership
  Handler finishScrub
    await pause
    seek(target)
    wait seek confirmation
    if wasPlaying:
      delay 500ms
      play()
      wait first confirmed playing position near target
      unfreeze official clock = that position
    else:
      unfreeze official clock = seeked position once
```

## Testing

Structural / unit coverage:

1. Progress widgets no longer call raw pause/seek during scrub; they call begin/finish scrub APIs.
2. `PositionNotifier` no longer treats raw discontinuity/polling as authoritative during a freeze.
3. Scrub finish order is pause → seek → 500ms → play.
4. Stale scrub ids cannot unfreeze after a newer scrub starts.
5. Lyric tap uses the shared finish path.

Manual verification on device:

1. Drag far while playing: audio stays silent; preview follows finger; official clock does not race ahead of audio after release.
2. Release while originally playing: audio resumes after 500ms; lyrics/time start with audible audio.
3. Drag while paused: remains paused; after release official position shows seek target without auto-play.
4. Rapid successive drags do not leave lyrics stuck or jumping backward from old futures.

## Implementation Boundaries

Touch these files:

- `lib/core/audio/audio_handler.dart`
- `lib/features/player/presentation/player_provider.dart`
- `lib/features/player/presentation/player_screen.dart`
- `lib/features/player/presentation/widgets/mini_player.dart`
- `lib/features/lyric/presentation/lyric_view.dart` only if lyric tap still bypasses the shared path
- related tests under `test/core/audio/`

Do not broaden into playlist, source, quality, or lock-screen auto-next refactors.
