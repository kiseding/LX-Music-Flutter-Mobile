# Persistence Task 4 Report

## Status

Implemented independent secure migration for `sync_token`. `SyncService` now
uses `SecureTokenStore` and `LegacyTokenMigrator` directly, with injectable
secure-store and preferences seams for deterministic tests. It never reads,
writes, or copies `cloud_api_token`.

## Changes

- Removed the sync service dependency on `StorageService` plaintext storage.
- `loadSavedToken()` migrates only `sync_token` through `LegacyTokenMigrator`.
  The migrator writes and reads the secure value before removing plaintext;
  verification failures leave plaintext in place for a later retry.
- Login writes and verifies the secure sync token before assigning it to the
  in-memory session. A verification failure leaves no usable in-memory token.
- Added `forgetSavedToken()` for explicit account forgetting. It deletes the
  secure `sync_token` before removing its legacy plaintext copy, so a secure
  deletion failure preserves the plaintext retry path. `disconnect()` remains
  in-memory only.

## TDD Evidence

- RED: `flutter test test/features/sync/domain/sync_service_test.dart` failed
  before implementation because `SyncService` had no `secureStore` or
  `preferences` constructor seams and still used `StorageService`.
- GREEN: focused tests pass for independent sync migration, mismatch retention
  and retry, secure-only login persistence, rejected unverified login tokens,
  scoped explicit forgetting, and failed secure deletion preserving the legacy
  retry credential.

## Verification

- `flutter test test/features/sync/domain/sync_service_test.dart`: PASS, 7
  tests.
- `flutter test test/core/storage/secure_token_store_test.dart test/features/sync/domain/sync_service_test.dart`:
  PASS, 12 tests.
- `flutter analyze lib/core/storage/secure_token_store.dart lib/features/sync/domain/sync_service.dart test/core/storage/secure_token_store_test.dart test/features/sync/domain/sync_service_test.dart`:
  PASS, no issues.
- `git diff --check`: PASS.

## Concerns

- Tests use a controlled secure store. Actual iOS Keychain behavior, including
  device-specific deletion failures, still requires physical-device or iOS CI
  coverage.

## Cloud Base URL Persistence Follow-up

### Status

Implemented revision-owned durable cloud base URL persistence. A superseded
`setBaseUrl` call resolves as a no-op and cannot leave an older endpoint in
preferences after a newer base URL mutation.

### Changes

- Added a dedicated base-URL revision and serialized base-URL persistence tail.
  Base updates still advance the session revision, preserving existing stale
  login, registration, verification, and migration invalidation semantics.
- A queued write checks its captured base-URL revision before preferences
  acquisition, before the durable write, and before publishing completion. A
  newer base URL is therefore the final durable and in-memory value.
- `load()` preserves a client-owned base update while a load snapshot races the
  queued durable commit; it still applies credential state only when its session
  snapshot remains current.
- A failed current write restores the previous in-memory URL, retains the prior
  durable URL, sets an actionable configuration error, and rethrows the storage
  failure. A stale failed write neither rolls back nor reports over a newer URL.

### TDD Evidence

- RED: `flutter test test/features/cloud/domain/cloud_api_client_test.dart`
  failed because `CloudApiClient` did not expose an injectable base-URL
  preferences seam. The regression suite uses completer-controlled preferences
  rather than timing delays.
- GREEN: deterministic cases cover overlapping old/new URLs, a blocked base
  update racing login, a blocked base update racing load, and current-write
  failure rollback with an actionable error. Existing HTTPS validation and
  credential/session safety tests remain in the same focused suite.

### Verification

- `flutter test test/features/cloud/domain/cloud_api_client_test.dart
  test/features/cloud/presentation/cloud_provider_test.dart`: PASS, 46 tests.
- `flutter analyze lib/features/cloud/domain/cloud_api_client.dart
  lib/features/cloud/presentation/cloud_provider.dart
  test/features/cloud/domain/cloud_api_client_test.dart
  test/features/cloud/presentation/cloud_provider_test.dart`: PASS, no issues.
- `git diff --check`: PASS.

### Concerns

- The controlled preferences seam proves ordering and failure behavior in Dart;
  platform-specific SharedPreferences interruption behavior still needs mobile
  integration coverage.
