# Persistence State Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve user data while moving secrets to iOS Keychain, playlists and recent history to atomic versioned files, playlist consumers to one revision stream, and asynchronous UI state to target-bound generations.

**Architecture:** `SecureTokenStore` is the only token persistence boundary and migrates each legacy plaintext key independently after write/read verification. `PlaylistRepository` owns strict versioned JSON decoding, atomic replacement, quarantine, and recovery; `PlaylistService` serializes commit-before-publish mutations and emits one authoritative revision. Cloud, lyric, search, history, and import notifiers use monotonically increasing generations so only the current target may publish, with transport cancellation where the owned API supports it.

**Tech Stack:** Flutter 3.x, Dart >=3.2, Riverpod 2.6.1, Dio 5.7.0, SharedPreferences 2.2.3, flutter_secure_storage 9.2.4, path_provider 2.1.4, flutter_test

**Test Fixture Rule:** Helpers shown in test snippets are private declarations in the same test file, not production APIs. `FakeSecureTokenStore` is a map-backed `SecureTokenStore` with configurable read/write/delete failures and an `operations` log; `preferences(Map<String, Object>)` calls `SharedPreferences.setMockInitialValues`, then returns `SharedPreferences.getInstance()`. Every `Controlled*` fake stores pending calls by exact target key in a `Completer`, exposes the named `complete`/`fail` method, and implements the consumed interface or typedef listed in that task. `song(String id)`, `lyrics(String text)`, `imported(String name)`, and playlist/snapshot fixtures return valid minimal domain objects with fixed UTC timestamps. Keep these declarations in the test that uses them so no hidden test-support dependency is introduced.

## Global Constraints

- The work is iOS-first; shared Dart code must continue to compile for other supported Flutter targets.
- Migrate existing cloud tokens without forcing users to sign in again.
- Preserve existing playlists and recent-play history through storage migration.
- Delete a plaintext token only after secure write/read verification; preserve it and retry on a later startup after any secure-storage failure.
- `cloud_api_token` and `sync_token` remain separate credentials; never copy one into the other service.
- Only an authoritative HTTP 401 signs a cloud user out; timeout, TLS, DNS, connection, HTTP 5xx, malformed responses, and secure-storage failures retain the last authenticated session and expose an actionable error.
- Playlist files use schema version `1`, strict decoding, temporary-file replacement, quarantine of corrupt current files, and recovery from validated current, recovery, or legacy data in that order.
- The protected system playlist IDs are exactly `favorites` and `recent`; both are restored when absent and neither can be deleted.
- A state-changing playlist mutation completes its durable write before changing the in-memory snapshot and emits exactly one revision; rejected, failed, and no-op operations emit none.
- Async results and errors publish only when both request generation and target identifier still match; cancellation itself does not publish an error.
- Do not modify `lib/core/audio/playback_cache_service.dart`, `test/core/audio/playback_cache_service_test.dart`, `docs/superpowers/plans/2026-07-29-playback-cache-transactions.md`, or `docs/superpowers/specs/2026-07-29-playback-cache-transactions-design.md`; they are owned by the active cache task.
- Do not weaken HTTPS validation or change the completed audio command architecture.

## File Structure

- Create `lib/core/storage/secure_token_store.dart`: secure token interface, Keychain implementation, and verified legacy migration.
- Modify `lib/features/cloud/domain/cloud_api_client.dart`: injected storage, typed verification outcome, and secure session persistence.
- Modify `lib/features/cloud/presentation/cloud_provider.dart`: cloud operation generations and outage-preserving session state.
- Modify `lib/features/sync/domain/sync_service.dart`: secure `sync_token` persistence and independent migration.
- Create `lib/features/playlist/data/playlist_repository.dart`: snapshot codec and repository contract.
- Create `lib/features/playlist/data/file_playlist_repository.dart`: atomic JSON file storage, migration, quarantine, and recovery.
- Modify `lib/features/playlist/domain/playlist_service.dart`: serialized async mutations, protected system lists, and revision publication.
- Modify playlist, sync, player, settings, and startup consumers to await service mutations and derive state from the revision stream.
- Modify lyric, search, search-history, and playlist-import state to use target-bound generations and cancellation.
- Add focused storage, provider, repository, service, and async race tests under matching `test/` paths.

---

### Task 1: Secure Token Store And Verified Legacy Migration

**Files:**
- Modify: `pubspec.yaml`
- Create: `lib/core/storage/secure_token_store.dart`
- Create: `test/core/storage/secure_token_store_test.dart`

**Interfaces:**
- Produces: `abstract interface class SecureTokenStore` with `Future<String?> read(String key)`, `Future<void> write(String key, String value)`, and `Future<void> delete(String key)`.
- Produces: `FlutterSecureTokenStore({FlutterSecureStorage? storage})` using iOS first-unlock, device-only Keychain accessibility.
- Produces: `LegacyTokenMigrator({required SecureTokenStore secureStore, required SharedPreferences preferences})` and `Future<String?> readAndMigrate(String key)`.
- Migration flags are `secure_token_migrated_v1_cloud_api_token` and `secure_token_migrated_v1_sync_token`.

- [ ] **Step 1: Add the secure-storage dependency and write failing migration tests**

Add `flutter_secure_storage: ^9.2.4` under storage dependencies. Test with in-memory fakes that record operation order:

```dart
test('verified migration writes and reads before deleting plaintext', () async {
  final secure = FakeSecureTokenStore();
  final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
  final migrator = LegacyTokenMigrator(
    secureStore: secure,
    preferences: prefs,
  );

  expect(await migrator.readAndMigrate('cloud_api_token'), 'cloud-secret');
  expect(secure.operations, [
    'read:cloud_api_token',
    'write:cloud_api_token:cloud-secret',
    'read:cloud_api_token',
  ]);
  expect(prefs.containsKey('cloud_api_token'), isFalse);
  expect(prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isTrue);
});

test('failed verification preserves plaintext and retries', () async {
  final secure = FakeSecureTokenStore(readAfterWrite: 'different');
  final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
  final migrator = LegacyTokenMigrator(secureStore: secure, preferences: prefs);

  expect(await migrator.readAndMigrate('cloud_api_token'), 'cloud-secret');
  expect(prefs.getString('cloud_api_token'), 'cloud-secret');
  expect(prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isNot(true));
});
```

- [ ] **Step 2: Run the tests to verify RED**

Run: `flutter test test/core/storage/secure_token_store_test.dart`

Expected: FAIL because `SecureTokenStore` and `LegacyTokenMigrator` do not exist.

- [ ] **Step 3: Implement the secure boundary and exact migration order**

