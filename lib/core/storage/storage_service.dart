import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// 统一的本地持久化服务
class StorageService {
  static StorageService? _instance;
  late final SharedPreferences _prefs;

  StorageService._(this._prefs);

  static Future<StorageService> get instance async {
    if (_instance != null) return _instance!;
    final prefs = await SharedPreferences.getInstance();
    _instance = StorageService._(prefs);
    return _instance!;
  }

  // ---- 基础类型 ----

  String? getString(String key) => _prefs.getString(key);
  Future<bool> setString(String key, String value) => _prefs.setString(key, value);

  int? getInt(String key) => _prefs.getInt(key);
  Future<bool> setInt(String key, int value) => _prefs.setInt(key, value);

  bool? getBool(String key) => _prefs.getBool(key);
  Future<bool> setBool(String key, bool value) => _prefs.setBool(key, value);

  double? getDouble(String key) => _prefs.getDouble(key);
  Future<bool> setDouble(String key, double value) => _prefs.setDouble(key, value);

  // ---- JSON 对象 ----

  Map<String, dynamic>? getJson(String key) {
    final str = _prefs.getString(key);
    if (str == null) return null;
    return json.decode(str) as Map<String, dynamic>;
  }

  Future<bool> setJson(String key, Map<String, dynamic> value) {
    return _prefs.setString(key, json.encode(value));
  }

  // ---- JSON 列表 ----

  List<Map<String, dynamic>> getJsonList(String key) {
    final str = _prefs.getString(key);
    if (str == null) return [];
    final list = json.decode(str) as List;
    return list.cast<Map<String, dynamic>>();
  }

  Future<bool> setJsonList(String key, List<Map<String, dynamic>> value) {
    return _prefs.setString(key, json.encode(value));
  }

  // ---- 字符串列表 ----

  List<String> getStringList(String key) => _prefs.getStringList(key) ?? [];
  Future<bool> setStringList(String key, List<String> value) =>
      _prefs.setStringList(key, value);

  // ---- 删除 ----

  Future<bool> remove(String key) => _prefs.remove(key);
}
