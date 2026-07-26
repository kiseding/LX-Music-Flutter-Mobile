import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PlaybackCacheService cache;
  var downloadCount = 0;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('playback_cache_test_');
    downloadCount = 0;
    cache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {CancelToken? cancelToken}) async {
        downloadCount++;
        final file = File(savePath);
        await file.parent.create(recursive: true);
        final bytes = url.contains('no-extension')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : List<int>.filled(32, downloadCount);
        await file.writeAsBytes(bytes);
      },
    );
    await cache.init();
  });

  tearDown(() async {
    await cache.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('cacheKey is stable for platform|songId|quality', () {
    final a = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: '001abc',
      quality: '320k',
    );
    final b = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: '001abc',
      quality: '320k',
    );
    final c = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: '001abc',
      quality: 'flac',
    );
    expect(a, b);
    expect(a, isNot(c));
    expect(a.length, 40);
  });

  test('getOrDownload downloads once and reuses local file', () async {
    final path1 = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/a.mp3',
      platform: 'tx',
      songId: 'sid1',
      quality: '320k',
    );
    expect(path1, isNotNull);
    expect(File(path1!).existsSync(), isTrue);
    expect(downloadCount, 1);

    final path2 = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/a.mp3',
      platform: 'tx',
      songId: 'sid1',
      quality: '320k',
    );
    expect(path2, path1);
    expect(downloadCount, 1);
  });

  test('expired entries are deleted and re-downloaded', () async {
    final path1 = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.flac',
      platform: 'kw',
      songId: 'old',
      quality: 'flac',
    );
    expect(path1, isNotNull);
    expect(downloadCount, 1);

    final key = PlaybackCacheService.cacheKey(
      platform: 'kw',
      songId: 'old',
      quality: 'flac',
    );
    await cache.debugBackdateEntry(key, daysAgo: 4);
    await cache.purgeExpired();

    expect(File(path1!).existsSync(), isFalse);

    final path2 = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.flac',
      platform: 'kw',
      songId: 'old',
      quality: 'flac',
    );
    expect(path2, isNotNull);
    expect(File(path2!).existsSync(), isTrue);
    expect(downloadCount, 2);
  });

  test('toPlayableUri prefixes file path', () {
    expect(
      PlaybackCacheService.toPlayableUri('/tmp/x.mp3'),
      'file:///tmp/x.mp3',
    );
    expect(
      PlaybackCacheService.toPlayableUri('file:///tmp/x.mp3'),
      'file:///tmp/x.mp3',
    );
  });

  test('detects audio extension from file signature when URL has none', () {
    expect(
      PlaybackCacheService.extensionFromBytes(
        [0x66, 0x4c, 0x61, 0x43, 0, 0, 0, 0],
        fallback: '.audio',
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

  test('no-extension FLAC is saved with a playable extension', () async {
    final path = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/no-extension',
      platform: 'tx',
      songId: 'unknown-ext',
      quality: 'flac',
    );
    expect(path, endsWith('.flac'));
  });

  test('flac quality supplies extension when the header is non-standard', () async {
    final path = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/opaque-stream',
      platform: 'tx',
      songId: 'opaque-flac',
      quality: 'flac',
    );
    expect(path, endsWith('.flac'));
  });

  test('cachedPlayableUri never falls back to a remote URL', () {
    expect(PlaybackCacheService.cachedPlayableUri(null), isNull);
    expect(
      PlaybackCacheService.cachedPlayableUri('/tmp/cached.flac'),
      'file:///tmp/cached.flac',
    );
  });
}