```dart
abstract interface class SecureTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

final class FlutterSecureTokenStore implements SecureTokenStore {
  FlutterSecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _ios = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );
  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key, iOptions: _ios);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value, iOptions: _ios);
  @override
  Future<void> delete(String key) =>
      _storage.delete(key: key, iOptions: _ios);
}

final class LegacyTokenMigrator {
  LegacyTokenMigrator({required this.secureStore, required this.preferences});
  final SecureTokenStore secureStore;
  final SharedPreferences preferences;

  Future<String?> readAndMigrate(String key) async {
    final legacy = preferences.getString(key);
    try {
      final secure = await secureStore.read(key);
      if (secure != null && secure.isNotEmpty) {
        if (legacy == secure) {
          await preferences.setBool('secure_token_migrated_v1_$key', true);
          await preferences.remove(key);
        }
        return secure;
      }
      if (legacy == null || legacy.isEmpty) return null;
      await secureStore.write(key, legacy);
      if (await secureStore.read(key) != legacy) return legacy;
      await preferences.setBool('secure_token_migrated_v1_$key', true);
      await preferences.remove(key);
    } catch (_) {
      if (legacy != null && legacy.isNotEmpty) return legacy;
      rethrow;
    }
    return legacy;
  }
}
```

Add a retry test where the first attempt writes successfully but fails before SharedPreferences cleanup; the second call must observe `secure == legacy`, mark migration complete, and delete plaintext. If a pre-existing secure token differs from plaintext, the secure token is authoritative and the mismatched plaintext is retained for explicit diagnosis rather than overwritten or silently deleted.

- [ ] **Step 4: Run focused tests and dependency resolution**

Run: `flutter pub get && flutter test test/core/storage/secure_token_store_test.dart`

Expected: dependency resolution succeeds and all secure-token tests PASS.

- [ ] **Step 5: Commit the secure storage boundary**

```bash
git add pubspec.yaml pubspec.lock lib/core/storage/secure_token_store.dart test/core/storage/secure_token_store_test.dart
git commit -m "fix: migrate tokens to secure storage"
```

### Task 2: Cloud Client Verification Semantics

**Files:**
- Modify: `lib/features/cloud/domain/cloud_api_client.dart`
- Modify: `test/features/cloud/domain/cloud_api_client_test.dart`

**Interfaces:**
- Consumes: `SecureTokenStore` and `LegacyTokenMigrator` from Task 1.
- Produces: `enum CloudVerification { valid, unauthorized, unavailable, noSession }`.
- Produces: `CloudApiClient({Dio? dio, SecureTokenStore? secureStore, Future<SharedPreferences> Function()? preferences})`.
- Produces: `Future<CloudVerification> verify()`; `unauthorized` is returned only for HTTP 401 and `noSession` means no local token/base pair exists.

- [ ] **Step 1: Write failing secure persistence and verification tests**

```dart
test('login stores token securely and leaves no plaintext token', () async {
  SharedPreferences.setMockInitialValues({'cloud_api_base': 'https://cloud.example'});
  final secure = FakeSecureTokenStore();
  final client = CloudApiClient(dio: loginDio('new-token'), secureStore: secure);
  await client.load();

  await client.login('user', 'password');

  expect(await secure.read('cloud_api_token'), 'new-token');
  expect((await SharedPreferences.getInstance()).containsKey('cloud_api_token'), isFalse);
});

test('verify distinguishes 401 from an outage', () async {
  expect(await loadedClient(statusCode: 401).verify(), CloudVerification.unauthorized);
  expect(await loadedClient(statusCode: 503).verify(), CloudVerification.unavailable);
  expect(await loadedClient(error: DioExceptionType.connectionTimeout).verify(),
      CloudVerification.unavailable);
});
```

- [ ] **Step 2: Run the cloud client tests to verify RED**

Run: `flutter test test/features/cloud/domain/cloud_api_client_test.dart`

Expected: FAIL because constructor injection and `CloudVerification` are absent.

- [ ] **Step 3: Move token load, save, and clear behind secure storage**

Keep base URL, username, role, and migration flags in SharedPreferences. `load()` obtains preferences once, validates `cloud_api_base`, and reads `LegacyTokenMigrator.readAndMigrate('cloud_api_token')` into local variables; assign `_baseUrl`, `_token`, `_username`, and `_role` only after every storage read succeeds so a transient Keychain failure cannot erase the in-memory session. `_persistSession()` writes `_token` to secure storage, reads it back, throws `StateError('Secure token verification failed')` on mismatch, then persists non-secret metadata. `clearSession()` deletes the secure token and removes any still-present plaintext token before clearing metadata; if deletion fails, retain all in-memory session fields and rethrow.

Implement exact verification classification:

```dart
Future<CloudVerification> verify() async {
  if (!isLoggedIn) return CloudVerification.noSession;
  try {
    final response = await _dio.get(
      _url('/api/user/auth/verify'),
      options: _authOptions(),
    );
    final data = response.data;
    if (data is! Map || data['valid'] != true) {
      return CloudVerification.unavailable;
    }
    _role = data['role']?.toString() ?? _role;
    _username = data['username']?.toString() ?? _username;
    await _persistSession();
    return CloudVerification.valid;
  } on DioException catch (error) {
    return error.response?.statusCode == 401
        ? CloudVerification.unauthorized
        : CloudVerification.unavailable;
  } catch (_) {
    return CloudVerification.unavailable;
  }
}
```

Make `login` and `register` transactional around persistence: capture the previous token/username/role, assign the response session, call `_persistSession`, and restore the previous in-memory values before rethrowing if secure persistence fails. This prevents a failed Keychain write from making `isLoggedIn` true for a token that will disappear at restart.

- [ ] **Step 4: Run cloud and URL regression tests**

Run: `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/core/network/outbound_url_test.dart`

Expected: PASS, including existing HTTPS base URL behavior.

- [ ] **Step 5: Commit cloud client persistence**

```bash
git add lib/features/cloud/domain/cloud_api_client.dart test/features/cloud/domain/cloud_api_client_test.dart
git commit -m "fix: distinguish cloud auth expiry from outages"
```

### Task 3: Cloud Session Generations

**Files:**
- Modify: `lib/features/cloud/presentation/cloud_provider.dart`
- Create: `test/features/cloud/presentation/cloud_provider_test.dart`

