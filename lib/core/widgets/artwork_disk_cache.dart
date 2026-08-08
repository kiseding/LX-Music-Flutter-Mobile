import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../network/outbound_url.dart';
import '../storage/ttl_cache.dart';
import 'artwork_image.dart';

/// Disk + memory artwork cache with last-access TTL (default 12h).
class ArtworkDiskCache {
  ArtworkDiskCache({
    this.ttl = TtlCache.defaultTtl,
    ArtworkBytesLoader? loader,
    DateTime Function()? clock,
    String? rootOverride,
  })  : _loader = loader ?? ArtworkBytesLoader(),
        _clock = clock ?? DateTime.now,
        _rootOverride = rootOverride,
        _memory = TtlCache<Uint8List>(ttl: ttl, clock: clock);

  final Duration ttl;
  final ArtworkBytesLoader _loader;
  final DateTime Function() _clock;
  final String? _rootOverride;
  final TtlCache<Uint8List> _memory;
  final Map<String, DateTime> _diskTouched = {};
  String? _root;
  Future<void>? _ready;

  static final instance = ArtworkDiskCache();

  Future<void> ensureReady() {
    return _ready ??= _init();
  }

  Future<void> _init() async {
    final base = _rootOverride ??
        '${(await getApplicationSupportDirectory()).path}/artwork_cache';
    final dir = Directory(base);
    await dir.create(recursive: true);
    _root = dir.path;
  }

  String _keyFor(String url) =>
      sha1.convert(utf8.encode(normalizeOutboundUrl(url))).toString();

  Future<File?> fileForUrl(String url) async {
    await ensureReady();
    final root = _root;
    if (root == null) return null;
    final key = _keyFor(url);
    // 用图片扩展名 .jpg：iOS 锁屏/灵动岛的 audio_service 用
    // `UIImage imageWithContentsOfFile` 读取 artCacheFile，该 API 按扩展名
    // 识别图片格式，`.img` 会导致 artImage 为 nil、锁屏封面缺失。
    final file = File('$root/$key.jpg');
    if (!await file.exists()) return null;
    final touched = _diskTouched[key] ?? await file.lastModified();
    if (_clock().difference(touched) > ttl) {
      try {
        await file.delete();
      } catch (_) {}
      _diskTouched.remove(key);
      _memory.remove(key);
      return null;
    }
    _diskTouched[key] = _clock();
    try {
      await file.setLastModified(_clock());
    } catch (_) {}
    return file;
  }

  Future<Uint8List?> bytesForUrl(String url) async {
    final key = _keyFor(url);
    final mem = _memory.get(key);
    if (mem != null) return mem;
    final file = await fileForUrl(url);
    if (file == null) return null;
    try {
      final bytes = await file.readAsBytes();
      _memory.set(key, bytes);
      return bytes;
    } catch (_) {
      return null;
    }
  }

  Future<File?> put(String url, Uint8List bytes) async {
    await ensureReady();
    final root = _root;
    if (root == null) return null;
    final key = _keyFor(url);
    final file = File('$root/$key.jpg');
    await file.writeAsBytes(bytes, flush: true);
    _diskTouched[key] = _clock();
    _memory.set(key, bytes);
    return file;
  }

  Future<File?> ensureLocalFile(String url) async {
    final existing = await fileForUrl(url);
    if (existing != null) return existing;
    try {
      final resolved = normalizeOutboundUrl(url);
      final uri = Uri.parse(resolved);
      final headers = artworkRequestHeaders(resolved);
      final bytes = await _loader.load(uri, headers, (_, __) {});
      if (bytes.isEmpty) return null;
      return put(resolved, bytes);
    } catch (e) {
      debugPrint('[ArtworkDiskCache] download failed: $e');
      return null;
    }
  }

  Future<Uri?> localArtUri(String? remoteUrl) async {
    if (remoteUrl == null || remoteUrl.isEmpty) return null;
    final file = await ensureLocalFile(remoteUrl);
    if (file == null) return Uri.tryParse(normalizeOutboundUrl(remoteUrl));
    return Uri.file(file.path);
  }

  Future<void> clear() async {
    await ensureReady();
    _memory.clear();
    _diskTouched.clear();
    final root = _root;
    if (root == null) return;
    final directory = Directory(root);
    await directory.create(recursive: true);
    await for (final entity in directory.list(followLinks: false)) {
      await entity.delete(recursive: true);
    }
  }
}
