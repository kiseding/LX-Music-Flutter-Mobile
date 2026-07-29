import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/storage/secure_token_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class FakeSecureTokenStore implements SecureTokenStore {
  FakeSecureTokenStore({this.readAfterWrite});

  final String? readAfterWrite;
  final Map<String, String> _values = {};
  final List<String> operations = [];
  var _writes = 0;

  @override
  Future<String?> read(String key) async {
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

Future<SharedPreferences> preferences([Map<String, Object> values = const {}]) async {
  SharedPreferences.setMockInitialValues(Map<String, Object>.from(values));
  return SharedPreferences.getInstance();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  test('retry completes migration when secure already matches plaintext', () async {
    final secure = FakeSecureTokenStore();
    secure.seed('cloud_api_token', 'cloud-secret');
    final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
    final migrator = LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('cloud_api_token'), 'cloud-secret');
    expect(secure.operations, ['read:cloud_api_token']);
    expect(prefs.containsKey('cloud_api_token'), isFalse);
    expect(prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isTrue);
  });

  test('mismatched secure token is authoritative and keeps plaintext', () async {
    final secure = FakeSecureTokenStore();
    secure.seed('cloud_api_token', 'secure-secret');
    final prefs = await preferences({'cloud_api_token': 'cloud-secret'});
    final migrator = LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('cloud_api_token'), 'secure-secret');
    expect(prefs.getString('cloud_api_token'), 'cloud-secret');
    expect(prefs.getBool('secure_token_migrated_v1_cloud_api_token'), isNot(true));
    expect(secure.operations, ['read:cloud_api_token']);
  });

  test('empty secure and empty legacy returns null', () async {
    final secure = FakeSecureTokenStore();
    final prefs = await preferences();
    final migrator = LegacyTokenMigrator(secureStore: secure, preferences: prefs);

    expect(await migrator.readAndMigrate('sync_token'), isNull);
    expect(prefs.getBool('secure_token_migrated_v1_sync_token'), isNot(true));
  });
}
