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

Known integration concern:
- `lib/features/cloud/presentation/cloud_provider.dart` still assigns `await _api.verify()` to a `bool`. It is intentionally unchanged because Task 3 is the planned consumer migration and this task explicitly excludes it. Whole-app static analysis will fail until Task 3 is implemented.
