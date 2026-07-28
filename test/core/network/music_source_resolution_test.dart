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
}
