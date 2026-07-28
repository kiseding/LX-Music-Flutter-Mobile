import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../../features/player/domain/music_item.dart';
import '../../features/custom_source/domain/custom_source_service.dart';
import '../music_source/platform/built_in_source_manager.dart';
import 'play_url_result.dart';
import 'outbound_url.dart';

typedef QualityResolver = Future<PlayUrlResult?> Function(
  MusicItem music,
  String quality,
  CancelToken? cancelToken,
);

class MusicSourceService {
  final CustomSourceService _customSourceService;
  final BuiltInSourceManager _builtInSources = BuiltInSourceManager();
  final bool Function()? _hasEnabledCustomSources;
  final QualityResolver? _customQualityResolver;
  final QualityResolver? _builtInQualityResolver;

  MusicSourceService(
    this._customSourceService, {
    bool Function()? hasEnabledCustomSources,
    QualityResolver? customQualityResolver,
    QualityResolver? builtInQualityResolver,
  })  : _hasEnabledCustomSources = hasEnabledCustomSources,
        _customQualityResolver = customQualityResolver,
        _builtInQualityResolver = builtInQualityResolver;

  BuiltInSourceManager get builtInSources => _builtInSources;

  /// 从高到低的音质降级链。优先 preferred，再依次更低档。
  static const qualityRank = [
    'hires',
    'flac24bit',
    'flac',
    '320k',
    '192k',
    '128k',
  ];

  static List<String> qualityChain(String preferred) {
    final p = preferred.isEmpty ? '320k' : preferred;
    final start = qualityRank.indexOf(p);
    if (start < 0) {
      return [p, ...qualityRank.where((q) => q != p)];
    }
    return qualityRank.sublist(start);
  }

  static int qualityRankIndex(String q) {
    final i = qualityRank.indexOf(q);
    return i < 0 ? qualityRank.length : i;
  }

  /// actual 是否明显低于 requested（用于拒绝“假成功”低码率 URL）
  static bool isQualityBelow(String actual, String requested) {
    return qualityRankIndex(actual) > qualityRankIndex(requested);
  }

  Future<List<MusicItem>> search(
    String keyword, {
    String? customSourceId,
    int page = 1,
    int limit = 20,
    String type = 'music',
  }) async {
    final platform = customSourceId ?? 'kw';
    final enabledCustomSources = _customSourceService.enabledSources;

    if (enabledCustomSources.isNotEmpty) {
      try {
        final results = await _customSourceService
            .searchWithSource(
              enabledCustomSources.first.id,
              keyword,
              source: platform,
              page: page,
              limit: limit,
              type: type,
            )
            .timeout(const Duration(seconds: 15));
        if (results.isNotEmpty) {
          return results;
        }
      } catch (e) {
        // Custom source search error, continue to built-in
      }
    }

    if (platform == 'all') {
      return _searchAllPlatforms(keyword, page: page, limit: limit);
    }

    if (type == 'songlist') {
      final builtInResult = await _builtInSources
          .searchSongLists(platform, keyword, page: page, limit: limit);
      if (builtInResult.isNotEmpty) return builtInResult;
    } else {
      final builtInResult = await _builtInSources.search(platform, keyword,
          page: page, limit: limit);
      if (builtInResult.isNotEmpty) return builtInResult;
    }

    if (enabledCustomSources.isNotEmpty) {
      return await _customSourceService
          .searchWithSource(
        enabledCustomSources.first.id,
        keyword,
        source: platform,
        page: page,
        limit: limit,
        type: type,
      )
          .catchError((e) {
        return <MusicItem>[];
      });
    }

    return [];
  }

