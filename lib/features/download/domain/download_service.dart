import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../../core/audio/playback_cache_service.dart';
import '../../../core/network/app_http_client.dart';
import '../../../core/network/music_source_service.dart';
import '../../../core/network/outbound_url.dart';
import '../../../core/network/play_url_result.dart';
import '../../../core/storage/storage_service.dart';
import '../../player/domain/music_item.dart';
import 'download_task.dart';

enum DownloadNetwork { wifi, mobile, none }

abstract interface class DownloadTaskStorage {
  List<dynamic> load();
  Future<void> save(List<Map<String, dynamic>> tasks);
  List<Map<String, dynamic>> loadQuarantine();
  Future<void> saveQuarantine(List<Map<String, dynamic>> records);
}

final class StorageDownloadTaskStorage implements DownloadTaskStorage {
  StorageDownloadTaskStorage(this.storage);
  final StorageService storage;

  static const _tasksKey = 'download_tasks';
  static const _quarantineKey = 'download_tasks_quarantine';

  @override
  List<dynamic> load() {
    final str = storage.getString(_tasksKey);
    if (str == null || str.isEmpty) return const [];
    final decoded = json.decode(str);
    if (decoded is! List) return const [];
    return decoded;
  }

  @override
  Future<void> save(List<Map<String, dynamic>> tasks) async {
    await storage.setJsonList(_tasksKey, tasks);
  }

  @override
  List<Map<String, dynamic>> loadQuarantine() {
    final str = storage.getString(_quarantineKey);
    if (str == null || str.isEmpty) return const [];
    final decoded = json.decode(str);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
  }

  @override
  Future<void> saveQuarantine(List<Map<String, dynamic>> records) async {
    await storage.setJsonList(_quarantineKey, records);
  }
}

typedef DownloadExecutor = Future<void> Function(
  DownloadTask task,
  CancelToken cancelToken,
  void Function(double progress) onProgress,
);

final class _DownloadAttempt {
  _DownloadAttempt(this.taskId, this.revision) : cancelToken = CancelToken();

  final String taskId;
  final int revision;
  final CancelToken cancelToken;
  late final Future<void> future;
}

Future<PlayUrlResult?> downloadWithFreshLinkRetry({
  CancelToken? cancelToken,
  required Future<PlayUrlResult?> Function() resolve,
  required Future<void> Function(PlayUrlResult result) download,
}) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    throwIfDownloadCancelled(cancelToken);
    final result = await resolve();
    throwIfDownloadCancelled(cancelToken);
    if (result == null) return null;
    try {
      throwIfDownloadCancelled(cancelToken);
      await download(result);
      throwIfDownloadCancelled(cancelToken);
      return result;
    } on DioException catch (error) {
      throwIfDownloadCancelled(cancelToken);
      final status = error.response?.statusCode;
      final expired = status == 401 ||
          status == 403 ||
          status == 404 ||
          status == 410 ||
          status == 416;
      if (!expired || attempt == 1) rethrow;
      throwIfDownloadCancelled(cancelToken);
    }
  }
  return null;
}

void throwIfDownloadCancelled(CancelToken? cancelToken) {
  final error = cancelToken?.cancelError;
  if (error != null) throw error;
}

Future<PlayUrlResult?> resolveFreshPlayableUrl({
  required MusicItem music,
  required String quality,
  required Future<PlayUrlResult?> Function(
          MusicItem music, String quality, CancelToken? cancelToken)
      resolve,
  CancelToken? cancelToken,
}) async {
  throwIfDownloadCancelled(cancelToken);
  PlayUrlResult? result;
  try {
    result = await resolve(music, quality, cancelToken);
  } catch (_) {
    throwIfDownloadCancelled(cancelToken);
    rethrow;
  }
  throwIfDownloadCancelled(cancelToken);
  return result != null && isPlayableMediaUrl(result.url) ? result : null;
}

DownloadStatus downloadFailureStatus(DownloadStatus current,
    {required bool cancelled}) {
  if (current == DownloadStatus.paused) return current;
  if (cancelled) return DownloadStatus.paused;
  return DownloadStatus.failed;
}

class DownloadService {
  final Dio _dio;
  final List<DownloadTask> _tasks = [];
  final StreamController<List<DownloadTask>> _tasksController =
      StreamController<List<DownloadTask>>.broadcast();
  final Map<String, _DownloadAttempt> _attempts = {};
  final Set<String> _activeTaskIds = <String>{};
  final int _maxConcurrent;
  bool _wifiOnly;
  final DownloadExecutor? _downloader;
  final String Function() _taskIdFactory;
  final Duration _progressPersistenceInterval;
  final Future<DownloadNetwork> Function() _currentNetwork;
  late final StreamSubscription<DownloadNetwork>? _connectivitySubscription;
  Future<void> _persistenceTail = Future<void>.value();
  DateTime _lastProgressPersistence = DateTime.fromMillisecondsSinceEpoch(0);
  int _connectivityEpoch = 0;

