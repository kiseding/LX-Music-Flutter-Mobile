# Persistence Task 2 Report

Status: completed

Scope:
- Updated only `CloudApiClient` and its focused domain tests.
- Used the `SecureTokenStore` and `LegacyTokenMigrator` introduced by commit `7818490`.
- Added injected `Dio`, secure-token-store, raw preferences, and narrow
  session-preferences seams.
- Kept cloud base URL and non-secret metadata in SharedPreferences.

TDD evidence:
- Initial RED run: `flutter test test/features/cloud/domain/cloud_api_client_test.dart` failed because the cloud client lacked the secure-store constructor seam and `CloudVerification` API.
- RED verification: `flutter test test/features/cloud/domain/cloud_api_client_test.dart`
  failed because `CloudSessionPreferences` and the `sessionPreferences` seam
  did not exist.
- GREEN verification: `flutter test test/features/cloud/domain test/features/cloud/presentation`
  passed with 28 tests.
- Static verification: `flutter analyze lib/features/cloud/domain/cloud_api_client.dart test/features/cloud/domain/cloud_api_client_test.dart`
  completed with no diagnostics.

Covered behaviors:
- Legacy cloud-token migration during load, with plaintext removal only after verified migration.
- Transactional login, registration, and verification persistence snapshots
  the secure token and session metadata. Post-write metadata failures restore
  the token (or delete a newly written token), restore metadata best effort,
  and synchronize in-memory state with durable storage.
- Verified secure read/write persistence after login, registration, and valid session verification.
- `clearSession` restores the secure token and retained session when metadata
  cleanup fails. If secure restoration fails, it clears memory and reports an
  actionable cleanup error.
- HTTP 401 maps to `unauthorized`; outages, timeouts, malformed responses, and secure persistence failures map to `unavailable`.
- No token/base pair maps to `noSession`.
- Secure-delete failure preserves the in-memory session.

## Critical/Important Review Follow-up

- Login and registration capture a session revision before their network request.
  The serialized persistence operation accepts that revision and exits before any
  secure-token or metadata write when it is stale. A post-write revision check
  compensates the durable snapshot before returning if a mutation races during
  persistence.
- `load()` snapshots the session revision and drops its completed secure-read or
  migration snapshot when a later login, registration, logout, or base-URL
  mutation has taken ownership of the session.
- Stale cleanup branches now require secure credential restoration to succeed.
  When restoration fails after deletion, memory is reloaded from durable state
  and cleanup throws an actionable error instead of returning success.
- Added controlled real-`CloudApiClient`/Dio regressions for delayed login plus
  logout, delayed login plus base-URL mutation, out-of-order login/register,
  stale cleanup with failed restore, and delayed load followed by login.

## Follow-up Verification

- RED: all five new controlled domain regressions failed against the prior
  implementation: three stale responses persisted credentials, stale cleanup
  returned success after failed restoration, and delayed load overwrote login.
- GREEN: `flutter test test/features/cloud/domain/cloud_api_client_test.dart`
  passed 27 tests.
- Combined cloud domain/provider verification passed 35 tests.
- Targeted cloud analysis completed without diagnostics.

Known integration concern:
- Device or iOS CI coverage is still required to exercise actual Keychain
  deletion and restoration failures; the controlled secure-store tests verify
  the client-side durable-state contract on Flutter/Linux.
