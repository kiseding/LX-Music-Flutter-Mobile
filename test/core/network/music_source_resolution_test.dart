import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';
import 'package:lx_music_flutter/core/music_source/platform/built_in_source_manager.dart';
import 'package:lx_music_flutter/core/music_source/platform/music_platform.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

class _LyricPlatform extends MusicPlatform {
  _LyricPlatform(this.lyric);

  final String lyric;

  @override
  String get id => 'tx';

  @override
  String get name => 'TX';

  @override
  Future<String?> getLyric(MusicItem music) async => lyric;

  @override
  Future<String?> getMusicUrl(MusicItem music,
          {String quality = '128k'}) async =>
      null;

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) => MusicItem(
        id: raw['id']?.toString() ?? '',
        name: raw['name']?.toString() ?? '',
        singer: raw['singer']?.toString() ?? '',
        source: source,
        platform: id,
      );

  @override
  Future<List<MusicItem>> search(String keyword,
          {int page = 1, int limit = 20}) async =>
      [];
}

class _SearchPlatform extends MusicPlatform {
  _SearchPlatform(
      {required this.platformId, this.results = const [], this.lyric});

  final String platformId;
  final List<MusicItem> results;
  final String? lyric;

  @override
  String get id => platformId;

  @override
  String get name => platformId;

  @override
  Future<List<MusicItem>> search(String keyword,
          {int page = 1, int limit = 20}) async =>
      results;

  @override
  Future<String?> getLyric(MusicItem music) async => lyric;

  @override
  Future<String?> getMusicUrl(MusicItem music,
          {String quality = '128k'}) async =>
      null;

  @override
  MusicItem parseItem(Map<String, dynamic> raw, String source) => MusicItem(
      id: raw['id']?.toString() ?? '',
      name: raw['name']?.toString() ?? '',
      singer: raw['singer']?.toString() ?? '',
      source: source,
      platform: id);
}

class _TrackingSearchPlatform extends _SearchPlatform {
  _TrackingSearchPlatform(
    String platformId,
    this.searched, {
    super.results,
  }) : super(platformId: platformId);

  final List<String> searched;

  @override
  Future<List<MusicItem>> search(String keyword,
      {int page = 1, int limit = 20}) async {
    searched.add(platformId);
    return super.search(keyword, page: page, limit: limit);
  }
}

