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