  Future<List<MusicItem>> _searchAllPlatforms(String keyword,
      {int page = 1, int limit = 20}) async {
    final platforms = _builtInSources.allIds;
    final results = await Future.wait(
      platforms.map((p) => _builtInSources
          .search(p, keyword, page: page, limit: limit)
          .timeout(const Duration(seconds: 10), onTimeout: () => <MusicItem>[])
          .catchError((_) => <MusicItem>[])),
    );

    final List<MusicItem> combined = [];
    int maxLen = results
        .map((r) => r.length)
        .fold(0, (max, len) => len > max ? len : max);
    for (int i = 0; i < maxLen; i++) {
      for (var list in results) {
        if (i < list.length) {
          combined.add(list[i]);
        }
      }
    }
    return combined;
  }

  String resolvePlatform(MusicItem music) {
    var platform = music.platform;
    if (platform.isEmpty ||
        platform == 'custom' ||
        platform == 'test' ||
        platform.startsWith('default_') ||
        (platform != 'kw' &&
            platform != 'tx' &&
            platform != 'wy' &&
            platform != 'kg' &&
            platform != 'mg')) {
      final metaSrc = music.meta?['source']?.toString();
      if (metaSrc == 'kw' || metaSrc == 'tx' || metaSrc == 'wy') {
        platform = metaSrc!;
      } else if (music.source == 'kw' ||
          music.source == 'tx' ||
          music.source == 'wy') {
        platform = music.source;
      } else {
        platform = 'tx';
      }
    }
    return platform;
  }

  Future<String?> getPlayUrl(MusicItem music, {String quality = '320k'}) async {
    final result = await resolvePlayableUrl(
      music,
      preferredQuality: quality,
    );
    return result?.url;
  }

  Future<PlayUrlResult?> getPlayUrlDetailed(MusicItem music,
      {String quality = '320k'}) {
    return resolvePlayableUrl(music, preferredQuality: quality);
  }

  Future<PlayUrlResult?> resolvePlayableUrl(
    MusicItem music, {
    required String preferredQuality,
    CancelToken? cancelToken,
  }) async {
    final resolvedQuality =
        preferredQuality.isEmpty ? '320k' : preferredQuality;
    final songId = (music.songmid?.isNotEmpty == true)
        ? music.songmid!
        : (music.hash?.isNotEmpty == true ? music.hash! : music.id);
    final platform = resolvePlatform(music);
    debugPrint(
        '[getPlayUrl] 开始解析: platform=$platform, songId=$songId, quality=$resolvedQuality, source=${music.source}');

    final qualities = qualityChain(resolvedQuality);
    PlayUrlResult? bestBelow;

    final hasCustom = _hasEnabledCustomSources?.call() ??
        _customSourceService.enabledSources.isNotEmpty;
    final resolver = hasCustom ? _resolveCustomQuality : _resolveBuiltInQuality;

    for (final quality in qualities) {
      _throwIfCancelled(cancelToken);
      final result = await resolver(music, quality, cancelToken);
      _throwIfCancelled(cancelToken);
      if (result == null || !isPlayableMediaUrl(result.url)) continue;

      final normalized = PlayUrlResult(
        url: result.url,
        requestedQuality: resolvedQuality,
        actualQuality: result.actualQuality,
        platform: result.platform,
      );
      if (isQualityBelow(normalized.actualQuality, quality)) {
        bestBelow ??= normalized;
        continue;
      }
      return normalized;
    }

    if (bestBelow != null) {
      debugPrint('[getPlayUrl] 使用偏低但可播结果 actual=${bestBelow.actualQuality}');
      return bestBelow;
    }
    debugPrint('[getPlayUrl] 所有源均失败');
    return null;
  }