void main() {
  final item = MusicItem(
    id: 'song-1',
    name: 'Song',
    singer: 'Singer',
    platform: 'tx',
    source: 'tx',
  );

  PlayUrlResult playable(String quality, {String? actual}) => PlayUrlResult(
        url: 'https://media.example/$quality.mp3',
        requestedQuality: quality,
        actualQuality: actual ?? quality,
        platform: 'tx',
      );

  test('unknown platform is not remapped to another platform', () {
    final service = MusicSourceService(CustomSourceService());

    expect(
      service.resolvePlatform(MusicItem(
        id: 'unknown',
        name: 'Song',
        singer: 'Singer',
        platform: 'custom',
        source: 'custom',
      )),
      isEmpty,
    );
    expect(
      service.resolvePlatform(MusicItem(
        id: 'kg',
        name: 'Song',
        singer: 'Singer',
        platform: 'kg',
        source: 'kg',
      )),
      'kg',
    );
  });

  test('known platform lyrics prefer built-in word timing', () async {
    const qrc = '[0,1000]逐(0,500)字(500,500)';
    final service = MusicSourceService(
      CustomSourceService(),
      builtInSources: BuiltInSourceManager(platforms: [_LyricPlatform(qrc)]),
    );

    expect(await service.getLyric(item), qrc);
  });

  test('custom source keeps an HTTP media URL unchanged', () async {
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        return PlayUrlResult(
          url: 'http://media.example.test/song.mp3?token=signature',
          requestedQuality: quality,
          actualQuality: quality,
          platform: 'tx',
        );
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: '320k',
    );

    expect(result?.url, 'http://media.example.test/song.mp3?token=signature');
  });

  test('failed custom platform falls back through a matching platform result',
      () async {
    final kwSong = MusicItem(
      id: 'kw-1',
      name: 'Song',
      singer: 'Singer',
      source: 'kw',
      platform: 'kw',
      songmid: 'kw-1',
    );
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      enabledCustomSourceIds: () => ['source'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        if (music.platform == 'kw') {
          return PlayUrlResult(
            url: playable(quality).url,
            requestedQuality: quality,
            actualQuality: quality,
            platform: 'kw',
          );
        }
        return null;
      },
      builtInSources: BuiltInSourceManager(platforms: [
        _SearchPlatform(platformId: 'tx'),
        _SearchPlatform(platformId: 'kw', results: [kwSong]),
      ]),
    );

    final result =
        await service.resolvePlayableUrl(item, preferredQuality: '320k');

    expect(result?.platform, 'kw');
    expect(result?.url, contains('/320k.mp3'));
  });

  test('incomplete imported metadata is refreshed from the same platform',
      () async {
    final refreshedSong = MusicItem(
      id: 'song-1',
      name: 'Song',
      singer: 'Singer',
      source: 'tx',
      platform: 'tx',
      songmid: 'song-1',
      meta: const {'strMediaMid': 'media-1'},
    );
    final service = MusicSourceService(
      CustomSourceService(),
      builtInQualityResolver: (music, quality, cancelToken) async {
        if (music.meta?['strMediaMid'] != 'media-1') return null;
        return playable(quality);
      },
      builtInSources: BuiltInSourceManager(platforms: [
        _SearchPlatform(platformId: 'tx', results: [refreshedSong]),
      ]),
    );

    final result =
        await service.resolvePlayableUrl(item, preferredQuality: '320k');

    expect(result?.url, 'https://media.example/320k.mp3');
    expect(result?.platform, 'tx');
  });

  test('automatic fallback only searches tx kw and wy', () async {
    final searched = <String>[];
    final kgSong = MusicItem(
      id: 'kg-1',
      name: 'Song',
      singer: 'Singer',
      source: 'kg',
      platform: 'kg',
    );
    final service = MusicSourceService(
      CustomSourceService(),
      builtInQualityResolver: (music, quality, cancelToken) async => null,
      builtInSources: BuiltInSourceManager(platforms: [
        _TrackingSearchPlatform('tx', searched),
        _TrackingSearchPlatform('kg', searched, results: [kgSong]),
        _TrackingSearchPlatform('kw', searched),
        _TrackingSearchPlatform('wy', searched),
      ]),
    );

    expect(
      await service.resolvePlayableUrl(
        item,
        preferredQuality: '320k',
        allowSamePlatformRefresh: false,
      ),
      isNull,
    );
    expect(searched, ['kw', 'wy']);
  });

  test('resolved result reports the platform actually being resolved',
      () async {
    final kwSong = MusicItem(
      id: 'kw-1',
      name: 'Song',
      singer: 'Singer',
      source: 'kw',
      platform: 'kw',
    );
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        if (music.platform != 'kw') return null;
        return PlayUrlResult(
          url: 'https://media.example/kw.mp3',
          requestedQuality: quality,
          actualQuality: quality,
          platform: 'tx',
        );
      },
      builtInQualityResolver: (music, quality, cancelToken) async => null,
      builtInSources: BuiltInSourceManager(platforms: [
        _SearchPlatform(platformId: 'tx'),
        _SearchPlatform(platformId: 'kw', results: [kwSong]),
      ]),
    );

    final result =
        await service.resolvePlayableUrl(item, preferredQuality: '320k');

    expect(result?.platform, 'kw');
  });

  test('lyrics fall back by matching the song on another platform', () async {
    const lyric = '[0,1000]逐(0,500)字(500,500)';
    final kwSong = MusicItem(
      id: 'kw-1',
      name: 'Song',
      singer: 'Singer',
      source: 'kw',
      platform: 'kw',
      songmid: 'kw-1',
    );
    final service = MusicSourceService(
      CustomSourceService(),
      builtInSources: BuiltInSourceManager(platforms: [
        _SearchPlatform(platformId: 'tx'),
        _SearchPlatform(platformId: 'kw', results: [kwSong], lyric: lyric),
      ]),
    );

    expect(await service.getLyric(item), lyric);
  });

  test('each quality is attempted once and actual downgrade is reported',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        return quality == '320k' ? playable(quality) : null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(calls, ['flac', '320k']);
    expect(result?.requestedQuality, 'flac');
    expect(result?.actualQuality, '320k');
  });

  test('uses a playable custom downgrade without requesting lower qualities',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        if (quality == 'flac') return playable(quality, actual: '128k');
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(calls, ['flac']);
    expect(result?.requestedQuality, 'flac');
    expect(result?.actualQuality, '128k');
  });

  test('custom downgrade stops before repeating at lower request qualities',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        return playable(quality, actual: '128k');
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(calls, ['flac']);
    expect(result?.requestedQuality, 'flac');
    expect(result?.actualQuality, '128k');
  });

  test('built-in source is used when every custom attempt fails', () async {
    var builtInCalls = 0;
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async => null,
      builtInQualityResolver: (music, quality, cancelToken) async {
        builtInCalls++;
        return playable(quality);
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: '320k',
    );

    expect(result?.url, 'https://media.example/320k.mp3');
    expect(builtInCalls, 1);
  });

  test('successful custom source still prevents built-in fallback', () async {
    var builtInCalls = 0;
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async =>
          playable(quality),
      builtInQualityResolver: (music, quality, cancelToken) async {
        builtInCalls++;
        return playable(quality);
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: '320k',
    );

    expect(result?.url, 'https://media.example/320k.mp3');
    expect(builtInCalls, 0);
  });

  test('built-in fallback skips the hidden 192k candidate',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => false,
      builtInQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        return quality == '128k' ? playable(quality) : null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: '320k',
    );

    expect(calls, ['320k', '128k']);
    expect(result?.requestedQuality, '320k');
    expect(result?.actualQuality, '128k');
  });

  test('cancellation stops fallback before another quality attempt', () async {
    final calls = <String>[];
    final token = CancelToken();
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        token.cancel('stop');
        return null;
      },
    );

    await expectLater(
      service.resolvePlayableUrl(
        item,
        preferredQuality: 'flac',
        cancelToken: token,
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
    expect(calls, ['flac']);
  });

  test('later custom source exact result beats earlier provisional result',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        calls.add('$sourceId:$quality');
        return sourceId == 'A'
            ? playable(quality, actual: '128k')
            : playable(quality);
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(calls, ['A:flac', 'B:flac']);
    expect(result?.actualQuality, 'flac');
    expect(result?.requestedQuality, 'flac');
  });

  test('best provisional result improves by actual quality across sources',
      () async {
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        if (quality != 'flac') return null;
        return sourceId == 'A'
            ? playable(quality, actual: '128k')
            : playable(quality, actual: '192k');
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.actualQuality, '192k');
    expect(result?.requestedQuality, 'flac');
  });

  test('equal provisional quality keeps earlier source priority', () async {
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        if (quality != 'flac') return null;
        return PlayUrlResult(
          url: 'https://media.example/$sourceId.mp3',
          requestedQuality: quality,
          actualQuality: '128k',
          platform: 'tx',
        );
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.url, 'https://media.example/A.mp3');
  });

  test('higher provisional actual quality beats later exact candidate',
      () async {
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        if (quality == 'hires') return playable(quality, actual: 'flac');
        if (quality == '320k') return playable(quality);
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'hires',
    );

    expect(result?.actualQuality, 'flac');
    expect(result?.requestedQuality, 'hires');
  });

  test('first playable custom downgrade is used immediately',
      () async {
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => true,
      customQualityResolver: (music, quality, cancelToken) async {
        if (quality == 'flac') return playable(quality, actual: '128k');
        if (quality == '320k') return playable(quality, actual: '192k');
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.actualQuality, '128k');
    expect(result?.requestedQuality, 'flac');
  });

  test('custom sources compare results within the requested quality',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        calls.add('$sourceId:$quality');
        if (sourceId == 'B' && quality == 'flac') {
          return playable(quality, actual: '192k');
        }
        if (sourceId == 'A' && quality == 'flac') {
          return playable(quality, actual: '192k');
        }
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.url, 'https://media.example/flac.mp3');
    expect(result?.actualQuality, '192k');
    expect(result?.requestedQuality, 'flac');
    expect(calls, ['A:flac', 'B:flac']);
  });

  test('inverse cross-candidate tie still follows source priority', () async {
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        if (sourceId == 'A' && quality == 'flac') {
          return playable(quality, actual: '192k');
        }
        if (sourceId == 'B' && quality == '320k') {
          return playable(quality, actual: '192k');
        }
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.url, 'https://media.example/flac.mp3');
    expect(result?.actualQuality, '192k');
  });

  test('honest early source success does not query lower-priority source',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      enabledCustomSourceIds: () => ['A', 'B'],
      customSourceQualityResolver:
          (sourceId, music, quality, cancelToken) async {
        calls.add('$sourceId:$quality');
        return sourceId == 'A' && quality == 'flac' ? playable(quality) : null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.actualQuality, 'flac');
    expect(calls, ['A:flac']);
  });
}
