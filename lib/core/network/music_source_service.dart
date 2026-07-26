import 'package:flutter/foundation.dart';
import '../../features/player/domain/music_item.dart';
import '../../features/custom_source/domain/custom_source_service.dart';
import '../music_source/platform/built_in_source_manager.dart';
import 'play_url_result.dart';

class MusicSourceService {
  final CustomSourceService _customSourceService;
  final BuiltInSourceManager _builtInSources = BuiltInSourceManager();

  MusicSourceService(this._customSourceService);

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
    final result = await getPlayUrlDetailed(music, quality: quality);
    return result?.url;
  }

  Future<PlayUrlResult?> getPlayUrlDetailed(MusicItem music,
      {String quality = '320k'}) async {
    final resolvedQuality = quality.isEmpty ? '320k' : quality;
    final songId = (music.songmid?.isNotEmpty == true)
        ? music.songmid!
        : (music.hash?.isNotEmpty == true ? music.hash! : music.id);
    final platform = resolvePlatform(music);
    debugPrint(
        '[getPlayUrl] 开始解析: platform=$platform, songId=$songId, quality=$resolvedQuality, source=${music.source}');

    final qualities = qualityChain(resolvedQuality);
    PlayUrlResult? bestBelow;

    // 1. 自定义 JS 音源：只请求当前档；假成功低码率不直接认，留给外层降级
    final enabledSources = _customSourceService.enabledSources;
    debugPrint(
        '[getPlayUrl] 已启用自定义源: ${enabledSources.map((s) => '${s.id}/${s.name}').join(', ')} (共${enabledSources.length})');
    final musicForScript = music.copyWith(platform: platform);
    for (final source in enabledSources) {
      try {
        debugPrint(
            '[getPlayUrl] 调自定义源 ${source.name} q=$resolvedQuality platform=$platform songId=$songId');
        final url = await _customSourceService
            .getMusicUrl(source.id, musicForScript, quality: resolvedQuality)
            .timeout(const Duration(seconds: 20));
        if (url != null && url.isNotEmpty) {
          if (!isPlayableMediaUrl(url)) {
            final host = Uri.tryParse(url)?.host ?? '?';
            final path = Uri.tryParse(url)?.path ?? '?';
            debugPrint(
                '[getPlayUrl] 自定义源 ${source.name} q=$resolvedQuality 无效地址 host=$host path=$path');
            continue;
          }
          final actual = correctQualityFromUrl(url, resolvedQuality);
          final result = PlayUrlResult(
            url: url,
            requestedQuality: resolvedQuality,
            actualQuality: actual,
            platform: platform,
          );
          if (isQualityBelow(actual, resolvedQuality)) {
            debugPrint(
                '[getPlayUrl] 自定义源 ${source.name} q=$resolvedQuality 实际=$actual 偏低，继续降级');
            bestBelow ??= result;
            continue;
          }
          debugPrint(
              '[getPlayUrl] 自定义源成功 ${source.name} q=$resolvedQuality actual=$actual');
          return result;
        }
        debugPrint('[getPlayUrl] 自定义源 ${source.name} q=$resolvedQuality 返回空');
      } catch (e) {
        debugPrint(
            '[getPlayUrl] 自定义源 ${source.id}/${source.name} q=$resolvedQuality 失败: $e');
      }
    }

    // 2. 内置平台源：按降级链尝试
    if (platform == 'kw' || platform == 'tx' || platform == 'wy') {
      for (final q in qualities) {
        try {
          final url = await _builtInSources
              .getMusicUrl(platform, music, quality: q)
              .timeout(const Duration(seconds: 8));
          if (url != null && url.isNotEmpty) {
            if (!isPlayableMediaUrl(url)) {
              debugPrint('[getPlayUrl] 内置源 $platform q=$q 返回无效播放地址，跳过');
              continue;
            }
            final actual = correctQualityFromUrl(url, q);
            final result = PlayUrlResult(
              url: url,
              requestedQuality: resolvedQuality,
              actualQuality: actual,
              platform: platform,
            );
            if (isQualityBelow(actual, resolvedQuality) &&
                q == resolvedQuality) {
              debugPrint('[getPlayUrl] 内置源 $platform q=$q 实际=$actual 偏低，继续降级');
              bestBelow ??= result;
              continue;
            }
            return result;
          }
        } catch (_) {}
      }
    }

    if (bestBelow != null) {
      debugPrint('[getPlayUrl] 使用偏低但可播结果 actual=${bestBelow.actualQuality}');
      return bestBelow;
    }
    debugPrint('[getPlayUrl] 所有源均失败');
    return null;
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
