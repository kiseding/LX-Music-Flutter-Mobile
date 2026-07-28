import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/app_http_client.dart';

typedef PlaybackDownloader = Future<void> Function(
  String url,
  String savePath, {
  CancelToken? cancelToken,
});

/// 索引持久化抽象，便于测试注入内存实现。
abstract class PlaybackCacheIndexStore {
  Future<String?> read();
  Future<void> write(String raw);
}

class PrefsPlaybackCacheIndexStore implements PlaybackCacheIndexStore {
  static const key = 'playback_cache_index_v1';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, raw);
  }
}

class MemoryPlaybackCacheIndexStore implements PlaybackCacheIndexStore {
  String? value;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String raw) async {
    value = raw;
  }
}

/// 播放前本地缓存：远程 URL 下载到本地后再播，条目保留 [ttl]。
class PlaybackCacheService {
  static const ttl = Duration(days: 3);
  static const maxBytes = 1024 * 1024 * 1024; // 1GB

  final Dio _dio;
  final PlaybackDownloader? _downloader;
  final String? cacheRootOverride;
  final PlaybackCacheIndexStore _indexStore;

  String? _root;
  final Map<String, _CacheEntry> _index = {};
  final Map<String, Future<String?>> _inflight = {};
  final Map<String, CancelToken> _cancelTokens = {};
  bool _initialized = false;

  PlaybackCacheService({
    Dio? dio,
    PlaybackDownloader? downloader,
    this.cacheRootOverride,
    PlaybackCacheIndexStore? indexStore,
  })  : _dio = dio ?? _createDownloadDio(),
        _downloader = downloader,
        _indexStore = indexStore ?? PrefsPlaybackCacheIndexStore();

