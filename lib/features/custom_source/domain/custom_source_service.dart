import 'dart:async';
import 'dart:convert';

import '../../../core/network/source_pinned_transport.dart';
import '../../../core/network/source_request_policy.dart';
import '../../../core/storage/storage_service.dart';
import '../domain/custom_source.dart';
import '../domain/custom_source_engine.dart';
import '../../player/domain/music_item.dart';

class CustomSourceService {
  CustomSourceService({
    SourceRequestSandbox? importSandbox,
    StorageService? storage,
    StorageLoader? storageLoader,
    DateTime Function()? clock,
  })  : _storage = storage,
        _storageLoader = storageLoader,
        _clock = clock ?? DateTime.now,
        _importSandbox = importSandbox ??
            SourceRequestSandbox(
              policy: SourceRequestPolicy(
                maximumResponseBytes: maximumScriptBytes,
              ),
              transport: SourcePinnedTransport().call,
              maximumRedirects: 5,
              maximumInFlightBytes: maximumScriptBytes,
              maximumConcurrentResponseBodies: 1,
              maximumConcurrentRequests: 1,
            );

  static const String _storageKey = 'custom_sources';
  static const int maximumScriptBytes = 2 * 1024 * 1024;
  static const Duration importTimeout = Duration(seconds: 15);

  final List<CustomSource> _sources = [];
  final Map<String, CustomSourceEngine> _engines = {};
  final SourceRequestSandbox _importSandbox;
  final StorageLoader? _storageLoader;
  final DateTime Function() _clock;
  StorageService? _storage;
  bool _initialized = false;
  Future<void>? _initFuture;
  Future<void> _mutationTail = Future<void>.value();

