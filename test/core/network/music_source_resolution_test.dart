import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';
import 'package:lx_music_flutter/features/custom_source/domain/custom_source_service.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

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

  test('retains a low-quality result only after preferred candidates fail',
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

    expect(calls, ['flac', '320k', '192k', '128k']);
    expect(result?.requestedQuality, 'flac');
    expect(result?.actualQuality, '128k');
  });

  test('a downgrade at an intermediate quality does not stop fallback',
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

    expect(calls, ['flac', '320k', '192k', '128k']);
    expect(result?.requestedQuality, 'flac');
    expect(result?.actualQuality, '128k');
  });

  test('enabled custom sources retain priority over built-in fallback',
      () async {
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

    expect(result, isNull);
    expect(builtInCalls, 0);
  });

  test('built-in fallback attempts each quality once when custom is absent',
      () async {
    final calls = <String>[];
    final service = MusicSourceService(
      CustomSourceService(),
      hasEnabledCustomSources: () => false,
      builtInQualityResolver: (music, quality, cancelToken) async {
        calls.add(quality);
        return quality == '192k' ? playable(quality) : null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: '320k',
    );

    expect(calls, ['320k', '192k']);
    expect(result?.requestedQuality, '320k');
    expect(result?.actualQuality, '192k');
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

  test('progressively better downgrade replaces lower provisional result',
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

    expect(result?.actualQuality, '192k');
    expect(result?.requestedQuality, 'flac');
  });

  test('higher-priority source wins equal actual quality across candidates',
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
        if (sourceId == 'A' && quality == '320k') {
          return playable(quality, actual: '192k');
        }
        return null;
      },
    );

    final result = await service.resolvePlayableUrl(
      item,
      preferredQuality: 'flac',
    );

    expect(result?.url, 'https://media.example/320k.mp3');
    expect(result?.actualQuality, '192k');
    expect(result?.requestedQuality, 'flac');
    expect(calls, [
      'A:flac',
      'B:flac',
      'A:320k',
      'B:320k',
      'A:192k',
      'B:192k',
      'A:128k',
      'B:128k',
    ]);
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