  static Dio _createDownloadDio() {
    return AppHttpClient.create(options: BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
    ));
  }

  static String cacheKey({
    required String platform,
    required String songId,
    required String quality,
  }) {
    final raw = '$platform|$songId|$quality';
    return sha1.convert(utf8.encode(raw)).toString();
  }

  static String toPlayableUri(String path) {
    if (path.startsWith('file://')) return path;
    return Uri.file(path).toString();
  }

  static String? cachedPlayableUri(String? path) {
    return path == null ? null : toPlayableUri(path);
  }

  static String extensionFromBytes(List<int> bytes, {required String fallback}) {
    bool starts(List<int> signature) {
      if (bytes.length < signature.length) return false;
      for (var i = 0; i < signature.length; i++) {
        if (bytes[i] != signature[i]) return false;
      }
      return true;
    }

    if (starts(const [0x66, 0x4c, 0x61, 0x43])) return '.flac';
    if (starts(const [0x49, 0x44, 0x33])) return '.mp3';
    if (starts(const [0x4f, 0x67, 0x67, 0x53])) return '.ogg';
    if (starts(const [0x52, 0x49, 0x46, 0x46])) return '.wav';
    if (bytes.length >= 8 && bytes[4] == 0x66 && bytes[5] == 0x74 &&
        bytes[6] == 0x79 && bytes[7] == 0x70) {
      return '.m4a';
    }
    if (bytes.length >= 2 && bytes[0] == 0xff) {
      if ((bytes[1] & 0xf6) == 0xf0) return '.aac';
      if ((bytes[1] & 0xe0) == 0xe0) return '.mp3';
    }
    return fallback;
  }

  Future<void> init() async {
    if (_initialized) return;
    if (cacheRootOverride != null) {
      _root = cacheRootOverride;
    } else {
      final dir = await getApplicationSupportDirectory();
      _root = '${dir.path}/playback_cache';
    }
    await Directory(_root!).create(recursive: true);
    await _loadIndex();
    await purgeExpired();
    _initialized = true;
  }

  Future<void> dispose() async {
    for (final t in _cancelTokens.values) {
      t.cancel('disposed');
    }
    _cancelTokens.clear();
    _inflight.clear();
  }

  void cancelKey(String key) {
    _cancelTokens.remove(key)?.cancel('switched track');
    _inflight.remove(key);
  }

  Future<String?> getOrDownload({
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) async {
    await init();
    final key = cacheKey(
      platform: platform,
      songId: songId,
      quality: quality,
    );

    final hit = _lookupValid(key);
    if (hit != null) {
      debugPrint('[PlaybackCache] hit key=$key');
      return hit.path;
    }

    final existing = _inflight[key];
    if (existing != null) return existing;

    final future = _download(key, remoteUrl, platform, songId, quality);
    _inflight[key] = future;
    try {
      return await future;
    } finally {
      _inflight.remove(key);
    }
  }

  Future<void> purgeExpired() async {
    if (_root == null) return;
    final now = DateTime.now();
    final expired = _index.entries
        .where((e) => now.difference(e.value.createdAt) > ttl)
        .map((e) => e.key)
        .toList();
    for (final key in expired) {
      await _removeEntry(key);
    }
    await _enforceSizeCap();
    await _saveIndex();
  }

  Future<void> debugBackdateEntry(String key, {required int daysAgo}) async {
    final e = _index[key];
    if (e == null) return;
    _index[key] = e.copyWith(
      createdAt: DateTime.now().subtract(Duration(days: daysAgo)),
    );
    await _saveIndex();
  }

  _CacheEntry? _lookupValid(String key) {
    final e = _index[key];
    if (e == null) return null;
    if (DateTime.now().difference(e.createdAt) > ttl) {
      return null;
    }
    if (e.path.endsWith('.audio')) {
      _index.remove(key);
      try {
        File(e.path).deleteSync();
      } catch (_) {}
      return null;
    }
    if (!File(e.path).existsSync()) {
      _index.remove(key);
      return null;
    }
    return e;
  }

  Future<String?> _download(
    String key,
    String remoteUrl,
    String platform,
    String songId,
    String quality,
  ) async {
    final urlExt = _guessExt(remoteUrl);
    final partPath = '$_root/$key.part';
    final token = CancelToken();
    _cancelTokens[key] = token;

    try {
      final downloadUrl = _normalizeMediaUrl(remoteUrl);
      debugPrint(
          '[PlaybackCache] download key=$key host=${Uri.tryParse(downloadUrl)?.host} path=${Uri.tryParse(downloadUrl)?.path}');
      if (_downloader != null) {
        await _downloader(downloadUrl, partPath, cancelToken: token);
      } else {
        await _dio.download(
          downloadUrl,
          partPath,
          cancelToken: token,
          options: Options(
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
              'Referer': _refererFor(downloadUrl, platform),
              'Accept': '*/*',
            },
            responseType: ResponseType.bytes,
            receiveTimeout: const Duration(minutes: 5),
            sendTimeout: const Duration(seconds: 30),
          ),
        );
      }

      final part = File(partPath);
      if (!await part.exists() || await part.length() == 0) {
        debugPrint('[PlaybackCache] empty file key=$key');
        if (await part.exists()) await part.delete();
        return null;
      }
      // 过小通常是错误页/空响应（真实音轨至少数 KB）；测试注入可更小
      final minBytes = _downloader != null ? 16 : 2048;
      if (await part.length() < minBytes) {
        debugPrint(
            '[PlaybackCache] file too small key=$key size=${await part.length()}');
        await part.delete();
        return null;
      }
      final header = await part.openRead(0, 64).fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      if (_looksLikeNonAudio(header)) {
        debugPrint('[PlaybackCache] non-audio body key=$key');
        await part.delete();
        return null;
      }
      final detectedExt = extensionFromBytes(
        header,
        fallback: urlExt == '.audio' ? _qualityExt(quality) : urlExt,
      );
      if (detectedExt == '.audio') {
        debugPrint('[PlaybackCache] unknown audio format key=$key');
        await part.delete();
        return null;
      }
      final path = '$_root/$key$detectedExt';
      final out = File(path);
      if (await out.exists()) await out.delete();
      await part.rename(path);

      final size = await File(path).length();
      _index[key] = _CacheEntry(
        key: key,
        path: path,
        remoteUrl: remoteUrl,
        createdAt: DateTime.now(),
        sizeBytes: size,
        quality: quality,
        platform: platform,
        songId: songId,
      );
      await purgeExpired();
      await _saveIndex();
      debugPrint('[PlaybackCache] saved key=$key size=$size');
      return path;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        debugPrint('[PlaybackCache] cancelled key=$key');
      } else {
        debugPrint('[PlaybackCache] download failed key=$key: $e');
      }
      final part = File(partPath);
      if (await part.exists()) await part.delete();
      return null;
    } catch (e) {
      debugPrint('[PlaybackCache] download error key=$key: $e');
      final part = File(partPath);
      if (await part.exists()) await part.delete();
      return null;
    } finally {
      _cancelTokens.remove(key);
    }
  }

  String _refererFor(String url, String platform) {
    final p = platform.toLowerCase();
    if (p == 'tx' || url.contains('qq.com') || url.contains('gtimg')) {
      return 'https://y.qq.com/';
    }
    if (p == 'wy' || url.contains('163.com') || url.contains('music.126')) {
      return 'https://music.163.com/';
    }
    if (p == 'kw' || url.contains('kuwo')) {
      return 'https://www.kuwo.cn/';
    }
    return 'https://www.google.com/';
  }

  String _normalizeMediaUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    // QQ 音源 CDN 常见 http，优先升 https 提高 iOS 下载成功率
    if (uri.scheme == 'http' &&
        (uri.host.contains('music.tc.qq.com') ||
            uri.host.contains('gtimg.com') ||
            uri.host.contains('qq.com'))) {
      return uri.replace(scheme: 'https').toString();
    }
    return url;
  }

  bool _looksLikeNonAudio(List<int> header) {
    if (header.isEmpty) return true;
    // HTML / JSON / XML 错误页
    final start = String.fromCharCodes(header.take(32)).trimLeft().toLowerCase();
    if (start.startsWith('<!doctype') ||
        start.startsWith('<html') ||
        start.startsWith('<?xml') ||
        start.startsWith('{') ||
        start.startsWith('[') ||
        start.startsWith('error')) {
      return true;
    }
    return false;
  }

  String _guessExt(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final ext in ['.flac', '.m4a', '.mp3', '.aac', '.ogg', '.wav', '.ape']) {
      if (path.contains(ext)) return ext;
    }
    return '.audio';
  }

  String _qualityExt(String quality) {
    final q = quality.toLowerCase();
    if (q == 'flac' || q == 'flac24bit' || q == 'hires') return '.flac';
    if (q == 'aac') return '.aac';
    if (q == 'm4a') return '.m4a';
    return '.mp3';
  }

  Future<void> _removeEntry(String key) async {
    final e = _index.remove(key);
    if (e != null) {
      final f = File(e.path);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
      final part = File('${e.path}.part');
      if (await part.exists()) {
        try {
          await part.delete();
        } catch (_) {}
      }
    }
  }

  Future<void> _enforceSizeCap() async {
    var total = _index.values.fold<int>(0, (s, e) => s + e.sizeBytes);
    if (total <= maxBytes) return;
    final ordered = _index.values.toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    for (final e in ordered) {
      if (total <= maxBytes) break;
      total -= e.sizeBytes;
      await _removeEntry(e.key);
    }
  }

  Future<void> _loadIndex() async {
    _index.clear();
    final raw = await _indexStore.read();
    if (raw == null || raw.isEmpty) return;
    try {
      final list = json.decode(raw) as List;
      for (final item in list) {
        if (item is Map) {
          final e = _CacheEntry.fromJson(Map<String, dynamic>.from(item));
          _index[e.key] = e;
        }
      }
    } catch (e) {
      debugPrint('[PlaybackCache] index load failed: $e');
    }
  }

  Future<void> _saveIndex() async {
    final list = _index.values.map((e) => e.toJson()).toList();
    await _indexStore.write(json.encode(list));
  }
}