**Interfaces:**
- Consumes: `CloudApiClient.verify() -> Future<CloudVerification>` from Task 2.
- Produces: `CloudSessionState` with `bool loaded`, `bool loggedIn`, `bool checking`, metadata, and nullable `String? error`.
- Produces: generation-guarded `refresh`, `setBaseUrl`, `login`, `register`, and `logout`; every command increments `_generation` before its first await.
- Test seam: `ControlledCloudApiClient extends CloudApiClient`, overrides only methods/getters consumed by `CloudSessionNotifier`, uses separate completers for load/login/clear and verify, and tracks `clearCount`.

- [ ] **Step 1: Write failing race and outage tests with a controlled fake client**

```dart
test('late refresh cannot overwrite a newer login', () async {
  final api = ControlledCloudApiClient();
  final notifier = CloudSessionNotifier(api, autoRefresh: false);
  final refresh = notifier.refresh();
  final login = notifier.login('new-user', 'password');
  api.completeLogin(username: 'new-user');
  expect(await login, isTrue);
  api.completeVerify(CloudVerification.unauthorized);
  await refresh;
  expect(notifier.state.loggedIn, isTrue);
  expect(notifier.state.username, 'new-user');
});

test('outage preserves authenticated session but 401 clears it', () async {
  final api = ControlledCloudApiClient(initiallyLoggedIn: true);
  final notifier = CloudSessionNotifier(api, autoRefresh: false);
  api.nextVerification = CloudVerification.unavailable;
  await notifier.refresh();
  expect(notifier.state.loggedIn, isTrue);
  expect(notifier.state.error, isNotNull);
  api.nextVerification = CloudVerification.unauthorized;
  await notifier.refresh();
  expect(notifier.state.loggedIn, isFalse);
  expect(api.clearCount, 1);
});
```

- [ ] **Step 2: Run the provider tests to verify RED**

Run: `flutter test test/features/cloud/presentation/cloud_provider_test.dart`

Expected: FAIL because cloud session operations have no generations and clear every failed verification.

- [ ] **Step 3: Guard every state publication and destructive clear**

```dart
class CloudSessionNotifier extends StateNotifier<CloudSessionState> {
  CloudSessionNotifier(this._api, {bool autoRefresh = true})
      : super(const CloudSessionState()) {
    if (autoRefresh) refresh();
  }
  final CloudApiClient _api;
  int _generation = 0;

  bool _current(int generation) => generation == _generation;

  Future<void> refresh() async {
    final generation = ++_generation;
    state = state.copyWith(checking: true, error: null);
    try {
      await _api.load();
    } catch (error) {
      if (!_current(generation)) return;
      state = state.copyWith(
        loaded: true,
        checking: false,
        error: '无法读取安全凭据: $error',
      );
      return;
    }
    if (!_current(generation)) return;
    final result = _api.isLoggedIn
        ? await _api.verify()
        : CloudVerification.noSession;
    if (!_current(generation)) return;
    if (result == CloudVerification.unauthorized && _api.isLoggedIn) {
      await _api.clearSession();
      if (!_current(generation)) return;
    }
    state = CloudSessionState(
      loaded: true,
      checking: false,
      loggedIn: result == CloudVerification.valid ||
          result == CloudVerification.unavailable && _api.isLoggedIn,
      baseUrl: _api.baseUrl,
      username: _api.username,
      role: _api.role,
      error: result == CloudVerification.unavailable
          ? '服务器暂时不可用，已保留登录状态'
          : _api.configurationError,
    );
  }
}
```

Apply the same `final generation = ++_generation` and `_current(generation)` checks around every await in `setBaseUrl`, `login`, `register`, and `logout`. Map `noSession` to logged out without calling `clearSession`; map `unauthorized` to logged out only after the generation-guarded clear. If authoritative-401 cleanup or explicit logout cannot delete Keychain state, retain the authenticated state and publish `无法清除安全凭据` so the app never claims logout while a restart would restore the token. A failed login/register reports its error but does not clear an already established session. Remove the fire-and-forget `client.load()` from `cloudApiProvider`; `CloudSessionNotifier.refresh()` is the single startup load.

- [ ] **Step 4: Run cloud domain and presentation tests**

Run: `flutter test test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart`

Expected: PASS; the controlled stale completion never changes newer state.

- [ ] **Step 5: Commit cloud generations**

```bash
git add lib/features/cloud/presentation/cloud_provider.dart test/features/cloud/presentation/cloud_provider_test.dart
git commit -m "fix: generation guard cloud sessions"
```

### Task 4: Independent Secure Migration For Legacy Sync Token

**Files:**
- Modify: `lib/features/sync/domain/sync_service.dart`
- Modify: `test/features/sync/domain/sync_service_test.dart`

**Interfaces:**
- Consumes: `SecureTokenStore` and `LegacyTokenMigrator` from Task 1.
- Produces: `SyncService({Dio? dio, SecureTokenStore? secureStore, Future<SharedPreferences> Function()? preferences})`.
- Preserves: `Future<String?> loadSavedToken()` but changes its backing store to secure key `sync_token`.

- [ ] **Step 1: Write failing independent migration tests**

```dart
test('sync token migrates to its own secure key', () async {
  SharedPreferences.setMockInitialValues({
    'sync_token': 'sync-secret',
    'cloud_api_token': 'cloud-secret',
  });
  final secure = FakeSecureTokenStore();
  final service = SyncService(dio: Dio(), secureStore: secure);
  addTearDown(service.dispose);

  expect(await service.loadSavedToken(), 'sync-secret');
  expect(await secure.read('sync_token'), 'sync-secret');
  expect(await secure.read('cloud_api_token'), isNull);
  final prefs = await SharedPreferences.getInstance();
  expect(prefs.containsKey('sync_token'), isFalse);
  expect(prefs.getString('cloud_api_token'), 'cloud-secret');
});
```

Also cover secure write/read mismatch preserving `sync_token`, and successful login writing only the secure key.

- [ ] **Step 2: Run sync tests to verify RED**

Run: `flutter test test/features/sync/domain/sync_service_test.dart`

Expected: FAIL because `SyncService` still stores `sync_token` through `StorageService`.

- [ ] **Step 3: Replace sync plaintext persistence**

Remove the `StorageService` import. `_saveToken` writes and reads `sync_token` through `SecureTokenStore`, throwing on mismatch. `loadSavedToken` creates a `LegacyTokenMigrator` and calls `readAndMigrate('sync_token')`. `disconnect()` remains an in-memory disconnect and does not erase the saved credential; add a separate `Future<void> forgetSavedToken()` that deletes secure and legacy copies for an explicit account-forget action.

- [ ] **Step 4: Run secure and sync tests**

Run: `flutter test test/core/storage/secure_token_store_test.dart test/features/sync/domain/sync_service_test.dart`

Expected: PASS; each token migrates independently.

