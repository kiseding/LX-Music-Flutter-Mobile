# Lock-Screen Skip Audio Keepalive

## Problem

Lock-screen next/previous commands may require a complete lossless download
before the target source can be installed. Keeping the old track playing only
protects the iOS background audio session until that track reaches its natural
end. If it ends first, the real player stops, iOS may suspend the Dart isolate,
and the pending target source never installs.

## Design

For public next and previous commands, replace the old source immediately with
a long `SilenceAudioSource` and keep the real player playing while target
resolution proceeds. Publish the target metadata, buffering state, and zero
position as today. When the target local or allowed streaming source is ready,
replace the placeholder through the existing source-command coordinator.

The placeholder belongs to the same source request token as the target. It is a
temporary native installation, not an authoritative target commit. A newer
source request, stop, pause, interruption, or disposal retains authority under
the existing coordinator and generation rules. A stale target may never replace
a newer source.

Only next and previous navigation use this keepalive. Direct selection, quality
reload, pause, stop, and automatic completion retain their current behavior.

## User Intent

The placeholder plays only while effective playback intent is true. If the user
pauses during resolution, the placeholder pauses and the target remains paused
after installation. A later explicit play resumes whichever source is currently
authoritative.

## Failure Handling

If target resolution or installation fails, the placeholder must not become a
permanent logical track. Existing error reporting and queue fallback choose the
next candidate. Stop and disposal remove the placeholder through the normal
coordinator lifecycle.

## Tests

- Next installs and plays a silence placeholder before a gated resolver starts.
- The old track may complete during resolution without leaving the native player
  stopped.
- A resolved target replaces the placeholder and remains playing.
- Explicit pause during resolution prevents target auto-resume.
- A newer navigation request prevents the older target from installing.
- Previous follows the same keepalive behavior.
- Existing audio, interruption, and source ownership suites remain green.