class _CacheEntry {
  final String key;
  final String path;
  final String remoteUrl;
  final DateTime createdAt;
  final int sizeBytes;
  final String quality;
  final String platform;
  final String songId;

  const _CacheEntry({
    required this.key,
    required this.path,
    required this.remoteUrl,
    required this.createdAt,
    required this.sizeBytes,
    required this.quality,
    required this.platform,
    required this.songId,
  });

  _CacheEntry copyWith({DateTime? createdAt}) {
    return _CacheEntry(
      key: key,
      path: path,
      remoteUrl: remoteUrl,
      createdAt: createdAt ?? this.createdAt,
      sizeBytes: sizeBytes,
      quality: quality,
      platform: platform,
      songId: songId,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'path': path,
        'remoteUrl': remoteUrl,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'sizeBytes': sizeBytes,
        'quality': quality,
        'platform': platform,
        'songId': songId,
      };

  factory _CacheEntry.fromJson(Map<String, dynamic> j) {
    return _CacheEntry(
      key: j['key']?.toString() ?? '',
      path: j['path']?.toString() ?? '',
      remoteUrl: j['remoteUrl']?.toString() ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (j['createdAt'] as num?)?.toInt() ?? 0,
      ),
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      quality: j['quality']?.toString() ?? '',
      platform: j['platform']?.toString() ?? '',
      songId: j['songId']?.toString() ?? '',
    );
  }
}