- [ ] **Step 5: Commit sync token migration**

```bash
git add lib/features/sync/domain/sync_service.dart test/features/sync/domain/sync_service_test.dart
git commit -m "fix: secure legacy sync token"
```

### Task 5: Versioned Playlist Snapshot Codec

**Files:**
- Create: `lib/features/playlist/data/playlist_repository.dart`
- Create: `test/features/playlist/data/playlist_repository_test.dart`

**Interfaces:**
- Produces: immutable `PlaylistSnapshot({required int schemaVersion, required List<Playlist> playlists})` with `schemaVersion == 1`.
- Produces: `PlaylistSnapshotCodec.encode(PlaylistSnapshot) -> String` and `decode(String) -> PlaylistSnapshot`.
- Produces: `abstract interface class PlaylistRepository` with `Future<PlaylistSnapshot> load()` and `Future<void> save(PlaylistSnapshot snapshot)`.

- [ ] **Step 1: Write strict round-trip and rejection tests**

```dart
test('version 1 snapshot round trips every MusicItem field', () {
  final original = PlaylistSnapshot(schemaVersion: 1, playlists: [playlistFixture()]);
  final decoded = const PlaylistSnapshotCodec().decode(
    const PlaylistSnapshotCodec().encode(original),
  );
  expect(decoded.schemaVersion, 1);
  expect(decoded.playlists.single.songs.single.toJson(),
      original.playlists.single.songs.single.toJson());
});

test('decoder rejects unknown version, duplicate ids, and malformed dates', () {
  const codec = PlaylistSnapshotCodec();
  expect(() => codec.decode('{"schemaVersion":2,"playlists":[]}'),
      throwsFormatException);
  expect(() => codec.decode(jsonEncode({
    'schemaVersion': 1,
    'playlists': [playlistJson('same'), playlistJson('same')],
  })), throwsFormatException);
  expect(() => codec.decode(jsonEncode({
    'schemaVersion': 1,
    'playlists': [playlistJson('one')..['createdAt'] = 'not-an-int'],
  })), throwsFormatException);
});
```

In this test file, `playlistJson(String id)` returns the exact object shape shown in Step 3 with empty `songs` and fixed integer dates; `playlistFixture()` uses the same fields plus one `MusicItem` containing every optional field and nested `meta`.

- [ ] **Step 2: Run codec tests to verify RED**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart`

Expected: FAIL because repository and codec types do not exist.

- [ ] **Step 3: Implement the exact version 1 envelope and strict decode**

```json
{
  "schemaVersion": 1,
  "playlists": [
    {
      "id": "favorites",
      "name": "我喜欢",
      "description": "收藏的歌曲",
      "coverUrl": null,
      "songs": [],
      "createdAt": 1785283200000,
      "updatedAt": 1785283200000
    }
  ]
}
```

Require an object root, integer schema version `1`, list `playlists`, unique non-empty string playlist IDs and names, integer millisecond dates, and a list of object songs. Decode each song through `MusicItem.fromJson` only after checking `id`, `name`, `singer`, `source`, and integer `duration`; copy decoded lists with `List.unmodifiable`. Throw `FormatException` with the failing field path.

- [ ] **Step 4: Run codec and model tests**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart test/features/player/domain/music_item_test.dart test/features/playlist/domain/playlist_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit the snapshot contract**

```bash
git add lib/features/playlist/data/playlist_repository.dart test/features/playlist/data/playlist_repository_test.dart
git commit -m "feat: define versioned playlist snapshots"
```

### Task 6: Atomic Playlist File Migration And Recovery

**Files:**
- Create: `lib/features/playlist/data/file_playlist_repository.dart`
- Create: `test/features/playlist/data/file_playlist_repository_test.dart`

**Interfaces:**
- Consumes: `PlaylistRepository`, `PlaylistSnapshot`, and `PlaylistSnapshotCodec` from Task 5.
- Produces: `FilePlaylistRepository({required Future<Directory> Function() directory, required SharedPreferences preferences, PlaylistSnapshotCodec codec = const PlaylistSnapshotCodec(), DateTime Function()? clock})`.
- Uses exact filenames `playlists.v1.json`, `playlists.v1.tmp`, `playlists.v1.previous`, and `playlists.v1.recovery.json`; corrupt files become `playlists.v1.corrupt.<milliseconds>.json`.
- Legacy source is the SharedPreferences string key `playlists` written by `StorageService.setJsonList`.
- Test seam: `repositoryFor` supplies the temporary directory, mock preferences, and fixed UTC clock; `writeValidRecovery` writes `codec.encode(snapshot)` to the exact recovery filename.

- [ ] **Step 1: Write failing migration, atomicity, and recovery tests with a temporary directory**

```dart
test('legacy migration keeps fallback until new file loads successfully', () async {
  final prefs = await preferences({'playlists': jsonEncode(legacyPlaylists)});
  final repository = repositoryFor(tempDir, prefs);

  final migrated = await repository.load();
  expect(migrated.playlists, isNotEmpty);
  expect(prefs.containsKey('playlists'), isTrue);
  expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(), isTrue);

  final reloaded = await repository.load();
  expect(reloaded.playlists, isNotEmpty);
  expect(prefs.containsKey('playlists'), isFalse);
  expect(File('${tempDir.path}/playlists.v1.recovery.json').existsSync(), isFalse);
});

test('corrupt current file is quarantined and restored from recovery', () async {
  await writeValidRecovery(tempDir, snapshotFixture());
  await File('${tempDir.path}/playlists.v1.json').writeAsString('{broken');
  final loaded = await repositoryFor(tempDir, await preferences({})).load();
  expect(loaded.playlists.single.id, 'favorites');
  expect(tempDir.listSync().where((e) => e.path.contains('.corrupt.')), hasLength(1));
  expect(() => const PlaylistSnapshotCodec().decode(
      File('${tempDir.path}/playlists.v1.json').readAsStringSync()), returnsNormally);
});
```

Also test interrupted save with `playlists.v1.previous`, malformed legacy data remaining untouched, and a failed temporary write leaving the current file readable.

- [ ] **Step 2: Run repository tests to verify RED**

Run: `flutter test test/features/playlist/data/file_playlist_repository_test.dart`

Expected: FAIL because `FilePlaylistRepository` does not exist.

- [ ] **Step 3: Implement ordered load and atomic save**

Load order:

1. If `playlists.v1.json` decodes, return it. If a migration recovery marker exists, this is the first successful new-format reload: remove legacy `playlists` and `playlists.v1.recovery.json` only after decode succeeds.
2. If current exists but fails decode, rename it to the timestamped corrupt name.
3. If `playlists.v1.previous` decodes, atomically restore it to current and return it.
4. If `playlists.v1.recovery.json` decodes, atomically restore it to current and return it without deleting recovery or legacy during that same recovery load.
5. If legacy `playlists` decodes under the version 1 playlist rules, write the same validated envelope to recovery and current, then return it while retaining legacy and recovery.
6. If no valid source exists, return `PlaylistSnapshot(schemaVersion: 1, playlists: const [])`; never erase malformed legacy data.

Atomic save algorithm:

```dart
bool _decodes(String source) {
  try {
    codec.decode(source);
    return true;
  } on FormatException {
    return false;
  }
}

