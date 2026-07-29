# Persistence Task 2 Report

Status: completed

Scope:
- Updated only `CloudApiClient` and its focused domain tests.
- Used the `SecureTokenStore` and `LegacyTokenMigrator` introduced by commit `7818490`.
- Added injected `Dio`, secure-token-store, and preferences seams.
- Kept cloud base URL and non-secret metadata in SharedPreferences.

TDD evidence:
- Initial RED run: `flutter test test/features/cloud/domain/cloud_api_client_test.dart` failed because the cloud client lacked the secure-store constructor seam and `CloudVerification` API.
- GREEN verification: `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/core/network/outbound_url_test.dart` passed with 21 tests.

Covered behaviors:
- Legacy cloud-token migration during load, with plaintext removal only after verified migration.
- Transactional login and registration rollback when secure persistence fails.
- Verified secure read/write persistence after login, registration, and valid session verification.
- HTTP 401 maps to `unauthorized`; outages, timeouts, malformed responses, and secure persistence failures map to `unavailable`.
- No token/base pair maps to `noSession`.
- Secure-delete failure preserves the in-memory session.

Known integration concern:
- `lib/features/cloud/presentation/cloud_provider.dart` still assigns `await _api.verify()` to a `bool`. It is intentionally unchanged because Task 3 is the planned consumer migration and this task explicitly excludes it. Whole-app static analysis will fail until Task 3 is implemented.
