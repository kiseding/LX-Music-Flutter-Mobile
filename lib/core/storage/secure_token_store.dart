import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