Future<void> save(PlaylistSnapshot snapshot) async {
  final current = File('${(await directory()).path}/playlists.v1.json');
  final temporary = File('${current.parent.path}/playlists.v1.tmp');
  final previous = File('${current.parent.path}/playlists.v1.previous');
  final encoded = codec.encode(snapshot);
  codec.decode(encoded);
  await temporary.writeAsString(encoded, flush: true);
  codec.decode(await temporary.readAsString());
  if (await previous.exists()) await previous.delete();
  if (await current.exists()) {
    await current.copy(previous.path);
    await previous.open(mode: FileMode.append).then((file) async {
      await file.flush();
      await file.close();
    });
  }
  try {
    // On Darwin/POSIX this replaces the existing file in one rename.
    await temporary.rename(current.path);
    codec.decode(await current.readAsString());
    if (await previous.exists()) await previous.delete();
  } catch (_) {
    if ((!await current.exists() ||
            !_decodes(await current.readAsString())) &&
        await previous.exists()) {
      await previous.copy(current.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
```

- [ ] **Step 4: Run file repository and codec tests**

Run: `flutter test test/features/playlist/data/playlist_repository_test.dart test/features/playlist/data/file_playlist_repository_test.dart`

Expected: PASS; failure injection proves current data survives interrupted replacement.

- [ ] **Step 5: Commit atomic playlist storage**

```bash
git add lib/features/playlist/data/file_playlist_repository.dart test/features/playlist/data/file_playlist_repository_test.dart
git commit -m "fix: atomically migrate playlist storage"
```

### Task 7: Serialized Playlist Mutations, System Lists, And Revision Stream

**Files:**
- Modify: `lib/features/playlist/domain/playlist_service.dart`
- Modify: `test/features/playlist/domain/playlist_service_test.dart`

**Interfaces:**
- Consumes: `PlaylistRepository` from Task 5.
- Produces: `PlaylistService({required PlaylistRepository repository, DateTime Function()? clock, String Function()? createId})`.
- Produces: `int get revision`, `Stream<int> get revisions`, and async mutation methods.
- Changes signatures to `Future<Playlist> createPlaylist({required String name, String? description, List<MusicItem> songs = const [], String? id})`, `Future<Playlist> updatePlaylist(...)`, `Future<bool> deletePlaylist(String id)`, `Future<bool> addSongToPlaylist(...)`, `Future<bool> removeSongFromPlaylist(...)`, `Future<bool> sortSongsInPlaylist(...)`, `Future<bool> sortSongsByName(...)`, `Future<bool> sortSongsByArtist(...)`, `Future<bool> sortSongsByDuration(...)`, `Future<bool> addToRecent(MusicItem song)`, `Future<int> addAllSongsToFavorites(String playlistId)`, and `Future<void> replaceAll(List<Playlist> playlists)`.

- [ ] **Step 1: Replace synchronous tests with failing durable mutation tests**

```dart
test('successful mutation writes before publishing exactly one revision', () async {
  final repository = ControlledPlaylistRepository(initial: systemSnapshot());
  final service = PlaylistService(repository: repository, createId: () => 'new');
  await service.init();
  final revisions = <int>[];
  final subscription = service.revisions.listen(revisions.add);

  final future = service.createPlaylist(name: 'Road trip');
  expect(service.getPlaylist('new'), isNull);
  expect(revisions, isEmpty);
  repository.completeSave();
  await future;
  expect(service.getPlaylist('new'), isNotNull);
  expect(revisions, [1]);
  await subscription.cancel();
});

test('failed, protected, and no-op mutations emit no revision', () async {
  final service = await initializedService();
  final before = service.revision;
  await expectLater(service.deletePlaylist('favorites'), throwsStateError);
  expect(await service.addSongToPlaylist('favorites', song('a')), isTrue);
  expect(await service.addSongToPlaylist('favorites', song('a')), isFalse);
  expect(service.revision, before + 1);
});
```

Also test concurrent mutations preserve invocation order, missing `favorites`/`recent` are restored and durably saved on init, `recent` is capped at 100 in newest-first order, and `replaceAll` repairs system lists before one save/revision.

- [ ] **Step 2: Run service tests to verify RED**

Run: `flutter test test/features/playlist/domain/playlist_service_test.dart`

Expected: FAIL because mutations are synchronous, fire-and-forget, and have no repository/revision contract.

- [ ] **Step 3: Implement serialized commit-before-publish mutation handling**

Use one tail future so all writes retain call order:

```dart
Future<void> _tail = Future.value();
final _revisionController = StreamController<int>.broadcast();
int _revision = 0;

Stream<int> get revisions => _revisionController.stream;

Future<T> _mutate<T>(FutureOr<({List<Playlist> next, T result, bool changed})>
    Function(List<Playlist> current) operation) {
  final completer = Completer<T>();
  _tail = _tail.then((_) async {
    try {
      final mutation = await operation(List<Playlist>.unmodifiable(_playlists));
      if (!mutation.changed) {
        completer.complete(mutation.result);
        return;
      }
      final repaired = _withSystemPlaylists(mutation.next);
      await _repository.save(PlaylistSnapshot(
        schemaVersion: 1,
        playlists: repaired,
      ));
      _playlists
        ..clear()
        ..addAll(repaired);
      _revisionController.add(++_revision);
      completer.complete(mutation.result);
    } catch (error, stackTrace) {
      completer.completeError(error, stackTrace);
    }
  });
  return completer.future;
}
```

Construct deterministic system playlists with the injected clock. Reject deletion of `favorites` and `recent` before entering `_mutate`. Add `dispose()` to close `_revisionController`. Every method computes a new immutable list, uses one `_mutate` call, and never calls repository save directly. `ControlledPlaylistRepository` returns its constructor snapshot from `load`, captures each save, and completes it only when `completeSave()` is called; `MemoryPlaylistRepository` is its immediate-save variant. `init()` repairs missing system lists through one durable save and emits one revision only when repair was required; loading an already valid snapshot emits none.

- [ ] **Step 4: Run playlist service and import model tests**

Run: `flutter test test/features/playlist/domain/playlist_service_test.dart test/features/playlist/domain/playlist_test.dart test/features/playlist/domain/playlist_import_service_test.dart`

Expected: PASS.

- [ ] **Step 5: Commit authoritative playlist mutations**

```bash
git add lib/features/playlist/domain/playlist_service.dart test/features/playlist/domain/playlist_service_test.dart
git commit -m "fix: serialize playlist revisions"
```

### Task 8: Repository Wiring And Revision-Driven Consumers

**Files:**
- Modify: `lib/features/playlist/presentation/playlist_provider.dart`
- Modify: `lib/features/playlist/presentation/playlist_screen.dart`
- Modify: `lib/features/playlist/presentation/playlist_detail_screen.dart`
- Modify: `lib/features/player/presentation/player_provider.dart`
- Modify: `lib/features/sync/presentation/sync_screen.dart`
- Modify: `lib/features/settings/presentation/settings_screen.dart`
- Modify: `lib/main.dart`
- Create: `test/features/playlist/presentation/playlist_provider_test.dart`
- Modify: `test/features/playlist/presentation/playlist_detail_favorites_test.dart`

**Interfaces:**
- Consumes: `FilePlaylistRepository` from Task 6 and async `PlaylistService` from Task 7.
- Produces: `playlistRevisionProvider = StreamProvider<int>` as the only playlist invalidation source.
- Produces: `playlistRepositoryProvider` for test overrides and settings backup/restore.
- Removes: `playlistVersionProvider` and every manual `.state++` call.

- [ ] **Step 1: Write failing provider and source-guard tests**

```dart
test('playlist providers rebuild from the service revision stream', () async {
  final repository = MemoryPlaylistRepository(systemSnapshot());
  final container = ProviderContainer(overrides: [
    playlistRepositoryProvider.overrideWithValue(repository),
  ]);
  addTearDown(container.dispose);
  final service = container.read(playlistServiceProvider);
  await service.init();
  expect(container.read(playlistsProvider), hasLength(2));
  await service.createPlaylist(name: 'One', id: 'one');
  await Future<void>.delayed(Duration.zero);
  expect(container.read(playlistsProvider).map((p) => p.id), contains('one'));
});

test('production playlist consumers contain no manual version increments', () {
  for (final path in playlistConsumerPaths) {
    final source = File(path).readAsStringSync();
    expect(source, isNot(contains('playlistVersionProvider')), reason: path);
  }
});
```

- [ ] **Step 2: Run provider and presentation tests to verify RED**

Run: `flutter test test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart`

Expected: FAIL because consumers depend on manual version increments.

- [ ] **Step 3: Wire repository and convert all callers to awaited mutations**

```dart
final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  throw StateError('playlistRepositoryProvider must be overridden at startup');
});

final playlistServiceProvider = Provider<PlaylistService>((ref) {
  final service = PlaylistService(repository: ref.watch(playlistRepositoryProvider));
  ref.onDispose(service.dispose);
  return service;
});

final playlistRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(playlistServiceProvider).revisions;
});

