# iOS Lossless Local Cache Playback

## Problem

Commit `2033247` reliably played FLAC through the existing
`just_audio`/AVPlayer stack by downloading each candidate completely, detecting
its format from file bytes, and installing a local `file://` source. Commit
`336d3f7` added remote streaming when cache acquisition fails. Remote FLAC and
Hi-Res CDN URLs are not consistently consumable by AVPlayer and frequently fail
with AVFoundation error `-11800`.

## Design

Keep the existing player, cache lease, TTL, LRU, and generation ownership
architecture. Change quality resolution so that lossless candidates (`hires`,
`flac24bit`, and `flac`) are playable only after successful local cache
acquisition. If a lossless candidate cannot be cached, continue through the
existing lower-quality candidate chain instead of returning its remote URL.

Lossy candidates (`320k`, `192k`, and `128k`) retain validated remote streaming
as a final fallback when local caching fails. This preserves the availability
benefit introduced by `336d3f7` without exposing AVPlayer to problematic remote
lossless URLs.

The resolver must preserve the user's requested quality in metadata while
recording the quality actually selected. A lower cached candidate is preferred
over a higher remote lossless candidate. Existing cancellation rules remain in
force: stale generations release leases and cannot publish or install sources.

## Error Handling

If all lossless candidates fail to cache, resolution continues at `320k`. If a
lossy candidate resolves but cannot cache, it may stream remotely. If no
candidate produces either a cached source or an allowed lossy stream, resolution
returns null and the existing queue fallback handles the failure.

## Tests

- A cached FLAC candidate returns `CachedPlayback` with a `file://` URI.
- A FLAC cache failure never returns `StreamingPlayback` for the FLAC URL.
- A FLAC cache failure continues to `320k` and returns its cached result.
- If the `320k` cache also fails, its validated remote URL may be streamed.
- Hi-Res and 24-bit FLAC follow the same local-only rule.
- Cancellation during a candidate attempt prevents later candidates and releases
  any late lease.
- Existing cache lease and audio handler suites remain green.

## Non-Goals

- No FLAC-to-ALAC conversion.
- No new decoder or second audio player.
- No changes to downloads explicitly requested by the user.
- No changes to Android playback behavior beyond sharing the corrected resolver
  semantics.
