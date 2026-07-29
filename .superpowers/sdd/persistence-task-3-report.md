# Persistence Task 3 Report

## Status

Implemented generation-guarded cloud session presentation state. Startup loading now occurs only through `CloudSessionNotifier.refresh()`, late async work cannot publish over newer commands, and session verification distinguishes an outage from an authoritative unauthorized response. The follow-up fix makes 401 cleanup token-conditional and serializes destructive credential mutations with login/register persistence.

## Commit

- Original implementation commit: `19eaf79`
- Original subject: `fix: generation guard cloud sessions`
- Author and committer: `kiseding <236300865+kiseding@users.noreply.github.com>`

## Changes

- Added `checking` to `CloudSessionState` alongside loaded, login, metadata, and error state.
- Removed the duplicate unawaited `CloudApiClient.load()` from `cloudApiProvider`; the notifier owns the single startup load.
- Added a monotonic generation guard to refresh, base URL updates, login, registration, and logout. Every state publication after an await requires ownership of the current generation.
- Mapped verification outcomes precisely: valid keeps the session, unavailable keeps an existing authenticated session with an actionable error, no-session publishes logged out without clearing credentials, and only unauthorized attempts credential clearing.
- Preserved the authenticated presentation state and reports `无法清除安全凭据` when 401 cleanup or explicit logout cannot delete the secure credential.
- Added controlled-client tests covering stale refresh against login, logout, and base URL changes; outage preservation; 401 clearing; and credential-clear failure.
- Captured the token verified by refresh and pass it as `expectedToken` for unauthorized cleanup. `CloudApiClient` skips conditional cleanup unless the persisted secure token still matches it.
- Serialized session persistence and cleanup in `CloudApiClient`, preventing a clear that has started from interleaving destructively with login or registration credential persistence.
- Added a deterministic regression test that blocks 401 cleanup, completes a newer login, releases cleanup, and asserts that the new logged-in state and token remain intact.
- Follow-up domain hardening now gives login/register responses a captured client
  session revision, so a delayed response cannot persist over logout, base URL,
  or a newer authentication command. `load()` also drops stale snapshots before
  assigning client state, keeping the provider generation contract backed by
  the durable client boundary.
- Conditional cleanup compensation now throws and reloads in-memory state from
  durable storage when a stale cleanup deleted a token but secure restoration
  fails; provider refresh already reports this as `无法清除安全凭据`.

## TDD Evidence

RED:

- `flutter test test/features/cloud/presentation/cloud_provider_test.dart` failed before implementation because `CloudSessionNotifier` had no `autoRefresh` seam and the prior provider still expected `verify()` to return `bool`.

GREEN:

- `flutter test test/features/cloud/presentation/cloud_provider_test.dart` passed all 6 focused presentation tests after the guarded state-machine implementation.
- The blocked-cleanup/new-login regression failed before the conditional clear implementation because the old cleanup set the replacement token to null; it passes after the fix.

## Verification

- `dart format --output=none --set-exit-if-changed lib/features/cloud/presentation/cloud_provider.dart test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS.
- `flutter test test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS: 8 tests after the follow-up regressions.
- `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS: 30 tests after conditional cleanup and mutation serialization.
- `flutter analyze lib/features/cloud/domain/cloud_api_client.dart lib/features/cloud/presentation/cloud_provider.dart test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS: no issues.
- `git diff --check`
  - PASS before the implementation commit.
- Review follow-up: `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS: 35 tests.
- Review follow-up: targeted cloud `flutter analyze`
  - PASS: no diagnostics.

## Concerns

- Device or iOS CI coverage is still required to exercise actual Keychain deletion failures; the controlled client verifies the presentation-state contract on Flutter/Linux.

## Important Review Follow-up

- `LegacyTokenMigrator` now accepts a client-owned revision predicate and runs
  every secure-storage and preferences write/removal through the cloud session
  mutation tail. A stale `load()` cannot migrate or remove plaintext after a
  newer login or base URL mutation; if its secure write completed just before
  ownership changed, it removes only the matching stale migrated token.
- `verify()` captures the token and session revision before its request. A valid
  response persists metadata only while that exact revision still owns the
  session, so delayed old responses cannot change a replacement token's user or
  role.
- Persistence rechecks revision ownership after every durable step. If a stale
  response credential cannot be compensated, the client deletes that stale
  credential where possible and throws `CloudSessionSafetyError`; the provider
  surfaces this actionable safety error even when its originating command is no
  longer the current presentation generation.
- Existing 401 token-conditional cleanup, outage preservation, and secure
  plaintext migration behavior remain covered by the focused cloud suite.

## Important Review TDD

- RED reproduced delayed legacy migration racing a newer login and a newer base
  URL, delayed verification overwriting replacement metadata, stale persistence
  after a competing base URL, and a stale safety failure hidden by provider
  generation suppression.
- GREEN coverage makes those races deterministic with paused secure-storage
  writes and delayed Dio responses.

## Important Review Verification

- `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart`
  - PASS: 40 tests.
- Targeted `flutter analyze` on cloud storage, domain, provider, and tests
  - PASS: no issues.
- `git diff --check`
  - PASS.
