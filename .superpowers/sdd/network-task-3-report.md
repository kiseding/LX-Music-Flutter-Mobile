# Network Task 3 Report

## Status

Implemented the single quality-resolution coordinator with strict RED/GREEN TDD.

## Implementation

- `MusicSourceService.resolvePlayableUrl` now owns the complete quality chain.
  Each quality is attempted once through either enabled custom sources or the
  documented built-in fallback path.
- Custom sources retain priority. Built-in playback resolution is used only
  when no custom source is enabled and only for supported built-in platforms.
- Every result reports the original requested quality and the actual quality.
  A source result below the current candidate remains provisional while lower
  candidates are attempted, and is returned only after preferred candidates
  fail.
- Resolver seams inject per-quality custom and built-in behavior. Tests assert
  call order and count through behavior rather than production source text.
- Cancellation is checked before and after each quality attempt and propagates
  as Dio cancellation, preventing further fallback attempts.
- The main audio URL resolver calls the unified coordinator once, then retains
  the existing local-cache and audio coordinator behavior.
- Downloads call the unified coordinator once for an initial fresh link. They
  re-resolve once only after `401`, `403`, `404`, `410`, or `416`; other HTTP
  and transport failures do not start another resolution or quality loop.
- Custom-source sandbox and audio coordinator code were not modified.

## TDD Evidence

- Initial resolver RED failed because the unified API and injectable seams did
  not exist.
- Download retry RED failed because the injectable fresh-link retry coordinator
  did not exist.
- An additional RED test caught premature acceptance of an intermediate
  downgrade (`128k` returned for a `320k` attempt); the coordinator now
  continues through the remaining quality candidates.
- Cancellation, source priority, built-in fallback, actual/requested quality,
  exact quality attempts, initial download resolution, expired-link retry, and
  non-expired failure behavior all have direct behavioral coverage.

## Verification

- Focused network/download/audio suite: 264 passed.
- Full `flutter test`: 398 passed.
- Targeted analysis: no issues.
- `git diff --check`: clean.

## Concerns

- Expired-link recovery is intentionally bounded to one fresh-link retry per
  download attempt to avoid unbounded re-resolution. A second expired response
  fails the task with its HTTP status.

## Review Fixes

- Custom quality resolution now evaluates every enabled source at each
  candidate quality. Below-candidate results remain provisional while later
  sources can provide an honest candidate-or-better result.
- Provisional results are compared by actual quality rank across sources and
  candidates. Higher actual quality replaces lower quality; ties retain the
  earlier source. Every returned result keeps the original preferred quality as
  `requestedQuality`.
- Download cancellation now throws the Dio `cancelError` before and after every
  resolve/download boundary. Pre-cancelled resolution and cancellation between
  an expired response and re-resolution cannot become `null`; task cancellation
  preserves an existing pause or maps active work to paused instead of failed.
- Built-in coordinator resolution now uses the opt-in exact API only. Legacy
  `getMusicUrl` behavior remains available to external callers, while platforms
  that do not implement exact attempts are excluded from coordinator fallback.
- QQ exact attempts use only `F000`, `M800`, or `M500`/`C400` candidates for
  their matching quality identity. Unsupported `192k` is skipped, and server
  responses with a mismatched filename prefix are rejected.
- Kuwo exact attempts collapse lossless aliases to one `flac` adapter key and
  all MP3 labels to one `mp3` key. Multiple endpoint mechanisms and RID forms
  remain available within that one attempt; returned URLs conservatively
  correct actual quality.
- NetEase exact attempts issue one bitrate request per distinct quality key and
  use response `br` metadata to report actual quality when available.
- Behavioral tests verify multi-source ordering, progressive provisional
  upgrades, tie priority, cross-candidate ranking, cancellation races, task
  status mapping, pure exact mappings, response identity, and real adapter-key
  invocation counts.

## Review Verification

- Focused network/music-source/download/audio suite: 292 passed.
- Full `flutter test`: 420 passed.
- Targeted analysis: no issues.
- `git diff --check`: clean.
