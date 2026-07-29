# Persistence and Network Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete approved Batch B so corrupted or stale persistence cannot damage startup state, network work cannot outlive its owner, untrusted inputs are bounded, and credentials are bound to the HTTPS authority that issued them.

**Architecture:** Keep the existing Riverpod, `PlaylistService`, Dio, and source-sandbox boundaries. Add strict decoders and snapshot-backed compensation at storage boundaries, monotonically increasing generations plus cancellation at asynchronous ownership boundaries, and shared bounded-input helpers before parsing or image decoding. Reuse `SourceRequestSandbox` with `SourcePinnedTransport` for remote custom-source imports so redirects are re-resolved and revalidated at every hop.

**Tech Stack:** Flutter/Dart 3.2+, Riverpod 2.6, Dio 5.7, SharedPreferences, flutter_secure_storage/Keychain, `dart:io`, `flutter_test`.

## Global Constraints

- Work directly in `/tmp/opencode/LX2IOS-main`; this tree has no Git metadata, so every version-control step from the generic workflow is intentionally omitted.
- Preserve both excluded Worker playlist-import behaviors unchanged.
- Avoid unrelated refactors and major dependency upgrades.
- Fix root causes rather than masking races with delays or retries.
- Every asynchronous publisher must prove ownership with a generation/session revision immediately before mutating memory or durable state.
- Cancellation is expected control flow and must not publish an error state.
- Durable success is published only after persistence succeeds; a failed multi-write restore compensates from its pre-operation snapshot.
- Limits used by this batch: backup file 8 MiB; custom-source script 2 MiB; artwork 8 MiB; JSON nesting 20; any imported string 64 KiB except custom-source script; 500 playlists; 5,000 songs per playlist; 20,000 songs total; five redirects; 15-second custom-source total deadline; 12-second artwork deadline.
- Run commands from `/tmp/opencode/LX2IOS-main`.

---

## File Map

- Create `lib/core/io/bounded_input.dart`: byte-limited file/stream reads and recursive JSON shape budgets shared by backup and custom-source import.
- Create `test/core/io/bounded_input_test.dart`: boundary, over-limit, and nesting tests.
- Create `test/core/storage/storage_service_test.dart`: SharedPreferences `false` handling and snapshot restoration tests.
- Create `test/features/settings/presentation/settings_initialization_test.dart`: delayed-load generation tests for every settings notifier and search history.
- Create `test/features/settings/backup_restore_transaction_test.dart`: complete decode, compensation, and live-publication ordering tests.
- Create `test/features/custom_source/domain/custom_source_import_policy_test.dart`: local/remote size, HTTPS, redirect, timeout, and provider-publication tests.
- Modify `lib/core/storage/storage_service.dart`: checked writes/removes, injectable test constructor, and typed preference snapshots.
- Modify `lib/core/storage/secure_token_store.dart`: origin-derived secure keys and fail-closed plaintext migration.
- Modify `lib/features/download/domain/download_task.dart`: strict persisted-record decoder.
- Modify `lib/features/download/domain/download_service.dart`: quarantine, owned canonical paths, injected download root, and startup file/index reconciliation.
- Modify `test/features/download/domain/download_task_test.dart`: malformed persisted-record tests.
- Modify `test/features/download/domain/download_service_test.dart`: independent quarantine, path escape, and crash-window reconciliation tests.
- Modify `lib/features/settings/presentation/settings_provider.dart`: injected storage loaders and initialization/mutation generations.
- Modify `lib/features/search/presentation/search_provider.dart`: search-history initialization/mutation generation and committed-state publisher.
- Modify `lib/features/settings/domain/playlist_backup.dart`: bounded complete backup model and restore coordinator.
- Modify `lib/features/settings/presentation/settings_screen.dart`: bounded file read and coordinator call; publish notifiers only after durable success.
- Modify `test/features/settings/playlist_backup_compatibility_test.dart`: full backup validation and resource-limit cases.
- Modify `lib/features/playlist/domain/playlist_service.dart`: explicit forced snapshot restore used only for transaction compensation.
- Modify `test/features/playlist/domain/playlist_service_test.dart`: forced snapshot restore persistence/publication test.
- Modify `lib/features/sync/presentation/cloud_playlist_merge.dart`: strict all-or-nothing remote snapshot decode.
- Modify `lib/features/sync/presentation/sync_screen.dart`: use the strict cloud decoder.
- Modify `test/features/sync/presentation/cloud_playlist_merge_test.dart`: malformed-song rejection without persistence.
- Modify `lib/features/sync/domain/sync_service.dart`: session/operation generations, CancelTokens, per-phase and total deadlines, and origin-scoped token storage.
- Modify `lib/features/sync/presentation/sync_provider.dart`: notifier generation and cancellation-aware publication.
- Modify `test/features/sync/domain/sync_service_test.dart`: stale response, disconnect, server change, cancellation, and deadline tests.
- Create `test/features/sync/presentation/sync_provider_test.dart`: stale notifier publication tests.
- Modify `lib/features/custom_source/domain/custom_source_service.dart`: checked persistence, bounded local text acceptance, and sandboxed remote imports.
- Modify `lib/features/custom_source/presentation/custom_source_provider.dart`: initialization/import generations.
- Modify `lib/features/custom_source/presentation/custom_source_screen.dart`: bounded local file reads and strict HTTPS copy.
- Modify `lib/core/widgets/artwork_image.dart`: bounded loader with total deadline and guaranteed client closure.
- Modify `test/core/widgets/artwork_image_test.dart`: deterministic close, timeout, content-length, and streamed-overflow tests; remove live-CDN dependence.
- Modify `lib/features/cloud/domain/cloud_api_client.dart`: normalized-origin token keys and atomic session invalidation on authority changes.
- Modify `test/features/cloud/domain/cloud_api_client_test.dart`: cross-origin isolation, migration, and Keychain failure tests.
- Modify `test/core/storage/secure_token_store_test.dart`: fail-closed migration expectations.

### Task 1: Make SharedPreferences Failures Observable

**Files:**
- Modify: `lib/core/storage/storage_service.dart:1-66`
- Create: `test/core/storage/storage_service_test.dart`
- Modify: `lib/core/storage/secure_token_store.dart:30-88`
- Modify: `test/core/storage/secure_token_store_test.dart:45-108`

**Interfaces:**
- Produces: `StorageWriteException(String key, String operation)`.
- Produces: `PreferenceSnapshot StorageService.snapshot(Set<String> keys)` and `Future<void> StorageService.restore(PreferenceSnapshot snapshot)`.
- Produces: `@visibleForTesting StorageService.forTesting(SharedPreferences preferences)`.
- Changes: every `StorageService.set*` and `remove` remains `Future<bool>` for call-site compatibility but throws when the plugin resolves `false`.
- Changes: `LegacyTokenMigrator.readAndMigrate` returns only a verified secure value; it never returns plaintext after secure read/write/verification failure.

- [ ] **Step 1: Write failing checked-write and fail-closed migration tests**

```dart
// test/core/storage/storage_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('false SharedPreferences result is a storage failure', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService.forTesting(
      prefs,
      writeOverride: (operation, key, value) async => false,
    );

    await expectLater(
      storage.setBool('wifi_only_download', false),
      throwsA(isA<StorageWriteException>()
          .having((error) => error.key, 'key', 'wifi_only_download')),
    );
  });

  test('snapshot restore preserves absent and typed values', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': 2});
    final prefs = await SharedPreferences.getInstance();
    final storage = StorageService.forTesting(prefs);
    final before = storage.snapshot({'theme_mode', 'search_history'});

    await storage.setInt('theme_mode', 1);
    await storage.setStringList('search_history', ['new']);
    await storage.restore(before);

    expect(storage.getInt('theme_mode'), 2);
    expect(prefs.containsKey('search_history'), isFalse);
  });
}
```

Add this case to `test/core/storage/secure_token_store_test.dart`:

```dart
test('Keychain failure removes plaintext and requires reauthentication', () async {
  final secure = FakeSecureTokenStore()..throwOnRead = true;
  final prefs = await preferences({'cloud_api_token': 'plaintext'});
  final migrator = LegacyTokenMigrator(
    secureStore: secure,
    preferences: prefs,
  );

  await expectLater(
    migrator.readAndMigrate('cloud_api_token'),
    throwsA(isA<SecureTokenMigrationException>()),
  );
  expect(prefs.containsKey('cloud_api_token'), isFalse);
}
```

Extend that test's `FakeSecureTokenStore` with:

```dart
bool throwOnRead = false;

@override
Future<String?> read(String key) async {
  if (throwOnRead) throw StateError('keychain unavailable');
  operations.add('read:$key');
  if (_writes > 0 && readAfterWrite != null) return readAfterWrite;
  return _values[key];
}
```

- [ ] **Step 2: Run the focused tests and verify red**

Run: `flutter test test/core/storage/storage_service_test.dart test/core/storage/secure_token_store_test.dart`

Expected: compilation fails because `StorageService.forTesting`, `StorageWriteException`, `PreferenceSnapshot`, and `SecureTokenMigrationException` do not exist; the old migration also returns plaintext.

- [ ] **Step 3: Implement checked writes, snapshots, and fail-closed migration**

Use one checked adapter for every SharedPreferences mutation:

```dart
typedef PreferenceWriteOverride = Future<bool> Function(
  String operation,
  String key,
  Object? value,
);

final class StorageWriteException implements Exception {
  const StorageWriteException(this.key, this.operation);
  final String key;
  final String operation;
  @override
  String toString() => 'StorageWriteException: $operation failed for $key';
}

final class PreferenceSnapshot {
  const PreferenceSnapshot(this.values);
  final Map<String, Object?> values;
}

class StorageService {
  StorageService._(this._prefs, [this._writeOverride]);
  @visibleForTesting
  StorageService.forTesting(
    SharedPreferences preferences, {
    PreferenceWriteOverride? writeOverride,
  }) : this._(preferences, writeOverride);

  final SharedPreferences _prefs;
  final PreferenceWriteOverride? _writeOverride;

  Future<bool> _checked(
    String operation,
    String key,
    Object? value,
    Future<bool> Function() write,
  ) async {
    final ok = await (_writeOverride?.call(operation, key, value) ?? write());
    if (!ok) throw StorageWriteException(key, operation);
    return true;
  }

  Future<bool> setBool(String key, bool value) =>
      _checked('setBool', key, value, () => _prefs.setBool(key, value));
  Future<bool> setInt(String key, int value) =>
      _checked('setInt', key, value, () => _prefs.setInt(key, value));
  Future<bool> setDouble(String key, double value) =>
      _checked('setDouble', key, value, () => _prefs.setDouble(key, value));
  Future<bool> setString(String key, String value) =>
      _checked('setString', key, value, () => _prefs.setString(key, value));
  Future<bool> setStringList(String key, List<String> value) => _checked(
      'setStringList', key, value, () => _prefs.setStringList(key, value));
  Future<bool> remove(String key) =>
      _checked('remove', key, null, () => _prefs.remove(key));

  PreferenceSnapshot snapshot(Set<String> keys) => PreferenceSnapshot({
        for (final key in keys)
          key: _prefs.containsKey(key) ? _prefs.get(key) : null,
      });

  Future<void> restore(PreferenceSnapshot snapshot) async {
    for (final entry in snapshot.values.entries) {
      final value = entry.value;
      if (value == null) {
        await remove(entry.key);
      } else if (value is bool) {
        await setBool(entry.key, value);
      } else if (value is int) {
        await setInt(entry.key, value);
      } else if (value is double) {
        await setDouble(entry.key, value);
      } else if (value is String) {
        await setString(entry.key, value);
      } else if (value is List<String>) {
        await setStringList(entry.key, value);
      } else {
        throw StateError('Unsupported preference snapshot value for ${entry.key}');
      }
    }
  }
}
```

Retain all existing JSON getters/setters, routing their writes through `_checked`. In `LegacyTokenMigrator`, remove both `return legacy` fallbacks. On any secure failure, attempt `preferences.remove(key)`, verify `containsKey(key) == false`, then throw `SecureTokenMigrationException`; after a verified secure write, require the migration marker and plaintext removal to return `true` before returning the secure token.

- [ ] **Step 4: Run focused tests and verify green**

Run: `flutter test test/core/storage/storage_service_test.dart test/core/storage/secure_token_store_test.dart`

Expected: all tests pass; no test expects plaintext to remain or be returned after secure verification failure.

### Task 2: Quarantine Bad Downloads and Reconcile File/Index Crashes

**Files:**
- Modify: `lib/features/download/domain/download_task.dart:140-167`
- Modify: `lib/features/download/domain/download_service.dart:21-37,152-253,656-711,825-897,968-1028`
- Modify: `test/features/download/domain/download_task_test.dart`
- Modify: `test/features/download/domain/download_service_test.dart`

**Interfaces:**
- Changes: `DownloadTaskStorage.load()` returns `List<dynamic>` so each raw element can be isolated.
- Produces: `List<Map<String, dynamic>> DownloadTaskStorage.loadQuarantine()` and `Future<void> saveQuarantine(List<Map<String, dynamic>> records)`.
- Produces: `DownloadTask.decodePersisted(Object? raw)` with strict required types, enum bounds, finite progress in `[0,1]`, non-negative sizes/revisions, and valid dates.
- Adds constructor input: `Future<Directory> Function()? downloadDirectory`.
- Produces for tests: `bool DownloadService.isOwnedDownloadPath(String path)` after `init()`.

- [ ] **Step 1: Add failing strict-decoder and startup-isolation tests**

```dart
// test/features/download/domain/download_task_test.dart
test('persisted task decoder rejects invalid status and required types', () {
  final valid = DownloadTask(
    id: 't1', musicId: 'm1', name: 'Song', singer: 'Singer',
    createdAt: DateTime.utc(2026),
  ).toJson();

  expect(
    () => DownloadTask.decodePersisted({...valid, 'status': 99}),
    throwsFormatException,
  );
  expect(
    () => DownloadTask.decodePersisted({...valid, 'musicId': 7}),
    throwsFormatException,
  );
  expect(
    () => DownloadTask.decodePersisted({...valid, 'progress': double.nan}),
    throwsFormatException,
  );
});
```

Update `_MemoryStorage` in `download_service_test.dart` to implement the expanded interface, then add:

```dart
test('startup quarantines one bad record and loads valid siblings', () async {
  final valid = DownloadTask(
    id: 'valid', musicId: 'm1', name: 'Song', singer: 'Singer',
    createdAt: DateTime.utc(2026), status: DownloadStatus.paused,
  ).toJson();
  final storage = _MemoryStorage()..saved = [valid, {'id': 7}];
  final root = await Directory.systemTemp.createTemp('downloads_');
  addTearDown(() => root.delete(recursive: true));
  final service = DownloadService(
    storage: storage,
    downloader: (_, __, ___) async {},
    downloadDirectory: () async => root,
  );
  addTearDown(service.dispose);

  await service.init();

  expect(service.tasks.map((task) => task.id), ['valid']);
  expect(storage.quarantine, hasLength(1));
  expect(storage.saved, hasLength(1));
});

test('outside-root completed path is quarantined and never deleted', () async {
  final root = await Directory.systemTemp.createTemp('downloads_');
  final outside = await Directory.systemTemp.createTemp('outside_');
  final victim = File('${outside.path}/victim.mp3')..writeAsBytesSync([1, 2, 3]);
  final storage = _MemoryStorage()
    ..saved = [DownloadTask(
      id: 'escaped', musicId: 'm1', name: 'Song', singer: 'Singer',
      createdAt: DateTime.utc(2026), status: DownloadStatus.completed,
      savePath: victim.path, fileSize: 3,
    ).toJson()];
  final service = DownloadService(
    storage: storage,
    downloader: (_, __, ___) async {},
    downloadDirectory: () async => root,
  );
  addTearDown(() async {
    await service.dispose();
    await root.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  await service.init();
  await service.clearCache();

  expect(service.tasks, isEmpty);
  expect(storage.quarantine, hasLength(1));
  expect(victim.existsSync(), isTrue);
});

test('startup recovers promoted file and removes strict orphan and part', () async {
  final root = await Directory.systemTemp.createTemp('downloads_');
  final recoverable = File('${root.path}/task-2.mp3')
    ..writeAsBytesSync(List<int>.filled(2048, 1));
  final orphan = File('${root.path}/orphan-1.flac')..writeAsBytesSync([1]);
  final part = File('${root.path}/task-2.part')..writeAsBytesSync([1]);
  final unrelated = File('${root.path}/notes.txt')..writeAsStringSync('keep');
  final storage = _MemoryStorage()
    ..saved = [DownloadTask(
      id: 'task', musicId: 'm1', name: 'Song', singer: 'Singer',
      createdAt: DateTime.utc(2026), status: DownloadStatus.downloading,
      attemptRevision: 2,
    ).toJson()];
  final service = DownloadService(
    storage: storage,
    downloader: (_, __, ___) async {},
    downloadDirectory: () async => root,
  );
  addTearDown(() async {
    await service.dispose();
    await root.delete(recursive: true);
  });

  await service.init();

  expect(service.tasks.single.status, DownloadStatus.completed);
  expect(service.tasks.single.savePath, recoverable.path);
  expect(orphan.existsSync(), isFalse);
  expect(part.existsSync(), isFalse);
  expect(unrelated.existsSync(), isTrue);
});
```

- [ ] **Step 2: Run download tests and verify red**

Run: `flutter test test/features/download/domain/download_task_test.dart test/features/download/domain/download_service_test.dart`

Expected: compilation fails on the new decoder/storage/root interfaces; current startup also throws on the malformed record and accepts the escaped path.

- [ ] **Step 3: Implement strict decode, canonical ownership, quarantine, and reconciliation**

Use `Directory.resolveSymbolicLinks()` for the root. For a target that exists, resolve the target; for a missing target, walk to its nearest existing ancestor, resolve that ancestor, and append the missing path segments before comparing. `File(path).absolute.path` is only the pre-resolution candidate. Ownership must require `candidate == root` or `candidate.startsWith('$root${Platform.pathSeparator}')` after this resolution. Never use a filename-only check for persisted paths. `_safeDelete`, `getCacheSize`, `getDownloadPath`, `clearCacheWithLRU`, cancellation, and startup reconciliation must all call the same ownership method.

Persist quarantine entries under `download_tasks_quarantine` in this exact shape:

```dart
{
  'record': raw,
  'reason': error.toString(),
  'quarantinedAt': DateTime.now().toUtc().toIso8601String(),
}
```

Reconciliation order in `init()` must be:

```dart
await _initDownloadDir();
await _loadFromStorageIndependently();
await _reconcileDownloadDirectory();
await _persistReconciledSnapshotIfChanged();
_initialized = true;
_processQueue();
```

Only filenames matching `^(.+)-(\d+)\.(part|mp3|m4a|aac|ogg|wav|ape|flac)$` are cleanup candidates. A final file is recoverable only when its base equals `safeDownloadBaseName(task.id)`, revision equals `task.attemptRevision`, the task is `downloading` or `pending`, and the file has non-zero length. If more than one final extension matches, quarantine the task and delete only those strict owned candidates. Delete strict `.part` files and strict final files with no matching task; leave all unrelated names untouched. Save the recovered completed task index before scheduling the queue.

- [ ] **Step 4: Run download tests and verify green**

Run: `flutter test test/features/download/domain/download_task_test.dart test/features/download/domain/download_service_test.dart`

Expected: all tests pass; the valid sibling loads, escaped file survives, promoted file is indexed, strict orphan/temp files are removed, and unrelated files remain.

### Task 3: Add Initialization Generations to Settings and Search History

**Files:**
- Modify: `lib/features/settings/presentation/settings_provider.dart:19-194`
- Modify: `lib/features/search/presentation/search_provider.dart:132-167`
- Create: `test/features/settings/presentation/settings_initialization_test.dart`

**Interfaces:**
- Produces: `typedef StorageLoader = Future<StorageService> Function()` in `storage_service.dart`.
- Adds optional `StorageLoader? storage` to every settings notifier and `SearchHistoryNotifier` constructor.
- Produces: `void applyCommitted(...)` on settings notifiers and `void applyCommitted(List<String>)` on search history; these increment generation and update state without writing.
- Invariant: `_load` captures generation before awaiting storage and publishes only when still current; every mutation increments generation before its first await.

- [ ] **Step 1: Write deterministic stale-initialization tests**

```dart
// test/features/settings/presentation/settings_initialization_test.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/storage_service.dart';
import 'package:lx_music_flutter/features/search/presentation/search_provider.dart';
import 'package:lx_music_flutter/features/settings/presentation/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('late theme load cannot overwrite a user mutation', () async {
    SharedPreferences.setMockInitialValues({'theme_mode': ThemeMode.dark.index});
    final gate = Completer<StorageService>();
    final notifier = ThemeModeNotifier(storage: () => gate.future);

    final mutation = notifier.setThemeMode(ThemeMode.light);
    final prefs = await SharedPreferences.getInstance();
    gate.complete(StorageService.forTesting(prefs));
    await mutation;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, ThemeMode.light);
    expect(prefs.getInt('theme_mode'), ThemeMode.light.index);
  });

  test('late history load cannot resurrect entries after clear', () async {
    SharedPreferences.setMockInitialValues({'search_history': ['old']});
    final gate = Completer<StorageService>();
    final notifier = SearchHistoryNotifier(storage: () => gate.future);

    final clear = notifier.clear();
    final prefs = await SharedPreferences.getInstance();
    gate.complete(StorageService.forTesting(prefs));
    await clear;
    await Future<void>.delayed(Duration.zero);

    expect(notifier.state, isEmpty);
    expect(prefs.getStringList('search_history'), isEmpty);
  });
}
```

Add the remaining delayed-loader cases using this table and explicit switch so every current public interface is exercised:

```dart
test('late settings loads cannot overwrite public setter mutations', () async {
  SharedPreferences.setMockInitialValues({
    'audio_quality': AudioQualityOption.low.index,
    'download_quality': AudioQualityOption.low.index,
    'wifi_only_download': true,
    'sync_server_url': 'https://old.example',
    'default_search_platform': 'tx',
  });
  final prefs = await SharedPreferences.getInstance();

  for (final kind in const [
    'audio', 'download', 'wifi', 'syncUrl', 'platform',
  ]) {
    final gate = Completer<StorageService>();
    final StorageLoader loader = () => gate.future;
    late final Object? Function() readState;
    late final Future<void> mutation;
    late final Object expected;
    switch (kind) {
      case 'audio':
        final value = AudioQualityNotifier(storage: loader);
        readState = () => value.state;
        expected = AudioQualityOption.hires;
        mutation = value.setQuality(AudioQualityOption.hires);
        break;
      case 'download':
        final value = DownloadQualityNotifier(storage: loader);
        readState = () => value.state;
        expected = AudioQualityOption.lossless;
        mutation = value.setQuality(AudioQualityOption.lossless);
        break;
      case 'wifi':
        final value = WifiOnlyDownloadNotifier(storage: loader);
        readState = () => value.state;
        expected = false;
        mutation = value.setWifiOnly(false);
        break;
      case 'syncUrl':
        final value = SyncServerUrlNotifier(storage: loader);
        readState = () => value.state;
        expected = 'https://new.example';
        mutation = value.setUrl('https://new.example');
        break;
      case 'platform':
        final value = DefaultSearchPlatformNotifier(storage: loader);
        readState = () => value.state;
        expected = 'wy';
        mutation = value.setPlatform('wy');
        break;
      default:
        throw StateError(kind);
    }
    gate.complete(StorageService.forTesting(prefs));
    await mutation;
    await Future<void>.delayed(Duration.zero);
    expect(readState(), expected, reason: kind);
  }

  expect(prefs.getInt('audio_quality'), AudioQualityOption.hires.index);
  expect(prefs.getInt('download_quality'), AudioQualityOption.lossless.index);
  expect(prefs.getBool('wifi_only_download'), isFalse);
  expect(prefs.getString('sync_server_url'), 'https://new.example');
  expect(prefs.getString('default_search_platform'), 'wy');
});
```

