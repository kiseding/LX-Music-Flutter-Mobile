import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import '../../features/player/domain/music_item.dart';
import '../../features/custom_source/domain/custom_source_service.dart';
import '../music_source/platform/built_in_source_manager.dart';
import 'play_url_result.dart';
import 'outbound_url.dart';

typedef QualityResolver =
    Future<PlayUrlResult?> Function(
      MusicItem music,
      String quality,
      CancelToken? cancelToken,
    );
typedef CustomSourceQualityResolver =
    Future<PlayUrlResult?> Function(
      String sourceId,
      MusicItem music,
      String quality,
      CancelToken? cancelToken,
    );

class _QualityAttempt {
  final PlayUrlResult result;
  final int sourceIndex;
  final int candidateIndex;
  final String songId;

  const _QualityAttempt({
    required this.result,
    required this.sourceIndex,
    required this.candidateIndex,
    this.songId = '',
  });
}

class MusicSourceService {
  static const fallbackPlatforms = ['tx', 'kw', 'wy'];

  final CustomSourceService _customSourceService;
  final BuiltInSourceManager _builtInSources;
  final bool Function()? _hasEnabledCustomSources;
  final List<String> Function()? _enabledCustomSourceIds;
  final QualityResolver? _customQualityResolver;
  final CustomSourceQualityResolver? _customSourceQualityResolver;
  final QualityResolver? _builtInQualityResolver;

  MusicSourceService(
    this._customSourceService, {
    bool Function()? hasEnabledCustomSources,
    List<String> Function()? enabledCustomSourceIds,
    QualityResolver? customQualityResolver,
    CustomSourceQualityResolver? customSourceQualityResolver,
    QualityResolver? builtInQualityResolver,
    BuiltInSourceManager? builtInSources,
  }) : _hasEnabledCustomSources = hasEnabledCustomSources,
       _enabledCustomSourceIds = enabledCustomSourceIds,
       _customQualityResolver = customQualityResolver,
       _customSourceQualityResolver = customSourceQualityResolver,
       _builtInSources = builtInSources ?? BuiltInSourceManager(),
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

  static const _fallbackQualityRank = [
    'hires',
    'flac24bit',
    'flac',
    '320k',
    '128k',
  ];

  static List<String> qualityChain(String preferred) {
    final p = preferred.isEmpty ? '320k' : preferred;
    if (p == '192k') return ['192k', '128k'];
    final start = _fallbackQualityRank.indexOf(p);
    if (start < 0) {
      return [p, ..._fallbackQualityRank.where((q) => q != p)];
    }
    return _fallbackQualityRank.sublist(start);
  }

  static int qualityRankIndex(String q) {
    final i = qualityRank.indexOf(q);
    return i < 0 ? qualityRank.length : i;
  }

