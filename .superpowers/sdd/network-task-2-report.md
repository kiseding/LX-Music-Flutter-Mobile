# Network Task 2 Report

## Status

Implemented the Task 2 request sandbox and resolved all three Important and
both Minor review findings.

## Resolutions

- Redirects track origin and implement explicit 301, 302, 303, 307, and 308
  method/body semantics. Body-preserving redirects reject `FormData` and stream
  bodies with `redirect_body_not_replayable`.
- Cross-origin redirects retain only `Accept`, `Accept-Language`, and
  `User-Agent`. Caller custom headers such as `X-Api-Key` are never forwarded.
  Content-Type is regenerated only when a replayable body is retained.
- Redirect `Location` is accepted only as one field value. Multiple values fail
  with `ambiguous_redirect`; non-redirect statuses do not interpret Location.
- IPv4 and IPv6 use explicit special-purpose deny-prefix tables under a
  conservative globally-routable policy. Tests cover the first and last address
  of every denied prefix plus known public controls.
- Validation races cancellation, rechecks after every await, and checks
  immediately before transport invocation. Cancellation during DNS and
  pre-cancelled disposal paths make zero transport calls.
- The production pinned transport checks cancellation before constructing Dio
  and synchronously cancels its token before `dio.request` when necessary.
- Per-response byte limits are checked before appending a chunk. Each response
  body reserves its maximum allowance before stream subscription under a
  default 20 MiB aggregate budget and four-body concurrency cap; both are
  injectable and released in `finally`.
- DNS pinning, HTTPS hostname/SNI validation, callback compatibility, one Dart
  base64 encoding, and the JavaScript `rawData = responseRaw` alias remain.

## TDD Evidence

Each finding was reproduced by a failing focused test before its production
change. Red runs covered redirect status behavior and header leakage, one-shot
body replay, omitted IP ranges, DNS cancellation, aggregate reservation,
concurrency release, and ambiguous Location handling.

## Verification

- Focused: `flutter test test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart test/features/custom_source/domain/custom_source_host_regression_test.dart`
  - Result: 46 passed.
- Targeted analysis: `flutter analyze lib/core/network/source_request_policy.dart lib/features/custom_source/domain/custom_source_engine.dart test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart`
  - Result: no issues.
- Full suite: `flutter test`
  - Result: 372 passed.

## Concerns

- Sources relying on HTTP, private/special-purpose addresses, URL credentials,
  proxies, cross-origin custom headers, or replaying one-shot redirect bodies
  are intentionally rejected.
- The default per-response cap remains 10 MiB. With the default 20 MiB aggregate
  reservation, at most two maximum-sized bodies can read concurrently even
  though the separate response-body concurrency cap is four.
