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