  Future<PlayUrlResult?> _resolveCustomQuality(
    MusicItem music,
    String quality,
    CancelToken? cancelToken,
  ) async {
    if (_customQualityResolver != null) {
      return _customQualityResolver(music, quality, cancelToken);
    }
    final platform = resolvePlatform(music);
    final musicForScript = music.copyWith(platform: platform);
    for (final source in _customSourceService.enabledSources) {
      _throwIfCancelled(cancelToken);
      try {
        final detailed = await _customSourceService
            .getMusicUrlDetailed(source.id, musicForScript, quality: quality)
            .timeout(const Duration(seconds: 20));
        _throwIfCancelled(cancelToken);
        final rawUrl = detailed?.url;
        final url = rawUrl == null ? null : normalizeOutboundUrl(rawUrl);
        if (!isPlayableMediaUrl(url)) continue;
        return PlayUrlResult(
          url: url!,
          requestedQuality: quality,
          actualQuality: normalizeScriptQuality(detailed?.type) ??
              correctQualityFromUrl(url, quality),
          platform: platform,
        );
      } catch (error) {
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        debugPrint(
            '[getPlayUrl] 自定义源 ${source.id}/${source.name} q=$quality 失败: $error');
      }
    }
    return null;
  }

  Future<PlayUrlResult?> _resolveBuiltInQuality(
    MusicItem music,
    String quality,
    CancelToken? cancelToken,
  ) async {
    if (_builtInQualityResolver != null) {
      return _builtInQualityResolver(music, quality, cancelToken);
    }
    final platform = resolvePlatform(music);
    if (platform != 'kw' && platform != 'tx' && platform != 'wy') return null;
    try {
      final rawUrl = await _builtInSources
          .getMusicUrl(platform, music, quality: quality)
          .timeout(const Duration(seconds: 8));
      _throwIfCancelled(cancelToken);
      final url = rawUrl == null ? null : normalizeOutboundUrl(rawUrl);
      if (!isPlayableMediaUrl(url)) return null;
      return PlayUrlResult(
        url: url!,
        requestedQuality: quality,
        actualQuality: correctQualityFromUrl(url, quality),
        platform: platform,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      return null;
    }
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    final error = cancelToken?.cancelError;
    if (error != null) throw error;
  }

  Future<String?> getLyric(MusicItem music) async {
    debugPrint(
        '[MusicSourceService] getLyric: platform=${music.platform}, source=${music.source}, songmid=${music.songmid}');

    final enabledSources = _customSourceService.enabledSources;
    if (enabledSources.isNotEmpty) {
      debugPrint('[MusicSourceService] 尝试 ${enabledSources.length} 个自定义源');
    }
    for (final source in enabledSources) {
      final lyric =
          await _customSourceService.getLyric(source.id, music).catchError((e) {
        debugPrint('[MusicSourceService] 自定义源 ${source.id} 歌词失败: $e');
        return null;
      });
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 自定义源 ${source.id} 返回歌词');
        return lyric;
      }
    }

    final platform = music.platform.isNotEmpty ? music.platform : music.source;
    debugPrint('[MusicSourceService] 尝试内置源 platform=$platform');
    if (platform.isNotEmpty && platform != 'custom' && platform != 'test') {
      final lyric = await _builtInSources.getLyric(platform, music);
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 内置源 $platform 返回歌词');
        return lyric;
      }
      debugPrint('[MusicSourceService] 内置源 $platform 返回空');
    }

    for (final pid in _builtInSources.allIds) {
      if (pid == platform) continue;
      final lyric = await _builtInSources.getLyric(pid, music);
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 兜底源 $pid 返回歌词');
        return lyric;
      }
    }

    debugPrint('[MusicSourceService] 所有源均未返回歌词');
    return null;
  }

  Future<List<MusicItem>> getSongListDetail(
      String platformId, String songListId,
      {int page = 1, int limit = 50}) async {
    final enabledSources = _customSourceService.enabledSources;
    for (final source in enabledSources) {
      try {
        final songs = await _customSourceService.getSongListDetail(
          source.id,
          songListId,
          page: page,
        );
        if (songs.isNotEmpty) return songs;
      } catch (_) {}
    }
    return _builtInSources.getSongListDetail(platformId, songListId,
        page: page, limit: limit);
  }

  void dispose() {
    _builtInSources.dispose();
  }
}