  static List<String> uniqueQualityCandidates(
    String preferred, {
    required String? Function(String quality) attemptKey,
    List<String>? candidates,
  }) {
    final seen = <String>{};
    return (candidates ?? qualityChain(preferred)).where((quality) {
      final key = attemptKey(quality);
      return key != null && seen.add(key);
    }).toList();
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
      final builtInResult = await _builtInSources.searchSongLists(
        platform,
        keyword,
        page: page,
        limit: limit,
      );
      if (builtInResult.isNotEmpty) return builtInResult;
    } else {
      final builtInResult = await _builtInSources.search(
        platform,
        keyword,
        page: page,
        limit: limit,
      );
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

  Future<List<MusicItem>> _searchAllPlatforms(
    String keyword, {
    int page = 1,
    int limit = 20,
  }) async {
    final platforms = _builtInSources.allIds;
    final results = await Future.wait(
      platforms.map(
        (p) => _builtInSources
            .search(p, keyword, page: page, limit: limit)
            .timeout(
              const Duration(seconds: 10),
              onTimeout: () => <MusicItem>[],
            )
            .catchError((_) => <MusicItem>[]),
      ),
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
    if (!_isScriptPlatform(platform)) {
      final metaSrc = music.meta?['source']?.toString();
      if (_isScriptPlatform(metaSrc)) {
        platform = metaSrc!;
      } else if (_isScriptPlatform(music.source)) {
        platform = music.source;
      } else {
        platform = '';
      }
    }
    return platform;
  }

  bool _isScriptPlatform(String? platform) =>
      platform == 'kw' ||
      platform == 'tx' ||
      platform == 'wy' ||
      platform == 'kg' ||
      platform == 'mg' ||
      platform == 'local';

  Future<String?> getPlayUrl(MusicItem music, {String quality = '320k'}) async {
    final result = await resolvePlayableUrl(music, preferredQuality: quality);
    return result?.url;
  }

  Future<PlayUrlResult?> getPlayUrlDetailed(
    MusicItem music, {
    String quality = '320k',
  }) {
    return resolvePlayableUrl(music, preferredQuality: quality);
  }

  Future<PlayUrlResult?> resolvePlayableUrl(
    MusicItem music, {
    required String preferredQuality,
    CancelToken? cancelToken,
    bool allowCrossPlatformFallback = true,
    bool allowSamePlatformRefresh = true,
    bool allowQualityFallback = true,
  }) async {
    final resolvedQuality = preferredQuality.isEmpty
        ? '320k'
        : preferredQuality;
    final songId = (music.songmid?.isNotEmpty == true)
        ? music.songmid!
        : (music.hash?.isNotEmpty == true ? music.hash! : music.id);
    final platform = resolvePlatform(music);
    debugPrint(
      '[getPlayUrl] 开始解析: platform=$platform, songId=$songId, quality=$resolvedQuality, source=${music.source}',
    );

    final hasCustom =
        _enabledCustomSourceIds != null ||
        _customSourceQualityResolver != null ||
        (_hasEnabledCustomSources?.call() ??
            _customSourceService.enabledSources.isNotEmpty);
    final customAttemptKeys = <String>{};
    final qualities = allowQualityFallback
        ? qualityChain(resolvedQuality)
        : [resolvedQuality];
    final customResult = hasCustom
        ? await _resolveQualityChain(
            music,
            resolvedQuality,
            qualities,
            (music, quality, cancelToken, {required candidateIndex}) =>
                _resolveCustomQuality(
                  music,
                  quality,
                  cancelToken,
                  candidateIndex: candidateIndex,
                  attemptKeys: customAttemptKeys,
                ),
            cancelToken,
            acceptDowngradeImmediately: true,
          )
        : null;
    if (customResult != null) return customResult;

    if (platform != 'kw' && platform != 'tx' && platform != 'wy') return null;
    final builtInQualities = _builtInQualityResolver != null
        ? qualities
        : uniqueQualityCandidates(
            resolvedQuality,
            candidates: allowQualityFallback ? null : [resolvedQuality],
            attemptKey: (quality) =>
                _builtInSources.exactAttemptKey(platform, quality),
          );
    final builtInResult = await _resolveQualityChain(
      music,
      resolvedQuality,
      builtInQualities,
      _resolveBuiltInQuality,
      cancelToken,
      acceptDowngradeImmediately: false,
    );
    if (builtInResult != null) return builtInResult;

    if (allowSamePlatformRefresh) {
      _throwIfCancelled(cancelToken);
      final matches = await _builtInSources
          .search(platform, music.name, page: 1, limit: 10)
          .catchError((_) => <MusicItem>[]);
      final candidate = _bestSongMatch(music, matches);
      if (candidate != null && !identical(candidate, music)) {
        debugPrint('[getPlayUrl] 使用同平台搜索结果补全播放元数据: $platform');
        final refreshed = await resolvePlayableUrl(
          candidate,
          preferredQuality: resolvedQuality,
          cancelToken: cancelToken,
          allowCrossPlatformFallback: false,
          allowSamePlatformRefresh: false,
          allowQualityFallback: false,
        );
        if (refreshed != null) return refreshed;
      }
    }

    if (allowCrossPlatformFallback) {
      final fallback = await _resolveCrossPlatformFallback(
        music,
        resolvedQuality,
        cancelToken,
      );
      if (fallback != null) return fallback;
    }

    debugPrint(
      allowCrossPlatformFallback
          ? '[getPlayUrl] 当前平台及跨平台回退均无可播地址'
          : '[getPlayUrl] 当前平台解析失败，跨平台回退已禁用',
    );
    return null;
  }

  Future<PlayUrlResult?> _resolveCrossPlatformFallback(
    MusicItem music,
    String quality,
    CancelToken? cancelToken,
  ) async {
    final sourcePlatform = resolvePlatform(music);
    final platforms = fallbackPlatforms
        .where(
          (platform) =>
              platform != sourcePlatform &&
              _builtInSources.get(platform) != null,
        )
        .toList(growable: false);
    for (final platform in platforms) {
      _throwIfCancelled(cancelToken);
      final matches = await _builtInSources
          .search(platform, music.name, page: 1, limit: 10)
          .catchError((_) => <MusicItem>[]);
      final candidate = _bestSongMatch(music, matches);
      if (candidate == null) continue;
      debugPrint(
        '[getPlayUrl] 跨平台回退: $sourcePlatform -> ${resolvePlatform(candidate)}',
      );
      final result = await resolvePlayableUrl(
        candidate,
        preferredQuality: quality,
        cancelToken: cancelToken,
        allowCrossPlatformFallback: false,
        allowSamePlatformRefresh: false,
        allowQualityFallback: false,
      );
      if (result != null) return result;
    }
    return null;
  }

  MusicItem? _bestSongMatch(MusicItem original, List<MusicItem> matches) {
    final name = _normalizeMatchText(original.name);
    final singer = _normalizeMatchText(original.singer);
    MusicItem? best;
    var bestScore = 0;
    for (final candidate in matches) {
      final candidateName = _normalizeMatchText(candidate.name);
      final candidateSinger = _normalizeMatchText(candidate.singer);
      var score = 0;
      if (candidateName == name) score += 2;
      if (singer.isNotEmpty && candidateSinger.contains(singer)) score += 2;
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
      }
    }
    return bestScore >= 4 ? best : null;
  }

  String _normalizeMatchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[()（）\[\]【】]'), '');

  Future<PlayUrlResult?> _resolveQualityChain(
    MusicItem music,
    String requestedQuality,
    List<String> qualities,
    Future<_QualityAttempt?> Function(
      MusicItem music,
      String quality,
      CancelToken? cancelToken, {
      required int candidateIndex,
    })
    resolver,
    CancelToken? cancelToken, {
    required bool acceptDowngradeImmediately,
  }) async {
    final songId = (music.songmid?.isNotEmpty == true)
        ? music.songmid!
        : (music.hash?.isNotEmpty == true ? music.hash! : music.id);
    _QualityAttempt? bestBelow;

    final attemptedQualities = <String>{};
    for (
      var candidateIndex = 0;
      candidateIndex < qualities.length;
      candidateIndex++
    ) {
      final quality = qualities[candidateIndex];
      if (!attemptedQualities.add(quality)) continue;
      _throwIfCancelled(cancelToken);
      final attempt = await resolver(
        music,
        quality,
        cancelToken,
        candidateIndex: candidateIndex,
      );
      _throwIfCancelled(cancelToken);
      if (attempt == null || !isPlayableMediaUrl(attempt.result.url)) continue;

      final normalized = PlayUrlResult(
        url: attempt.result.url,
        requestedQuality: requestedQuality,
        actualQuality: attempt.result.actualQuality,
        platform: attempt.result.platform,
        songId: attempt.songId.isNotEmpty ? attempt.songId : songId,
        validUntil: attempt.result.validUntil ??
            DateTime.now().add(const Duration(hours: 3)),
      );
      final normalizedAttempt = _QualityAttempt(
        result: normalized,
        sourceIndex: attempt.sourceIndex,
        candidateIndex: candidateIndex,
      );
      if (isQualityBelow(normalized.actualQuality, quality)) {
        if (acceptDowngradeImmediately) return normalized;
        bestBelow = _betterProvisional(bestBelow, normalizedAttempt);
        continue;
      }
      return _betterProvisional(bestBelow, normalizedAttempt)?.result;
    }

    if (bestBelow != null) {
      debugPrint(
        '[getPlayUrl] 使用偏低但可播结果 actual=${bestBelow.result.actualQuality}',
      );
      return bestBelow.result;
    }
    return null;
  }

  Future<_QualityAttempt?> _resolveCustomQuality(
    MusicItem music,
    String quality,
    CancelToken? cancelToken, {
    required int candidateIndex,
    required Set<String> attemptKeys,
  }) async {
    if (_customSourceQualityResolver == null &&
        _customQualityResolver != null) {
      final result = await _customQualityResolver(music, quality, cancelToken);
      return result == null
          ? null
          : _QualityAttempt(
              result: PlayUrlResult(
                url: result.url,
                requestedQuality: result.requestedQuality,
                actualQuality: result.actualQuality,
                platform: resolvePlatform(music),
                songId: result.songId,
              ),
              sourceIndex: 0,
              candidateIndex: candidateIndex,
              songId: result.songId,
            );
    }
    final platform = resolvePlatform(music);
    final musicForScript = music.copyWith(platform: platform);
    final sourceIds =
        _enabledCustomSourceIds?.call() ??
        _customSourceService.enabledSources.map((source) => source.id).toList();
    _QualityAttempt? bestBelow;
    for (var sourceIndex = 0; sourceIndex < sourceIds.length; sourceIndex++) {
      final sourceId = sourceIds[sourceIndex];
      _throwIfCancelled(cancelToken);
      try {
        if (_customSourceQualityResolver != null) {
          final result = await _customSourceQualityResolver(
            sourceId,
            musicForScript,
            quality,
            cancelToken,
          );
          _throwIfCancelled(cancelToken);
          if (result == null || !isPlayableMediaUrl(result.url)) continue;
          final normalized = PlayUrlResult(
            url: result.url,
            requestedQuality: quality,
            actualQuality: result.actualQuality,
            platform: platform,
            songId: result.songId,
          );
          if (!isQualityBelow(normalized.actualQuality, quality)) {
            return _QualityAttempt(
              result: normalized,
              sourceIndex: sourceIndex,
              candidateIndex: candidateIndex,
              songId: normalized.songId,
            );
          }
          bestBelow = _betterProvisional(
            bestBelow,
            _QualityAttempt(
              result: normalized,
              sourceIndex: sourceIndex,
              candidateIndex: candidateIndex,
              songId: normalized.songId,
            ),
          );
          continue;
        }
        final effectiveQuality = await _customSourceService
            .effectiveMusicQuality(sourceId, platform, quality);
        if (effectiveQuality == null ||
            !attemptKeys.add('$sourceId|$effectiveQuality')) {
          continue;
        }
        final detailed = await _customSourceService
            .getMusicUrlDetailed(sourceId, musicForScript, quality: quality)
            .timeout(const Duration(seconds: 20));
        _throwIfCancelled(cancelToken);
        final rawUrl = detailed?.url;
        final url = rawUrl == null ? null : normalizeMediaUrl(rawUrl);
        if (!isPlayableMediaUrl(url)) {
          debugPrint(
            '[getPlayUrl] 自定义源 $sourceId q=$quality 返回不可播放URL: ${rawUrl ?? 'null'}',
          );
          continue;
        }
        final result = PlayUrlResult(
          url: url!,
          requestedQuality: quality,
          actualQuality:
              normalizeScriptQuality(detailed?.type) ??
              correctQualityFromUrl(url, quality),
          platform: platform,
        );
        if (!isQualityBelow(result.actualQuality, quality)) {
          return _QualityAttempt(
            result: result,
            sourceIndex: sourceIndex,
            candidateIndex: candidateIndex,
            songId: result.songId,
          );
        }
        bestBelow = _betterProvisional(
          bestBelow,
          _QualityAttempt(
            result: result,
            sourceIndex: sourceIndex,
            candidateIndex: candidateIndex,
            songId: result.songId,
          ),
        );
      } catch (error) {
        if (error is DioException && CancelToken.isCancel(error)) rethrow;
        debugPrint('[getPlayUrl] 自定义源 $sourceId q=$quality 失败: $error');
      }
    }
    return bestBelow;
  }

  Future<_QualityAttempt?> _resolveBuiltInQuality(
    MusicItem music,
    String quality,
    CancelToken? cancelToken, {
    required int candidateIndex,
  }) async {
    if (_builtInQualityResolver != null) {
      final result = await _builtInQualityResolver(music, quality, cancelToken);
      return result == null
          ? null
          : _QualityAttempt(
              result: PlayUrlResult(
                url: result.url,
                requestedQuality: result.requestedQuality,
                actualQuality: result.actualQuality,
                platform: resolvePlatform(music),
                songId: result.songId,
              ),
              sourceIndex: 0,
              candidateIndex: candidateIndex,
              songId: result.songId,
            );
    }
    final platform = resolvePlatform(music);
    if (platform != 'kw' && platform != 'tx' && platform != 'wy') return null;
    try {
      final detailed = await _builtInSources
          .getMusicUrlExactDetailed(platform, music, quality: quality)
          .timeout(const Duration(seconds: 8));
      _throwIfCancelled(cancelToken);
      final url = detailed == null ? null : normalizeMediaUrl(detailed.url);
      if (!isPlayableMediaUrl(url)) return null;
      return _QualityAttempt(
        result: PlayUrlResult(
          url: url!,
          requestedQuality: quality,
          actualQuality: detailed!.actualQuality,
          platform: platform,
          songId: songIdOf(music),
        ),
        sourceIndex: 0,
        candidateIndex: candidateIndex,
      );
    } catch (error) {
      if (error is DioException && CancelToken.isCancel(error)) rethrow;
      return null;
    }
  }

  String songIdOf(MusicItem music) {
    if (music.songmid?.isNotEmpty == true) return music.songmid!;
    if (music.hash?.isNotEmpty == true) return music.hash!;
    return music.id;
  }

  void _throwIfCancelled(CancelToken? cancelToken) {
    final error = cancelToken?.cancelError;
    if (error != null) throw error;
  }

  _QualityAttempt? _betterProvisional(
    _QualityAttempt? current,
    _QualityAttempt candidate,
  ) {
    if (current == null) return candidate;
    final actualComparison = qualityRankIndex(
      candidate.result.actualQuality,
    ).compareTo(qualityRankIndex(current.result.actualQuality));
    if (actualComparison < 0 ||
        (actualComparison == 0 &&
            (candidate.sourceIndex < current.sourceIndex ||
                (candidate.sourceIndex == current.sourceIndex &&
                    candidate.candidateIndex < current.candidateIndex)))) {
      return candidate;
    }
    return current;
  }

  Future<String?> getLyric(MusicItem music) async {
    debugPrint(
      '[MusicSourceService] getLyric: platform=${music.platform}, source=${music.source}, songmid=${music.songmid}',
    );

    final platform = music.platform.isNotEmpty ? music.platform : music.source;
    if (platform.isNotEmpty && platform != 'custom' && platform != 'test') {
      // Built-in platform lyrics include QQ QRC/YRC word timing. Prefer them
      // over a custom source's plain LRC so an enabled source cannot silently
      // remove the platform's word-by-word rendering.
      debugPrint('[MusicSourceService] 尝试内置源 platform=$platform');
      final lyric = await _builtInSources.getLyric(platform, music);
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 内置源 $platform 返回歌词');
        return lyric;
      }
      debugPrint('[MusicSourceService] 内置源 $platform 返回空');
    }

    final enabledSources = _customSourceService.enabledSources;
    if (enabledSources.isNotEmpty) {
      debugPrint('[MusicSourceService] 尝试 ${enabledSources.length} 个自定义源');
    }
    for (final source in enabledSources) {
      final lyric = await _customSourceService
          .getLyric(source.id, music)
          .catchError((e) {
            debugPrint('[MusicSourceService] 自定义源 ${source.id} 歌词失败: $e');
            return null;
          });
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 自定义源 ${source.id} 返回歌词');
        return lyric;
      }
    }

