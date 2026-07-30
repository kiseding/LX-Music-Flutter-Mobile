import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../network/app_http_client.dart';
import '../network/outbound_url.dart';
import '../network/play_url_result.dart';
import '../storage/storage_service.dart';

typedef PlaybackDownloader = Future<void> Function(
  String url,
  String savePath, {
  CancelToken? cancelToken,
});
typedef PlaybackCacheKeyHook = Future<void> Function(String key);

abstract class PlaybackCacheIndexStore {
  Future<String?> read();
  Future<void> write(String raw);
}

class PrefsPlaybackCacheIndexStore implements PlaybackCacheIndexStore {
  PrefsPlaybackCacheIndexStore({StorageService? storage}) : _storage = storage;

  static const key = 'playback_cache_index_v1';
  StorageService? _storage;

  Future<StorageService> get _store async =>
      _storage ??= await StorageService.instance;

  @override
  Future<String?> read() async {
    return (await _store).getString(key);
  }

  @override
  Future<void> write(String raw) async {
    await (await _store).setString(key, raw);
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

  bool get isReleased => _released;

  /// Test-only constructor for pure lease-session unit tests.
  @visibleForTesting
  factory PlaybackCacheLease.test(
    String path,
    String playableUri,
    Future<void> Function() release,
  ) {
    return PlaybackCacheLease._(path, playableUri, release);
  }

  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _release();
  }
}

sealed class PlaybackCachePathClassification {
  const PlaybackCachePathClassification();
}

class NonCacheLocalPlaybackPath extends PlaybackCachePathClassification {
  const NonCacheLocalPlaybackPath();
}

class RejectedPlaybackCachePath extends PlaybackCachePathClassification {
  const RejectedPlaybackCachePath();
}

class LeasedPlaybackCachePath extends PlaybackCachePathClassification {
  final PlaybackCacheLease lease;

  const LeasedPlaybackCachePath(this.lease);
}

/// Cache-or-stream outcome for a single playable media URL resolution.
sealed class PlaybackResolution {
  const PlaybackResolution();

  String get playableUrl;
  Map<String, dynamic> get qualityExtras;
  PlaybackCacheLease? get leaseOrNull;
}

final class CachedPlayback extends PlaybackResolution {
  final PlaybackCacheLease lease;
  final Map<String, dynamic> _qualityExtras;

  const CachedPlayback(this.lease, this._qualityExtras);

  @override
  String get playableUrl => lease.playableUri;

  @override
  Map<String, dynamic> get qualityExtras =>
      Map<String, dynamic>.from(_qualityExtras);

  @override
  PlaybackCacheLease? get leaseOrNull => lease;
}

final class StreamingPlayback extends PlaybackResolution {
  final String remoteUrl;
  final Map<String, dynamic> _qualityExtras;

  const StreamingPlayback(this.remoteUrl, this._qualityExtras);

  @override
  String get playableUrl => remoteUrl;

  @override
  Map<String, dynamic> get qualityExtras =>
      Map<String, dynamic>.from(_qualityExtras);

  @override
  PlaybackCacheLease? get leaseOrNull => null;
}

typedef PlaybackLeaseAcquirer = Future<PlaybackCacheLease?> Function({
  required String remoteUrl,
  required String platform,
  required String songId,
  required String quality,
});

/// Resolves quality once, then cache-or-stream with generation-safe cancel.
class PlaybackUrlResolver<T> {
  final Future<PlayUrlResult?> Function(
    T music, {
    required String preferredQuality,
  }) resolvePlayableUrl;
  final PlaybackLeaseAcquirer acquireOrDownload;
  final void Function(String key)? cancelCacheKey;
  final String Function(T music) songIdFor;
  final bool Function(String? url) isPlayableUrl;

  int _generation = 0;
  final Map<int, Set<String>> _generationKeys = {};

  PlaybackUrlResolver({
    required this.resolvePlayableUrl,
    required this.acquireOrDownload,
    required this.songIdFor,
    this.cancelCacheKey,
    this.isPlayableUrl = isPlayableMediaUrl,
  });

  int beginGeneration({bool cancelPrevious = false}) {
    if (cancelPrevious) {
      cancelAllTracked();
    }
    final gen = ++_generation;
    _generationKeys[gen] = <String>{};
    return gen;
  }

