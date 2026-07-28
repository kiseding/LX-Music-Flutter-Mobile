# Network Task 2 Report

## Status

Implemented the final Network Task 2 admission, response ownership, redirect
cleanup, pinned-transport testability, and delivery ownership race findings
using strict TDD.

## Resolutions

- `SourceRequestSandbox` now admits at most four requests by default before DNS
  starts. The injectable `maximumConcurrentRequests` limit fails excess work
  immediately with `too_many_requests`; permits span DNS, redirects, transport,
  body reads, and callback handoff.
- `SourceRequestResponse` owns an idempotent lease with explicit `pending`,
  `delivering`, and `released` states. Successful requests transfer their
  request permit and retained actual-byte accounting to that lease.
- `withSourceResponseLease` synchronously moves a pending lease to delivery
  ownership. Cancellation before that transition releases and skips delivery;
  cancellation after it marks the response cancelled but cannot release the
  permit or byte budget. Only delivery `finally` releases after processing and
  callback execution return or throw.
- Aggregate response accounting is incremental and checks capacity before each
  chunk append. Retained bytes remain charged after the sandbox returns and
  until callback serialization finishes. Cancellation or disposal releases a
  pending response, but cannot release one whose delivery has started.
- `CustomSourceEngine` wraps UTF-8/JSON/base64 conversion and
  `_executeJsCallback` in `withSourceResponseLease`; the cancellation entry stays
  registered until that work exits. Session invalidation suppresses a success
  or error callback but retains the lease until in-progress compute/callback
  work unwinds. The callback API, one Dart base64 encoding, and JavaScript
  `rawData = responseRaw` alias are unchanged.
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
exact-once redirect cleanup, each pinned-transport seam, cancellation before
delivery, cancellation during a deterministic async processing gate, callback
failure, and cancelled callback suppression.

## Verification

- Focused network/custom-source suite: 62 passed.
- Full `flutter test`: 388 passed.
- Targeted analysis: no issues.
- `git diff --check`: clean.

## Concerns

- Admission and byte-budget rejection are intentionally fail-fast rather than
  queued. Sources issuing more than four overlapping requests must retry later.
- Response consumers outside `CustomSourceEngine` must call `release()` or use
  `withSourceResponseLease`. Once delivery starts, direct release and
  cancellation intentionally cannot free ownership; delivery completion is the
  sole release path.