  String? _downloadDir;
  String? _resolvedDownloadRoot;
  final Future<Directory> Function()? _downloadDirectory;
  MusicSourceService? _musicSourceService;
  DownloadTaskStorage? _storage;
  bool _initialized = false;
  bool _disposed = false;
  bool _tasksDirtyFromReconcile = false;

  static final RegExp _strictDownloadName = RegExp(
    r'^(.+)-(\d+)\.(part|mp3|m4a|aac|ogg|wav|ape|flac)$',
  );

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  Stream<List<DownloadTask>> get tasksStream => _tasksController.stream;
  int get maxCacheSizeMB => 2048;
  Set<String> get activeTaskIds => Set.unmodifiable(_activeTaskIds);

  bool get wifiOnly => _wifiOnly;

  /// 更新「仅 WiFi 下载」策略，不影响下载服务实例本身。
  void setWifiOnly(bool value) {
    if (_wifiOnly == value) return;
    _wifiOnly = value;
    if (value) {
      _connectivityEpoch++;
      _processQueue();
    } else {
      _processQueue();
    }
  }

  Future<void> get idle async {
    while (_activeTaskIds.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> get persistenceIdle => _persistenceTail;

  DownloadService({
    Dio? dio,
    int maxConcurrent = 3,
    bool wifiOnly = false,
    Stream<DownloadNetwork>? connectivity,
    Future<DownloadNetwork> Function()? currentNetwork,
    String Function()? taskIdFactory,
    DownloadExecutor? downloader,
    DownloadTaskStorage? storage,
    Future<Directory> Function()? downloadDirectory,
    Duration progressPersistenceInterval = const Duration(seconds: 2),
  })  : assert(maxConcurrent > 0),
        _dio = dio ?? _createDownloadDio(),
        _maxConcurrent = maxConcurrent,
        _wifiOnly = wifiOnly,
        _downloader = downloader,
        _storage = storage,
        _downloadDirectory = downloadDirectory,
        _taskIdFactory = taskIdFactory ?? const Uuid().v4,
        _currentNetwork = currentNetwork ?? _platformNetwork,
        _progressPersistenceInterval = progressPersistenceInterval {
    _connectivitySubscription = connectivity?.listen(_onNetworkChanged);
  }

  static Future<DownloadNetwork> _platformNetwork() async {
    final result = await Connectivity().checkConnectivity();
    return _networkFrom(result);
  }

  static DownloadNetwork _networkFrom(List<ConnectivityResult> results) {
    if (results.contains(ConnectivityResult.wifi) ||
        results.contains(ConnectivityResult.ethernet)) {
      return DownloadNetwork.wifi;
    }
    if (results.contains(ConnectivityResult.none)) return DownloadNetwork.none;
    return DownloadNetwork.mobile;
  }

  static Dio _createDownloadDio() {
    return AppHttpClient.create(
        options: BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(minutes: 5),
      followRedirects: true,
      maxRedirects: 5,
      validateStatus: (s) => s != null && s >= 200 && s < 400,
    ));
  }

  void setMusicSourceService(MusicSourceService service) {
    _musicSourceService = service;
  }

  Future<void> init() async {
    if (_initialized) return;
    _storage ??= StorageDownloadTaskStorage(await StorageService.instance);
    await _initDownloadDir();
    await _loadFromStorageIndependently();
    await _reconcileDownloadDirectory();
    await _persistReconciledSnapshotIfChanged();
    _initialized = true;
    _processQueue();
  }

  Future<void> _loadFromStorageIndependently() async {
    final saved = _storage!.load();
    final quarantine = List<Map<String, dynamic>>.from(
      _storage!.loadQuarantine(),
    );
    final valid = <DownloadTask>[];
    var tasksChanged = false;

    for (final raw in saved) {
      try {
        final task = DownloadTask.decodePersisted(raw);
        if (task.savePath != null &&
            task.savePath!.isNotEmpty &&
            !isOwnedDownloadPath(task.savePath!)) {
          quarantine.add(_quarantineEntry(
            raw is Map ? Map<String, dynamic>.from(raw) : raw,
            FormatException('savePath outside download root: ${task.savePath}'),
          ));
          tasksChanged = true;
          continue;
        }
        valid.add(task);
      } catch (error) {
        quarantine.add(_quarantineEntry(
          raw is Map ? Map<String, dynamic>.from(raw) : raw,
          error,
        ));
        tasksChanged = true;
      }
    }

    _tasks
      ..clear()
      ..addAll(valid);
    _emitTasks();

    if (tasksChanged ||
        quarantine.length != _storage!.loadQuarantine().length) {
      await _storage!.saveQuarantine(quarantine);
      await _saveToStorage();
    }
  }

  Map<String, dynamic> _quarantineEntry(Object? raw, Object error) {
    return {
      'record': raw,
      'reason': error.toString(),
      'quarantinedAt': DateTime.now().toUtc().toIso8601String(),
    };
  }

  Future<void> _reconcileDownloadDirectory() async {
    final dirPath = _downloadDir;
    if (dirPath == null) return;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;

    final files = <File>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File) files.add(entity);
    }

