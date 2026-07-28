import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late PlaybackCacheService cache;
  var downloadCount = 0;
  String? downloadedUrl;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('playback_cache_test_');
    downloadCount = 0;
    downloadedUrl = null;
    cache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {CancelToken? cancelToken}) async {
        downloadCount++;
        downloadedUrl = url;
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

  test('normalizes arbitrary dynamic HTTP media URLs before download',
      () async {
    await cache.getOrDownload(
      remoteUrl: 'http://media.example.com/a.mp3?token=1',
      platform: 'custom',
      songId: 'dynamic-http',
      quality: '128k',
    );

    expect(downloadedUrl, 'https://media.example.com/a.mp3?token=1');
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

  test('flac quality supplies extension when the header is non-standard',
      () async {
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

  test('leased entry survives expiration until its idempotent release',
      () async {
    var now = DateTime(2026, 1, 1);
    final leasedCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = leasedCache;

    final lease = await cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/leased.mp3',
      platform: 'tx',
      songId: 'leased',
      quality: '320k',
    );
    expect(lease, isNotNull);
    now = now.add(const Duration(hours: 2));

    await cache.purgeExpired();
    expect(File(lease!.path).existsSync(), isTrue);
    await lease.release();
    await lease.release();
    await cache.purgeExpired();
    expect(File(lease.path).existsSync(), isFalse);
  });

  test('shared cache leases use exact reference counts', () async {
    var now = DateTime(2026, 1, 1);
    final leasedCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = leasedCache;

    final first = await cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/shared-lease.mp3',
      platform: 'tx',
      songId: 'shared-lease',
      quality: '320k',
    );
    final second = await cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/shared-lease.mp3',
      platform: 'tx',
      songId: 'shared-lease',
      quality: '320k',
    );
    now = now.add(const Duration(hours: 2));

    await first!.release();
    await cache.purgeExpired();
    expect(File(first.path).existsSync(), isTrue);
    await second!.release();
    await cache.purgeExpired();
    expect(File(first.path).existsSync(), isFalse);
  });

  test('leased and inflight entries are excluded from size eviction', () async {
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final sizeCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      maxBytes: 40,
      downloader: (url, savePath, {cancelToken}) async {
        if (url.contains('first')) {
          firstStarted.complete();
          await finishFirst.future;
        }
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = sizeCache;

    final firstFuture = cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/first.mp3',
      platform: 'tx',
      songId: 'first',
      quality: '320k',
    );
    await firstStarted.future;
    final second = await cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/second.mp3',
      platform: 'tx',
      songId: 'second',
      quality: '320k',
    );
    finishFirst.complete();
    final first = await firstFuture;

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(File(first!.path).existsSync(), isTrue);
    expect(File(second!.path).existsSync(), isTrue);
    await second.release();
    await cache.purgeExpired();
    expect(File(first.path).existsSync(), isTrue);
    expect(File(second.path).existsSync(), isFalse);
    await first.release();
  });

  test('cache hits persist lastAccessedAt and size eviction uses true LRU',
      () async {
    var now = DateTime(2026, 1, 1);
    final store = MemoryPlaybackCacheIndexStore();
    final lruCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      clock: () => now,
      maxBytes: 64,
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = lruCache;

    Future<String> get(String id) async {
      final path = await cache.getOrDownload(
        remoteUrl: 'https://cdn.example.com/$id.mp3',
        platform: 'tx',
        songId: id,
        quality: '320k',
      );
      return path!;
    }

    final first = await get('first');
    now = now.add(const Duration(minutes: 1));
    final second = await get('second');
    now = now.add(const Duration(minutes: 1));
    expect(await get('first'), first);
    final persisted = (jsonDecode(store.value!) as List).cast<Map>();
    final firstJson = persisted.firstWhere((item) => item['path'] == first);
    expect(firstJson['lastAccessedAt'], now.millisecondsSinceEpoch);
    now = now.add(const Duration(minutes: 1));
    final third = await get('third');

    expect(File(first).existsSync(), isTrue);
    expect(File(second).existsSync(), isFalse);
    expect(File(third).existsSync(), isTrue);
  });

  test('rejects poisoned outside-root index without deleting outside file',
      () async {
    final outside = await Directory.systemTemp.createTemp('cache_outside_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final outsideFile = File('${outside.path}/song.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 1));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(
          key: PlaybackCacheService.cacheKey(
            platform: 'tx',
            songId: 'poisoned',
            quality: '320k',
          ),
          path: outsideFile.path,
        ),
      ]);
    final safeCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = safeCache;

    await cache.init();
    final result = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/poisoned.mp3',
      platform: 'tx',
      songId: 'poisoned',
      quality: '320k',
    );

    expect(result, isNot(outsideFile.path));
    expect(outsideFile.existsSync(), isTrue);
  });

  test('rejects dot-dot and sibling-prefix persisted paths', () async {
    final parent = tempDir.parent;
    final sibling = Directory('${tempDir.path}_sibling')..createSync();
    addTearDown(() => sibling.deleteSync(recursive: true));
    final escaped =
        File('${parent.path}/${tempDir.path.split('/').last}/../escape.mp3')
          ..writeAsBytesSync(List<int>.filled(32, 1));
    final siblingFile = File('${sibling.path}/song.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 1));
    for (final record in [
      ('dot-dot', escaped.path),
      ('sibling', siblingFile.path),
    ]) {
      final store = MemoryPlaybackCacheIndexStore()
        ..value = jsonEncode([
          _entryJson(
            key: PlaybackCacheService.cacheKey(
              platform: 'tx',
              songId: record.$1,
              quality: '320k',
            ),
            path: record.$2,
          ),
        ]);
      final safeCache = _cacheForPersistedPath(tempDir, store);
      await safeCache.init();
      final result = await safeCache.getOrDownload(
        remoteUrl: 'https://cdn.example.com/${record.$1}.mp3',
        platform: 'tx',
        songId: record.$1,
        quality: '320k',
      );
      expect(result, isNot(record.$2));
      expect(File(record.$2).existsSync(), isTrue);
      await safeCache.dispose();
    }
  });

  test('missing persisted file is removed from the index', () async {
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(
          key: PlaybackCacheService.cacheKey(
            platform: 'tx',
            songId: 'missing',
            quality: '320k',
          ),
          path: '${tempDir.path}/missing.mp3',
        ),
      ]);
    final safeCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = safeCache;

    await cache.init();
    await cache.purgeExpired();

    expect(jsonDecode(store.value!) as List, isEmpty);
  });

  test('rejects a persisted symlink escape without deleting its target',
      () async {
    if (Platform.isWindows) return;
    final outside = await Directory.systemTemp.createTemp('cache_symlink_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final target = File('${outside.path}/song.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 1));
    final link = Link('${tempDir.path}/linked.mp3');
    try {
      await link.create(target.path);
    } on FileSystemException {
      return;
    }
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(
          key: PlaybackCacheService.cacheKey(
            platform: 'tx',
            songId: 'linked',
            quality: '320k',
          ),
          path: link.path,
        ),
      ]);
    final safeCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = safeCache;

    await cache.init();
    final result = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/linked.mp3',
      platform: 'tx',
      songId: 'linked',
      quality: '320k',
    );

    expect(result, isNot(link.path));
    expect(target.existsSync(), isTrue);
  });

  test('cancelKey cancels every shared caller for the operation key', () async {
    final started = Completer<void>();
    final finish = Completer<void>();
    var calls = 0;
    final sharedCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {cancelToken}) async {
        calls++;
        started.complete();
        await finish.future;
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = sharedCache;
    final args = (
      remoteUrl: 'https://cdn.example.com/shared.mp3',
      platform: 'tx',
      songId: 'shared',
      quality: '320k',
    );

    final first = cache.acquireOrDownload(
      remoteUrl: args.remoteUrl,
      platform: args.platform,
      songId: args.songId,
      quality: args.quality,
    );
    final second = cache.acquireOrDownload(
      remoteUrl: args.remoteUrl,
      platform: args.platform,
      songId: args.songId,
      quality: args.quality,
    );
    await started.future;
    cache.cancelKey(PlaybackCacheService.cacheKey(
      platform: args.platform,
      songId: args.songId,
      quality: args.quality,
    ));
    finish.complete();

    expect(await first, isNull);
    expect(await second, isNull);
    expect(calls, 1);
  });

  test('late cancelled downloader cannot replace a newer generation', () async {
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    var calls = 0;
    final generationCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {cancelToken}) async {
        calls++;
        if (calls == 1) {
          firstStarted.complete();
          await finishFirst.future;
        }
        await File(savePath).writeAsBytes(List<int>.filled(32, calls));
      },
    );
    await cache.dispose();
    cache = generationCache;
    const platform = 'tx';
    const songId = 'generation';
    const quality = '320k';
    final key = PlaybackCacheService.cacheKey(
      platform: platform,
      songId: songId,
      quality: quality,
    );

    final stale = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.mp3',
      platform: platform,
      songId: songId,
      quality: quality,
    );
    await firstStarted.future;
    cache.cancelKey(key);
    final fresh = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/new.mp3',
      platform: platform,
      songId: songId,
      quality: quality,
    );
    finishFirst.complete();

    expect(await stale, isNull);
    expect(fresh, isNotNull);
    expect(await File(fresh!).readAsBytes(), List<int>.filled(32, 2));
    expect(
        await cache.getOrDownload(
          remoteUrl: 'https://cdn.example.com/new.mp3',
          platform: platform,
          songId: songId,
          quality: quality,
        ),
        fresh);
  });

  test('late cancelled downloader cannot detach newer inflight cancellation',
      () async {
    final firstStarted = Completer<void>();
    final finishFirst = Completer<void>();
    final secondStarted = Completer<void>();
    final finishSecond = Completer<void>();
    var calls = 0;
    final generationCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {cancelToken}) async {
        calls++;
        if (calls == 1) {
          firstStarted.complete();
          await finishFirst.future;
        } else {
          secondStarted.complete();
          await finishSecond.future;
        }
        await File(savePath).writeAsBytes(List<int>.filled(32, calls));
      },
    );
    await cache.dispose();
    cache = generationCache;
    final key = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: 'token-generation',
      quality: '320k',
    );

    final stale = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.mp3',
      platform: 'tx',
      songId: 'token-generation',
      quality: '320k',
    );
    await firstStarted.future;
    cache.cancelKey(key);
    final replacement = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/new.mp3',
      platform: 'tx',
      songId: 'token-generation',
      quality: '320k',
    );
    await secondStarted.future;
    finishFirst.complete();
    expect(await stale, isNull);
    cache.cancelKey(key);
    finishSecond.complete();

    expect(await replacement, isNull);
  });

  test('serialized index writes cannot persist an older snapshot last',
      () async {
    final store = _BlockingIndexStore();
    final persistentCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = persistentCache;
    await cache.init();
    store.blockNextWrite();

    final first = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/one.mp3',
      platform: 'tx',
      songId: 'one',
      quality: '320k',
    );
    await store.firstWriteStarted.future;
    final second = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/two.mp3',
      platform: 'tx',
      songId: 'two',
      quality: '320k',
    );
    store.releaseFirstWrite.complete();
    await Future.wait([first, second]);

    final persisted = jsonDecode(store.value!) as List;
    expect(persisted, hasLength(2));
  });

  test(
      'post-commit cancellation returns null to both shared callers and preserves replacement',
      () async {
    final store = _ControlledIndexStore();
    var calls = 0;
    final commitCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      downloader: (url, savePath, {cancelToken}) async {
        calls++;
        await File(savePath).writeAsBytes(List<int>.filled(32, calls));
      },
    );
    await cache.dispose();
    cache = commitCache;
    await cache.init();
    store.blockWriteAfter(0);
    final key = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: 'post-commit',
      quality: '320k',
    );

    final first = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.mp3',
      platform: 'tx',
      songId: 'post-commit',
      quality: '320k',
    );
    final joined = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.mp3',
      platform: 'tx',
      songId: 'post-commit',
      quality: '320k',
    );
    await store.blockedWriteStarted.future;
    cache.cancelKey(key);
    store.releaseBlockedWrite.complete();
    final replacement = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/new.mp3',
      platform: 'tx',
      songId: 'post-commit',
      quality: '320k',
    );

    expect(await first, isNull);
    expect(await joined, isNull);
    expect(replacement, isNotNull);
    expect(await File(replacement!).readAsBytes(), List<int>.filled(32, 2));
    final persisted = (jsonDecode(store.value!) as List).single as Map;
    expect(persisted['generation'], 3);
  });

  test('dispose waits for token-ignoring inflight cleanup and rejects new work',
      () async {
    final downloadStarted = Completer<void>();
    final releaseDownload = Completer<void>();
    final store = _ControlledIndexStore();
    final disposeCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      downloader: (url, savePath, {cancelToken}) async {
        downloadStarted.complete();
        await releaseDownload.future;
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = disposeCache;
    final result = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/dispose.mp3',
      platform: 'tx',
      songId: 'dispose',
      quality: '320k',
    );
    await downloadStarted.future;

    var disposeCompleted = false;
    final disposing = cache.dispose().then((_) => disposeCompleted = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposeCompleted, isFalse);
    expect(
      await cache.getOrDownload(
        remoteUrl: 'https://cdn.example.com/new.mp3',
        platform: 'tx',
        songId: 'new-after-dispose',
        quality: '320k',
      ),
      isNull,
    );
    releaseDownload.complete();
    await disposing;

    expect(await result, isNull);
    expect(
      tempDir.listSync().whereType<File>().where((file) =>
          file.path.endsWith('.part') || file.path.contains('.stage')),
      isEmpty,
    );
    final writesAtDispose = store.writes;
    await Future<void>.delayed(Duration.zero);
    expect(store.writes, writesAtDispose);
  });

  test('failed durable commit rolls back owned file and later write recovers',
      () async {
    final store = _ControlledIndexStore();
    final durableCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = durableCache;
    await cache.init();
    store.failNextWrite();

    final failed = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/fail.mp3',
      platform: 'tx',
      songId: 'fail',
      quality: '320k',
    );

    expect(failed, isNull);
    expect(tempDir.listSync().whereType<File>(), isEmpty);
    expect(jsonDecode(store.value!) as List, isEmpty);

    final recovered = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/recover.mp3',
      platform: 'tx',
      songId: 'recover',
      quality: '320k',
    );
    expect(recovered, isNotNull);
    expect(File(recovered!).existsSync(), isTrue);
    await expectLater(cache.dispose(), completes);
  });

  test('failed cache-hit persistence restores metadata and queue recovers',
      () async {
    var now = DateTime(2026, 1, 1);
    final store = _ControlledIndexStore();
    final durableCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      clock: () => now,
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = durableCache;
    final path = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/hit.mp3',
      platform: 'tx',
      songId: 'hit-write',
      quality: '320k',
    );
    final persistedBefore = store.value;
    now = now.add(const Duration(minutes: 1));
    store.failNextWrite();

    expect(
      await cache.getOrDownload(
        remoteUrl: 'https://cdn.example.com/hit.mp3',
        platform: 'tx',
        songId: 'hit-write',
        quality: '320k',
      ),
      isNull,
    );
    expect(File(path!).existsSync(), isTrue);
    expect(store.value, persistedBefore);

    expect(
      await cache.getOrDownload(
        remoteUrl: 'https://cdn.example.com/hit.mp3',
        platform: 'tx',
        songId: 'hit-write',
        quality: '320k',
      ),
      path,
    );
  });
}