- [ ] **Step 2: Run initialization tests and verify red**

Run: `flutter test test/features/settings/presentation/settings_initialization_test.dart`

Expected: constructors reject `storage`; with current constructors a late `_load()` can overwrite newer state.

- [ ] **Step 3: Implement the same ownership pattern in every notifier**

Use this exact pattern, changing only key/type validation per notifier:

```dart
class WifiOnlyDownloadNotifier extends StateNotifier<bool> {
  WifiOnlyDownloadNotifier({StorageLoader? storage})
      : _storage = storage ?? (() => StorageService.instance),
        super(true) {
    _load();
  }
  final StorageLoader _storage;
  int _generation = 0;

  Future<void> _load() async {
    final generation = _generation;
    final storage = await _storage();
    final value = storage.getBool('wifi_only_download');
    if (generation == _generation && value != null) state = value;
  }

  Future<void> setWifiOnly(bool value) async {
    ++_generation;
    final previous = state;
    state = value;
    try {
      await (await _storage()).setBool('wifi_only_download', value);
    } catch (_) {
      if (state == value) state = previous;
      rethrow;
    }
  }

  void applyCommitted(bool value) {
    ++_generation;
    state = value;
  }
}
```

Search history mutations must capture their intended list before awaiting, roll memory back on a current write failure, and never derive a later write from state after an await.

- [ ] **Step 4: Run settings/search tests and verify green**

Run: `flutter test test/features/settings/presentation/settings_initialization_test.dart test/features/settings/default_quality_test.dart test/features/settings/sync_server_url_test.dart`

Expected: all tests pass without timing delays longer than `Duration.zero`.

### Task 4: Bound and Transactionally Restore Backups

**Files:**
- Create: `lib/core/io/bounded_input.dart`
- Create: `test/core/io/bounded_input_test.dart`
- Modify: `lib/features/settings/domain/playlist_backup.dart:1-26`
- Modify: `lib/features/settings/presentation/settings_screen.dart:503-624`
- Modify: `lib/features/playlist/domain/playlist_service.dart:278-291,324-350`
- Modify: `test/features/playlist/domain/playlist_service_test.dart`
- Modify: `test/features/settings/playlist_backup_compatibility_test.dart`
- Create: `test/features/settings/backup_restore_transaction_test.dart`

**Interfaces:**
- Produces: `Future<Uint8List> readFileBytesBounded(File file, {required int maximumBytes})` using `openRead`, not `readAsString`.
- Produces: `void validateJsonBudget(Object? value, JsonBudget budget)` with `maximumDepth`, `maximumStringLength`, and collection-count checks.
- Replaces playlist-only decode with `BackupData decodeBackup(String source, {BackupLimits limits = const BackupLimits()})`.
- Produces: `BackupRestoreCoordinator.restore(BackupData data)`; constructor consumes `StorageService`, `PlaylistService`, and a non-throwing `void Function(BackupData) publishCommitted`.
- Produces: `Future<void> PlaylistService.restoreSnapshot(PlaylistSnapshot snapshot)`, which always saves the supplied validated snapshot and publishes it only after save success; this is the compensation path when a repository may have replaced durable bytes before reporting failure.

- [ ] **Step 1: Write failing byte/depth and rollback tests**

```dart
// test/core/io/bounded_input_test.dart
test('bounded file reader rejects content larger than the limit', () async {
  final dir = await Directory.systemTemp.createTemp('bounded_');
  addTearDown(() => dir.delete(recursive: true));
  final file = File('${dir.path}/input.json')
    ..writeAsBytesSync(List<int>.filled(9, 1));

  await expectLater(
    readFileBytesBounded(file, maximumBytes: 8),
    throwsA(isA<InputLimitException>()
        .having((error) => error.code, 'code', 'bytes')),
  );
});

test('JSON budget rejects excessive nesting before domain decode', () {
  Object value = 'leaf';
  for (var index = 0; index < 21; index++) value = [value];
  expect(
    () => validateJsonBudget(value, const JsonBudget(maximumDepth: 20)),
    throwsA(isA<InputLimitException>()),
  );
});
```

```dart
// test/features/settings/backup_restore_transaction_test.dart
test('failed setting write restores preferences and never publishes live state',
    () async {
  SharedPreferences.setMockInitialValues({'theme_mode': 2});
  final prefs = await SharedPreferences.getInstance();
  var failAudioOnce = true;
  final storage = StorageService.forTesting(
    prefs,
    writeOverride: (operation, key, value) async {
      if (key == 'audio_quality' && failAudioOnce) {
        failAudioOnce = false;
        return false;
      }
      return switch ((operation, value)) {
        ('setInt', int value) => prefs.setInt(key, value),
        ('setBool', bool value) => prefs.setBool(key, value),
        ('setStringList', List<String> value) => prefs.setStringList(key, value),
        ('remove', _) => prefs.remove(key),
        _ => throw StateError('unexpected write: $operation $key'),
      };
    },
  );
  final repository = _MemoryRepository(_systemSnapshot());
  final playlists = PlaylistService(repository: repository);
  await playlists.init();
  var publications = 0;
  final coordinator = BackupRestoreCoordinator(
    storage: storage,
    playlists: playlists,
    publishCommitted: (_) => publications++,
  );

  await expectLater(coordinator.restore(_backupData()), throwsStateError);

  expect(storage.getInt('theme_mode'), 2);
  expect(repository.saves, isEmpty);
  expect(publications, 0);
});

test('playlist save failure compensates playlists and preferences',
    () async {
  SharedPreferences.setMockInitialValues({'theme_mode': 2});
  final storage = StorageService.forTesting(
    await SharedPreferences.getInstance(),
  );
  final repository = _FailOnceAfterReplaceRepository(_systemSnapshot());
  final playlists = PlaylistService(repository: repository);
  await playlists.init();
  var publications = 0;
  final coordinator = BackupRestoreCoordinator(
    storage: storage,
    playlists: playlists,
    publishCommitted: (_) => publications++,
  );

  await expectLater(coordinator.restore(_backupData()), throwsStateError);

  expect(storage.getInt('theme_mode'), 2);
  expect(repository.saves, hasLength(2));
  expect(repository.snapshot.playlists.map((playlist) => playlist.id),
      _systemSnapshot().playlists.map((playlist) => playlist.id));
  expect(playlists.playlists.map((playlist) => playlist.id),
      _systemSnapshot().playlists.map((playlist) => playlist.id));
  expect(publications, 0);
});
```

`_FailOnceAfterReplaceRepository.save` assigns its first candidate to `snapshot` and then throws, while its second save succeeds; this models failure after durable replacement and proves compensation writes the old snapshot. `_backupData()` returns a fully valid `BackupData` with one imported playlist and all five optional setting/history values.

- [ ] **Step 2: Run bounded-input and restore tests and verify red**

Run: `flutter test test/core/io/bounded_input_test.dart test/features/settings/playlist_backup_compatibility_test.dart test/features/settings/backup_restore_transaction_test.dart`

Expected: compilation fails because bounded input, complete backup decode, limits, and coordinator interfaces do not exist.

- [ ] **Step 3: Implement complete decode and snapshot-backed restore**