final playlistsProvider = Provider<List<Playlist>>((ref) {
  ref.watch(playlistRevisionProvider);
  return ref.watch(playlistServiceProvider).playlists;
});
```

In `main.dart`, obtain SharedPreferences and the application documents directory, construct `FilePlaylistRepository`, override `playlistRepositoryProvider`, then initialize `playlistServiceProvider` before `runApp`. Keep that repository override beside the existing container creation and do not change playback-cache initialization:

```dart
final preferences = await SharedPreferences.getInstance();
final documents = await getApplicationDocumentsDirectory();
final repository = FilePlaylistRepository(
  directory: () async => documents,
  preferences: preferences,
);
final container = ProviderContainer(overrides: [
  playlistRepositoryProvider.overrideWithValue(repository),
]);
await container.read(playlistServiceProvider).init();
```

Convert every UI callback touching playlists to `async` and await exactly one service operation. Import uses `createPlaylist(..., songs: imported.songs)` instead of create-then-update. Bulk cloud sync builds a complete `List<Playlist>` and calls one `replaceAll`; backup reads `playlistService.playlists` and serializes with the version 1 codec, while restore decodes the backup and calls `replaceAll`. The recent recorder uses `unawaited(service.addToRecent(music))`; serialization in Task 7 preserves ordering and the service stream refreshes consumers.

- [ ] **Step 4: Run all playlist, sync, settings, and widget tests**

Run: `flutter test test/features/playlist test/features/sync test/features/settings test/widget_test.dart`

Expected: PASS; source guard finds no `playlistVersionProvider`.

- [ ] **Step 5: Commit repository integration**

```bash
git add lib/features/playlist/presentation/playlist_provider.dart lib/features/playlist/presentation/playlist_screen.dart lib/features/playlist/presentation/playlist_detail_screen.dart lib/features/player/presentation/player_provider.dart lib/features/sync/presentation/sync_screen.dart lib/features/settings/presentation/settings_screen.dart lib/main.dart test/features/playlist/presentation/playlist_provider_test.dart test/features/playlist/presentation/playlist_detail_favorites_test.dart
git commit -m "refactor: derive playlists from one revision stream"
```

### Task 9: Target-Bound Lyric Requests And Real Retry

**Files:**
- Modify: `lib/features/lyric/domain/lyric_service.dart`
- Modify: `lib/features/lyric/presentation/lyric_provider.dart`
- Modify: `lib/features/lyric/presentation/lyric_view.dart`
- Create: `test/features/lyric/presentation/lyric_provider_test.dart`

**Interfaces:**
- Produces: `LyricService({MusicSourceService? musicSourceService, Dio? dio})` and `fetchLyric(MusicItem music, {CancelToken? cancelToken})`.
- Produces: `typedef LyricLoader = Future<Lyrics> Function(MusicItem music, {CancelToken? cancelToken})` for deterministic notifier tests.
- Produces: `LyricState({required String? targetId, required Lyrics lyrics, required bool isLoading, String? error})`.
- Produces: `LyricNotifier.loadLyric(MusicItem)`, `retry()`, and `cancel()` guarded by `_generation` plus target ID.
- Produces: `LyricNotifier.forTest(LyricLoader loader)`; the normal constructor adapts `ref.read(lyricServiceProvider).fetchLyric` to the same typedef.

- [ ] **Step 1: Write failing stale success, stale error, cancellation, and retry tests**

```dart
test('stale lyric success and error cannot replace the current song', () async {
  final loader = ControlledLyricLoader();
  final notifier = LyricNotifier.forTest(loader.call);
  final first = notifier.loadLyric(song('a'));
  final second = notifier.loadLyric(song('b'));
  loader.complete('b', lyrics('B'));
  await second;
  loader.fail('a', Exception('old failure'));
  await first;
  expect(notifier.state.targetId, 'b');
  expect(notifier.state.lyrics, lyrics('B'));
  expect(notifier.state.error, isNull);
});

