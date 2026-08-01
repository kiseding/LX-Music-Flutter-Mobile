import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/storage/storage_service.dart';

/// 在线歌词翻译 + 磁盘缓存（primuse 风格）。
///
/// - Key：SHA256(targetLang|源文) 截断
/// - positive cache 与 negative cache（24h TTL）分开存，避免对"无法翻译"
///   的语言对反复重试
class LyricsTranslationService {
  LyricsTranslationService(this._storageLoader, {Dio? dio})
      : _dio = dio ?? Dio();

  final StorageLoader _storageLoader;
  final Dio _dio;
  StorageService? _storage;

  Future<StorageService> _storageAsync() async =>
      _storage ??= await _storageLoader();

  static const String _storageKey = 'lyrics_translation_cache_v1';
  static const Duration negativeTtl = Duration(hours: 24);
  static const int maxEntries = 5000;

  final Map<String, String> _cache = {};
  final Map<String, DateTime> _negative = {};
  bool _loaded = false;

  /// 从缓存读取（不触发网络）。
  String? cached(String text, String targetLang) {
    return _cache[_key(text, targetLang)];
  }

  /// 最近 24h 内翻译失败的，跳过不重试。
  bool isMarkedFailed(String text, String targetLang) {
    final when = _negative[_key(text, targetLang)];
    if (when == null) return false;
    if (DateTime.now().difference(when) > negativeTtl) {
      _negative.remove(_key(text, targetLang));
      return false;
    }
    return true;
  }

  /// 翻译单行。命中缓存立即返回；失败进入 negative cache。
  Future<String?> translate(
    String text, {
    String targetLang = 'zh-CN',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final k = _key(trimmed, targetLang);
    final hit = _cache[k];
    if (hit != null) return hit;
    if (isMarkedFailed(trimmed, targetLang)) return null;

    try {
      final response = await _dio.get(
        'https://api.mymemory.translated.net/get',
        queryParameters: {
          'q': trimmed,
          'langpair': 'auto|$targetLang',
        },
      );
      final data = response.data;
      final translated =
          (data is Map && data['responseData'] is Map)
              ? data['responseData']['translatedText']?.toString()
              : null;
      if (translated == null ||
          translated.isEmpty ||
          translated.toLowerCase() == trimmed.toLowerCase()) {
        _negative[k] = DateTime.now();
        _persist();
        return null;
      }
      _cache[k] = translated;
      if (_cache.length > maxEntries) {
        _cache.remove(_cache.keys.first);
      }
      _persist();
      return translated;
    } catch (_) {
      _negative[k] = DateTime.now();
      _persist();
      return null;
    }
  }

  String _key(String text, String targetLang) {
    final digest = sha256.convert(utf8.encode('$targetLang|$text'));
    return digest.toString().substring(0, 16);
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final storage = await _storageAsync();
      final list = storage.getJsonList(_storageKey);
      for (final item in list) {
        final k = item['k']?.toString();
        if (k == null) continue;
        final value = item['v']?.toString();
        if (value != null) {
          _cache[k] = value;
        } else if (item['failAt'] is num) {
          _negative[k] =
              DateTime.fromMillisecondsSinceEpoch((item['failAt'] as num).toInt());
        }
      }
    } catch (_) {
      // 忽略损坏的缓存
    }
  }

  Future<void> _persist() async {
    final list = <Map<String, dynamic>>[
      for (final e in _cache.entries)
        {'k': e.key, 'v': e.value},
      for (final e in _negative.entries)
        {'k': e.key, 'failAt': e.value.millisecondsSinceEpoch},
    ];
    await (await _storageAsync()).setJsonList(_storageKey, list);
  }
}