`decodeBackup` must UTF-8 decode strictly, `jsonDecode`, call `validateJsonBudget`, require only these root keys, and validate every present value before any write:

```dart
const backupKeys = {
  'version', 'timestamp', 'playlists', 'search_history', 'theme_mode',
  'audio_quality', 'download_quality', 'wifi_only_download',
};
```

Require version `1`; strict `PlaylistSnapshotCodec`; history as at most 20 non-empty strings of at most 64 KiB; enum indices in range; `wifi_only_download` as bool; at most 500 playlists, 5,000 songs in one playlist, and 20,000 songs total. Reject unknown keys. `BackupRestoreCoordinator.restore` must snapshot all five preference keys and `PlaylistSnapshot(schemaVersion: 1, playlists: playlists.playlists)`, write settings/history first, set `playlistWriteAttempted = true` immediately before calling `PlaylistService.replaceAll`, and call that replacement last. On failure, restore preferences; if `playlistWriteAttempted`, also call `PlaylistService.restoreSnapshot(previousPlaylists)` even when current memory still equals that snapshot. Rethrow the original failure unless compensation itself fails, in which case throw a `BackupRestoreException` carrying both errors. Invoke `publishCommitted(data)` only after `replaceAll` resolves.

Implement the forced compensation method through the existing `_enqueue` serialization boundary:

```dart
Future<void> restoreSnapshot(PlaylistSnapshot snapshot) {
  return _enqueue(() async {
    if (_disposing || !_initialized) {
      throw StateError('PlaylistService is not available for restore');
    }
    _validatePlaylistIds(snapshot.playlists);
    final repaired = PlaylistSnapshot(
      schemaVersion: 1,
      playlists: _withSystemPlaylists(snapshot.playlists),
    );
    await _repository.save(repaired);
    _playlists
      ..clear()
      ..addAll(repaired.playlists);
    _revisionController.add(++_revision);
  });
}
```

In `SettingsScreen`, replace `file.readAsString()` with:

```dart
final bytes = await readFileBytesBounded(
  file,
  maximumBytes: BackupLimits.maximumFileBytes,
);
final data = decodeBackup(utf8.decode(bytes, allowMalformed: false));
await BackupRestoreCoordinator(
  storage: await StorageService.instance,
  playlists: ref.read(playlistServiceProvider),
  publishCommitted: (data) {
    ref.read(searchHistoryProvider.notifier).applyCommitted(data.searchHistory);
    ref.read(themeModeProvider.notifier).applyCommitted(data.themeMode);
    ref.read(audioQualityProvider.notifier).applyCommitted(data.audioQuality);
    ref.read(downloadQualityProvider.notifier)
        .applyCommitted(data.downloadQuality);
    ref.read(wifiOnlyDownloadProvider.notifier)
        .applyCommitted(data.wifiOnlyDownload);
  },
).restore(data);
```

- [ ] **Step 4: Run restore tests and verify green**

Run: `flutter test test/core/io/bounded_input_test.dart test/features/settings/playlist_backup_compatibility_test.dart test/features/settings/backup_restore_transaction_test.dart`

Expected: all tests pass; malformed/oversized input performs zero writes, and injected write/save failures restore prior durable state with zero live publication.

### Task 5: Reject Entire Malformed Cloud Playlist Replacements

**Files:**
- Modify: `lib/features/sync/presentation/cloud_playlist_merge.dart:1-67`
- Modify: `lib/features/sync/presentation/sync_screen.dart:320-366`
- Modify: `test/features/sync/presentation/cloud_playlist_merge_test.dart`

**Interfaces:**
- Changes: `CloudSongDecoder = MusicItem Function(Object? raw)`; invalid input throws `FormatException` instead of returning null.
- Produces: `MusicItem decodeCloudSong(Object? raw)` in `cloud_playlist_merge.dart`.
- Invariant: fully validate `love` and every `userList` object/song into an immutable candidate list before calling `PlaylistService.replaceAll` once.

- [ ] **Step 1: Add failing all-or-nothing tests**

```dart
test('one malformed favorite rejects the whole cloud replacement', () async {
  final repository = _CountingRepository(_systemSnapshot());
  final service = PlaylistService(repository: repository);
  await service.init();

  await expectLater(
    mergeAndPersistCloudPlaylists(
      service: service,
      love: const [
        {'songmid': 'ok', 'name': 'Good', 'singer': 'Singer', 'source': 'tx'},
        {'songmid': '', 'name': '', 'singer': 'Singer', 'source': 'tx'},
      ],
      userList: const [],
      decodeSong: decodeCloudSong,
    ),
    throwsFormatException,
  );

  expect(repository.saveCalls, 0);
  expect(service.favorites!.songs, isEmpty);
});

test('malformed song in one user playlist rejects all user playlists', () async {
  final repository = _CountingRepository(_systemSnapshot());
  final service = PlaylistService(repository: repository);
  await service.init();

  await expectLater(
    mergeAndPersistCloudPlaylists(
      service: service,
      love: const [],
      userList: const [
        {'id': 'good', 'name': 'Good', 'list': []},
        {'id': 'bad', 'name': 'Bad', 'list': [7]},
      ],
      decodeSong: decodeCloudSong,
    ),
    throwsFormatException,
  );

  expect(repository.saveCalls, 0);
  expect(service.getPlaylist('good'), isNull);
});
```

- [ ] **Step 2: Run cloud merge tests and verify red**

Run: `flutter test test/features/sync/presentation/cloud_playlist_merge_test.dart`

Expected: current `.whereType<MusicItem>()` silently drops malformed songs, so both rejection assertions fail.

- [ ] **Step 3: Implement strict candidate decode before replacement**

`decodeCloudSong` must require a map, non-empty `source`, non-empty `name`, non-empty `singer`, and either non-empty `songmid` or `hash`; optional artwork/album must be strings. Require every user playlist to be a map with non-empty non-reserved id, non-empty name, and a list-valued `list`. Do not retain the old `continue`, default-name, `as List? ?? []`, or `whereType` paths. Build candidates first, then merge them into the current playlist map and call `replaceAll` exactly once.

- [ ] **Step 4: Run cloud merge tests and verify green**

Run: `flutter test test/features/sync/presentation/cloud_playlist_merge_test.dart`

Expected: all tests pass; one malformed remote song causes no save and no in-memory playlist change.

### Task 6: Give Sync Requests Session Ownership, Cancellation, and Deadlines

**Files:**
- Modify: `lib/features/sync/domain/sync_service.dart:36-286`
- Modify: `lib/features/sync/presentation/sync_provider.dart:22-77`
- Modify: `test/features/sync/domain/sync_service_test.dart`
- Create: `test/features/sync/presentation/sync_provider_test.dart`

**Interfaces:**
- Produces: `SyncDeadlines(connect, send, receive, total)` with defaults 5s, 10s, 15s, and 25s.
- Adds constructor input: `SyncDeadlines deadlines = const SyncDeadlines()`.
- Produces: `int get sessionGeneration`, `int get operationGeneration`, and `void cancelActiveOperation([String reason])`.
- All Dio calls receive a `CancelToken`, `connectTimeout`, `sendTimeout`, and `receiveTimeout`; the enclosing future receives `total` via `.timeout`, which cancels the token before returning failure.
- `disconnect`, a new `connect`, login/register, server change, and `dispose` increment ownership and cancel active work.

- [ ] **Step 1: Add failing stale/cancel/timeout tests**

