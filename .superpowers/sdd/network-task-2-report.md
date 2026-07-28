# Network Task 2 Report

## Status

Implemented the final Network Task 2 admission, response ownership, redirect
cleanup, and pinned-transport testability findings using strict TDD.

## Resolutions

- `SourceRequestSandbox` now admits at most four requests by default before DNS
  starts. The injectable `maximumConcurrentRequests` limit fails excess work
  immediately with `too_many_requests`; permits span DNS, redirects, transport,
  body reads, and callback handoff.
- `SourceRequestResponse` owns an idempotent release lease. Successful requests
  transfer their request permit and retained actual-byte accounting to that
  lease. Cancellation, timeout, transport errors, body errors, and callback
  failures release ownership on every path.
- Aggregate response accounting is incremental and checks capacity before each
  chunk append. Retained bytes remain charged after the sandbox returns and
  until callback serialization finishes or cancellation/disposal releases the
  response.
- `CustomSourceEngine` wraps UTF-8/JSON/base64 conversion and
  `_executeJsCallback` in `withSourceResponseLease`; the cancellation entry stays
  registered until that work exits. The callback API, one Dart base64 encoding,
  and JavaScript `rawData = responseRaw` alias are unchanged.
- Redirect setup now closes each response exactly once in `finally`, including
  malformed URI, ambiguous Location, redirect-limit, and one-shot FormData or
  stream replay failures. `SourceTransportResponse.close()` is idempotent.
- Production pinning moved into the testable `SourcePinnedTransport`. Injected
  Dio construction/execution/close and socket-start seams verify pre-cancel does
  not construct Dio, cancellation force-closes, proxies are rejected, and only
  validated numeric addresses are dialed.
- Dio still receives the original HTTPS URI. Host header generation, TLS SNI,
  and certificate hostname verification therefore remain bound to the original
  source hostname; no bad-certificate callback was introduced.

## TDD Evidence

Failing tests were observed before each implementation change for global
pre-DNS admission, lease transfer and idempotent release, actual-byte callback
retention, error/cancellation release, late transport response closure,
exact-once redirect cleanup, and each pinned-transport seam.

## Verification

- Focused network/custom-source suite: 59 passed.
- Full `flutter test`: 385 passed.
- Targeted analysis: no issues.
- `git diff --check`: clean.

## Concerns

- Admission and byte-budget rejection are intentionally fail-fast rather than
  queued. Sources issuing more than four overlapping requests must retry later.
- Response consumers outside `CustomSourceEngine` must call `release()` or use
  `withSourceResponseLease`; cancellation is a fallback release path, not a
  substitute for explicit ownership completion.