  List<CustomSource> get sources => List.unmodifiable(_sources);
  List<CustomSource> get enabledSources =>
      _sources.where((s) => s.isEnabled).toList();

  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      _storage ??= await (_storageLoader ?? () => StorageService.instance)();
      await _loadSources();
      _initialized = true;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
  }

  bool _exceedsScriptByteLimit(String text) =>
      utf8.encode(text).length > maximumScriptBytes;

  Future<void> _loadSources() async {
    final jsonStr = _storage?.getString(_storageKey);
    if (jsonStr != null) {
      final List<dynamic> jsonList = json.decode(jsonStr);
      _sources.clear();
      _sources.addAll(jsonList
          .map((j) => CustomSource.fromJson(j as Map<String, dynamic>)));
    }
  }

  List<CustomSource> _dedupeSources(List<CustomSource> sources) {
    if (sources.isEmpty) return const [];
    final seenIds = <String>{};
    final seenNameAuthor = <String>{};
    final kept = <CustomSource>[];

    final ordered = [...sources]..sort((a, b) {
        if (a.isEnabled != b.isEnabled) return a.isEnabled ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });

    for (final s in ordered) {
      final key = '${s.name}|${s.author}'.toLowerCase();
      if (seenIds.contains(s.id) || seenNameAuthor.contains(key)) {
        continue;
      }
      seenIds.add(s.id);
      seenNameAuthor.add(key);
      kept.add(s);
    }
    return kept;
  }

  Future<void> _saveSources(List<CustomSource> sources) async {
    final jsonList = sources.map((s) => s.toJson()).toList();
    await _storage!.setString(_storageKey, json.encode(jsonList));
  }

  Future<T> _mutate<T>(
    _SourceMutation<T> Function(List<CustomSource> current) calculate,
  ) {
    final operation = _mutationTail.then((_) async {
      final mutation = calculate(List<CustomSource>.of(_sources));
      await _saveSources(mutation.sources);
      _publish(mutation.sources);
      for (final id in mutation.invalidateEngines) {
        _engines[id]?.dispose();
        _engines.remove(id);
      }
      return mutation.result;
    });
    _mutationTail = operation.then<void>((_) {}, onError: (_, __) {});
    return operation;
  }

  void _publish(List<CustomSource> sources) {
    _sources
      ..clear()
      ..addAll(sources);
  }

  Future<void> addSource(CustomSource source) async {
    await _mutate<void>((current) => _SourceMutation(
          _dedupeSources([...current, source]),
          null,
        ));
  }

  Future<void> updateSource(CustomSource source) async {
    await _mutate<void>((current) {
      final index = current.indexWhere((item) => item.id == source.id);
      if (index < 0) return _SourceMutation(current, null);
      current[index] = source.copyWith(updatedAt: DateTime.now());
      return _SourceMutation(
        _dedupeSources(current),
        null,
        invalidateEngines: {source.id},
      );
    });
  }

  Future<void> deleteSource(String id) async {
    await _mutate<void>((current) => _SourceMutation(
          current.where((source) => source.id != id).toList(),
          null,
          invalidateEngines: {id},
        ));
  }

  /// 切换源启用状态。启用时会立即初始化引擎（官方行为），
  /// 返回初始化是否成功；禁用返回 true。
  Future<bool> toggleSource(String id) async {
    final int index = _sources.indexWhere((source) => source.id == id);
    final CustomSource? target = index >= 0 ? _sources[index] : null;
    final bool willEnable = target != null && !target.isEnabled;
    await _mutate<void>((current) {
      final curIndex = current.indexWhere((source) => source.id == id);
      if (curIndex >= 0) {
        for (int i = 0; i < current.length; i++) {
          if (i == curIndex) {
            current[i] = current[i].copyWith(
              isEnabled: willEnable,
              updatedAt: DateTime.now(),
            );
          } else if (willEnable) {
            current[i] = current[i].copyWith(isEnabled: false);
          }
        }
      }
      return _SourceMutation(current, null);
    });
    // 启用时立即初始化引擎（真实加载脚本并注册 handler），
    // 而不是等到第一次请求才懒加载。
    if (willEnable && target != null) {
      final engine = _getEngine(id);
      try {
        return await engine.loadSource(target);
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  CustomSourceEngine _getEngine(String sourceId) {
    if (!_engines.containsKey(sourceId)) {
      _engines[sourceId] = CustomSourceEngine();
    }
    return _engines[sourceId]!;
  }

  Stream<Map<String, dynamic>> getEventStream(String sourceId) {
    return _getEngine(sourceId).eventStream;
  }

  Future<List<MusicItem>> searchWithSource(
    String sourceId,
    String keyword, {
    String source = 'kw',
    int page = 1,
    int limit = 20,
    String type = 'music',
  }) async {
    final customSource = _sources.firstWhere(
      (s) => s.id == sourceId,
      orElse: () => throw Exception('源不存在'),
    );
    if (!customSource.isEnabled) return [];
    try {
      final engine = _getEngine(sourceId);
      await engine.loadSource(customSource);
      return await engine.search(keyword,
          source: source, page: page, limit: limit, type: type);
    } catch (e) {
      return [];
    }
  }

  Future<String?> getMusicUrl(String sourceId, MusicItem music,
      {String quality = '320k'}) async {
    final detailed =
        await getMusicUrlDetailed(sourceId, music, quality: quality);
    return detailed?.url;
  }

  Future<({String url, String? type})?> getMusicUrlDetailed(
    String sourceId,
    MusicItem music, {
    String quality = '320k',
  }) async {
    try {
      final customSource = _sources.firstWhere(
        (s) => s.id == sourceId,
        orElse: () => throw Exception('源不存在'),
      );
      if (!customSource.isEnabled) return null;
      if (customSource.script.trim().isEmpty) {
        throw Exception('源脚本为空: ${customSource.name}');
      }
      final engine = _getEngine(sourceId);
      final loaded = await engine.loadSource(customSource);
      if (!loaded) {
        throw Exception('源脚本加载失败: ${customSource.name}');
      }
      return await engine.getMusicUrlDetailed(music, quality: quality);
    } catch (e) {
      // 向上抛出由调用方记录；勿静默吞掉导致“源没生效”难排查
      rethrow;
    }
  }

  Future<String?> getLyric(String sourceId, MusicItem music) async {
    try {
      final customSource = _sources.firstWhere(
        (s) => s.id == sourceId,
        orElse: () => throw Exception('源不存在'),
      );
      if (!customSource.isEnabled) return null;
      final engine = _getEngine(sourceId);
      await engine.loadSource(customSource);
      return await engine.getLyric(music);
    } catch (e) {
      return null;
    }
  }

  Future<List<MusicItem>> getSongListDetail(String sourceId, String id,
      {int page = 1}) async {
    try {
      final customSource = _sources.firstWhere(
        (s) => s.id == sourceId,
        orElse: () => throw Exception('源不存在'),
      );
      if (!customSource.isEnabled) return [];
      final engine = _getEngine(sourceId);
      final loaded = await engine.loadSource(customSource);
      if (!loaded) return [];
      return await engine.getSongListDetail(id, page: page);
    } catch (e) {
      return [];
    }
  }

  Future<bool> importSource(String jsonStr) async {
    if (_exceedsScriptByteLimit(jsonStr)) return false;
    try {
      final json = jsonDecode(jsonStr);
      final source = CustomSource.fromJson(json as Map<String, dynamic>);
      final now = _clock();
      return await _mutate<bool>((current) {
        final index = current.indexWhere((item) => item.id == source.id);
        final invalidated = <String>{};
        if (index >= 0) {
          current[index] = source.copyWith(updatedAt: now);
          invalidated.add(source.id);
        } else {
          current.add(source);
        }
        return _SourceMutation(
          _dedupeSources(current),
          true,
          invalidateEngines: invalidated,
        );
      });
    } catch (e) {
      return false;
    }
  }

  Future<bool> importLxMusicScript(String script) async {
    if (_exceedsScriptByteLimit(script)) return false;
    try {
      final nameMatch = RegExp(r'@name\s+(.+)').firstMatch(script);
      final descMatch = RegExp(r'@description\s+(.+)').firstMatch(script);
      final versionMatch = RegExp(r'@version\s+(.+)').firstMatch(script);
      final authorMatch = RegExp(r'@author\s+(.+)').firstMatch(script);

      final name = nameMatch?.group(1)?.trim() ?? '未命名音源';
      final description = descMatch?.group(1)?.trim() ?? '';
      final version = versionMatch?.group(1)?.trim() ?? '1.0.0';
      final author = authorMatch?.group(1)?.trim() ?? '未知';

      return await _mutate<bool>((current) {
        final now = _clock();
        final shouldEnable = !current.any((source) => source.isEnabled);
        final candidate = CustomSource(
          id: now.microsecondsSinceEpoch.toString(),
          name: name,
          description: description,
          version: version,
          author: author,
          script: script,
          createdAt: now,
          updatedAt: now,
          isEnabled: shouldEnable,
        );
        final invalidated = <String>{};
        late final String targetId;
        final existingIndex = current.indexWhere(
            (source) => source.name == name && source.author == author);
        if (existingIndex >= 0) {
          final old = current[existingIndex];
          current[existingIndex] = old.copyWith(
            description: description,
            version: version,
            script: script,
            updatedAt: now,
            isEnabled: old.isEnabled || shouldEnable,
          );
          targetId = old.id;
          invalidated.add(old.id);
        } else {
          current.add(candidate);
          targetId = candidate.id;
        }
        if (current
            .any((source) => source.id == targetId && source.isEnabled)) {
          for (var i = 0; i < current.length; i++) {
            if (current[i].id != targetId && current[i].isEnabled) {
              current[i] = current[i].copyWith(isEnabled: false);
            }
          }
        }
        return _SourceMutation(
          _dedupeSources(current),
          true,
          invalidateEngines: invalidated,
        );
      });
    } catch (e) {
      return false;
    }
  }

  Future<bool> importSourceFromUrl(
    String url, {
    SourceRequestCancellation? cancellation,
  }) async {
    final cancel = cancellation ?? SourceRequestCancellation();
    try {
      return await () async {
        final response = await _importSandbox.request(
          Uri.parse(url),
          const {'method': 'GET', 'timeout': 15000},
          cancellation: cancel,
        );
        final script = await withSourceResponseLease(response, (owned) async {
          if (owned.statusCode != 200) return null;
          return utf8.decode(owned.bytes, allowMalformed: false);
        });
        if (script == null || !validateScript(script)) return false;
        // 脚本最终在 CustomSourceEngine 的沙箱里执行（无 DOM/Node、
        // HTTPS-only、SSRF 拦截、超时与资源限制），导入校验不承担
        // 安全边界，只过滤明显非音源内容。
        return await importLxMusicScript(script);
      }()
          .timeout(importTimeout, onTimeout: () {
        cancel.cancel('import timeout');
        return false;
      });
    } catch (_) {
      if (!cancel.isCancelled) cancel.cancel('import failed');
      return false;
    }
  }

  String exportSource(String id) {
    final source = _sources.firstWhere((s) => s.id == id);
    return json.encode(source.toJson());
  }

  String exportAllSources() {
    final jsonList = _sources.map((s) => s.toJson()).toList();
    return json.encode(jsonList);
  }

  /// 校验音源脚本。与洛雪桌面端（`parseScriptInfo`）保持一致：
  /// 只要求脚本以 `/* ... */` 文件头注释开头，并从中解析出 `@name` 元数据，
  /// **不检查正文内容关键字**。
  ///
  /// 为什么这么宽松：
  /// - 音源脚本经常用 obfuscator.io / Unicode 变量名混淆（如 sixyin、lx），
  ///   混淆后正文不含 `EVENT_NAMES` / `musicUrl` 等明文关键字。
  ///   若校验正文关键字，这些能正常运行的源会被误拒（Windows 桌面端可用，
  ///   仅移动端被拦）。
  /// - 洛雪桌面端同样只做文件头校验，我们与其对齐，保证同一份源在两个端
  ///   行为一致。
  ///
  /// 安全性并未因此削弱：
  /// - 真正的安全边界不在「导入校验」，而在**运行时沙箱**：
  ///   脚本执行受限（无 DOM/Node、HTTPS-only 请求、SSRF 拦截、超时与
  ///   并发/字节限制、能力声明校验）。脚本是用户主动导入并信任的，与
  ///   桌面端风险模型一致。
  /// - 文件头 `@name` 同时是导入后元数据（名称/作者/版本）的来源，要求它
  ///   存在可过滤掉纯文本、无注释的普通 JS 等非音源内容。
  bool validateScript(String script) {
    final trimmed = script.trimLeft();
    if (!trimmed.startsWith('/*')) return false;
    // 注释必须闭合，且位于文件开头
    final close = trimmed.indexOf('*/');
    if (close < 0) return false;
    final header = trimmed.substring(0, close + 2);
    // 文件头应包含 @name 元数据（对齐洛雪 INFO_NAMES）
    return header.contains('@name');
  }

  void dispose() {
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
  }
}

final class _SourceMutation<T> {
  const _SourceMutation(
    this.sources,
    this.result, {
    this.invalidateEngines = const {},
  });

  final List<CustomSource> sources;
  final T result;
  final Set<String> invalidateEngines;
}