```dart
test('disconnect cancels pull and late response cannot publish synced', () async {
  final started = Completer<CancelToken>();
  final response = Completer<Response<dynamic>>();
  final dio = Dio()..interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      started.complete(options.cancelToken!);
      final late = await response.future;
      handler.resolve(late);
    },
  ));
  final service = SyncService(dio: dio);
  addTearDown(service.dispose);
  await service.connect('https://sync.example');

  final pull = service.pull();
  final token = await started.future;
  service.disconnect();
  expect(token.isCancelled, isTrue);
  response.complete(Response(
    requestOptions: RequestOptions(path: '/pull'),
    statusCode: 200,
    data: {'snapshot': 1},
  ));

  expect(await pull, isNull);
  expect(service.status, SyncStatus.disconnected);
  expect(service.lastSyncTime, isNull);
});

test('newer push owns status when older push completes last', () async {
  final requests = <Completer<Response<dynamic>>>[];
  final dio = Dio()..interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) async {
      final pending = Completer<Response<dynamic>>();
      requests.add(pending);
      handler.resolve(await pending.future);
    },
  ));
  final service = SyncService(dio: dio);
  addTearDown(service.dispose);
  await service.connect('https://sync.example');

  final older = service.push(playlists: const [], history: const []);
  await Future<void>.delayed(Duration.zero);
  final newer = service.push(playlists: const [], history: const []);
  requests.last.complete(Response(
    requestOptions: RequestOptions(path: '/new'), statusCode: 200));
  expect(await newer, isTrue);
  requests.first.complete(Response(
    requestOptions: RequestOptions(path: '/old'), statusCode: 500));
  expect(await older, isFalse);
  expect(service.status, SyncStatus.synced);
});

test('total deadline cancels transport and returns controlled failure', () async {
  CancelToken? token;
  final dio = Dio()..interceptors.add(InterceptorsWrapper(
    onRequest: (options, handler) {
      token = options.cancelToken;
    },
  ));
  final service = SyncService(
    dio: dio,
    deadlines: const SyncDeadlines(
      connect: Duration(milliseconds: 5),
      send: Duration(milliseconds: 5),
      receive: Duration(milliseconds: 5),
      total: Duration(milliseconds: 10),
    ),
  );
  addTearDown(service.dispose);

  expect(await service.connect('https://sync.example'), isFalse);
  expect(token?.isCancelled, isTrue);
  expect(service.status, SyncStatus.error);
});
```

In `sync_provider_test.dart`, use a controlled subclass and the notifier's real public methods:

```dart
final class _ControlledSyncService extends SyncService {
  final connectResult = Completer<bool>();
  var disconnectCalls = 0;

  @override
  Future<bool> connect(String serverUrl, {String? token}) => connectResult.future;

  @override
  Future<String?> loadSavedToken() async => 'token';

  @override
  void disconnect() {
    disconnectCalls++;
  }
}

test('late notifier connect cannot publish after disconnect', () async {
  final service = _ControlledSyncService();
  final container = ProviderContainer(overrides: [
    syncServiceProvider.overrideWithValue(service),
    syncServerUrlProvider.overrideWith((ref) =>
        SyncServerUrlNotifier(initialValue: 'https://sync.example')),
  ]);
  addTearDown(container.dispose);
  final notifier = container.read(syncConnectionProvider.notifier);

  final connect = notifier.connect();
  await Future<void>.delayed(Duration.zero);
  notifier.disconnect();
  service.connectResult.complete(true);

  expect(await connect, isFalse);
  expect(container.read(syncConnectionProvider), isFalse);
  expect(service.disconnectCalls, 1);
});
```

Add `String? initialValue` to `SyncServerUrlNotifier` only as a testable constructor input; when non-null it is validated and used synchronously, and `_load` is skipped. Production providers continue calling the zero-argument constructor.

- [ ] **Step 2: Run sync tests and verify red**

Run: `flutter test test/features/sync/domain/sync_service_test.dart test/features/sync/presentation/sync_provider_test.dart`

Expected: new deadline/generation APIs do not compile; current pull can publish after disconnect and push/pull have no cancellation or total timeout.

- [ ] **Step 3: Implement one active operation with generation checks**

At operation start, cancel the previous token, increment `_operationGeneration`, capture `_sessionGeneration`, and create a token. Immediately before status, `_lastSyncTime`, token, or result publication require all three:

```dart
bool _owns(int session, int operation, CancelToken token) =>
    !_disposed &&
    session == _sessionGeneration &&
    operation == _operationGeneration &&
    identical(token, _activeCancelToken) &&
    !token.isCancelled;
```

Wrap each request in a helper that applies all Dio phase timeouts and:

```dart
return request.timeout(_deadlines.total, onTimeout: () {
  cancelToken.cancel('sync total deadline exceeded');
  throw TimeoutException('sync total deadline exceeded', _deadlines.total);
});
```

Catch cancellation separately and return `false`/`null` without status mutation. For a current non-cancellation error, publish `SyncStatus.error`. `SyncConnectionNotifier` uses its own `_generation`; increment it in every command and check it after each await before assigning `state`.

- [ ] **Step 4: Run sync tests and verify green**

Run: `flutter test test/features/sync/domain/sync_service_test.dart test/features/sync/presentation/sync_provider_test.dart`

Expected: all tests pass; stale/cancelled requests cannot publish status, payload, token, or sync time, and total timeout cancels transport.

### Task 7: Bound Custom-Source Imports and Reuse the Pinned Transport

**Files:**
- Modify: `lib/features/custom_source/domain/custom_source_service.dart:9-24,122-125,268-384,411-417`
- Modify: `lib/features/custom_source/presentation/custom_source_provider.dart:19-80`
- Modify: `lib/features/custom_source/presentation/custom_source_screen.dart:160-189,293-374`
- Create: `test/features/custom_source/domain/custom_source_import_policy_test.dart`
- Reuse unchanged: `lib/core/network/source_request_policy.dart`
- Reuse unchanged: `lib/core/network/source_pinned_transport.dart`

**Interfaces:**
- Adds constructor inputs: `SourceRequestSandbox? importSandbox`, `StorageLoader? storage`, and `DateTime Function()? clock`.
- Produces: `static const maximumScriptBytes = 2 * 1024 * 1024` and `static const importTimeout = Duration(seconds: 15)`.
- Changes: `importSourceFromUrl(String url, {SourceRequestCancellation? cancellation})` validates through the sandbox, reads at most 2 MiB, releases its response lease, and returns false for policy/format failure.
- Changes: local/pasted `importSource` and `importLxMusicScript` reject UTF-8 byte length over 2 MiB before JSON parsing or regex scanning.

- [ ] **Step 1: Add failing local and remote policy tests**

```dart
test('local script over byte limit is rejected before persistence', () async {
  final service = CustomSourceService();
  SharedPreferences.setMockInitialValues({});
  await service.init();
  addTearDown(service.dispose);

  final oversized = List.filled(
    CustomSourceService.maximumScriptBytes + 1,
    'a',
  ).join();
  expect(await service.importLxMusicScript(oversized), isFalse);
  expect(service.sources, isEmpty);
});

test('remote import rejects HTTP before transport', () async {
  var transports = 0;
  final sandbox = SourceRequestSandbox(
    policy: SourceRequestPolicy(resolve: (_) async =>
      [InternetAddress('93.184.216.34')], maximumResponseBytes: 16),
    transport: (request, cancellation) async {
      transports++;
      return SourceTransportResponse(
        statusCode: 200, headers: const {}, body: Stream.value(utf8.encode('x')));
    },
  );
  final service = CustomSourceService(importSandbox: sandbox);

  expect(await service.importSourceFromUrl('http://source.example/a.js'), isFalse);
  expect(transports, 0);
});

test('remote import revalidates redirect and rejects private target', () async {
  final requests = <Uri>[];
  final sandbox = SourceRequestSandbox(
    policy: SourceRequestPolicy(resolve: (host) async => host == 'public.example'
        ? [InternetAddress('93.184.216.34')]
        : [InternetAddress.loopbackIPv4]),
    transport: (request, cancellation) async {
      requests.add(request.uri);
      return SourceTransportResponse(
        statusCode: 302,
        headers: const {'location': ['https://private.example/source.js']},
        body: const Stream.empty(),
      );
    },
  );
  final service = CustomSourceService(importSandbox: sandbox);

  expect(await service.importSourceFromUrl(
    'https://public.example/source.js'), isFalse);
  expect(requests, [Uri.parse('https://public.example/source.js')]);
});

test('remote response over script limit is rejected and released', () async {
  var closed = 0;
  final sandbox = SourceRequestSandbox(
    policy: SourceRequestPolicy(
      resolve: (_) async => [InternetAddress('93.184.216.34')],
      maximumResponseBytes: CustomSourceService.maximumScriptBytes,
    ),
    transport: (request, cancellation) async => SourceTransportResponse(
      statusCode: 200,
      headers: const {},
      body: Stream.value(List<int>.filled(
        CustomSourceService.maximumScriptBytes + 1, 65)),
      close: () => closed++,
    ),
  );
  final service = CustomSourceService(importSandbox: sandbox);

  expect(await service.importSourceFromUrl(
    'https://public.example/source.js'), isFalse);
  expect(closed, 1);
});
```

