import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../network/app_http_client.dart';
import '../network/outbound_url.dart';

typedef PlaybackDownloader = Future<void> Function(
  String url,
  String savePath, {
  CancelToken? cancelToken,
});

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

class PlaybackCacheLease {
  final String path;
  final String playableUri;
  final Future<void> Function() _release;
  bool _released = false;

  PlaybackCacheLease._(this.path, this.playableUri, this._release);

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

class PlaybackCacheService {
  static const defaultTtl = Duration(days: 3);
  static const defaultMaxBytes = 1024 * 1024 * 1024;

  final Dio _dio;
  final PlaybackDownloader? _downloader;
  final String? cacheRootOverride;
  final PlaybackCacheIndexStore _indexStore;
  final DateTime Function() _clock;
  final Duration ttl;
  final int maxBytes;

  String? _root;
  Future<void>? _initializing;
  final Map<String, _CacheEntry> _index = {};
  final Map<String, _InflightOperation> _inflight = {};
  final Set<_InflightOperation> _activeOperations = {};
  final Map<String, int> _generations = {};
  final Map<String, int> _leaseCounts = {};
  final Map<String, Future<void>> _commitTails = {};
  Future<void> _pendingIndexWrite = Future<void>.value();
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  PlaybackCacheService({
    Dio? dio,
    PlaybackDownloader? downloader,
    this.cacheRootOverride,
    PlaybackCacheIndexStore? indexStore,
    DateTime Function()? clock,
    this.ttl = defaultTtl,
    this.maxBytes = defaultMaxBytes,
  })  : _dio = dio ?? _createDownloadDio(),
        _downloader = downloader,
        _indexStore = indexStore ?? PrefsPlaybackCacheIndexStore(),
        _clock = clock ?? DateTime.now;

  static Dio _createDownloadDio() {
    return AppHttpClient.create(
      options: BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(minutes: 5),
        followRedirects: true,
        maxRedirects: 5,
        validateStatus: (s) => s != null && s >= 200 && s < 400,
      ),
    );
  }

  static String cacheKey({
    required String platform,
    required String songId,
    required String quality,
  }) {
    return sha1.convert(utf8.encode('$platform|$songId|$quality')).toString();
  }

  static String toPlayableUri(String path) {
    if (path.startsWith('file://')) return path;
    return Uri.file(path).toString();
  }

  static String? cachedPlayableUri(String? path) {
    return path == null ? null : toPlayableUri(path);
  }

  static String extensionFromBytes(List<int> bytes,
      {required String fallback}) {
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
    if (bytes.length >= 8 &&
        bytes[4] == 0x66 &&
        bytes[5] == 0x74 &&
        bytes[6] == 0x79 &&
        bytes[7] == 0x70) {
      return '.m4a';
    }
    if (bytes.length >= 2 && bytes[0] == 0xff) {
      if ((bytes[1] & 0xf6) == 0xf0) return '.aac';
      if ((bytes[1] & 0xe0) == 0xe0) return '.mp3';
    }
    return fallback;
  }

  Future<void> init() {
    if (_disposed) return Future<void>.value();
    if (_initialized) return Future<void>.value();
    return _initializing ??= _initialize();
  }