test('retry starts a new generation for the same target', () async {
  final loader = ControlledLyricLoader();
  final notifier = LyricNotifier.forTest(loader.call);
  await notifier.loadLyric(song('a'));
  final before = loader.calls;
  await notifier.retry();
  expect(loader.calls, before + 1);
});
```

- [ ] **Step 2: Run lyric provider tests to verify RED**

Run: `flutter test test/features/lyric/presentation/lyric_provider_test.dart`

Expected: FAIL because lyric state has neither target nor generation and retry invalidates the provider.

- [ ] **Step 3: Implement generation checks and direct-Dio cancellation**

```dart
Future<void> loadLyric(MusicItem music) async {
  final generation = ++_generation;
  _target = music;
  _cancelToken?.cancel('superseded');
  final token = _cancelToken = CancelToken();
  state = LyricState(targetId: music.id, lyrics: Lyrics.empty(), isLoading: true);
  try {
    final lyrics = await _loader(music, cancelToken: token);
    if (generation != _generation || _target?.id != music.id) return;
    state = LyricState(targetId: music.id, lyrics: lyrics, isLoading: false);
  } on DioException catch (error) {
    if (CancelToken.isCancel(error) || generation != _generation ||
        _target?.id != music.id) return;
    state = LyricState(targetId: music.id, lyrics: Lyrics.empty(),
        isLoading: false, error: error.toString());
  } catch (error) {
    if (generation != _generation || _target?.id != music.id) return;
    state = LyricState(targetId: music.id, lyrics: Lyrics.empty(),
        isLoading: false, error: error.toString());
  }
}
```

Pass `cancelToken` to direct lyrics URL Dio calls. Music-source fallback remains logically cancelled because its current abstraction has no cancellation token; its completion is discarded by generation and target. `retry()` calls `loadLyric(_target!)`. Replace `ref.invalidate(currentLyricProvider)` in the view with `ref.read(currentLyricProvider.notifier).retry()`. In `currentLineIndexProvider`, use `final lyrics = ref.watch(currentLyricProvider).lyrics`; in `lyric_view.dart`, replace each watched `Lyrics` value with `final lyricState = ref.watch(currentLyricProvider)` and read `lyricState.lyrics`, `lyricState.isLoading`, and `lyricState.error` explicitly.

- [ ] **Step 4: Run lyric parser and provider tests**

Run: `flutter test test/features/lyric/data/lyric_parser_test.dart test/features/lyric/presentation/lyric_provider_test.dart`

Expected: PASS; cancellation does not surface as an error.

- [ ] **Step 5: Commit lyric request ownership**

```bash
git add lib/features/lyric/domain/lyric_service.dart lib/features/lyric/presentation/lyric_provider.dart lib/features/lyric/presentation/lyric_view.dart test/features/lyric/presentation/lyric_provider_test.dart
git commit -m "fix: generation guard lyric requests"
```

### Task 10: Search And Search-History Generations

**Files:**
- Modify: `lib/features/search/presentation/search_provider.dart`
- Create: `test/features/search/presentation/search_provider_test.dart`
- Create: `test/features/search/presentation/search_history_provider_test.dart`

**Interfaces:**
- Produces: `SearchTarget({required String query, required String sourceId})` with value equality.
- Produces: `typedef SearchLoader = Future<List<MusicItem>> Function(String query, {required String sourceId, required int page})` for notifier isolation tests.
- Adds `SearchState.target` and generation-guarded `search`, load-more, and `reset` behavior.
- Produces: `SearchHistoryNotifier({Future<StorageService> Function()? storage})` whose startup load and mutations share one generation.
- Produces: `SearchNotifier.forTest(SearchLoader loader, {required String Function() source})`; the normal constructor adapts `MusicSourceService.search` to `SearchLoader`.

- [ ] **Step 1: Write failing search target and history startup-race tests**

```dart
test('older query cannot publish success or error over newer target', () async {
  final service = ControlledMusicSourceService();
  final notifier = SearchNotifier.forTest(service.search, source: () => 'tx');
  final old = notifier.search('old');
  final current = notifier.search('new');
  service.complete('new', [song('new')]);
  await current;
  service.fail('old', Exception('stale'));
  await old;
  expect(notifier.state.target, const SearchTarget(query: 'new', sourceId: 'tx'));
  expect(notifier.state.items.single.id, 'new');
  expect(notifier.state.error, isNull);
});

test('late history load cannot overwrite an immediate add', () async {
  final storage = Completer<StorageService>();
  final notifier = SearchHistoryNotifier(storage: () => storage.future);
  final add = notifier.add('new');
  storage.complete(fakeStorageWithHistory(['old']));
  await add;
  expect(notifier.state, ['new']);
});
```

Also test source changes create a new target, load-more appends only to the same target/generation, `reset()` invalidates in-flight work, duplicate history entries move to front, and delayed remove/clear persistence cannot republish old state.

- [ ] **Step 2: Run search tests to verify RED**

Run: `flutter test test/features/search/presentation/search_provider_test.dart test/features/search/presentation/search_history_provider_test.dart`

Expected: FAIL because search suppresses newer requests while loading and history startup load is unguarded.

- [ ] **Step 3: Implement logical cancellation and target checks**

For every new base search, increment `_generation`, capture `SearchTarget(query: query, sourceId: sourceId)`, and allow it to supersede an existing load. Before publishing success or error require both `generation == _generation` and `state.target == target`. Load-more captures the current target and generation; discard it if either changes. `reset()` increments `_generation` before clearing state.

For history, increment `_generation` synchronously at the start of `add`, `remove`, and `clear`; `_load` captures constructor generation and publishes only if still current. Serialize preference writes through `_writeTail` so persisted order matches invocation order:

```dart
Future<void> _writeTail = Future.value();
int _generation = 0;

