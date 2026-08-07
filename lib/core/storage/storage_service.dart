import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef PreferenceWriteOverride = Future<bool> Function(
  String operation,
  String key,
  Object? value,
);

typedef StorageLoader = Future<StorageService> Function();

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

/// 统一的本地持久化服务
class StorageService {
  static StorageService? _instance;
  final SharedPreferences _prefs;
  final PreferenceWriteOverride? _writeOverride;

  StorageService._(this._prefs, [this._writeOverride]);

  @visibleForTesting
  StorageService.forTesting(
    SharedPreferences preferences, {
    PreferenceWriteOverride? writeOverride,
  }) : this._(preferences, writeOverride);

  static Future<StorageService> get instance async {
    if (_instance != null) return _instance!;
    final prefs = await SharedPreferences.getInstance();
    _instance = StorageService._(prefs);
    return _instance!;
  }

  // ---- 基础类型 ----

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

  String? getString(String key) => _prefs.getString(key);
  Future<bool> setString(String key, String value) =>
      _checked('setString', key, value, () => _prefs.setString(key, value));

  int? getInt(String key) => _prefs.getInt(key);
  Future<bool> setInt(String key, int value) =>
      _checked('setInt', key, value, () => _prefs.setInt(key, value));

  bool? getBool(String key) => _prefs.getBool(key);
  Future<bool> setBool(String key, bool value) =>
      _checked('setBool', key, value, () => _prefs.setBool(key, value));

  double? getDouble(String key) => _prefs.getDouble(key);
  Future<bool> setDouble(String key, double value) =>
      _checked('setDouble', key, value, () => _prefs.setDouble(key, value));

  // ---- JSON 对象 ----

  Map<String, dynamic>? getJson(String key) {
    final str = _prefs.getString(key);
    if (str == null) return null;
    return json.decode(str) as Map<String, dynamic>;
  }

  Future<bool> setJson(String key, Map<String, dynamic> value) {
    return setString(key, json.encode(value));
  }

  // ---- JSON 列表 ----

  List<Map<String, dynamic>> getJsonList(String key) {
    final str = _prefs.getString(key);
    if (str == null) return [];
    final list = json.decode(str) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<bool> setJsonList(String key, List<Map<String, dynamic>> value) {
    return setString(key, json.encode(value));
  }

  // ---- 字符串列表 ----

  List<String> getStringList(String key) => _prefs.getStringList(key) ?? [];
  Future<bool> setStringList(String key, List<String> value) => _checked(
      'setStringList', key, value, () => _prefs.setStringList(key, value));

  // ---- 删除 ----

  Future<bool> remove(String key) =>
      _checked('remove', key, null, () => _prefs.remove(key));

  PreferenceSnapshot snapshot(Set<String> keys) => PreferenceSnapshot({
        for (final key in keys)
          key: _prefs.containsKey(key) ? _prefs.get(key) : null,
      });

  Future<void> restore(PreferenceSnapshot snapshot) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final entry in snapshot.values.entries) {
      try {
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
          throw StateError(
            'Unsupported preference snapshot value for ${entry.key}',
          );
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<Never> restorePreserving(
    PreferenceSnapshot snapshot,
    Object original,
    StackTrace originalStackTrace, {
    void Function(Object error, StackTrace stackTrace)? onRollbackError,
  }) async {
    try {
      await restore(snapshot);
    } catch (rollbackError, rollbackStackTrace) {
      onRollbackError?.call(rollbackError, rollbackStackTrace);
      debugPrint(
        'Preference rollback failed: $rollbackError\n$rollbackStackTrace',
      );
    }
    Error.throwWithStackTrace(original, originalStackTrace);
  }
}