  Future<void> _initialize() async {
    final requestedRoot = cacheRootOverride ??
        '${(await getApplicationSupportDirectory()).path}/playback_cache';
    final directory = Directory(requestedRoot);
    await directory.create(recursive: true);
    _root = _normalizeAbsolute(await directory.resolveSymbolicLinks());
    await _loadIndex();
    _initialized = true;
    await purgeExpired();
  }

  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    for (final operation in _inflight.values.toList()) {
      operation.token.cancel('disposed');
      _generations[operation.key] = operation.generation + 1;
    }
    _inflight.clear();
    return _disposeFuture = _drainForDispose();
  }

  Future<void> _drainForDispose() async {
    final initialization = _initializing;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {}
    }
    while (_activeOperations.isNotEmpty) {
      final operations = _activeOperations
          .map((operation) => operation.future)
          .toList(growable: false);
      await Future.wait(operations.map((future) async {
        try {
          await future;
        } catch (_) {}
      }));
    }
    while (true) {
      final tail = _pendingIndexWrite;
      try {
        await tail;
      } catch (_) {}
      if (identical(tail, _pendingIndexWrite)) return;
    }
  }

  /// Cancels the shared operation for [key], so every current caller receives
  /// null. Callers do not own cancellation independently.
  void cancelKey(String key) {
    final operation = _inflight[key];
    if (operation == null ||
        operation.token.isCancelled ||
        _generations[key] != operation.generation) {
      return;
    }
    _generations[key] = operation.generation + 1;
    operation.token.cancel('switched track');
    if (identical(_inflight[key], operation)) {
      _inflight.remove(key);
    }
  }

  Future<PlaybackCacheLease?> acquireOrDownload({
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) async {
    if (_disposed) return null;
    final key = cacheKey(
      platform: platform,
      songId: songId,
      quality: quality,
    );
    final path = await _getOrDownloadPath(
      key: key,
      remoteUrl: remoteUrl,
      platform: platform,
      songId: songId,
      quality: quality,
    );
    if (path == null) return null;
    final safePath = await _validatedExistingFile(path);
    final entry = _index[key];
    if (safePath == null ||
        entry == null ||
        entry.path != safePath ||
        (_generations[key] ?? entry.generation) != entry.generation) {
      return null;
    }
    _leaseCounts[key] = (_leaseCounts[key] ?? 0) + 1;
    return PlaybackCacheLease._(
      safePath,
      toPlayableUri(safePath),
      () => _releaseLease(key),
    );
  }

  Future<String?> getOrDownload({
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) {
    if (_disposed) return Future<String?>.value();
    return _getOrDownloadPath(
      key: cacheKey(
        platform: platform,
        songId: songId,
        quality: quality,
      ),
      remoteUrl: remoteUrl,
      platform: platform,
      songId: songId,
      quality: quality,
    );
  }

  Future<String?> _getOrDownloadPath({
    required String key,
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) async {
    if (_disposed) return null;
    await init();
    if (_disposed) return null;
    final hit = await _lookupValid(key);
    if (hit != null) {
      final current = _index[key];
      if (current == null || current.generation != hit.generation) return null;
      final updated = current.copyWith(
        lastAccessedAt: _clock(),
        revision: current.revision + 1,
      );
      _index[key] = updated;
      try {
        await _saveIndex();
      } catch (_) {
        if (_index[key]?.revision == updated.revision) {
          _index[key] = current;
        }
        return null;
      }
      final safePath = await _validatedExistingFile(hit.path);
      if (safePath == null) return null;
      debugPrint('[PlaybackCache] hit key=$key');
      return safePath;
    }

    final existing = _inflight[key];
    if (existing != null) return existing.future;

    final generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    final token = CancelToken();
    final operation = _InflightOperation(key, generation, token);
    _inflight[key] = operation;
    _activeOperations.add(operation);
    operation.future = _finalizeOperation(
      operation,
      remoteUrl,
      platform,
      songId,
      quality,
    );
    return operation.future;
  }

  Future<String?> _finalizeOperation(
    _InflightOperation operation,
    String remoteUrl,
    String platform,
    String songId,
    String quality,
  ) async {
    try {
      final path = await _download(
        operation,
        remoteUrl,
        platform,
        songId,
        quality,
      );
      if (path == null || !_isCurrentOperation(operation)) return null;
      return await _validatedExistingFile(path);
    } catch (error) {
      debugPrint(
          '[PlaybackCache] operation failed key=${operation.key}: $error');
      return null;
    } finally {
      if (identical(_inflight[operation.key], operation)) {
        _inflight.remove(operation.key);
      }
      _activeOperations.remove(operation);
    }
  }

  Future<void> _releaseLease(String key) async {
    final count = _leaseCounts[key] ?? 0;
    if (count <= 1) {
      _leaseCounts.remove(key);
    } else {
      _leaseCounts[key] = count - 1;
    }
  }

  Future<void> purgeExpired() async {
    if (_root == null || _disposed) return;
    final now = _clock();
    final expired = _index.entries
        .where((entry) =>
            !_isProtected(entry.key) &&
            now.difference(entry.value.lastAccessedAt) > ttl)
        .map((entry) => entry.key)
        .toList();
    for (final key in expired) {
      await _removeEntry(key);
    }
    await _enforceSizeCap();
    await _saveIndex();
  }

  Future<void> debugBackdateEntry(String key, {required int daysAgo}) async {
    if (_disposed) return;
    final entry = _index[key];
    if (entry == null) return;
    final backdated = _clock().subtract(Duration(days: daysAgo));
    _index[key] = entry.copyWith(
      createdAt: backdated,
      lastAccessedAt: backdated,
    );
    await _saveIndex();
  }

  Future<_CacheEntry?> _lookupValid(String key) async {
    final entry = _index[key];
    if (entry == null) return null;
    if (_clock().difference(entry.lastAccessedAt) > ttl && !_isProtected(key)) {
      return null;
    }
    if (entry.path.endsWith('.audio')) {
      await _removeEntry(key);
      return null;
    }
    if (await _validatedExistingFile(entry.path) == null) {
      _index.remove(key);
      await _saveIndex();
      return null;
    }
    return entry;
  }

  Future<String?> _download(
    _InflightOperation operation,
    String remoteUrl,
    String platform,
    String songId,
    String quality,
  ) async {
    final key = operation.key;
    final generation = operation.generation;
    final token = operation.token;
    final partPath = '$_root/$key.$generation.part';
    String? stagePath;
    try {
      final safePartPath = await _validatedDestination(partPath);
      if (safePartPath == null || !_isCurrentOperation(operation)) {
        return null;
      }
      final downloadUrl = normalizeOutboundUrl(remoteUrl);
      debugPrint(
          '[PlaybackCache] download key=$key host=${Uri.tryParse(downloadUrl)?.host} path=${Uri.tryParse(downloadUrl)?.path}');
      if (_downloader != null) {
        await _downloader(downloadUrl, safePartPath, cancelToken: token);
      } else {
        await _dio.download(
          downloadUrl,
          safePartPath,
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

      if (!_isCurrentOperation(operation)) {
        await _deleteSafe(partPath);
        return null;
      }
      final safePart = await _validatedExistingFile(partPath);
      if (safePart == null) return null;
      final part = File(safePart);
      final length = await part.length();
      if (length == 0 || length < (_downloader != null ? 16 : 2048)) {
        await _deleteSafe(safePart);
        return null;
      }
      final header = await part.openRead(0, 64).fold<List<int>>(
        <int>[],
        (all, chunk) => all..addAll(chunk),
      );
      if (_looksLikeNonAudio(header)) {
        await _deleteSafe(safePart);
        return null;
      }
      final urlExt = _guessExt(remoteUrl);
      final detectedExt = extensionFromBytes(
        header,
        fallback: urlExt == '.audio' ? _qualityExt(quality) : urlExt,
      );
      if (detectedExt == '.audio') {
        await _deleteSafe(safePart);
        return null;
      }
      stagePath = '$_root/$key.$generation.stage$detectedExt';
      final safeStage = await _validatedDestination(stagePath);
      if (safeStage == null ||
          await _validatedExistingFile(safePart) == null ||
          !_isCurrentOperation(operation)) {
        await _deleteSafe(safePart);
        return null;
      }
      if (await _validatedExistingFile(safePart) == null ||
          await _validatedDestination(safeStage) == null ||
          !_isCurrentOperation(operation)) {
        await _deleteSafe(safePart);
        return null;
      }
      await File(safePart).rename(safeStage);
      final staged = await _validatedExistingFile(safeStage);
      if (staged == null || !_isCurrentOperation(operation)) {
        await _deleteSafe(safeStage);
        return null;
      }
      return await _serializeCommit(
        key,
        () => _commitStaged(
          operation,
          staged,
          detectedExt,
          remoteUrl,
          platform,
          songId,
          quality,
        ),
      );
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) {
        debugPrint('[PlaybackCache] download failed key=$key: $error');
      }
      await _deleteSafe(partPath);
      if (stagePath != null) await _deleteSafe(stagePath);
      return null;
    } catch (error) {
      debugPrint('[PlaybackCache] download error key=$key: $error');
      await _deleteSafe(partPath);
      if (stagePath != null) await _deleteSafe(stagePath);
      return null;
    }
  }

  Future<String?> _commitStaged(
    _InflightOperation operation,
    String staged,
    String extension,
    String remoteUrl,
    String platform,
    String songId,
    String quality,
  ) async {
    final key = operation.key;
    final generation = operation.generation;
    if (!_isCurrentOperation(operation)) {
      await _deleteSafe(staged);
      return null;
    }
    final stablePath = await _validatedDestination('$_root/$key$extension');
    final safeStage = await _validatedExistingFile(staged);
    if (stablePath == null || safeStage == null) return null;

    final previousEntry = _index[key];
    final backupPath = '$_root/$key.$generation.previous$extension';
    String? safeBackup;
    var installed = false;
    try {
      final previousFile = await _validatedExistingFile(stablePath);
      if (previousFile != null) {
        safeBackup = await _validatedDestination(backupPath);
        if (safeBackup == null || !_isCurrentOperation(operation)) return null;
        await File(previousFile).rename(safeBackup);
      }
      if (!_isCurrentOperation(operation) ||
          await _validatedExistingFile(safeStage) == null ||
          await _validatedDestination(stablePath) == null) {
        await _restorePrevious(stablePath, safeBackup);
        return null;
      }
      await File(safeStage).rename(stablePath);
      installed = true;
      final stable = await _validatedExistingFile(stablePath);
      if (stable == null || !_isCurrentOperation(operation)) {
        await _deleteSafe(stablePath);
        await _restorePrevious(stablePath, safeBackup);
        return null;
      }

      final now = _clock();
      _index[key] = _CacheEntry(
        key: key,
        path: stable,
        remoteUrl: remoteUrl,
        createdAt: now,
        lastAccessedAt: now,
        sizeBytes: await File(stable).length(),
        quality: quality,
        platform: platform,
        songId: songId,
        generation: generation,
      );
      await _purgeUnprotectedWithoutSaving();
      try {
        await _saveIndex(allowDuringDispose: true);
      } catch (_) {
        await _rollbackCommit(
          key,
          generation,
          stablePath,
          safeBackup,
          previousEntry,
        );
        return null;
      }
      if (!_isCurrentOperation(operation) ||
          _index[key]?.generation != generation ||
          await _validatedExistingFile(stablePath) == null) {
        await _rollbackCommit(
          key,
          generation,
          stablePath,
          safeBackup,
          previousEntry,
        );
        return null;
      }
      if (safeBackup != null) await _deleteSafe(safeBackup);
      debugPrint('[PlaybackCache] saved key=$key generation=$generation');
      return await _validatedExistingFile(stablePath);
    } catch (_) {
      if (installed) {
        if (_index[key]?.generation == generation) {
          await _rollbackCommit(
            key,
            generation,
            stablePath,
            safeBackup,
            previousEntry,
          );
        } else if (_index[key] == previousEntry) {
          await _deleteSafe(stablePath);
          await _restorePrevious(stablePath, safeBackup);
        }
      } else {
        await _deleteSafe(staged);
        await _restorePrevious(stablePath, safeBackup);
      }
      return null;
    }
  }

  Future<void> _rollbackCommit(
    String key,
    int generation,
    String stablePath,
    String? backupPath,
    _CacheEntry? previousEntry,
  ) async {
    if (_index[key]?.generation != generation) return;
    _index.remove(key);
    await _deleteSafe(stablePath);
    await _restorePrevious(stablePath, backupPath);
    if (previousEntry != null &&
        await _validatedExistingFile(previousEntry.path) != null) {
      _index[key] = previousEntry;
    }
    try {
      await _saveIndex(allowDuringDispose: true);
    } catch (_) {}
  }

  Future<void> _purgeUnprotectedWithoutSaving() async {
    final now = _clock();
    final expired = _index.entries
        .where((entry) =>
            !_isProtected(entry.key) &&
            now.difference(entry.value.lastAccessedAt) > ttl)
        .map((entry) => entry.key)
        .toList();
    for (final key in expired) {
      await _removeEntry(key);
    }
    await _enforceSizeCap();
  }

  Future<void> _restorePrevious(String stablePath, String? backupPath) async {
    if (backupPath == null) return;
    final backup = await _validatedExistingFile(backupPath);
    final destination = await _validatedDestination(stablePath);
    if (backup != null && destination != null) {
      await File(backup).rename(destination);
    }
  }

  Future<T> _serializeCommit<T>(String key, Future<T> Function() action) {
    final previous = _commitTails[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _commitTails[key] = tail;
    tail.whenComplete(() {
      if (identical(_commitTails[key], tail)) _commitTails.remove(key);
    });
    return result;
  }

  bool _isCurrentOperation(_InflightOperation operation) {
    return !_disposed &&
        !operation.token.isCancelled &&
        _generations[operation.key] == operation.generation &&
        identical(_inflight[operation.key], operation);
  }

  bool _isProtected(String key) {
    return _inflight.containsKey(key) || (_leaseCounts[key] ?? 0) > 0;
  }

  Future<String?> _validatedExistingFile(String path) async {
    final lexical = _lexicalChild(path);
    if (lexical == null) return null;
    try {
      if (await FileSystemEntity.type(lexical, followLinks: true) !=
          FileSystemEntityType.file) {
        return null;
      }
      final resolved =
          _normalizeAbsolute(await File(lexical).resolveSymbolicLinks());
      return _isRootChild(resolved) ? resolved : null;
    } on FileSystemException {
      return null;
    }
  }

  Future<String?> _validatedDestination(String path) async {
    final lexical = _lexicalChild(path);
    if (lexical == null) return null;
    final parentPath = File(lexical).parent.path;
    try {
      final resolvedParent = _normalizeAbsolute(
          await Directory(parentPath).resolveSymbolicLinks());
      if (!_isRootOrChild(resolvedParent)) return null;
      final name = lexical.substring(parentPath.length + 1);
      final resolved = _normalizeAbsolute('$resolvedParent/$name');
      return _isRootChild(resolved) ? resolved : null;
    } on FileSystemException {
      return null;
    }
  }

  String? _lexicalChild(String path) {
    if (_root == null || path.isEmpty) return null;
    final normalized = _normalizeAbsolute(path);
    return _isRootChild(normalized) ? normalized : null;
  }

  String _normalizeAbsolute(String path) {
    final absolute = File(path).absolute.path;
    return Uri.file(absolute).normalizePath().toFilePath();
  }

  bool _isRootChild(String path) {
    final root = _root;
    if (root == null) return false;
    final separator = Platform.pathSeparator;
    final prefix = root.endsWith(separator) ? root : '$root$separator';
    return path.startsWith(prefix);
  }

  bool _isRootOrChild(String path) => path == _root || _isRootChild(path);

  Future<void> _deleteSafe(String path) async {
    final safePath = await _validatedExistingFile(path);
    if (safePath == null) return;
    try {
      await File(safePath).delete();
    } on FileSystemException {
      // Cleanup is best-effort; the index is still dropped.
    }
  }

  Future<void> _removeEntry(String key) async {
    if (_isProtected(key)) return;
    final entry = _index.remove(key);
    if (entry != null) await _deleteSafe(entry.path);
  }

  Future<void> _enforceSizeCap() async {
    var total =
        _index.values.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
    if (total <= maxBytes) return;
    final ordered = _index.values.toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    for (final entry in ordered) {
      if (total <= maxBytes) break;
      if (_isProtected(entry.key)) continue;
      total -= entry.sizeBytes;
      await _removeEntry(entry.key);
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
          final entry = _CacheEntry.fromJson(Map<String, dynamic>.from(item));
          if (entry.key.isNotEmpty &&
              await _validatedExistingFile(entry.path) != null) {
            _index[entry.key] = entry;
            _generations[entry.key] = entry.generation;
          }
        }
      }
    } catch (error) {
      debugPrint('[PlaybackCache] index load failed: $error');
    }
  }

  Future<void> _saveIndex({bool allowDuringDispose = false}) {
    if (_disposed && !allowDuringDispose) return Future<void>.value();
    final write = _pendingIndexWrite.then((_) async {
      final snapshot = json.encode(
        _index.values.map((entry) => entry.toJson()).toList(),
      );
      await _indexStore.write(snapshot);
    });
    _pendingIndexWrite = write.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return write;
  }

  String _refererFor(String url, String platform) {
    final value = platform.toLowerCase();
    if (value == 'tx' || url.contains('qq.com') || url.contains('gtimg')) {
      return 'https://y.qq.com/';
    }
    if (value == 'wy' || url.contains('163.com') || url.contains('music.126')) {
      return 'https://music.163.com/';
    }
    if (value == 'kw' || url.contains('kuwo')) return 'https://www.kuwo.cn/';
    return 'https://www.google.com/';
  }

  bool _looksLikeNonAudio(List<int> header) {
    if (header.isEmpty) return true;
    final start =
        String.fromCharCodes(header.take(32)).trimLeft().toLowerCase();
    return start.startsWith('<!doctype') ||
        start.startsWith('<html') ||
        start.startsWith('<?xml') ||
        start.startsWith('{') ||
        start.startsWith('[') ||
        start.startsWith('error');
  }

  String _guessExt(String url) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    for (final ext in [
      '.flac',
      '.m4a',
      '.mp3',
      '.aac',
      '.ogg',
      '.wav',
      '.ape'
    ]) {
      if (path.contains(ext)) return ext;
    }
    return '.audio';
  }

  String _qualityExt(String quality) {
    final value = quality.toLowerCase();
    if (value == 'flac' || value == 'flac24bit' || value == 'hires') {
      return '.flac';
    }
    if (value == 'aac') return '.aac';
    if (value == 'm4a') return '.m4a';
    return '.mp3';
  }
}

class _InflightOperation {
  final String key;
  final int generation;
  final CancelToken token;
  late final Future<String?> future;

  _InflightOperation(this.key, this.generation, this.token);
}

class _CacheEntry {
  final String key;
  final String path;
  final String remoteUrl;
  final DateTime createdAt;
  final DateTime lastAccessedAt;
  final int sizeBytes;
  final String quality;
  final String platform;
  final String songId;
  final int generation;
  final int revision;

  const _CacheEntry({
    required this.key,
    required this.path,
    required this.remoteUrl,
    required this.createdAt,
    required this.lastAccessedAt,
    required this.sizeBytes,
    required this.quality,
    required this.platform,
    required this.songId,
    required this.generation,
    this.revision = 0,
  });

  _CacheEntry copyWith({
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    int? revision,
  }) {
    return _CacheEntry(
      key: key,
      path: path,
      remoteUrl: remoteUrl,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      sizeBytes: sizeBytes,
      quality: quality,
      platform: platform,
      songId: songId,
      generation: generation,
      revision: revision ?? this.revision,
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'path': path,
        'remoteUrl': remoteUrl,
        'createdAt': createdAt.millisecondsSinceEpoch,
        'lastAccessedAt': lastAccessedAt.millisecondsSinceEpoch,
        'sizeBytes': sizeBytes,
        'quality': quality,
        'platform': platform,
        'songId': songId,
        'generation': generation,
      };

  factory _CacheEntry.fromJson(Map<String, dynamic> json) {
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      (json['createdAt'] as num?)?.toInt() ?? 0,
    );
    return _CacheEntry(
      key: json['key']?.toString() ?? '',
      path: json['path']?.toString() ?? '',
      remoteUrl: json['remoteUrl']?.toString() ?? '',
      createdAt: createdAt,
      lastAccessedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['lastAccessedAt'] as num?)?.toInt() ??
            createdAt.millisecondsSinceEpoch,
      ),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      quality: json['quality']?.toString() ?? '',
      platform: json['platform']?.toString() ?? '',
      songId: json['songId']?.toString() ?? '',
      generation: (json['generation'] as num?)?.toInt() ?? 0,
    );
  }
}
