import 'dart:async';
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
  List<Map<String, dynamic>> load();
  Future<void> save(List<Map<String, dynamic>> tasks);
}

final class _StorageAdapter implements DownloadTaskStorage {
  _StorageAdapter(this.storage);
  final StorageService storage;

  @override
  List<Map<String, dynamic>> load() => storage.getJsonList('download_tasks');

  @override
  Future<void> save(List<Map<String, dynamic>> tasks) async {
    await storage.setJsonList('download_tasks', tasks);
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
  final bool _wifiOnly;
  final DownloadExecutor? _downloader;
  final String Function() _taskIdFactory;
  final Duration _progressPersistenceInterval;
  final Future<DownloadNetwork> Function() _currentNetwork;
  late final StreamSubscription<DownloadNetwork>? _connectivitySubscription;
  Future<void> _persistenceTail = Future<void>.value();
  DateTime _lastProgressPersistence = DateTime.fromMillisecondsSinceEpoch(0);

  String? _downloadDir;
  MusicSourceService? _musicSourceService;
  DownloadTaskStorage? _storage;
  bool _initialized = false;
  bool _disposed = false;

  List<DownloadTask> get tasks => List.unmodifiable(_tasks);
  Stream<List<DownloadTask>> get tasksStream => _tasksController.stream;
  int get maxCacheSizeMB => 2048;
  Set<String> get activeTaskIds => Set.unmodifiable(_activeTaskIds);
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
    Duration progressPersistenceInterval = const Duration(seconds: 2),
  })  : assert(maxConcurrent > 0),
        _dio = dio ?? _createDownloadDio(),
        _maxConcurrent = maxConcurrent,
        _wifiOnly = wifiOnly,
        _downloader = downloader,
        _storage = storage,
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
    _storage ??= _StorageAdapter(await StorageService.instance);
    _loadFromStorage();
    if (_downloader == null) await _initDownloadDir();
    // 上次异常退出时可能卡在 downloading
    var demoted = false;
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.status == DownloadStatus.downloading) {
        _tasks[i] = t.copyWith(
          status: DownloadStatus.pending,
          progress: 0.0,
          clearSavePath: true,
          clearErrorMsg: true,
        );
        demoted = true;
      }
    }
    if (demoted) {
      _emitTasks();
      await _saveToStorage();
    }
    _initialized = true;
    _processQueue();
  }

  void _loadFromStorage() {
    final saved = _storage!.load();
    if (saved.isEmpty) return;
    _tasks.clear();
    for (final json in saved) {
      _tasks.add(DownloadTask.fromJson(Map<String, dynamic>.from(json as Map)));
    }
    _emitTasks();
  }

  Future<void> _saveToStorage() async {
    _storage ??= _StorageAdapter(await StorageService.instance);
    final data = _tasks.map((t) => t.toJson()).toList(growable: false);
    final write =
        _persistenceTail.catchError((_) {}).then((_) => _storage!.save(data));
    _persistenceTail = write.catchError((_) {});
    return write;
  }

  Future<void> _initDownloadDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    _downloadDir = '${appDir.path}/downloads';
    await Directory(_downloadDir!).create(recursive: true);
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

    final baseName = safeDownloadBaseName(task.musicId);
    final partPath = _partPathFor(task.id, task.musicId, attempt.revision);

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
          final downloadUrl = normalizeOutboundUrl(resolved.url);
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
        final downloadUrl = normalizeOutboundUrl(resolved.url);
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
              final savePath = '$_downloadDir/$baseName$detectedExt';
              final out = File(savePath);
              if (!_isCurrent(attempt)) {
                await _safeDeleteOwned(partPath, attempt);
                return;
              }
              if (await out.exists()) await out.delete();
              await _promotePartFile(part, savePath);
              if (!_isCurrent(attempt)) {
                await _safeDeleteOwned(savePath, attempt);
                return;
              }
              await _cleanupSiblingFiles(baseName, keep: savePath);

              final size = await File(savePath).length();
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
      _currentNetwork().then((network) {
        if (network == DownloadNetwork.wifi) _processQueueAllowed();
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

  String _partPathFor(String taskId, String musicId, int revision) =>
      '$_downloadDir/${safeDownloadBaseName(musicId)}.'
      '${safeDownloadBaseName(taskId)}.$revision.part';

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
    await _cleanupSiblingFiles(safeDownloadBaseName(task.musicId), keep: '');
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
      return task.savePath;
    } catch (_) {
      return null;
    }
  }

  Future<int> getCacheSize() async {
    int totalSize = 0;
    for (final task in _tasks) {
      if (task.savePath != null) {
        final file = File(task.savePath!);
        if (await file.exists()) {
          totalSize += await file.length();
        }
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
      if (task.savePath != null) {
        final file = File(task.savePath!);
        if (await file.exists()) {
          final fileSize = await file.length();
          await file.delete();
          currentSize -= fileSize;
          _tasks.remove(task);
        }
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
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> _safeDeleteOwned(String path, _DownloadAttempt attempt) async {
    await _safeDelete(path);
  }

  /// 将 .part 提升为最终文件；rename 失败时 copy+delete 兜底。
  Future<void> _promotePartFile(File part, String savePath) async {
    try {
      await part.rename(savePath);
      return;
    } on PathNotFoundException catch (e) {
      debugPrint('[DownloadService] rename missing: $e');
    } catch (e) {
      debugPrint('[DownloadService] rename failed, try copy: $e');
    }
    if (!await part.exists()) {
      throw PathNotFoundException(part.path, const OSError(), '临时文件不存在');
    }
    await part.copy(savePath);
    await _safeDelete(part.path);
  }

  /// 清理同 baseName 的其它成品扩展名；**永不删除 .part**（进行中的临时文件）。
  Future<void> _cleanupSiblingFiles(String baseName,
      {required String keep}) async {
    final dirPath = _downloadDir;
    if (dirPath == null) return;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    final keepCanon = File(keep).absolute.path;
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : entity.path.split(Platform.pathSeparator).last;
      if (name.endsWith('.part')) continue;
      if (!name.startsWith('$baseName.')) continue;
      if (entity.absolute.path == keepCanon) continue;
      await _safeDelete(entity.path);
    }
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
