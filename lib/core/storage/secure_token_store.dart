import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String normalizedOrigin(String serviceUrl) {
  final uri = Uri.parse(serviceUrl.trim());
  final scheme = uri.scheme.toLowerCase();
  final host = uri.host.toLowerCase();
  final port = uri.hasPort ? uri.port : uri.scheme == 'https'
      ? 443
      : uri.scheme == 'http'
          ? 80
          : uri.port;
  final defaultPort =
      scheme == 'https' ? 443 : scheme == 'http' ? 80 : null;
  if (defaultPort != null && port == defaultPort) {
    return '$scheme://$host';
  }
  return '$scheme://$host:$port';
}

String originTokenKey(String namespace, String serviceUrl) {
  final digest =
      sha256.convert(utf8.encode(normalizedOrigin(serviceUrl))).toString();
  return '$namespace:$digest';
}

abstract interface class SecureTokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class LegacyTokenPreferences {
  String? getString(String key);
  bool containsKey(String key);
  Future<bool> setBool(String key, bool value);
  Future<bool> remove(String key);
}

final class SharedPreferencesLegacyTokenPreferences
    implements LegacyTokenPreferences {
  const SharedPreferencesLegacyTokenPreferences(this.preferences);

  final SharedPreferences preferences;

  @override
  String? getString(String key) => preferences.getString(key);

  @override
  bool containsKey(String key) => preferences.containsKey(key);

  @override
  Future<bool> setBool(String key, bool value) =>
      preferences.setBool(key, value);

  @override
  Future<bool> remove(String key) => preferences.remove(key);
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
  Future<void> delete(String key) => _storage.delete(key: key, iOptions: _ios);
}

final class SecureTokenMigrationException implements Exception {
  const SecureTokenMigrationException(this.key, [this.cause]);

  final String key;
  final Object? cause;

  @override
  String toString() =>
      'SecureTokenMigrationException: migration failed for $key';
}

final class LegacyTokenMigrator {
  LegacyTokenMigrator({
    required this.secureStore,
    required Object preferences,
  }) : preferences = preferences is LegacyTokenPreferences
            ? preferences
            : SharedPreferencesLegacyTokenPreferences(
                preferences as SharedPreferences,
              );

  final SecureTokenStore secureStore;
  final LegacyTokenPreferences preferences;

  Future<String?> readAndMigrate(
    String key, {
    bool Function()? canMutate,
    Future<void> Function(Future<void> Function())? mutate,
    Future<void> Function(String token)? discardStaleToken,
  }) async {
    Future<void> runMutation(Future<void> Function() operation) async {
      if (canMutate != null && !canMutate()) return;
      if (mutate == null) {
        await operation();
      } else {
        await mutate(() async {
          if (canMutate != null && !canMutate()) return;
          await operation();
        });
      }
    }

    final legacy = preferences.getString(key);
    try {
      final secure = await secureStore.read(key);
      if (secure != null && secure.isNotEmpty) {
        if (legacy != null && legacy.isNotEmpty) {
          if (canMutate != null && !canMutate()) return secure;
          if (legacy == secure) {
            var marked = false;
            await runMutation(() async {
              marked = await preferences.setBool(
                'secure_token_migrated_v1_$key',
                true,
              );
            });
            if (!marked) throw SecureTokenMigrationException(key);
            if (canMutate != null && !canMutate()) return secure;
          }
          var removed = false;
          await runMutation(() async {
            removed = await preferences.remove(key);
          });
          if (!removed || preferences.containsKey(key)) {
            throw SecureTokenMigrationException(key);
          }
        }
        return secure;
      }
      if (legacy == null || legacy.isEmpty) return null;
      if (canMutate != null && !canMutate()) return null;
      await runMutation(() => secureStore.write(key, legacy));
      if (await secureStore.read(key) != legacy) {
        throw SecureTokenMigrationException(key);
      }
      if (canMutate != null && !canMutate()) {
        await discardStaleToken?.call(legacy);
        return null;
      }
      var marked = false;
      await runMutation(() async {
        marked = await preferences.setBool(
          'secure_token_migrated_v1_$key',
          true,
        );
      });
      if (!marked) throw SecureTokenMigrationException(key);
      if (canMutate != null && !canMutate()) {
        await discardStaleToken?.call(legacy);
        return null;
      }
      var removed = false;
      await runMutation(() async {
        removed = await preferences.remove(key);
      });
      if (!removed || preferences.containsKey(key)) {
        throw SecureTokenMigrationException(key);
      }
      return legacy;
    } catch (error) {
      try {
        await preferences.remove(key);
      } catch (_) {
        // Best-effort plaintext cleanup; original failure is rethrown.
      }
      if (error is SecureTokenMigrationException) rethrow;
      throw SecureTokenMigrationException(key, error);
    }
  }