- [ ] **Step 2: Run custom-source policy tests and verify red**

Run: `flutter test test/features/custom_source/domain/custom_source_import_policy_test.dart`

Expected: constructor/constants do not compile; current URL import accepts HTTP, follows redirects in Dio without per-hop policy validation, and buffers without a byte cap.

- [ ] **Step 3: Implement bounded imports and provider generation**

Default the sandbox exactly once in the service constructor:

```dart
importSandbox ??= SourceRequestSandbox(
  policy: SourceRequestPolicy(maximumResponseBytes: maximumScriptBytes),
  transport: SourcePinnedTransport(),
  maximumRedirects: 5,
  maximumInFlightBytes: maximumScriptBytes,
  maximumConcurrentResponseBodies: 1,
  maximumConcurrentRequests: 1,
);
```

Call `sandbox.request(Uri.parse(url), {'method': 'GET', 'timeout': 15000})`, require status 200, and decode under `withSourceResponseLease` using `utf8.decode(response.bytes, allowMalformed: false)`. Enclose request plus import in the 15-second total timeout and cancel on timeout. Replace `_prefs?.setString` and migration marker writes with checked `StorageService` calls. In `CustomSourcesNotifier`, increment a generation before initialization/import and publish `_service.sources` only if still current. The screen must use `readFileBytesBounded(... maximumBytes: maximumScriptBytes)` and change validation copy to “请输入有效的 HTTPS 链接”.

- [ ] **Step 4: Run custom-source and source-policy tests and verify green**

Run: `flutter test test/features/custom_source/domain/custom_source_import_policy_test.dart test/core/network/source_request_policy_test.dart test/core/network/source_pinned_transport_test.dart test/features/custom_source/domain/default_source_seed_test.dart`

Expected: all tests pass; policy remains pinned and redirect-aware, all response leases close, and no over-limit local/remote import mutates sources.

### Task 8: Close and Bound Artwork Networking

**Files:**
- Modify: `lib/core/widgets/artwork_image.dart:66-155`
- Modify: `test/core/widgets/artwork_image_test.dart`

**Interfaces:**
- Produces: `abstract interface class ArtworkHttpClient` with `Future<HttpClientRequest> getUrl(Uri)` and `void close({bool force = false})`.
- Produces: `typedef ArtworkClientFactory = ArtworkHttpClient Function()`.
- Produces: `ArtworkBytesLoader({ArtworkClientFactory? createClient, int maximumBytes = 8 * 1024 * 1024, Duration timeout = const Duration(seconds: 12)})` and `Future<Uint8List> load(Uri uri, Map<String,String> headers, void Function(int,int?) onProgress)`.
- Adds optional `ArtworkBytesLoader? loader` to `ArtworkNetworkImage` for deterministic tests; equality/hash remain URL and scale based so injected loaders do not fragment image cache keys.

- [ ] **Step 1: Replace live-CDN tests with deterministic closure/limit tests**

```dart
test('artwork loader closes client when request fails', () async {
  final client = FakeArtworkClient()..requestError = StateError('offline');
  final loader = ArtworkBytesLoader(createClient: () => client);

  await expectLater(
    loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
    throwsStateError,
  );
  expect(client.closeCalls, 1);
});

test('artwork loader rejects declared content length over limit', () async {
  final client = FakeArtworkClient.response(
    statusCode: 200,
    contentLength: 9,
    chunks: const [[1, 2]],
  );
  final loader = ArtworkBytesLoader(
    createClient: () => client,
    maximumBytes: 8,
  );

  await expectLater(
    loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
    throwsA(isA<ArtworkLimitException>()),
  );
  expect(client.closeCalls, 1);
});

test('artwork loader rejects streamed bytes over limit and closes', () async {
  final client = FakeArtworkClient.response(
    statusCode: 200,
    contentLength: -1,
    chunks: const [[1, 2, 3], [4, 5, 6]],
  );
  final loader = ArtworkBytesLoader(
    createClient: () => client,
    maximumBytes: 5,
  );

  await expectLater(
    loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
    throwsA(isA<ArtworkLimitException>()),
  );
  expect(client.closeCalls, 1);
});

test('artwork total timeout closes a stalled client', () async {
  final client = FakeArtworkClient.stalled();
  final loader = ArtworkBytesLoader(
    createClient: () => client,
    timeout: const Duration(milliseconds: 10),
  );

  await expectLater(
    loader.load(Uri.parse(qqUrl), const {}, (_, __) {}),
    throwsA(isA<TimeoutException>()),
  );
  expect(client.closeCalls, 1);
});
```

The fake implements the new interface and returns a real interface-compatible fake request/response stream; retain the existing pure header and URL-normalization tests, but remove both tests that call `music.126.net`.

- [ ] **Step 2: Run artwork tests and verify red**

Run: `flutter test test/core/widgets/artwork_image_test.dart`

Expected: loader/fake interfaces do not compile; current client is not closed on request, status, consolidation, or decode failure and has no byte/deadline cap.

- [ ] **Step 3: Implement bounded loader and wire the image provider**

In `ArtworkBytesLoader.load`, create the client inside the method, set browser UA through the adapter, wrap the whole request/read future in `timeout`, reject `contentLength > maximumBytes` before listening, enforce the same cap while streaming, and place `client.close(force: true)` in the outermost `finally`. `_loadAsync` calls the loader, rejects empty/tiny HTML, creates the immutable buffer, and decodes only after the bounded load succeeds.

- [ ] **Step 4: Run artwork tests and verify green**

Run: `flutter test test/core/widgets/artwork_image_test.dart`

Expected: all deterministic tests pass with exactly one close on success, HTTP error, transport error, over-limit body, and timeout.

### Task 9: Partition Tokens by Origin and Remove Plaintext Fallbacks

**Files:**
- Modify: `lib/core/storage/secure_token_store.dart:1-88`
- Modify: `lib/features/cloud/domain/cloud_api_client.dart:57-497`
- Modify: `lib/features/sync/domain/sync_service.dart:185-243`
- Modify: `test/core/storage/secure_token_store_test.dart`
- Modify: `test/features/cloud/domain/cloud_api_client_test.dart`
- Modify: `test/features/sync/domain/sync_service_test.dart`

**Interfaces:**
- Produces: `String normalizedOrigin(String serviceUrl)` returning lowercase `scheme://host:effectivePort` with default HTTPS port omitted.
- Produces: `String originTokenKey(String namespace, String serviceUrl)` as `'$namespace:${sha256.convert(utf8.encode(normalizedOrigin(serviceUrl)))}'`.
- Cloud keys: origin-scoped `cloud_api_token:<digest>`; sync keys: origin-scoped `sync_token:<digest>`.
- Invariant: changing normalized origin clears active token/username/role in memory and durably removes old-origin metadata before the new base URL is published. A path-only change on the same origin retains the origin token.

- [ ] **Step 1: Add failing origin and no-fallback tests**