Map<String, Object> _entryJson({required String key, required String path}) => {
      'key': key,
      'path': path,
      'remoteUrl': 'https://cdn.example.com/song.mp3',
      'createdAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'lastAccessedAt': DateTime(2026, 1, 1).millisecondsSinceEpoch,
      'sizeBytes': 32,
      'quality': '320k',
      'platform': 'tx',
      'songId': 'song',
    };

PlaybackCacheService _cacheForPersistedPath(
  Directory root,
  PlaybackCacheIndexStore store,
) =>
    PlaybackCacheService(
      cacheRootOverride: root.path,
      indexStore: store,
      clock: () => DateTime(2026, 1, 2),
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 2));
      },
    );

class _BlockingIndexStore implements PlaybackCacheIndexStore {
  String? value;
  Completer<void> firstWriteStarted = Completer<void>();
  Completer<void> releaseFirstWrite = Completer<void>();
  var _blockNext = false;

  void blockNextWrite() {
    firstWriteStarted = Completer<void>();
    releaseFirstWrite = Completer<void>();
    _blockNext = true;
  }

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String raw) async {
    if (_blockNext) {
      _blockNext = false;
      firstWriteStarted.complete();
      await releaseFirstWrite.future;
    }
    value = raw;
  }
}

class _ControlledIndexStore implements PlaybackCacheIndexStore {
  String? value;
  var writes = 0;
  var _writesBeforeBlock = -1;
  var _failNext = false;
  Completer<void> blockedWriteStarted = Completer<void>();
  Completer<void> releaseBlockedWrite = Completer<void>();

  void blockWriteAfter(int writesBeforeBlock) {
    _writesBeforeBlock = writesBeforeBlock;
    blockedWriteStarted = Completer<void>();
    releaseBlockedWrite = Completer<void>();
  }

  void failNextWrite() => _failNext = true;

  @override
  Future<String?> read() async => value;

  @override
  Future<void> write(String raw) async {
    writes++;
    if (_writesBeforeBlock == 0) {
      _writesBeforeBlock = -1;
      blockedWriteStarted.complete();
      await releaseBlockedWrite.future;
    } else if (_writesBeforeBlock > 0) {
      _writesBeforeBlock--;
    }
    if (_failNext) {
      _failNext = false;
      throw StateError('index write failed');
    }
    value = raw;
  }
}
