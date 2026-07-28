import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/core/network/music_source_service.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';
import 'package:lx_music_flutter/features/download/domain/download_service.dart';
import 'package:lx_music_flutter/features/download/domain/download_task.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

void main() {
  test('safeDownloadBaseName strips path separators', () {
    expect(DownloadService.safeDownloadBaseName('a/b:c'), 'a_b_c');
    expect(DownloadService.safeDownloadBaseName(''), 'track');
  });

  test('promote part must not delete .part before rename (filesystem)',
      () async {
    final dir = await Directory.systemTemp.createTemp('dl_part_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    const base = 'song123';
    final part = File('${dir.path}/$base.part');
    final finalPath = '${dir.path}/$base.mp3';
    // 模拟旧 bug：cleanup 删掉 .part
    await part
        .writeAsBytes(List<int>.filled(4096, 1)..setAll(0, [0x49, 0x44, 0x33]));
    expect(await part.exists(), isTrue);

    // 正确顺序：rename 先于清理其它扩展名
    final out = File(finalPath);
    if (await out.exists()) await out.delete();
    await part.rename(finalPath);
    expect(await File(finalPath).exists(), isTrue);
    expect(await part.exists(), isFalse);

    // 清理 sibling 时不得匹配 .part（已不存在）且不得删 keep
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = e.uri.pathSegments.last;
      if (name == '$base.part') {
        fail('must not keep deleting part after promote');
      }
      if (name.startsWith('$base.') && e.path != finalPath) {
        await e.delete();
      }
    }
    expect(await File(finalPath).exists(), isTrue);
  });

  test('toMusicItem restores ids needed for URL resolve', () {
    final task = DownloadTask(
      id: 't1',
      musicId: 'tx_001B',
      name: '告白气球',
      singer: '周杰伦',
      createdAt: DateTime(2026, 1, 1),
      platform: 'tx',
      source: 'linglan',
      songmid: '001Bbywq2gicae',
      hash: null,
      album: '周杰伦的床边故事',
      quality: '320k',
      duration: 215,
      url: 'https://expired.cdn.example/old.mp3?sign=dead',
    );

    final music = task.toMusicItem();
    expect(music.id, 'tx_001B');
    expect(music.platform, 'tx');
    expect(music.source, 'linglan');
    expect(music.songmid, '001Bbywq2gicae');
    expect(music.name, '告白气球');
    // toMusicItem 不携带 CDN 直链；下载服务也始终重新解析
    expect(music.url, isNull);
  });

  test('qualityChain used for download always starts with preferred', () {
    final chain = MusicSourceService.qualityChain('flac');
    expect(chain.first, 'flac');
    expect(chain, contains('320k'));
    expect(chain, contains('128k'));
  });

  test('copyWith can clear savePath and errorMsg', () {
    final task = DownloadTask(
      id: 't1',
      musicId: 'm1',
      name: 'n',
      singer: 's',
      createdAt: DateTime(2026, 1, 1),
      savePath: '/tmp/a.mp3',
      errorMsg: 'boom',
    );
    final cleared = task.copyWith(clearSavePath: true, clearErrorMsg: true);
    expect(cleared.savePath, isNull);
    expect(cleared.errorMsg, isNull);
  });

  test('isPlayableMediaUrl rejects QQ root fake success', () {
    expect(isPlayableMediaUrl('http://wx.music.tc.qq.com/'), isFalse);
    expect(
      isPlayableMediaUrl('https://wx.music.tc.qq.com/abc/file.mp3'),
      isTrue,
    );
  });

  test('extensionFromBytes detects flac and mp3', () {
    expect(
      PlaybackCacheService.extensionFromBytes(
        [0x66, 0x4c, 0x61, 0x43, 0, 0, 0, 0],
        fallback: '.mp3',
      ),
      '.flac',
    );
    expect(
      PlaybackCacheService.extensionFromBytes(
        [0x49, 0x44, 0x33, 0, 0, 0],
        fallback: '.audio',
      ),
      '.mp3',
    );
  });

  test('fresh-link download resolves once when the first link succeeds',
      () async {
    var resolveCalls = 0;
    final result = PlayUrlResult(
      url: 'https://media.example/one.mp3',
      requestedQuality: 'flac',
      actualQuality: '320k',
      platform: 'tx',
    );

    final downloaded = await downloadWithFreshLinkRetry(
      resolve: () async {
        resolveCalls++;
        return result;
      },
      download: (_) async {},
    );

    expect(resolveCalls, 1);
    expect(downloaded, same(result));
  });

  test('fresh-link download re-resolves only after an expired HTTP response',
      () async {
    var resolveCalls = 0;
    var downloadCalls = 0;

    final downloaded = await downloadWithFreshLinkRetry(
      resolve: () async {
        resolveCalls++;
        return PlayUrlResult(
          url: 'https://media.example/$resolveCalls.mp3',
          requestedQuality: 'flac',
          actualQuality: '320k',
          platform: 'tx',
        );
      },
      download: (_) async {
        downloadCalls++;
        if (downloadCalls == 1) {
          throw DioException(
            requestOptions: RequestOptions(path: '/expired'),
            response: Response(
              requestOptions: RequestOptions(path: '/expired'),
              statusCode: 403,
            ),
          );
        }
      },
    );

    expect(resolveCalls, 2);
    expect(downloadCalls, 2);
    expect(downloaded?.url, 'https://media.example/2.mp3');
  });

  test('fresh-link download does not re-resolve after another HTTP failure',
      () async {
    var resolveCalls = 0;

    await expectLater(
      downloadWithFreshLinkRetry(
        resolve: () async {
          resolveCalls++;
          return PlayUrlResult(
            url: 'https://media.example/one.mp3',
            requestedQuality: 'flac',
            actualQuality: '320k',
            platform: 'tx',
          );
        },
        download: (_) async {
          throw DioException(
            requestOptions: RequestOptions(path: '/failed'),
            response: Response(
              requestOptions: RequestOptions(path: '/failed'),
              statusCode: 500,
            ),
          );
        },
      ),
      throwsA(isA<DioException>()),
    );
    expect(resolveCalls, 1);
  });

  test('fresh-link retry rejects pre-cancellation before resolve', () async {
    final token = CancelToken()..cancel('paused');
    var resolveCalls = 0;

    await expectLater(
      downloadWithFreshLinkRetry(
        cancelToken: token,
        resolve: () async {
          resolveCalls++;
          return null;
        },
        download: (_) async {},
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
    expect(resolveCalls, 0);
  });

  test('cancellation after expired response prevents fresh re-resolve',
      () async {
    final token = CancelToken();
    var resolveCalls = 0;

    await expectLater(
      downloadWithFreshLinkRetry(
        cancelToken: token,
        resolve: () async {
          resolveCalls++;
          return const PlayUrlResult(
            url: 'https://media.example/expired.mp3',
            requestedQuality: '320k',
            actualQuality: '320k',
            platform: 'tx',
          );
        },
        download: (_) async {
          token.cancel('paused');
          throw DioException(
            requestOptions: RequestOptions(path: '/expired'),
            response: Response(
              requestOptions: RequestOptions(path: '/expired'),
              statusCode: 403,
            ),
          );
        },
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
    expect(resolveCalls, 1);
  });

  test('fresh resolver rejects pre-cancellation instead of returning null',
      () async {
    final token = CancelToken()..cancel('paused');
    var serviceCalls = 0;

    await expectLater(
      resolveFreshPlayableUrl(
        music: MusicItem(
          id: 'm1',
          name: 'Song',
          singer: 'Singer',
          platform: 'tx',
          source: 'tx',
        ),
        quality: '320k',
        cancelToken: token,
        resolve: (music, quality, cancelToken) async {
          serviceCalls++;
          return null;
        },
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
    expect(serviceCalls, 0);
  });

  test('fresh resolver cancellation wins over simultaneous resolver error',
      () async {
    final token = CancelToken();

    await expectLater(
      resolveFreshPlayableUrl(
        music: MusicItem(
          id: 'm1',
          name: 'Song',
          singer: 'Singer',
          platform: 'tx',
          source: 'tx',
        ),
        quality: '320k',
        cancelToken: token,
        resolve: (music, quality, cancelToken) async {
          token.cancel('paused');
          throw StateError('resolver failed');
        },
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
  });

  test('download cancellation wins over simultaneous non-expired HTTP error',
      () async {
    final token = CancelToken();

    await expectLater(
      downloadWithFreshLinkRetry(
        cancelToken: token,
        resolve: () async => const PlayUrlResult(
          url: 'https://media.example/song.mp3',
          requestedQuality: '320k',
          actualQuality: '320k',
          platform: 'tx',
        ),
        download: (_) async {
          token.cancel('paused');
          throw DioException(
            requestOptions: RequestOptions(path: '/failed'),
            response: Response(
              requestOptions: RequestOptions(path: '/failed'),
              statusCode: 500,
            ),
          );
        },
      ),
      throwsA(
          isA<DioException>().having(CancelToken.isCancel, 'cancelled', true)),
    );
  });

  test('cancelled status is preserved and never replaced with failed', () {
    expect(
      downloadFailureStatus(DownloadStatus.paused, cancelled: true),
      DownloadStatus.paused,
    );
  });

  test('cancelled active download becomes paused rather than failed', () {
    expect(
      downloadFailureStatus(DownloadStatus.downloading, cancelled: true),
      DownloadStatus.paused,
    );
  });

  test('ordinary active download failure becomes failed', () {
    expect(
      downloadFailureStatus(DownloadStatus.downloading, cancelled: false),
      DownloadStatus.failed,
    );
  });
}