  bool isGenerationCurrent(int generation) =>
      _generationKeys.containsKey(generation);

  void noteCacheKey(int generation, String key) {
    final keys = _generationKeys[generation];
    if (keys == null) return;
    keys.add(key);
  }

  void cancelGeneration(int generation) {
    final keys = _generationKeys.remove(generation);
    if (keys == null) return;
    final cancel = cancelCacheKey;
    if (cancel == null) return;
    for (final key in keys) {
      cancel(key);
    }
  }

  /// Cancels every tracked key from generations older than [current].
  void cancelObsoleteGenerations(int current) {
    final stale = _generationKeys.keys
        .where((generation) => generation < current)
        .toList(growable: false);
    for (final generation in stale) {
      cancelGeneration(generation);
    }
  }

  void cancelAllTracked() {
    final generations = _generationKeys.keys.toList(growable: false);
    for (final generation in generations) {
      cancelGeneration(generation);
    }
  }

  Future<PlaybackResolution?> resolve(
    T music, {
    required String preferredQuality,
    int? generation,
    bool exclusive = false,
  }) async {
    final gen = generation ?? beginGeneration(cancelPrevious: exclusive);
    if (!_generationKeys.containsKey(gen) && generation != null) {
      return null;
    }
    if (generation == null && !_generationKeys.containsKey(gen)) {
      _generationKeys[gen] = <String>{};
    }

    final result = await resolvePlayableUrl(
      music,
      preferredQuality: preferredQuality,
    );
    if (!_generationKeys.containsKey(gen)) return null;
    if (result == null || !isPlayableUrl(result.url)) return null;

    final songId = songIdFor(music);
    final qualityKey = result.actualQuality.isNotEmpty
        ? result.actualQuality
        : preferredQuality;
    final key = PlaybackCacheService.cacheKey(
      platform: result.platform,
      songId: songId,
      quality: qualityKey,
    );
    noteCacheKey(gen, key);
    if (!_generationKeys.containsKey(gen)) {
      cancelCacheKey?.call(key);
      return null;
    }

    final lease = await acquireOrDownload(
      remoteUrl: result.url,
      platform: result.platform,
      songId: songId,
      quality: qualityKey,
    );
    if (!_generationKeys.containsKey(gen)) {
      if (lease != null) {
        await lease.release();
      } else {
        cancelCacheKey?.call(key);
      }
      return null;
    }

    // Resolution completed; stop tracking this generation for cancel purposes.
    _generationKeys.remove(gen);

    final qualityExtras = <String, dynamic>{
      'remoteUrl': result.url,
      'actualQuality': result.actualQuality,
      'requestedQuality': result.requestedQuality,
      'platform': result.platform,
      'cacheKey': key,
      'songId': songId,
    };

    if (lease != null) {
      qualityExtras['url'] = lease.playableUri;
      return CachedPlayback(lease, qualityExtras);
    }

    qualityExtras['url'] = result.url;
    return StreamingPlayback(result.url, qualityExtras);
  }
}

/// Owns the currently playing cache lease and any pending replacement lease.
class PlaybackLeaseSession {
  PlaybackCacheLease? _active;
  PlaybackCacheLease? _pending;

  PlaybackCacheLease? get activeLease => _active;
  PlaybackCacheLease? get pendingLease => _pending;

  void holdPending(PlaybackCacheLease? lease) {
    if (identical(_pending, lease)) return;
    final previous = _pending;
    _pending = lease;
    if (previous != null && !identical(previous, _active)) {
      unawaited(previous.release());
    }
  }

  Future<void> discardPending(PlaybackCacheLease? lease) async {
    if (lease == null) return;
    if (!identical(_pending, lease)) {
      if (!identical(lease, _active)) await lease.release();
      return;
    }
    _pending = null;
    if (!identical(lease, _active)) await lease.release();
  }

  Future<void> commitAuthoritative(PlaybackCacheLease? lease) async {
    final previous = _active;
    final pending = _pending;
    if (identical(pending, lease)) {
      _pending = null;
    } else if (lease == null) {
      _pending = null;
      if (pending != null && !identical(pending, previous)) {
        await pending.release();
      }
    }
    if (identical(previous, lease)) {
      _active = lease;
      return;
    }
    _active = lease;
    if (previous != null) await previous.release();
  }