    final matchedFinals = <String, List<File>>{};
    final parts = <File>[];
    final orphans = <File>[];

    for (final file in files) {
      final name = file.uri.pathSegments.last;
      final match = _strictDownloadName.firstMatch(name);
      if (match == null) continue;
      if (!isOwnedDownloadPath(file.path)) continue;

      final base = match.group(1)!;
      final revision = int.parse(match.group(2)!);
      final kind = match.group(3)!;

      if (kind == 'part') {
        parts.add(file);
        continue;
      }

      DownloadTask? owner;
      for (final task in _tasks) {
        if (safeDownloadBaseName(task.id) == base &&
            task.attemptRevision == revision) {
          owner = task;
          break;
        }
      }
      if (owner == null) {
        orphans.add(file);
      } else {
        matchedFinals.putIfAbsent(owner.id, () => []).add(file);
      }
    }

    final quarantine = List<Map<String, dynamic>>.from(
      _storage!.loadQuarantine(),
    );
    var quarantineChanged = false;

    for (final entry in matchedFinals.entries) {
      final taskId = entry.key;
      final candidates = entry.value;
      final index = _tasks.indexWhere((t) => t.id == taskId);
      if (index < 0) continue;
      final task = _tasks[index];
      final recoverable = task.status == DownloadStatus.downloading ||
          task.status == DownloadStatus.pending;

      if (!recoverable) continue;

      if (candidates.length > 1) {
        quarantine.add(_quarantineEntry(
          task.toJson(),
          FormatException(
            'multiple final files for ${task.id}@${task.attemptRevision}',
          ),
        ));
        quarantineChanged = true;
        _tasks.removeAt(index);
        _tasksDirtyFromReconcile = true;
        for (final f in candidates) {
          await _safeDelete(f.path);
        }
        continue;
      }

      final nonEmpty = <File>[];
      for (final f in candidates) {
        if (await f.length() > 0) nonEmpty.add(f);
      }

      if (nonEmpty.length == 1) {
        final recovered = nonEmpty.single;
        final length = await recovered.length();
        _tasks[index] = task.copyWith(
          status: DownloadStatus.completed,
          progress: 1.0,
          savePath: recovered.path,
          fileSize: length,
          completedAt: DateTime.now().toUtc(),
          clearErrorMsg: true,
        );
        _tasksDirtyFromReconcile = true;
      }
    }

    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.status == DownloadStatus.downloading) {
        _tasks[i] = t.copyWith(
          status: DownloadStatus.pending,
          progress: 0.0,
          clearSavePath: true,
          clearErrorMsg: true,
        );
        _tasksDirtyFromReconcile = true;
      }
    }

    for (final part in parts) {
      await _safeDelete(part.path);
    }
    for (final orphan in orphans) {
      await _safeDelete(orphan.path);
    }

    if (quarantineChanged) {
      await _storage!.saveQuarantine(quarantine);
    }
    if (_tasksDirtyFromReconcile) {
      _emitTasks();
    }
  }

  Future<void> _persistReconciledSnapshotIfChanged() async {
    if (!_tasksDirtyFromReconcile) return;
    await _saveToStorage();
    _tasksDirtyFromReconcile = false;
  }

  Future<void> _saveToStorage() async {
    _storage ??= StorageDownloadTaskStorage(await StorageService.instance);
    final data = _tasks.map((t) => t.toJson()).toList(growable: false);
    final write =
        _persistenceTail.catchError((_) {}).then((_) => _storage!.save(data));
    _persistenceTail = write.catchError((_) {});
    return write;
  }

  Future<void> _initDownloadDir() async {
    final directoryFactory = _downloadDirectory;
    if (directoryFactory != null) {
      final dir = await directoryFactory();
      await dir.create(recursive: true);
      _downloadDir = dir.path;
    } else {
      final appDir = await getApplicationDocumentsDirectory();
      _downloadDir = '${appDir.path}/downloads';
      await Directory(_downloadDir!).create(recursive: true);
    }
    _resolvedDownloadRoot =
        await Directory(_downloadDir!).resolveSymbolicLinks();
  }

  bool isOwnedDownloadPath(String path) {
    final root = _resolvedDownloadRoot;
    if (root == null) return false;
    final candidate = _resolveOwnershipCandidate(path);
    if (candidate == null) return false;
    return candidate == root ||
        candidate.startsWith('$root${Platform.pathSeparator}');
  }

  String? _resolveOwnershipCandidate(String path) {
    try {
      final absolute = File(path).absolute.path;
      final entity = FileSystemEntity.typeSync(absolute, followLinks: false);
      if (entity != FileSystemEntityType.notFound) {
        return File(absolute).resolveSymbolicLinksSync();
      }

      var current = Directory(absolute).parent;
      final missing = <String>[File(absolute).uri.pathSegments.last];
      while (true) {
        if (current.existsSync()) {
          final resolvedAncestor = current.resolveSymbolicLinksSync();
          final suffix = missing.reversed.join(Platform.pathSeparator);
          return '$resolvedAncestor${Platform.pathSeparator}$suffix';
        }
        final parent = current.parent;
        if (parent.path == current.path) {
          return absolute;
        }
        missing.add(current.uri.pathSegments.isEmpty
            ? current.path
            : current.uri.pathSegments.last);
        current = parent;
      }
    } catch (_) {
      return null;
    }
  }

  Future<void> addTask(MusicItem music, {String? quality}) async {
    if (_tasks.any(
        (t) => t.musicId == music.id && t.status != DownloadStatus.failed)) {
      return;
    }

    if (_downloader == null && _downloadDir == null) {
      await _initDownloadDir();
    }

    final task = DownloadTask(
      id: _taskIdFactory(),
      musicId: music.id,
      name: music.name,
      singer: music.singer,
      url: music.url,
      createdAt: DateTime.now(),
      quality: quality,
      platform: music.platform,
      source: music.source,
      songmid: music.songmid,
      hash: music.hash,
      album: music.album,
      artwork: music.artwork,
      duration: music.duration.inSeconds,
      status: DownloadStatus.pending,
    );

    _tasks.add(task);
    _emitTasks();
    await _saveToStorage();
    _processQueue();
  }

  Future<void> addTasks(List<MusicItem> songs, {String? quality}) async {
    for (final song in songs) {
      await addTask(song, quality: quality);
    }
  }

  Future<void> _runAttempt(DownloadTask task, _DownloadAttempt attempt) async {
    final latest = _taskById(task.id);
    if (!_isCurrent(attempt) || latest == null) return;

    if (_downloader == null && _downloadDir == null) {
      await _initDownloadDir();
    }

    final cancelToken = attempt.cancelToken;
    _updateCurrent(attempt, status: DownloadStatus.downloading, errorMsg: '');

    final partPath = _partPathFor(task.id, attempt.revision);

    try {
      if (_downloader != null) {
        await _downloader(latest, cancelToken, (progress) {
          _updateCurrent(attempt, progress: progress, persistProgress: true);
        });
        if (_isCurrent(attempt) && !cancelToken.isCancelled) {
          _updateCurrent(attempt,
              status: DownloadStatus.completed, progress: 1.0);
        }
        return;
      }
      final music = _musicFromTask(latest);
      // 丢弃任务里缓存的 CDN 直链：签名会过期，重试时复用会 403。
      // 每次下载/重试都向源重新解析（与播放路径一致）。
      final preferred = (latest.quality == null || latest.quality!.isEmpty)
          ? '320k'
          : latest.quality!;
      var completedOk = false;
      final resolved = await downloadWithFreshLinkRetry(
        cancelToken: cancelToken,
        resolve: () => _resolveFreshUrl(
          music,
          preferred,
          cancelToken: cancelToken,
        ),
        download: (resolved) async {
          final downloadUrl = normalizeMediaUrl(resolved.url);
          _updateCurrent(
            attempt,
            url: resolved.url,
            quality: resolved.actualQuality,
            progress: 0.0,
          );
          debugPrint(
            '[DownloadService] fetch q=${resolved.actualQuality} '
            'host=${Uri.tryParse(downloadUrl)?.host}',
          );

          try {
            await _dio.download(
              downloadUrl,
              partPath,
              cancelToken: cancelToken,
              onReceiveProgress: (received, total) {
                if (total > 0) {
                  _updateCurrent(attempt, progress: received / total);
                }
              },
              options: Options(
                headers: _downloadHeaders(downloadUrl, resolved.platform),
                responseType: ResponseType.bytes,
                receiveTimeout: const Duration(minutes: 5),
                sendTimeout: const Duration(seconds: 30),
                followRedirects: true,
                validateStatus: (s) => s != null && s >= 200 && s < 400,
              ),
            );
          } on DioException catch (e) {
            await _safeDeleteOwned(partPath, attempt);
            if (CancelToken.isCancel(e)) rethrow;
            debugPrint(
              '[DownloadService] HTTP fail q=${resolved.actualQuality} '
              'code=${e.response?.statusCode}',
            );
            rethrow;
          }
        },
      );

      if (resolved != null) {
        final downloadUrl = normalizeMediaUrl(resolved.url);
        final after = _taskById(task.id);
        if (!_isCurrent(attempt) ||
            after == null ||
            after.status != DownloadStatus.downloading) {
          await _safeDeleteOwned(partPath, attempt);
          return;
        }

        final part = File(partPath);
        if (!await part.exists() || await part.length() == 0) {
          await _safeDeleteOwned(partPath, attempt);
        } else if (await part.length() < 2048) {
          await _safeDeleteOwned(partPath, attempt);
        } else {
          final header = await part.openRead(0, 64).fold<List<int>>(
            <int>[],
            (all, chunk) => all..addAll(chunk),
          );
          if (_looksLikeNonAudio(header)) {
            await _safeDeleteOwned(partPath, attempt);
          } else {
            final urlExt = _guessExt(downloadUrl);
            final qualityExt = _qualityExt(resolved.actualQuality);
            final detectedExt = PlaybackCacheService.extensionFromBytes(
              header,
              fallback: urlExt == '.audio' ? qualityExt : urlExt,
            );
            if (detectedExt == '.audio') {
              await _safeDeleteOwned(partPath, attempt);
            } else {
              final savePath = _finalPathFor(
                task.id,
                attempt.revision,
                detectedExt,
              );
              final out = File(savePath);
              if (!_isCurrent(attempt)) {
                await _safeDeleteOwned(partPath, attempt);
                return;
              }
              if (await out.exists()) {
                if (!_isCurrent(attempt)) return;
                await _safeDeleteOwned(savePath, attempt);
              }
              if (!_isCurrent(attempt) ||
                  !await _promotePartFile(part, savePath, attempt)) {
                await _safeDeleteOwned(savePath, attempt);
                return;
              }
              final size = await File(savePath).length();
              if (!_isCurrent(attempt)) {
                await _safeDeleteOwned(savePath, attempt);
                return;
              }
              _updateCurrent(
                attempt,
                status: DownloadStatus.completed,
                progress: 1.0,
                savePath: savePath,
                completedAt: DateTime.now(),
                fileSize: size,
                errorMsg: '',
              );
              completedOk = true;
            }
          }
        }
      }

      if (!completedOk &&
          _isCurrent(attempt) &&
          _taskById(task.id)?.status != DownloadStatus.paused &&
          !cancelToken.isCancelled) {
        _updateCurrent(
          attempt,
          status: DownloadStatus.failed,
          errorMsg: '无法获取下载链接',
        );
      }
    } on DioException catch (e) {
      await _safeDeleteOwned(partPath, attempt);
      if (CancelToken.isCancel(e)) {
        final cur = _taskById(task.id);
        if (_isCurrent(attempt) &&
            cur != null &&
            cur.status == DownloadStatus.downloading) {
          _updateCurrent(attempt, status: DownloadStatus.paused);
        }
        return;
      }
      _updateCurrent(
        attempt,
        status: DownloadStatus.failed,
        errorMsg: _dioErrorMessage(e),
      );
    } catch (e) {
      await _safeDeleteOwned(partPath, attempt);
      final current = _taskById(task.id)?.status;
      if (_isCurrent(attempt) && current != null) {
        final status = downloadFailureStatus(
          current,
          cancelled: cancelToken.isCancelled,
        );
        _updateCurrent(
          attempt,
          status: status,
          errorMsg: status == DownloadStatus.failed ? e.toString() : '',
        );
      }
    } finally {
      if (identical(_attempts[task.id], attempt)) {
        _attempts.remove(task.id);
        _activeTaskIds.remove(task.id);
      }
      if (!_disposed) _processQueue();
    }
  }

  /// 始终向音源重新解析；不使用任务/MusicItem 上过期的 CDN 直链。
  Future<PlayUrlResult?> _resolveFreshUrl(
    MusicItem music,
    String quality, {
    CancelToken? cancelToken,
  }) async {
    if (_musicSourceService == null) return null;
    throwIfDownloadCancelled(cancelToken);
    // 仅 file:// 本地路径可直用
    final existing = music.url;
    if (existing != null &&
        (existing.startsWith('file:') || existing.startsWith('/'))) {
      return PlayUrlResult(
        url: existing,
        requestedQuality: quality,
        actualQuality: quality,
        platform: music.platform,
      );
    }
    try {
      // 不带 url，强制源重新签发 CDN 地址
      final clean = MusicItem(
        id: music.id,
        name: music.name,
        singer: music.singer,
        album: music.album,
        duration: music.duration,
        source: music.source,
        platform: music.platform,
        artwork: music.artwork,
        songmid: music.songmid,
        hash: music.hash,
        meta: music.meta,
      );
      return await resolveFreshPlayableUrl(
        music: clean,
        quality: quality,
        cancelToken: cancelToken,
        resolve: (music, quality, token) => _musicSourceService!
            .resolvePlayableUrl(
              music,
              preferredQuality: quality,
              cancelToken: token,
            )
            .timeout(const Duration(seconds: 25)),
      );
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      debugPrint('[DownloadService] resolve q=$quality failed: $e');
    } catch (e) {
      debugPrint('[DownloadService] resolve q=$quality failed: $e');
    }
    return null;
  }

  Map<String, String> _downloadHeaders(String url, String platform) {
    return {
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      'Referer': _refererFor(url, platform),
      'Accept': '*/*',
      // 部分 CDN 对无 Range 的整文件 GET 更友好；明确不要条件缓存
      'Cache-Control': 'no-cache',
      'Pragma': 'no-cache',
    };
  }

  MusicItem _musicFromTask(DownloadTask task) {
    // 故意不带 task.url：CDN 签名链极易过期，下载一律重新解析
    return MusicItem(
      id: task.musicId,
      name: task.name,
      singer: task.singer,
      album: task.album ?? '',
      duration: Duration(seconds: task.duration ?? 0),
      source: task.source ?? '',
      platform: task.platform ?? 'kw',
      artwork: task.artwork,
      songmid: task.songmid,
      hash: task.hash,
    );
  }

  void _processQueue() {
    if (_disposed) return;
    final slots = _maxConcurrent - _activeTaskIds.length;
    if (slots <= 0) return;
    if (_wifiOnly) {
      final epoch = _connectivityEpoch;
      _currentNetwork().then((network) {
        if (!_disposed &&
            _wifiOnly &&
            epoch == _connectivityEpoch &&
            network == DownloadNetwork.wifi) {
          _processQueueAllowed();
        }
      });
      return;
    }
    _processQueueAllowed();
  }

  void _processQueueAllowed() {
    if (_disposed) return;
    final slots = _maxConcurrent - _activeTaskIds.length;
    if (slots <= 0) return;
    final pendingTasks = _tasks
        .where((t) => t.status == DownloadStatus.pending)
        .take(slots)
        .toList();
    for (final task in pendingTasks) {
      if (!_activeTaskIds.add(task.id)) continue;
      final revision = task.attemptRevision + 1;
      _updateTask(task.id, attemptRevision: revision);
      final attempt = _DownloadAttempt(task.id, revision);
      _attempts[task.id] = attempt;
      attempt.future = _runAttempt(_taskById(task.id)!, attempt);
      unawaited(attempt.future);
    }
  }

  void _onNetworkChanged(DownloadNetwork network) {
    if (!_wifiOnly) return;
    if (network == DownloadNetwork.wifi) {
      _processQueue();
      return;
    }
    _connectivityEpoch++;
    for (final attempt in _attempts.values.toList()) {
      _invalidate(attempt, status: DownloadStatus.pending, progress: 0.0);
      attempt.cancelToken.cancel('wifi policy');
    }
  }

  void pauseTask(String taskId) {
    final attempt = _attempts[taskId];
    if (attempt != null) {
      _invalidate(attempt, status: DownloadStatus.paused);
      attempt.cancelToken.cancel('paused');
      return;
    }
    _updateTask(taskId, status: DownloadStatus.paused);
  }

  void resumeTask(String taskId) {
    final task = _taskById(taskId);
    if (task == null) return;
    if (task.status == DownloadStatus.paused ||
        task.status == DownloadStatus.failed) {
      _updateTask(
        taskId,
        status: DownloadStatus.pending,
        progress: 0.0,
        errorMsg: '',
      );
      _processQueue();
    }
  }

  String _partPathFor(String taskId, int revision) =>
      '$_downloadDir/${completedPathName(taskId, revision, '')}.part';

  String _finalPathFor(String taskId, int revision, String extension) =>
      '$_downloadDir/${completedPathName(taskId, revision, extension)}';

  void cancelTask(String taskId) {
    final attempt = _attempts[taskId];
    if (attempt != null) {
      _invalidate(attempt);
      attempt.cancelToken.cancel('cancelled');
    }
    final task = _taskById(taskId);
    if (task != null) {
      if (task.savePath != null) {
        unawaited(_safeDelete(task.savePath!));
      }
    }
    _tasks.removeWhere((t) => t.id == taskId);
    _emitTasks();
    unawaited(_saveToStorage());
  }

  void retryTask(String taskId) {
    final task = _taskById(taskId);
    if (task == null) return;
    final attempt = _attempts[taskId];
    if (attempt != null) {
      _invalidate(attempt);
      attempt.cancelToken.cancel('retry');
    }
    _updateTask(
      taskId,
      status: DownloadStatus.pending,
      progress: 0.0,
      errorMsg: '',
      savePath: '',
    );
    _processQueue();
  }

  Future<void> deleteDownloaded(String taskId) async {
    final task = _taskById(taskId);
    if (task == null) return;
    if (task.savePath != null) {
      await _safeDelete(task.savePath!);
    }
    final attempt = _attempts[taskId];
    if (attempt != null) {
      _invalidate(attempt);
      attempt.cancelToken.cancel('deleted');
    }
    _tasks.removeWhere((t) => t.id == taskId);
    _emitTasks();
    await _saveToStorage();
  }

  DownloadTask? _taskById(String taskId) {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return null;
    return _tasks[index];
  }

  void _updateTask(
    String taskId, {
    DownloadStatus? status,
    double? progress,
    int? speed,
    String? errorMsg,
    String? savePath,
    bool clearSavePath = false,
    bool clearErrorMsg = false,
    DateTime? completedAt,
    int? fileSize,
    String? url,
    String? quality,
    int? attemptRevision,
    bool persistProgress = false,
  }) {
    final index = _tasks.indexWhere((t) => t.id == taskId);
    if (index < 0) return;

    final task = _tasks[index];
    _tasks[index] = task.copyWith(
      status: status,
      progress: progress,
      speed: speed,
      errorMsg: errorMsg,
      clearErrorMsg: clearErrorMsg || errorMsg == '',
      savePath: savePath,
      clearSavePath: clearSavePath || savePath == '',
      completedAt: completedAt,
      fileSize: fileSize,
      url: url,
      quality: quality,
      attemptRevision: attemptRevision,
    );
    _emitTasks();
    final terminal = status == DownloadStatus.completed ||
        status == DownloadStatus.failed ||
        status == DownloadStatus.paused;
    final now = DateTime.now();
    if (!persistProgress ||
        terminal ||
        now.difference(_lastProgressPersistence) >=
            _progressPersistenceInterval) {
      if (persistProgress) _lastProgressPersistence = now;
      unawaited(_saveToStorage());
    }
  }

  bool _isCurrent(_DownloadAttempt attempt) {
    return !_disposed &&
        identical(_attempts[attempt.taskId], attempt) &&
        _taskById(attempt.taskId)?.attemptRevision == attempt.revision;
  }

  void _updateCurrent(
    _DownloadAttempt attempt, {
    DownloadStatus? status,
    double? progress,
    int? speed,
    String? errorMsg,
    String? savePath,
    bool clearSavePath = false,
    bool clearErrorMsg = false,
    DateTime? completedAt,
    int? fileSize,
    String? url,
    String? quality,
    bool persistProgress = false,
  }) {
    if (!_isCurrent(attempt)) return;
    _updateTask(
      attempt.taskId,
      status: status,
      progress: progress,
      speed: speed,
      errorMsg: errorMsg,
      savePath: savePath,
      clearSavePath: clearSavePath,
      clearErrorMsg: clearErrorMsg,
      completedAt: completedAt,
      fileSize: fileSize,
      url: url,
      quality: quality,
      persistProgress: persistProgress,
    );
  }

  void _invalidate(
    _DownloadAttempt attempt, {
    DownloadStatus? status,
    double? progress,
  }) {
    final task = _taskById(attempt.taskId);
    if (task == null || task.attemptRevision != attempt.revision) return;
    _updateTask(
      attempt.taskId,
      attemptRevision: attempt.revision + 1,
      status: status,
      progress: progress,
    );
  }

  void _emitTasks() {
    if (!_disposed && !_tasksController.isClosed) _tasksController.add(_tasks);
  }

  Future<List<DownloadTask>> getDownloadedTasks() async {
    return _tasks.where((t) => t.status == DownloadStatus.completed).toList();
  }

  bool isDownloaded(String musicId) {
    return _tasks.any(
        (t) => t.musicId == musicId && t.status == DownloadStatus.completed);
  }

  String? getDownloadPath(String musicId) {
    try {
      final task = _tasks.firstWhere(
        (t) => t.musicId == musicId && t.status == DownloadStatus.completed,
      );
      final path = task.savePath;
      if (path == null || !isOwnedDownloadPath(path)) return null;
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<int> getCacheSize() async {
    int totalSize = 0;
    for (final task in _tasks) {
      final path = task.savePath;
      if (path == null || !isOwnedDownloadPath(path)) continue;
      final file = File(path);
      if (await file.exists()) {
        totalSize += await file.length();
      }
    }
    return totalSize;
  }

  Future<void> clearCache() async {
    for (final task in _tasks) {
      if (task.savePath != null) {
        await _safeDelete(task.savePath!);
      }
      final attempt = _attempts[task.id];
      if (attempt != null) {
        _invalidate(attempt);
        attempt.cancelToken.cancel('cleared');
      }
    }
    _tasks.clear();
    _emitTasks();
    await _saveToStorage();
  }

  Future<void> clearCacheWithLRU({required int maxBytes}) async {
    final completedTasks = _tasks
        .where((t) => t.status == DownloadStatus.completed)
        .toList()
      ..sort((a, b) => (a.completedAt ?? a.createdAt)
          .compareTo(b.completedAt ?? b.createdAt));

    int currentSize = await getCacheSize();

    for (final task in completedTasks) {
      if (currentSize <= maxBytes) break;
      final path = task.savePath;
      if (path == null || !isOwnedDownloadPath(path)) continue;
      final file = File(path);
      if (await file.exists()) {
        final fileSize = await file.length();
        await _safeDelete(path);
        currentSize -= fileSize;
        _tasks.remove(task);
      }
    }
    _emitTasks();
    await _saveToStorage();
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

  bool _looksLikeNonAudio(List<int> header) {
    if (header.isEmpty) return true;
    final start =
        String.fromCharCodes(header.take(32)).trimLeft().toLowerCase();
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
    final q = quality.toLowerCase();
    if (q == 'flac' || q == 'flac24bit' || q == 'hires') return '.flac';
    if (q == 'aac') return '.aac';
    if (q == 'm4a') return '.m4a';
    return '.mp3';
  }

  String _dioErrorMessage(DioException e) {
    if (e.type == DioExceptionType.connectionTimeout ||
        e.type == DioExceptionType.sendTimeout ||
        e.type == DioExceptionType.receiveTimeout) {
      return '下载超时';
    }
    if (e.type == DioExceptionType.connectionError) {
      return '网络连接失败';
    }
    final code = e.response?.statusCode;
    if (code != null) return 'HTTP $code';
    final msg = e.message;
    if (msg != null && msg.isNotEmpty) return msg;
    return '下载失败';
  }

  Future<void> _safeDelete(String path) async {
    try {
      if (!isOwnedDownloadPath(path)) return;
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _safeDeleteOwned(String path, _DownloadAttempt attempt) async {
    if (!isOwnedDownloadPath(path) || !_isAttemptOwnedPath(path, attempt)) {
      return;
    }
    await _safeDelete(path);
  }

  bool _isAttemptOwnedPath(String path, _DownloadAttempt attempt) {
    final prefix =
        '${safeDownloadBaseName(attempt.taskId)}-${attempt.revision}';
    final name = File(path).uri.pathSegments.last;
    return name == '$prefix.part' ||
        (name.startsWith('$prefix.') && !name.endsWith('.part'));
  }

  /// Promotes only while the owning attempt remains current.
  Future<bool> _promotePartFile(
    File part,
    String savePath,
    _DownloadAttempt attempt,
  ) async {
    if (!_isCurrent(attempt)) return false;
    try {
      await part.rename(savePath);
      return _isCurrent(attempt);
    } on PathNotFoundException catch (e) {
      debugPrint('[DownloadService] rename missing: $e');
    } catch (e) {
      debugPrint('[DownloadService] rename failed, try copy: $e');
    }
    if (!_isCurrent(attempt) || !await part.exists()) {
      if (!_isCurrent(attempt)) return false;
      throw PathNotFoundException(part.path, const OSError(), '临时文件不存在');
    }
    if (!_isCurrent(attempt)) return false;
    await part.copy(savePath);
    if (!_isCurrent(attempt)) return false;
    await _safeDeleteOwned(part.path, attempt);
    return _isCurrent(attempt);
  }

  /// 文件名安全化：去掉路径分隔与异常字符。
  static String safeDownloadBaseName(String musicId) {
    final cleaned = musicId
        .replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^\.|\.$'), '');
    if (cleaned.isEmpty) return 'track';
    return cleaned.length > 120 ? cleaned.substring(0, 120) : cleaned;
  }

  static String completedPathName(
    String taskId,
    int attemptRevision,
    String extension,
  ) =>
      '${safeDownloadBaseName(taskId)}-$attemptRevision$extension';

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final attempts = _attempts.values.toList();
    for (final attempt in attempts) {
      _invalidate(attempt);
      attempt.cancelToken.cancel('disposed');
    }
    await _connectivitySubscription?.cancel();
    await Future.wait(attempts.map((attempt) => attempt.future));
    await _saveToStorage().catchError((_) {});
    await _persistenceTail;
    _dio.close();
    await _tasksController.close();
  }
}