Future<void> add(String keyword) async {
  final normalized = keyword.trim();
  if (normalized.isEmpty) return;
  ++_generation;
  final updated = [normalized, ...state.where((item) => item != normalized)];
  state = List.unmodifiable(updated.take(20));
  final snapshot = state;
  _writeTail = _writeTail.then((_) async {
    final value = await _storage();
    await value.setStringList('search_history', snapshot);
  });
  await _writeTail;
}
```

- [ ] **Step 4: Run search state and screen tests**

Run: `flutter test test/features/search/presentation/search_provider_test.dart test/features/search/presentation/search_history_provider_test.dart test/widget_test.dart`

Expected: PASS; stale errors remain invisible.

- [ ] **Step 5: Commit search and history generations**

```bash
git add lib/features/search/presentation/search_provider.dart test/features/search/presentation/search_provider_test.dart test/features/search/presentation/search_history_provider_test.dart
git commit -m "fix: generation guard search state"
```

### Task 11: Cancellable Playlist Import State And Final Verification

**Files:**
- Modify: `lib/features/playlist/domain/playlist_import_service.dart`
- Create: `lib/features/playlist/presentation/playlist_import_provider.dart`
- Modify: `lib/features/playlist/presentation/playlist_screen.dart`
- Modify: `test/features/playlist/domain/playlist_import_service_test.dart`
- Create: `test/features/playlist/presentation/playlist_import_provider_test.dart`

**Interfaces:**
- Produces: `PlaylistImportService({Dio? dio})` and `import({required String input, String platformHint = 'tx', CancelToken? cancelToken})`.
- Produces: `typedef PlaylistImporter = Future<ImportedPlaylist> Function({required String input, required String platformHint, CancelToken? cancelToken})`.
- Produces: `PlaylistImportTarget({required String input, required String platform})` and `PlaylistImportState` with target, loading, result, and error.
- Produces: auto-disposed `playlistImportProvider` notifier with `start`, `cancel`, and generation checks.

- [ ] **Step 1: Write failing transport and notifier race tests**

```dart
test('import forwards cancellation to owned Dio requests', () async {
  final dio = recordingDio();
  final service = PlaylistImportService(dio: dio);
  final token = CancelToken()..cancel('dialog closed');
  await expectLater(
    service.import(input: '12345', platformHint: 'tx', cancelToken: token),
    throwsA(isA<DioException>().having(CancelToken.isCancel, 'cancelled', isTrue)),
  );
});

test('cancelled or stale import cannot publish into a newer dialog request', () async {
  final importer = ControlledPlaylistImporter();
  final notifier = PlaylistImportNotifier(importer.call);
  final first = notifier.start(input: '1', platform: 'tx');
  final second = notifier.start(input: '2', platform: 'wy');
  importer.complete('2', imported('current'));
  await second;
  importer.fail('1', Exception('stale'));
  await first;
  expect(notifier.state.target,
      const PlaylistImportTarget(input: '2', platform: 'wy'));
  expect(notifier.state.result?.name, 'current');
  expect(notifier.state.error, isNull);
});
```

- [ ] **Step 2: Run import tests to verify RED**

Run: `flutter test test/features/playlist/domain/playlist_import_service_test.dart test/features/playlist/presentation/playlist_import_provider_test.dart`

Expected: FAIL because the service owns a non-injectable Dio and the dialog owns unguarded local async state.

- [ ] **Step 3: Add cancellation and replace dialog-local request ownership**

Pass `cancelToken` to every `_dio.get`; rethrow `DioException` cancellation in the Netease fallback instead of swallowing it:

```dart
} on DioException catch (error) {
  if (CancelToken.isCancel(error)) rethrow;
}
```

`PlaylistImportNotifier.start` trims input, increments `_generation`, cancels the previous token, records the exact target, and publishes result/error only if generation and target still match. `cancel()` increments generation, cancels the token, and clears loading without an error. Register `cancel` with provider disposal. The dialog watches this provider, calls `start`, and calls `cancel` when dismissed; after confirmation it awaits one `PlaylistService.createPlaylist(name: ..., description: ..., songs: ...)` call.

- [ ] **Step 4: Run focused and full Linux verification**

Run: `flutter test test/features/playlist/domain/playlist_import_service_test.dart test/features/playlist/presentation/playlist_import_provider_test.dart test/features/playlist`

Expected: PASS.

Run: `flutter analyze`

Expected: PASS with no errors or warnings introduced by this subsystem.

Run: `flutter test`

Expected: PASS for the complete Dart suite.

Run on macOS/CI: `flutter build ios --release --no-codesign`

Expected: PASS; keep this result explicitly pending when execution occurs only on Linux.

- [ ] **Step 5: Perform installed-upgrade acceptance and commit**

On a physical iOS device, install a pre-remediation build containing distinct `cloud_api_token`, `sync_token`, user playlists, favorites, and recent history. Upgrade without uninstalling; verify both services remain authenticated, plaintext token keys disappear only after successful Keychain verification, playlists/history survive, system lists cannot be deleted, an outage does not log out cloud auth, and a real 401 does.

```bash
git add lib/features/playlist/domain/playlist_import_service.dart lib/features/playlist/presentation/playlist_import_provider.dart lib/features/playlist/presentation/playlist_screen.dart test/features/playlist/domain/playlist_import_service_test.dart test/features/playlist/presentation/playlist_import_provider_test.dart
git commit -m "fix: cancel stale playlist imports"
```

## Dependency Order

1. Task 1 defines secure storage used by Tasks 2 and 4.
2. Task 2 defines typed cloud verification used by Task 3.
3. Task 5 defines the playlist snapshot contract used by Tasks 6 and 7.
4. Task 6 supplies durable storage and must land before Task 7 changes mutation guarantees.
5. Task 7 defines async service signatures and revision semantics consumed by Task 8 and Task 11.
6. Tasks 9, 10, and the provider portion of Task 11 are independent after their listed interfaces exist and may be implemented in parallel.
7. Task 11 full verification runs only after Tasks 1 through 10 are integrated.

## Acceptance Concerns

- `flutter_secure_storage` Keychain behavior and installed-upgrade migration require a real iOS device; Dart fakes prove ordering and failure retention but not entitlement/device behavior.
- Atomic rename and fsync behavior must be exercised on Darwin in addition to temporary-directory Dart tests; Linux passing is not evidence of iOS filesystem durability.
- `MusicSourceService` and custom-source lyric fallback do not currently expose cancellation tokens. This plan uses logical cancellation for those calls and transport cancellation only for direct Dio work; extending cancellation through every music source is outside this persistence/state subsystem.
- Existing settings backup files use an unversioned playlist list inside backup version `1`. Restore must accept that validated shape and route it through `PlaylistSnapshotCodec`/`PlaylistService.replaceAll`; it must not write the removed SharedPreferences playlist key.
- Playlist mutation signatures become asynchronous. Analyzer success plus the source guard are required to catch every formerly synchronous caller and every manual version increment.