```dart
test('cloud tokens are isolated by normalized origin', () async {
  SharedPreferences.setMockInitialValues({});
  final secure = FakeSecureTokenStore();
  final client = CloudApiClient(
    dio: responseDio(data: {
      'token': 'one-token', 'username': 'one', 'role': 'user',
    }),
    secureStore: secure,
  );

  await client.setBaseUrl('https://one.example/api');
  await client.login('one', 'password');
  final oneKey = originTokenKey('cloud_api_token', 'https://one.example/api');
  expect(await secure.read(oneKey), 'one-token');

  await client.setBaseUrl('https://two.example/api');
  expect(client.isLoggedIn, isFalse);
  expect(client.username, isNull);
  expect(await secure.read(oneKey), 'one-token');
  expect(await secure.read(
    originTokenKey('cloud_api_token', 'https://two.example/api')), isNull);
});

test('same-origin path change retains cloud session', () async {
  SharedPreferences.setMockInitialValues({});
  final secure = FakeSecureTokenStore();
  final client = CloudApiClient(
    dio: responseDio(data: {
      'token': 'token', 'username': 'user', 'role': 'user',
    }),
    secureStore: secure,
  );
  await client.setBaseUrl('https://cloud.example/one');
  await client.login('user', 'password');

  await client.setBaseUrl('https://CLOUD.example/two');

  expect(client.isLoggedIn, isTrue);
  expect(client.token, 'token');
});

test('legacy cloud plaintext is deleted when Keychain is unavailable', () async {
  SharedPreferences.setMockInitialValues({
    'cloud_api_base': 'https://cloud.example',
    'cloud_api_token': 'plaintext',
  });
  final secure = FakeSecureTokenStore()..throwOnRead = true;
  final client = CloudApiClient(secureStore: secure);

  await expectLater(client.load(), throwsA(isA<SecureTokenMigrationException>()));

  expect((await SharedPreferences.getInstance())
      .containsKey('cloud_api_token'), isFalse);
  expect(client.isLoggedIn, isFalse);
});
```

Add equivalent sync tests: login at `https://one.example`, assert secure key `originTokenKey('sync_token', ...)`; connect to `https://two.example`, assert no Authorization header is sent; simulate secure read failure with legacy `sync_token`, assert plaintext removal and `loadSavedToken()` throws rather than authenticating.

- [ ] **Step 2: Run credential tests and verify red**

Run: `flutter test test/core/storage/secure_token_store_test.dart test/features/cloud/domain/cloud_api_client_test.dart test/features/sync/domain/sync_service_test.dart`

Expected: `originTokenKey` does not exist; clients use global keys; current migration tests preserve or return plaintext on verification/Keychain failure.

- [ ] **Step 3: Implement origin-derived keys and atomic authority changes**

Use the already-direct `crypto` dependency. Migrate the old unscoped secure/plaintext key only after a valid HTTPS base URL is loaded: write and verify the origin key, delete old secure key and plaintext, then return the origin value. If any secure step fails, delete plaintext, clear in-memory session, and throw `SecureTokenMigrationException`.

For `CloudApiClient.setBaseUrl`, compare `normalizedOrigin(previous)` and `normalizedOrigin(validated)`. On an origin change, increment session revision, snapshot current origin session, clear old active metadata through `_runSessionMutation`, persist the new base through `_runBaseUrlMutation`, and only then publish `_baseUrl`; compensate both snapshots on failure. On same-origin path changes, preserve token and metadata. Apply the same origin key selection to `SyncService.connect`, `_saveToken`, `loadSavedToken`, and `forgetSavedToken`.

- [ ] **Step 4: Run credential tests and verify green**

Run: `flutter test test/core/storage/secure_token_store_test.dart test/features/cloud/domain/cloud_api_client_test.dart test/features/cloud/presentation/cloud_provider_test.dart test/features/sync/domain/sync_service_test.dart`

Expected: all tests pass; no token crosses origins, same-origin path changes retain the session, plaintext is absent after migration attempts, and Keychain failures require sign-in.

### Task 10: Full Batch B Verification

**Files:**
- Verify only; do not modify production or test files during this task unless a preceding red/green cycle exposed a defect in that task's scope.

**Interfaces:**
- Consumes all interfaces and invariants produced by Tasks 1-9.
- Produces no new API.

- [ ] **Step 1: Run every focused Batch B suite together**

Run:

```bash
flutter test \
  test/core/io/bounded_input_test.dart \
  test/core/storage/storage_service_test.dart \
  test/core/storage/secure_token_store_test.dart \
  test/core/network/source_request_policy_test.dart \
  test/core/network/source_pinned_transport_test.dart \
  test/core/widgets/artwork_image_test.dart \
  test/features/download/domain/download_task_test.dart \
  test/features/download/domain/download_service_test.dart \
  test/features/settings/presentation/settings_initialization_test.dart \
  test/features/settings/playlist_backup_compatibility_test.dart \
  test/features/settings/backup_restore_transaction_test.dart \
  test/features/sync/domain/sync_service_test.dart \
  test/features/sync/presentation/sync_provider_test.dart \
  test/features/sync/presentation/cloud_playlist_merge_test.dart \
  test/features/custom_source/domain/custom_source_import_policy_test.dart \
  test/features/cloud/domain/cloud_api_client_test.dart \
  test/features/cloud/presentation/cloud_provider_test.dart
```

Expected: exit code 0 and every listed test passes.

- [ ] **Step 2: Run the complete Flutter regression suite**

Run: `flutter test`

Expected: exit code 0 with zero failures, including the pre-existing queue-move regressions outside Batch B.

- [ ] **Step 3: Run static analysis**

Run: `flutter analyze`

Expected: exit code 0, no diagnostics introduced by Batch B, no unawaited persistence writes in modified files, and no async-context diagnostics in modified import flows.

- [ ] **Step 4: Perform structural security scans**

Run:

```bash
rg -n "readAsString\(|Dio\(\).*import|return legacy|cloud_api_token'|sync_token'" \
  lib/features/settings \
  lib/features/custom_source \
  lib/features/cloud \
  lib/features/sync \
  lib/core/storage \
  lib/core/widgets/artwork_image.dart
```

Expected: no unbounded import `readAsString`; no standalone Dio remote custom-source import; no plaintext `return legacy`; literal legacy token keys appear only in migration constants/tests, while active secure reads/writes use `originTokenKey`.

Run:

```bash
rg -n "File\((task\.savePath|path)|\.delete\(\)" \
  lib/features/download/domain/download_service.dart
```

Expected: every persisted-path read/delete is immediately dominated by `isOwnedDownloadPath` or the private canonical ownership helper; generated attempt paths remain rooted under the canonical download directory.

- [ ] **Step 5: Record the no-Git completion state**

No version-control command or revision identifier is expected. Report the changed file list, focused/full test results, analyzer result, and any Linux-incompatible iOS checks separately; Batch B itself has no Xcode-only verification requirement.

---

## Self-Review Checklist

- Download bad-record isolation: Task 2.
- Canonical download path ownership before read/delete/reconcile: Task 2.
- Completed-file/task-index crash reconciliation: Task 2.
- SharedPreferences `false` as failure: Task 1 and checked use in Tasks 4, 7, and 9.
- Settings and search-history initialization generations: Task 3.
- Fully decoded, bounded, snapshot-backed backup restore with post-durability live publication: Task 4.
- Entire cloud replacement rejected for one malformed song: Task 5.
- Sync session/operation generation, cancellation, connect/send/receive/total deadlines: Task 6.
- Remote custom source through HTTPS pinned transport with redirect validation, time, and byte caps: Task 7.
- Local backup/custom-source byte, nesting, field, playlist, and song caps: Tasks 4 and 7.
- Artwork client closure, response deadline, and byte cap before decode: Task 8.
- Bearer token partition by normalized origin and atomic authority change: Task 9.
- Plaintext token fallback removed; Keychain failure requires reauthentication: Tasks 1 and 9.
- No placeholder implementation steps and no version-control steps: confirmed.