    final sourcePlatform = platform;
    final fallbackPlatforms = MusicSourceService.fallbackPlatforms
        .where(
          (pid) => pid != sourcePlatform && _builtInSources.get(pid) != null,
        )
        .toList(growable: false);
    for (final pid in fallbackPlatforms) {
      final matches = await _builtInSources
          .search(pid, music.name, page: 1, limit: 10)
          .catchError((_) => <MusicItem>[]);
      final candidate = _bestSongMatch(music, matches);
      if (candidate == null) continue;
      final lyric = await _builtInSources.getLyric(pid, candidate);
      if (lyric != null && lyric.isNotEmpty) {
        debugPrint('[MusicSourceService] 歌词跨平台回退 $sourcePlatform -> $pid');
        return lyric;
      }
    }

    for (final pid in MusicSourceService.fallbackPlatforms) {
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
    String platformId,
    String songListId, {
    int page = 1,
    int limit = 50,
  }) async {
    final enabledSources = _customSourceService.enabledSources;
    for (final source in enabledSources) {
      try {
        final songs = await _customSourceService.getSongListDetail(
          source.id,
          songListId,
          source: platformId,
          page: page,
        );
        if (songs.isNotEmpty) return songs;
      } catch (_) {}
    }
    return _builtInSources.getSongListDetail(
      platformId,
      songListId,
      page: page,
      limit: limit,
    );
  }

  void dispose() {
    _builtInSources.dispose();
  }
}