  Future<bool> commitIfGeneration({
    required int generation,
    required int Function() currentGeneration,
    required PlaybackCacheLease? lease,
  }) async {
    if (generation != currentGeneration()) {
      await discardPending(lease);
      if (lease != null &&
          !identical(lease, _pending) &&
          !identical(lease, _active)) {
        await lease.release();
      }
      return false;
    }
    await commitAuthoritative(lease);
    return true;
  }

  Future<void> releaseAll() async {
    final active = _active;
    final pending = _pending;
    _active = null;
    _pending = null;
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> release(PlaybackCacheLease lease) async {
      try {
        await lease.release();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (pending != null && !identical(pending, active)) {
      await release(pending);
    }
    if (active != null) await release(active);
    if (firstError case final error?) {
      Error.throwWithStackTrace(error, firstStackTrace!);
    }
  }
}

class PlaybackCacheService {
  static const defaultTtl = Duration(days: 3);
  static const defaultMaxBytes = 1024 * 1024 * 1024;
  static const _stableAudioExtensions = [
    '.flac',
    '.m4a',
    '.mp3',
    '.aac',
    '.ogg',
    '.wav',
    '.ape',
  ];
  static final _stableCacheName = RegExp(
    r'^([0-9a-f]{40})\.(flac|m4a|mp3|aac|ogg|wav|ape)$',
  );

  final Dio _dio;
  final PlaybackDownloader? _downloader;
  final String? cacheRootOverride;
  final PlaybackCacheIndexStore _indexStore;
  final DateTime Function() _clock;
  final PlaybackCacheKeyHook? _beforeLeaseValidation;
  final PlaybackCacheKeyHook? _beforeExistingLeaseValidation;
  final Duration ttl;
  final int maxBytes;

  String? _root;
  Future<void>? _initializing;
  final Map<String, _CacheEntry> _index = {};
  final Map<String, _InflightOperation> _inflight = {};
  final Set<_InflightOperation> _activeOperations = {};
  final Set<Future<void>> _activeAcquisitions = {};
  final Map<String, int> _generations = {};
  final Map<String, int> _leaseCounts = {};
  final Map<String, Future<void>> _keyTransactionTails = {};
  final Set<String> _preservedRejectedPaths = {};
  final Set<String> _uncertainLoadKeys = {};
  Future<void> _pendingIndexWrite = Future<void>.value();
  bool _loadIntegrity = true;
  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  PlaybackCacheService({
    Dio? dio,
    PlaybackDownloader? downloader,
    this.cacheRootOverride,
    PlaybackCacheIndexStore? indexStore,
    DateTime Function()? clock,
    PlaybackCacheKeyHook? beforeLeaseValidation,
    @visibleForTesting PlaybackCacheKeyHook? beforeExistingLeaseValidation,
    this.ttl = defaultTtl,
    this.maxBytes = defaultMaxBytes,
  })  : _dio = dio ?? _createDownloadDio(),
        _downloader = downloader,
        _indexStore = indexStore ?? PrefsPlaybackCacheIndexStore(),
        _clock = clock ?? DateTime.now,
        _beforeLeaseValidation = beforeLeaseValidation,
        _beforeExistingLeaseValidation = beforeExistingLeaseValidation;

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
    if (_loadIntegrity) await _cleanupUnindexedStableFiles();
    _initialized = true;
    if (_loadIntegrity) await purgeExpired();
  }

  Future<void> dispose() {
    if (_disposeFuture != null) return _disposeFuture!;
    _disposed = true;
    final operations = _inflight.values.toList();
    for (final operation in operations) {
      operation.token.cancel('disposed');
    }
    return _disposeFuture = _drainForDispose(operations);
  }

  Future<void> _drainForDispose(
      List<_InflightOperation> cancelledOperations) async {
    for (final operation in cancelledOperations) {
      await _withKeyTransaction(operation.key, () async {
        if ((_generations[operation.key] ?? 0) <= operation.generation) {
          _generations[operation.key] = operation.generation + 1;
        }
        if (identical(_inflight[operation.key], operation)) {
          _inflight.remove(operation.key);
        }
      });
    }
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
    while (_activeAcquisitions.isNotEmpty) {
      await Future.wait(_activeAcquisitions.toList(growable: false));
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
    operation.token.cancel('switched track');
    unawaited(_withKeyTransaction(key, () async {
      if ((_generations[key] ?? 0) <= operation.generation) {
        _generations[key] = operation.generation + 1;
      }
      if (identical(_inflight[key], operation)) _inflight.remove(key);
    }));
  }

  Future<PlaybackCacheLease?> acquireOrDownload({
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) {
    return _trackAcquisition<PlaybackCacheLease?>(
      () => _acquireOrDownload(
        remoteUrl: remoteUrl,
        platform: platform,
        songId: songId,
        quality: quality,
      ),
      disposedResult: null,
      releaseLate: (lease) => lease?.release() ?? Future<void>.value(),
    );
  }

  Future<T> _trackAcquisition<T>(
    Future<T> Function() operation, {
    required T disposedResult,
    required Future<void> Function(T result) releaseLate,
  }) {
    if (_disposed) return Future<T>.value(disposedResult);
    final acquisition = () async {
      final result = await operation();
      if (!_disposed) return result;
      await releaseLate(result);
      return disposedResult;
    }();
    final tracked = acquisition.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _activeAcquisitions.add(tracked);
    tracked.whenComplete(() => _activeAcquisitions.remove(tracked)).ignore();
    return acquisition;
  }

  Future<PlaybackCacheLease?> _acquireOrDownload({
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) async {
    final key = cacheKey(
      platform: platform,
      songId: songId,
      quality: quality,
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      final path = await _getOrDownloadPath(
        key: key,
        remoteUrl: remoteUrl,
        platform: platform,
        songId: songId,
        quality: quality,
      );
      if (path == null) return null;
      if (_disposed) return null;
      await _beforeLeaseValidation?.call(key);
      if (_disposed) return null;
      final lease = await _withKeyTransaction(
        key,
        () async => _disposed ? null : await _acquireLeaseLocked(key, path),
      );
      if (lease != null) {
        if (_disposed) {
          await lease.release();
          return null;
        }
        return lease;
      }
    }
    return null;
  }

  /// Reacquires a lease for an already indexed exact stable cache file.
  /// This never downloads and rejects paths not owned by this cache instance.
  Future<PlaybackCacheLease?> acquireExisting(String path) {
    return _trackAcquisition<PlaybackCacheLease?>(
      () async {
        final classification = await _classifyExisting(path);
        return switch (classification) {
          LeasedPlaybackCachePath(:final lease) => lease,
          _ => null,
        };
      },
      disposedResult: null,
      releaseLate: (lease) => lease?.release() ?? Future<void>.value(),
    );
  }

  /// Classifies a local file path at this cache's boundary. Cache-shaped files
  /// under the cache root are never treated as ordinary local media.
  Future<PlaybackCachePathClassification> classifyExisting(String path) {
    return _trackAcquisition<PlaybackCachePathClassification>(
      () => _classifyExisting(path),
      disposedResult: const RejectedPlaybackCachePath(),
      releaseLate: (classification) => switch (classification) {
        LeasedPlaybackCachePath(:final lease) => lease.release(),
        _ => Future<void>.value(),
      },
    );
  }

  Future<PlaybackCachePathClassification> _classifyExisting(String path) async {
    if (_disposed) return const RejectedPlaybackCachePath();
    await init();
    if (_disposed) return const RejectedPlaybackCachePath();
    final localPath =
        path.startsWith('file://') ? Uri.tryParse(path)?.toFilePath() : path;
    if (localPath == null) return const NonCacheLocalPlaybackPath();
    final normalized = _normalizeAbsolute(localPath);
    if (!_isRootChild(normalized)) return const NonCacheLocalPlaybackPath();
    final name = File(normalized).uri.pathSegments.last;
    final match = _stableCacheName.firstMatch(name);
    if (match == null) return const NonCacheLocalPlaybackPath();
    final key = match.group(1)!;
    await _beforeExistingLeaseValidation?.call(key);
    if (_disposed) return const RejectedPlaybackCachePath();
    return _withKeyTransaction(
      key,
      () async {
        final lease = await _acquireLeaseLocked(
          key,
          normalized,
          persistAccessedAt: true,
        );
        return lease == null
            ? const RejectedPlaybackCachePath()
            : LeasedPlaybackCachePath(lease);
      },
    );
  }

  Future<PlaybackCacheLease?> _acquireLeaseLocked(
    String key,
    String path, {
    bool persistAccessedAt = false,
  }) async {
    if (_disposed) return null;
    final entry = _index[key];
    final validated = entry == null ? null : await _validatedStableEntry(entry);
    if (_disposed) return null;
    if (validated == null ||
        path != validated.path ||
        (_generations[key] ?? validated.generation) != validated.generation) {
      return null;
    }
    if (persistAccessedAt) {
      final updated = validated.copyWith(
        lastAccessedAt: _clock(),
        revision: validated.revision + 1,
      );
      _index[key] = updated;
      try {
        await _saveIndex();
        if (_disposed) return null;
      } catch (_) {
        if (_index[key]?.revision == updated.revision) {
          _index[key] = validated;
        }
        return null;
      }
    } else {
      _index[key] = validated;
    }
    if (_disposed) return null;
    _leaseCounts[key] = (_leaseCounts[key] ?? 0) + 1;
    return PlaybackCacheLease._(
      validated.path,
      toPlayableUri(validated.path),
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
    final decision = await _withKeyTransaction(
      key,
      () => _getOrStartLocked(
        key: key,
        remoteUrl: remoteUrl,
        platform: platform,
        songId: songId,
        quality: quality,
      ),
    );
    if (decision.path != null) return decision.path;
    return decision.future;
  }

  Future<_PathDecision> _getOrStartLocked({
    required String key,
    required String remoteUrl,
    required String platform,
    required String songId,
    required String quality,
  }) async {
    final hit = await _lookupValidLocked(key);
    if (hit != null) {
      final current = _index[key];
      if (current == null || current.generation != hit.generation) {
        return const _PathDecision();
      }
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
        return const _PathDecision();
      }
      final persisted = _index[key];
      final validated =
          persisted == null ? null : await _validatedStableEntry(persisted);
      if (validated == null) {
        _index.remove(key);
        await _deleteRejectedOwnedStablePath(updated);
        await _saveIndex();
        return const _PathDecision();
      }
      _index[key] = validated;
      debugPrint('[PlaybackCache] hit key=$key');
      return _PathDecision(path: validated.path);
    }

    final existing = _inflight[key];
    if (existing != null) return _PathDecision(future: existing.future);

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
    return _PathDecision(future: operation.future);
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
      if (path == null) return null;
      return await _withKeyTransaction(operation.key, () async {
        if (!_isCurrentOperation(operation)) return null;
        final entry = _index[operation.key];
        final validated =
            entry == null ? null : await _validatedStableEntry(entry);
        return validated?.path == path ? validated!.path : null;
      });
    } catch (error) {
      debugPrint(
          '[PlaybackCache] operation failed key=${operation.key}: $error');
      return null;
    } finally {
      await _withKeyTransaction(operation.key, () async {
        if (identical(_inflight[operation.key], operation)) {
          _inflight.remove(operation.key);
        }
      });
      _activeOperations.remove(operation);
    }
  }

  Future<void> _releaseLease(String key) {
    return _withKeyTransaction(key, () async => _releaseLeaseLocked(key));
  }

  void _releaseLeaseLocked(String key) {
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
    final expired = _index.values.toList();
    for (final candidate in expired) {
      await _withKeyTransaction(candidate.key, () async {
        final current = _index[candidate.key];
        if (current == null ||
            current.generation != candidate.generation ||
            _isProtected(candidate.key) ||
            now.difference(current.lastAccessedAt) <= ttl) {
          return;
        }
        await _removeEntryLocked(candidate.key, expected: current);
      });
    }
    await _cleanupUnindexedStableFiles();
    await _enforceSizeCap();
    await _saveIndex();
  }

  Future<void> debugBackdateEntry(String key, {required int daysAgo}) async {
    if (_disposed) return;
    await _withKeyTransaction(key, () async {
      final entry = _index[key];
      if (entry == null) return;
      final backdated = _clock().subtract(Duration(days: daysAgo));
      _index[key] = entry.copyWith(
        createdAt: backdated,
        lastAccessedAt: backdated,
      );
      await _saveIndex();
    });
  }

  Future<_CacheEntry?> _lookupValidLocked(String key) async {
    final entry = _index[key];
    if (entry == null) return null;
    if (_clock().difference(entry.lastAccessedAt) > ttl && !_isProtected(key)) {
      return null;
    }
    if (entry.path.endsWith('.audio')) {
      await _removeEntryLocked(key, expected: entry);
      return null;
    }
    final validated = await _validatedStableEntry(entry);
    if (validated == null) {
      _index.remove(key);
      await _deleteRejectedOwnedStablePath(entry);
      await _saveIndex();
      return null;
    }
    if (validated.path != entry.path ||
        validated.sizeBytes != entry.sizeBytes) {
      _index[key] = validated;
    }
    return validated;
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
      final committed = await _withKeyTransaction(
        key,
        () => _commitStagedLocked(
          operation,
          staged,
          detectedExt,
          remoteUrl,
          platform,
          songId,
          quality,
        ),
      );
      if (committed != null) {
        await _purgeUnprotectedWithoutSaving();
        await _saveIndex(allowDuringDispose: true);
      }
      return committed;
    } on DioException catch (error) {
      if (!CancelToken.isCancel(error)) {
        debugPrint('[PlaybackCache] download failed key=$key: $error');
      }
      await _withKeyTransaction(
        key,
        () => _cleanupTransientFilesLocked(partPath, stagePath),
      );
      return null;
    } catch (error) {
      debugPrint('[PlaybackCache] download error key=$key: $error');
      await _withKeyTransaction(
        key,
        () => _cleanupTransientFilesLocked(partPath, stagePath),
      );
      return null;
    }
  }

  Future<void> _cleanupTransientFilesLocked(
      String partPath, String? stagePath) async {
    await _deleteSafe(partPath);
    if (stagePath != null) await _deleteSafe(stagePath);
  }

  Future<String?> _commitStagedLocked(
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
    if (stablePath == null || safeStage == null) {
      await _deleteSafe(staged);
      return null;
    }
    if (await FileSystemEntity.type(stablePath, followLinks: false) ==
        FileSystemEntityType.link) {
      await _deleteSafe(staged);
      return null;
    }
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
      final stableType =
          await FileSystemEntity.type(stablePath, followLinks: false);
      if (stableType != FileSystemEntityType.file ||
          !_isCurrentOperation(operation)) {
        await _deleteOwnedStablePath(key, stablePath);
        await _restorePrevious(stablePath, safeBackup);
        return null;
      }

      final now = _clock();
      _index[key] = _CacheEntry(
        key: key,
        path: stablePath,
        remoteUrl: remoteUrl,
        createdAt: now,
        lastAccessedAt: now,
        sizeBytes: await File(stablePath).length(),
        quality: quality,
        platform: platform,
        songId: songId,
        generation: generation,
      );
      try {
        await _saveIndex(allowDuringDispose: true);
      } catch (_) {
        await _rollbackCommitLocked(
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
          await _validatedStableEntry(_index[key]!) == null) {
        await _rollbackCommitLocked(
          key,
          generation,
          stablePath,
          safeBackup,
          previousEntry,
        );
        return null;
      }
      if (safeBackup != null) await _deleteSafe(safeBackup);
      await _deleteStableSiblingsOwnedByLocked(
        key,
        generation,
        except: stablePath,
      );
      debugPrint('[PlaybackCache] saved key=$key generation=$generation');
      return (await _validatedStableEntry(_index[key]!))?.path;
    } catch (_) {
      if (installed) {
        if (_index[key]?.generation == generation) {
          await _rollbackCommitLocked(
            key,
            generation,
            stablePath,
            safeBackup,
            previousEntry,
          );
        } else if (_index[key] == previousEntry) {
          await _deleteOwnedStablePath(key, stablePath);
          await _restorePrevious(stablePath, safeBackup);
        }
      } else {
        await _deleteSafe(staged);
        await _restorePrevious(stablePath, safeBackup);
      }
      return null;
    }
  }

  Future<void> _rollbackCommitLocked(
    String key,
    int generation,
    String stablePath,
    String? backupPath,
    _CacheEntry? previousEntry,
  ) async {
    if (_index[key]?.generation != generation) return;
    _index.remove(key);
    await _deleteOwnedStablePath(key, stablePath);
    await _restorePrevious(stablePath, backupPath);
    if (previousEntry != null) {
      final validatedPrevious = await _validatedStableEntry(previousEntry);
      if (validatedPrevious != null) _index[key] = validatedPrevious;
    }
    try {
      await _saveIndex(allowDuringDispose: true);
    } catch (_) {}
  }

  Future<void> _purgeUnprotectedWithoutSaving() async {
    final now = _clock();
    final expired = _index.values.toList();
    for (final candidate in expired) {
      await _withKeyTransaction(candidate.key, () async {
        final current = _index[candidate.key];
        if (current == null ||
            current.generation != candidate.generation ||
            _isProtected(candidate.key) ||
            now.difference(current.lastAccessedAt) <= ttl) {
          return;
        }
        await _removeEntryLocked(candidate.key, expected: current);
      });
    }
    await _cleanupUnindexedStableFiles();
    await _enforceSizeCap();
  }

  Future<void> _deleteStableSiblingsOwnedByLocked(
    String key,
    int generation, {
    required String except,
  }) async {
    final normalizedExcept = _normalizeAbsolute(except);
    for (final extension in _stableAudioExtensions) {
      if (_index[key]?.generation != generation) return;
      final candidate = _normalizeAbsolute('$_root/$key$extension');
      if (candidate == normalizedExcept) continue;
      await _deleteOwnedStablePath(key, candidate);
    }
  }

  Future<void> _cleanupUnindexedStableFiles() async {
    final root = _root;
    if (root == null || !_loadIntegrity) return;
    await for (final entity in Directory(root).list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      final match = _stableCacheName.firstMatch(name);
      if (match == null) continue;
      final key = match.group(1)!;
      final path = _normalizeAbsolute(entity.path);
      await _withKeyTransaction(key, () async {
        final indexed = _index.values.any(
          (entry) => _normalizeAbsolute(entry.path) == path,
        );
        if (indexed ||
            _preservedRejectedPaths.contains(path) ||
            _uncertainLoadKeys.contains(key) ||
            _isProtected(key)) {
          return;
        }
        await _deleteOwnedStablePath(key, path);
      });
    }
  }

  Future<void> _restorePrevious(String stablePath, String? backupPath) async {
    if (backupPath == null) return;
    final backup = await _validatedExistingFile(backupPath);
    final destination = await _validatedDestination(stablePath);
    if (backup != null && destination != null) {
      await File(backup).rename(destination);
    }
  }

  Future<T> _withKeyTransaction<T>(String key, Future<T> Function() action) {
    final previous = _keyTransactionTails[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final tail =
        result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _keyTransactionTails[key] = tail;
    tail.whenComplete(() {
      if (identical(_keyTransactionTails[key], tail)) {
        _keyTransactionTails.remove(key);
      }
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

  Future<_CacheEntry?> _validatedStableEntry(_CacheEntry entry) async {
    final lexical = _exactStablePath(entry.key, entry.path);
    if (lexical == null) return null;
    try {
      if (await FileSystemEntity.type(lexical, followLinks: false) !=
          FileSystemEntityType.file) {
        return null;
      }
      final length = await File(lexical).length();
      return entry.copyWith(path: lexical, sizeBytes: length);
    } on FileSystemException {
      return null;
    }
  }

  String? _exactStablePath(String key, String path) {
    if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(key)) return null;
    final root = _root;
    if (root == null) return null;
    final lexical = _normalizeAbsolute(path);
    if (File(lexical).parent.path != root) return null;
    final name = File(lexical).uri.pathSegments.last;
    final match = _stableCacheName.firstMatch(name);
    if (match == null || match.group(1) != key) return null;
    return lexical;
  }

  Future<void> _handleRejectedPersistedEntry(_CacheEntry entry) async {
    final exactPath = _exactStablePath(entry.key, entry.path);
    if (exactPath != null) {
      final type = await FileSystemEntity.type(exactPath, followLinks: false);
      if (type == FileSystemEntityType.link) {
        await _deleteLexicalLink(exactPath);
        return;
      }
    }
    final lexical = _lexicalChild(entry.path);
    if (lexical != null) _preservedRejectedPaths.add(lexical);
  }

  Future<void> _deleteRejectedOwnedStablePath(_CacheEntry entry) async {
    final exactPath = _exactStablePath(entry.key, entry.path);
    if (exactPath == null) return;
    final type = await FileSystemEntity.type(exactPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await _deleteLexicalLink(exactPath);
    }
  }

  Future<void> _deleteOwnedStablePath(String key, String path) async {
    final exactPath = _exactStablePath(key, path);
    if (exactPath == null) return;
    final type = await FileSystemEntity.type(exactPath, followLinks: false);
    if (type == FileSystemEntityType.link) {
      await _deleteLexicalLink(exactPath);
      return;
    }
    if (type != FileSystemEntityType.file) return;
    try {
      await File(exactPath).delete();
    } on FileSystemException {
      // Exact stable cleanup is best-effort and never resolves another path.
    }
  }

  Future<void> _deleteLexicalLink(String path) async {
    final lexical = _lexicalChild(path);
    if (lexical == null || File(lexical).parent.path != _root) return;
    try {
      if (await FileSystemEntity.type(lexical, followLinks: false) ==
          FileSystemEntityType.link) {
        await Link(lexical).delete();
      }
    } on FileSystemException {
      // Rejected aliases are best-effort cleanup; targets are never followed.
    }
  }

  Future<String?> _validatedExistingFile(String path) async {
    final lexical = _lexicalChild(path);
    if (lexical == null) return null;
    try {
      if (await FileSystemEntity.type(lexical, followLinks: false) !=
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
      if (await FileSystemEntity.type(resolved, followLinks: false) ==
          FileSystemEntityType.link) {
        return null;
      }
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

  Future<void> _removeEntryLocked(String key, {_CacheEntry? expected}) async {
    if (_isProtected(key)) return;
    if (expected != null && !identical(_index[key], expected)) return;
    final entry = _index.remove(key);
    if (entry != null) await _deleteOwnedStablePath(entry.key, entry.path);
  }

  Future<void> _enforceSizeCap() async {
    final ordered = _index.values.toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    for (final candidate in ordered) {
      await _withKeyTransaction(candidate.key, () async {
        final total =
            _index.values.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
        final current = _index[candidate.key];
        if (total <= maxBytes ||
            current == null ||
            current.generation != candidate.generation ||
            _isProtected(candidate.key)) {
          return;
        }
        await _removeEntryLocked(candidate.key, expected: current);
      });
    }
  }

  Future<void> _loadIndex() async {
    _index.clear();
    _preservedRejectedPaths.clear();
    _uncertainLoadKeys.clear();
    _loadIntegrity = true;
    final raw = await _indexStore.read();
    if (raw == null || raw.isEmpty) return;
    late final List<dynamic> list;
    try {
      final decoded = json.decode(raw);
      if (decoded is! List) throw const FormatException('index is not a list');
      list = decoded;
    } catch (error) {
      _loadIntegrity = false;
      debugPrint('[PlaybackCache] index load failed: $error');
      return;
    }
    for (final item in list) {
      try {
        if (item is! Map) continue;
        final entry = _CacheEntry.fromJson(Map<String, dynamic>.from(item));
        final validated = await _validatedStableEntry(entry);
        if (validated != null) {
          _index[validated.key] = validated;
          _generations[validated.key] = validated.generation;
        } else {
          await _handleRejectedPersistedEntry(entry);
        }
      } catch (error) {
        _protectMalformedRecord(item);
        debugPrint('[PlaybackCache] index record skipped: $error');
      }
    }
    try {
      await _saveIndex();
    } catch (error) {
      debugPrint('[PlaybackCache] index repair failed: $error');
    }
  }

  void _protectMalformedRecord(Object? item) {
    if (item is! Map) return;
    final key = item['key'];
    if (key is String && RegExp(r'^[0-9a-f]{40}$').hasMatch(key)) {
      _uncertainLoadKeys.add(key);
    }
    final path = item['path'];
    if (path is! String) return;
    final lexical = _lexicalChild(path);
    if (lexical == null || File(lexical).parent.path != _root) return;
    final match =
        _stableCacheName.firstMatch(File(lexical).uri.pathSegments.last);
    if (match == null) return;
    _preservedRejectedPaths.add(lexical);
    _uncertainLoadKeys.add(match.group(1)!);
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
    for (final ext in _stableAudioExtensions) {
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

class _PathDecision {
  final String? path;
  final Future<String?>? future;

  const _PathDecision({this.path, this.future});
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
    String? path,
    DateTime? createdAt,
    DateTime? lastAccessedAt,
    int? sizeBytes,
    int? revision,
  }) {
    return _CacheEntry(
      key: key,
      path: path ?? this.path,
      remoteUrl: remoteUrl,
      createdAt: createdAt ?? this.createdAt,
      lastAccessedAt: lastAccessedAt ?? this.lastAccessedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
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
