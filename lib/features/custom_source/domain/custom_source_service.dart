import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import '../../../core/network/outbound_url.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/custom_source.dart';
import '../domain/custom_source_engine.dart';
import '../../player/domain/music_item.dart';

class CustomSourceService {
  static const String _storageKey = 'custom_sources';

  /// 历史内置 Huibq 的 id；启动时若仍存在则移除，不再自动种源。
  static const String defaultSourceId = 'default_huibq';
  static const String _legacySeededKey = 'default_source_seeded';
  static const String _legacyDeletedKey = 'default_source_deleted';
  static const String _builtinPurgedKey = 'builtin_huibq_purged_v1';

  final List<CustomSource> _sources = [];
  final Map<String, CustomSourceEngine> _engines = {};
  final Dio _dio = Dio();
  SharedPreferences? _prefs;
  bool _initialized = false;
  Future<void>? _initFuture;

  List<CustomSource> get sources => List.unmodifiable(_sources);
  List<CustomSource> get enabledSources =>
      _sources.where((s) => s.isEnabled).toList();

  Future<void> init() {
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      await _loadSources();
      await _purgeBuiltInHuibqOnce();
      await _dedupeSources();
      _initialized = true;
    } catch (e) {
      _initFuture = null;
      rethrow;
    }
  }

  /// 去掉历史内置 default_huibq（用户自行导入的同名源保留，但 id 为 default_huibq 的一律清掉）。
  Future<void> _purgeBuiltInHuibqOnce() async {
    final hadDefault = _sources.any((s) => s.id == defaultSourceId);
    if (hadDefault) {
      _sources.removeWhere((s) => s.id == defaultSourceId);
      _engines[defaultSourceId]?.dispose();
      _engines.remove(defaultSourceId);
      await _saveSources();
    }
    // 清理旧 seed 标记，避免其它逻辑误判
    await _prefs?.remove(_legacySeededKey);
    await _prefs?.remove(_legacyDeletedKey);
    await _prefs?.setBool(_builtinPurgedKey, true);
  }

  static bool isHuibqFamily(CustomSource s) {
    final nameL = s.name.toLowerCase();
    final authorL = s.author.toLowerCase();
    final homeL = (s.homepage ?? '').toLowerCase();
    if (s.id == defaultSourceId) return true;
    if (nameL.contains('huibq') || authorL.contains('huibq')) return true;
    if (nameL.contains('lxmusic源') || nameL.contains('lxmusic')) return true;
    if (homeL.contains('huibq') || homeL.contains('lx-music-source')) {
      return true;
    }
    return false;
  }

  Future<void> _loadSources() async {
    final jsonStr = _prefs?.getString(_storageKey);
    if (jsonStr != null) {
      final List<dynamic> jsonList = json.decode(jsonStr);
      _sources.clear();
      _sources.addAll(jsonList
          .map((j) => CustomSource.fromJson(j as Map<String, dynamic>)));
      await _dedupeSources();
    }
  }

  Future<void> _dedupeSources() async {
    if (_sources.isEmpty) return;
    final seenIds = <String>{};
    final seenNameAuthor = <String>{};
    var seenHuibq = false;
    final kept = <CustomSource>[];

    final ordered = [..._sources]..sort((a, b) {
        if (a.isEnabled != b.isEnabled) return a.isEnabled ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });

    var changed = false;
    for (final s in ordered) {
      final key = '${s.name}|${s.author}'.toLowerCase();
      final huibq = isHuibqFamily(s);
      if (seenIds.contains(s.id) ||
          seenNameAuthor.contains(key) ||
          (huibq && seenHuibq)) {
        changed = true;
        continue;
      }
      seenIds.add(s.id);
      seenNameAuthor.add(key);
      if (huibq) seenHuibq = true;
      kept.add(s);
    }

    if (changed || kept.length != _sources.length) {
      _sources
        ..clear()
        ..addAll(kept);
      await _saveSources();
    }
  }

  Future<void> _saveSources() async {
    final jsonList = _sources.map((s) => s.toJson()).toList();
    await _prefs?.setString(_storageKey, json.encode(jsonList));
  }

  Future<void> addSource(CustomSource source) async {
    _sources.add(source);
    await _dedupeSources();
    await _saveSources();
  }

  Future<void> updateSource(CustomSource source) async {
    final index = _sources.indexWhere((s) => s.id == source.id);
    if (index >= 0) {
      _sources[index] = source.copyWith(updatedAt: DateTime.now());
      await _dedupeSources();
      await _saveSources();
      _engines[source.id]?.dispose();
      _engines.remove(source.id);
    }
  }

  Future<void> deleteSource(String id) async {
    _sources.removeWhere((s) => s.id == id);
    await _saveSources();
    _engines[id]?.dispose();
    _engines.remove(id);
  }

  Future<void> toggleSource(String id) async {
    final index = _sources.indexWhere((s) => s.id == id);
    if (index >= 0) {
      final bool willEnable = !_sources[index].isEnabled;
      for (int i = 0; i < _sources.length; i++) {
        if (i == index) {
          _sources[i] = _sources[i].copyWith(
            isEnabled: willEnable,
            updatedAt: DateTime.now(),
          );
        } else if (willEnable) {
          _sources[i] = _sources[i].copyWith(isEnabled: false);
        }
      }
      await _saveSources();
    }
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
    try {
      final json = jsonDecode(jsonStr);
      final source = CustomSource.fromJson(json as Map<String, dynamic>);
      // 禁止再以内置 id 写入
      final normalized = source.id == defaultSourceId
          ? source.copyWith(
              id: DateTime.now().millisecondsSinceEpoch.toString())
          : source;
      if (_sources.any((s) => s.id == normalized.id)) {
        await updateSource(normalized);
      } else {
        await addSource(normalized);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> importLxMusicScript(String script) async {
    try {
      final nameMatch = RegExp(r'@name\s+(.+)').firstMatch(script);
      final descMatch = RegExp(r'@description\s+(.+)').firstMatch(script);
      final versionMatch = RegExp(r'@version\s+(.+)').firstMatch(script);
      final authorMatch = RegExp(r'@author\s+(.+)').firstMatch(script);

      final name = nameMatch?.group(1)?.trim() ?? '未命名音源';
      final description = descMatch?.group(1)?.trim() ?? '';
      final version = versionMatch?.group(1)?.trim() ?? '1.0.0';
      final author = authorMatch?.group(1)?.trim() ?? '未知';

      // 没有其它已启用源时，导入后自动启用，否则 musicUrl 永远不会走脚本
      final shouldEnable = !_sources.any((s) => s.isEnabled);
      final candidate = CustomSource(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        description: description,
        version: version,
        author: author,
        script: script,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isEnabled: shouldEnable,
      );

      late final String targetId;
      final existingIndex =
          _sources.indexWhere((s) => s.name == name && s.author == author);
      if (existingIndex >= 0) {
        final old = _sources[existingIndex];
        _sources[existingIndex] = old.copyWith(
          description: description,
          version: version,
          script: script,
          updatedAt: DateTime.now(),
          // 更新脚本时若当前无任何启用源，则启用本条
          isEnabled: old.isEnabled || shouldEnable,
        );
        targetId = old.id;
        _engines[old.id]?.dispose();
        _engines.remove(old.id);
      } else if (isHuibqFamily(candidate) && _sources.any(isHuibqFamily)) {
        final idx = _sources.indexWhere(isHuibqFamily);
        final old = _sources[idx];
        _sources[idx] = old.copyWith(
          name: name,
          description: description.isNotEmpty ? description : old.description,
          version: version,
          author: author,
          script: script,
          updatedAt: DateTime.now(),
          isEnabled: old.isEnabled || shouldEnable,
        );
        targetId = old.id;
        _engines[old.id]?.dispose();
        _engines.remove(old.id);
      } else {
        if (shouldEnable) {
          for (var i = 0; i < _sources.length; i++) {
            if (_sources[i].isEnabled) {
              _sources[i] = _sources[i].copyWith(isEnabled: false);
            }
          }
        }
        _sources.add(candidate);
        targetId = candidate.id;
      }
      // 确保至多一个启用
      if (_sources.any((s) => s.id == targetId && s.isEnabled)) {
        for (var i = 0; i < _sources.length; i++) {
          if (_sources[i].id != targetId && _sources[i].isEnabled) {
            _sources[i] = _sources[i].copyWith(isEnabled: false);
          }
        }
      }
      await _dedupeSources();
      await _saveSources();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> importSourceFromUrl(String url) async {
    try {
      final response = await _dio.get(normalizeOutboundUrl(url),
          options: Options(responseType: ResponseType.plain));
      final script = response.data.toString();
      if (validateScript(script)) {
        return await importLxMusicScript(script);
      }
      return false;
    } catch (e) {
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

  bool validateScript(String script) {
    if (script.contains('globalThis.lx') || script.contains('EVENT_NAMES')) {
      return true;
    }
    return script.contains('search') ||
        script.contains('getMusicUrl') ||
        script.contains('musicUrl');
  }

  bool isLxMusicScript(String script) {
    return script.contains('globalThis.lx') ||
        script.contains('EVENT_NAMES') ||
        script.contains('on(EVENT_NAMES.request');
  }

  void dispose() {
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
  }
}
