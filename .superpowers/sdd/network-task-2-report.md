# Network Task 2 Report

## Status

Implemented the compatibility-first custom-source HTTPS request sandbox.

- Requires absolute HTTPS URLs without credentials.
- Resolves and validates every DNS result for every request and redirect.
- Rejects non-public, private, loopback, link-local, multicast, unspecified,
  documentation, benchmark, reserved, IPv4-mapped, and unsupported IPv6
  destinations.
- Rejects mixed public/private DNS answer sets.
- Sanitizes sensitive, proxy, forwarding, host, content-length, and hop-by-hop
  request headers.
- Disables automatic redirects, validates each `Location`, and limits redirects
  to five.
- Bounds DNS, transport, response-read time, and response bytes.
- Cancels and closes active requests safely during source cancellation, reload,
  or engine disposal.
- Injects the resolver and transport for deterministic tests.
- Pins each connection to a validated numeric address with
  `HttpClient.connectionFactory`; the original HTTPS URI remains visible to
  `HttpClient` for hostname certificate verification and TLS SNI.
- Preserves the LX callback response shape and aliases `rawData` to the decoded
  `responseRaw` buffer in JavaScript, avoiding a second Dart base64 copy.

## TDD Evidence

The policy test was run before production implementation and failed because
`source_request_policy.dart` and all requested policy types did not exist.
Additional DNS-timeout, stalled-body cancellation, and redirect-close tests
were also observed failing before their implementations.

## Verification

- Focused: `flutter test test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart test/features/custom_source/domain/custom_source_host_regression_test.dart`
  - Result: 22 passed.
- Full: `flutter test`
  - Result: 348 passed.
- Targeted analysis: `flutter analyze lib/core/network/source_request_policy.dart lib/features/custom_source/domain/custom_source_engine.dart test/core/network/source_request_policy_test.dart test/features/custom_source/domain/custom_source_engine_test.dart`
  - Result: no issues.
- Formatting: `dart format` on all four changed Dart files.
- Whitespace: `git diff --check`
  - Result: clean.

## Concerns

- The sandbox intentionally rejects HTTP sources, credential-bearing URLs,
  private/reserved destinations, sensitive script-provided headers, and proxy
  routing. Existing public HTTPS custom sources retain the callback API and
  body/form/query behavior, but sources relying on those unsafe behaviors will
  no longer work.
- The default maximum response size is 10 MiB and the redirect limit is five.
