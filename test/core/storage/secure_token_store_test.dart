import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class FakeSecureTokenStore implements SecureTokenStore {
  FakeSecureTokenStore({this.readAfterWrite});

  final String? readAfterWrite;
  final Map<String, String> _values = {};
  final List<String> operations = [];
  var _writes = 0;
  bool throwOnRead = false;

  @override
  Future<String?> read(String key) async {
    if (throwOnRead) throw StateError('keychain unavailable');
    operations.add('read:$key');
    if (_writes > 0 && readAfterWrite != null) {
      return readAfterWrite;
    }
    return _values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    operations.add('write:$key:$value');
    _writes++;
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    operations.add('delete:$key');
    _values.remove(key);
  }

  void seed(String key, String value) {
    _values[key] = value;
  }
}

final class FakeLegacyTokenPreferences implements LegacyTokenPreferences {
  FakeLegacyTokenPreferences(
    this.values, {
    this.markerResult = true,
    this.removeResults = const [true],
  });

  final Map<String, Object> values;
  final bool markerResult;
  final List<bool> removeResults;
  int removeCalls = 0;

  @override
  bool containsKey(String key) => values.containsKey(key);

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<bool> setBool(String key, bool value) async {
    if (markerResult) values[key] = value;
    return markerResult;
  }

  @override
  Future<bool> remove(String key) async {
    final result =
        removeResults[removeCalls.clamp(0, removeResults.length - 1)];
    removeCalls++;
    if (result) values.remove(key);
    return result;
  }
}

Future<SharedPreferences> preferences(
    [Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(Map<String, Object>.from(values));
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('verified migration writes and reads before deleting plaintext',
      () async {
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

  test('failed verification removes plaintext and requires reauthentication',
      () async {
    final secure = FakeSecureTokenStore(readAfterWrite: 'different');
    final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    await expectLater(
      migrator.readAndMigrate('cloud_api_token'),
      throwsA(isA<SecureTokenMigrationException>()),
    );
    expect(prefs.containsKey('cloud_api_token'), isFalse);
    expect(
        prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isNot(true));
  });

  test('Keychain failure removes plaintext and requires reauthentication',
      () async {
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
  });

  test('Keychain failure without plaintext is a migration failure', () async {
    final secure = FakeSecureTokenStore()..throwOnRead = true;
    final prefs = await preferences();
    final migrator = LegacyTokenMigrator(
      secureStore: secure,
      preferences: prefs,
    );

    await expectLater(
      migrator.readAndMigrate('cloud_api_token'),
      throwsA(isA<SecureTokenMigrationException>()),
    );
    expect(prefs.containsKey('cloud_api_token'), isFalse);
  });

  test('retry completes migration when secure already matches plaintext',
      () async {
    final secure = FakeSecureTokenStore();
    secure.seed('cloud_api_token', 'cloud-secret');
    final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('cloud_api_token'), 'cloud-secret');
    expect(secure.operations, ['read:cloud_api_token']);
    expect(prefs.containsKey('cloud_api_token'), isFalse);
    expect(prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isTrue);
  });

  test('mismatched secure token is authoritative and deletes plaintext',
      () async {
    final secure = FakeSecureTokenStore();
    secure.seed('cloud_api_token', 'secure-secret');
    final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('cloud_api_token'), 'secure-secret');
    expect(prefs.containsKey('cloud_api_token'), isFalse);
    expect(secure.operations, ['read:cloud_api_token']);
  });

  test('normalizedOrigin lowercases host and omits default https port', () {
    expect(
      normalizedOrigin('https://Cloud.Example:443/api'),
      'https://cloud.example',
    );
    expect(
      normalizedOrigin('https://cloud.example:8443/path'),
      'https://cloud.example:8443',
    );
  });

  test('originTokenKey namespaces a sha256 of the normalized origin', () {
    final key = originTokenKey('cloud_api_token', 'https://Cloud.Example/api');
    final digest = sha256
        .convert(utf8.encode(normalizedOrigin('https://Cloud.Example/api')))
        .toString();
    expect(key, 'cloud_api_token:$digest');
    expect(
      originTokenKey('cloud_api_token', 'https://cloud.example/other'),
      key,
    );
  });

  test('origin migration rekeys legacy secure value and removes plaintext',
      () async {
    final secure = FakeSecureTokenStore();
    secure.seed('cloud_api_token', 'legacy-secret');
    final prefs = await preferences({'cloud_api_token': 'legacy-secret'});
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);
    final originKey =
        originTokenKey('cloud_api_token', 'https://cloud.example/api');

    expect(
      await migrator.readAndMigrateToOrigin(
        legacyKey: 'cloud_api_token',
        serviceUrl: 'https://cloud.example/api',
      ),
      'legacy-secret',
    );
    expect(await secure.read(originKey), 'legacy-secret');
    expect(await secure.read('cloud_api_token'), isNull);
    expect(prefs.containsKey('cloud_api_token'), isFalse);
  });

  test('empty secure and empty legacy returns null', () async {
    final secure = FakeSecureTokenStore();
    final prefs = await preferences();
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('sync_token'), isNull);
    expect(prefs.getBool('secure_token_migrated_v1_sync_token'), isNot(true));
  });

  test('marker false throws and still attempts plaintext cleanup', () async {
    final secure = FakeSecureTokenStore();
    final prefs = FakeLegacyTokenPreferences(
      {'cloud_api_token': 'plaintext'},
      markerResult: false,
    );
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    await expectLater(
      migrator.readAndMigrate('cloud_api_token'),
      throwsA(isA<SecureTokenMigrationException>()),
    );

    expect(prefs.removeCalls, 1);
    expect(prefs.containsKey('cloud_api_token'), isFalse);
  });

  test('remove false throws and never returns plaintext', () async {
    final secure = FakeSecureTokenStore();
    final prefs = FakeLegacyTokenPreferences(
      {'cloud_api_token': 'plaintext'},
      removeResults: const [false, false],
    );
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    await expectLater(
      migrator.readAndMigrate('cloud_api_token'),
      throwsA(isA<SecureTokenMigrationException>()),
    );

    expect(prefs.removeCalls, 2);
    expect(prefs.containsKey('cloud_api_token'), isTrue);
  });

  test('cleanup false preserves the original Keychain error as cause',
      () async {
    final keychainError = StateError('keychain unavailable');
    final secure = FakeSecureTokenStore()..throwOnRead = true;
    final prefs = FakeLegacyTokenPreferences(
      {'cloud_api_token': 'plaintext'},
      removeResults: const [false],
    );
    final migrator =
        LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    await expectLater(
      migrator.readAndMigrate('cloud_api_token'),
      throwsA(
        isA<SecureTokenMigrationException>().having(
          (error) => error.cause.toString(),
          'cause',
          keychainError.toString(),
        ),
      ),
    );
    expect(prefs.removeCalls, 1);
  });
}