  /// Migrates unscoped secure/plaintext [legacyKey] into an origin-scoped key.
  ///
  /// Only call after a valid HTTPS service URL is known. Writes and verifies
  /// the origin key, deletes the old secure key and plaintext, then returns
  /// the origin value. Failures delete plaintext and throw.
  Future<String?> readAndMigrateToOrigin({
    required String legacyKey,
    required String serviceUrl,
    bool Function()? canMutate,
    Future<void> Function(Future<void> Function())? mutate,
    Future<void> Function(String token)? discardStaleToken,
  }) async {
    final originKey = originTokenKey(legacyKey, serviceUrl);

    Future<void> runMutation(Future<void> Function() operation) async {
      if (canMutate != null && !canMutate()) return;
      if (mutate == null) {
        await operation();
      } else {
        await mutate(() async {
          if (canMutate != null && !canMutate()) return;
          await operation();
        });
      }
    }

    final legacyPlain = preferences.getString(legacyKey);
    try {
      final originSecure = await secureStore.read(originKey);
      if (originSecure != null && originSecure.isNotEmpty) {
        if (legacyPlain != null && legacyPlain.isNotEmpty) {
          if (canMutate != null && !canMutate()) return originSecure;
          var removed = false;
          await runMutation(() async {
            removed = await preferences.remove(legacyKey);
          });
          if (!removed || preferences.containsKey(legacyKey)) {
            throw SecureTokenMigrationException(originKey);
          }
        }
        final leftoverLegacy = await secureStore.read(legacyKey);
        if (leftoverLegacy != null && leftoverLegacy.isNotEmpty) {
          try {
            await secureStore.delete(legacyKey);
          } catch (_) {}
        }
        return originSecure;
      }

      final legacySecure = await secureStore.read(legacyKey);
      final source = (legacySecure != null && legacySecure.isNotEmpty)
          ? legacySecure
          : (legacyPlain != null && legacyPlain.isNotEmpty ? legacyPlain : null);
      if (source == null) return null;
      if (canMutate != null && !canMutate()) return null;

      await runMutation(() => secureStore.write(originKey, source));
      if (await secureStore.read(originKey) != source) {
        throw SecureTokenMigrationException(originKey);
      }
      if (canMutate != null && !canMutate()) {
        await discardStaleToken?.call(source);
        return null;
      }

      try {
        await runMutation(() => secureStore.delete(legacyKey));
      } catch (_) {}

      if (legacyPlain != null && legacyPlain.isNotEmpty) {
        var marked = false;
        await runMutation(() async {
          marked = await preferences.setBool(
            'secure_token_migrated_v1_$legacyKey',
            true,
          );
        });
        if (!marked) throw SecureTokenMigrationException(originKey);
        if (canMutate != null && !canMutate()) {
          await discardStaleToken?.call(source);
          return null;
        }
        var removed = false;
        await runMutation(() async {
          removed = await preferences.remove(legacyKey);
        });
        if (!removed || preferences.containsKey(legacyKey)) {
          throw SecureTokenMigrationException(originKey);
        }
      }
      return source;
    } catch (error) {
      try {
        await preferences.remove(legacyKey);
      } catch (_) {}
      if (error is SecureTokenMigrationException) rethrow;
      throw SecureTokenMigrationException(originKey, error);
    }
  }
}
