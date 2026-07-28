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

  test('cancelKey is a no-op after commit and reacquire keeps its lease',
      () async {
    final key = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: 'idle-cancel',
      quality: '320k',
    );
    final path = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/idle-cancel.mp3',
      platform: 'tx',
      songId: 'idle-cancel',
      quality: '320k',
    );
    expect(downloadCount, 1);

    cache.cancelKey(key);
    final lease = await cache.acquireOrDownload(
      remoteUrl: 'https://cdn.example.com/idle-cancel.mp3',
      platform: 'tx',
      songId: 'idle-cancel',
      quality: '320k',
    );

    expect(lease?.path, path);
    expect(downloadCount, 1);
    await lease?.release();
  });

  test('repeated cancel targets the current replacement, not stale work',
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
      songId: 'replacement-cancel',
      quality: '320k',
    );

    final stale = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/old.mp3',
      platform: 'tx',
      songId: 'replacement-cancel',
      quality: '320k',
    );
    await firstStarted.future;
    cache.cancelKey(key);
    final replacement = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/new.mp3',
      platform: 'tx',
      songId: 'replacement-cancel',
      quality: '320k',
    );
    await secondStarted.future;
    finishFirst.complete();
    expect(await stale, isNull);
    cache.cancelKey(key);
    finishSecond.complete();

    expect(await replacement, isNull);
    expect(tempDir.listSync().whereType<File>(), isEmpty);
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

  test('overlapping hit failure cannot roll back newer access metadata',
      () async {
    var now = DateTime(2026, 1, 1);
    var callsAtCurrentTime = 0;
    final newerMetadataInstalled = Completer<void>();
    final store = _ControlledIndexStore();
    final metadataCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      clock: () {
        callsAtCurrentTime++;
        if (now == DateTime(2026, 1, 1, 2) &&
            callsAtCurrentTime == 2 &&
            !newerMetadataInstalled.isCompleted) {
          newerMetadataInstalled.complete();
        }
        return now;
      },
      ttl: const Duration(minutes: 90),
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes(List<int>.filled(32, 1));
      },
    );
    await cache.dispose();
    cache = metadataCache;
    final path = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/metadata.mp3',
      platform: 'tx',
      songId: 'metadata-race',
      quality: '320k',
    );
    now = now.add(const Duration(minutes: 60));
    callsAtCurrentTime = 0;
    store.blockWriteAfter(0);
    store.failNextWrite();

    final failedHit = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/metadata.mp3',
      platform: 'tx',
      songId: 'metadata-race',
      quality: '320k',
    );
    await store.blockedWriteStarted.future;
    now = now.add(const Duration(minutes: 60));
    callsAtCurrentTime = 0;
    final newerHit = cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/metadata.mp3',
      platform: 'tx',
      songId: 'metadata-race',
      quality: '320k',
    );
    await newerMetadataInstalled.future;
    store.releaseBlockedWrite.complete();

    expect(await failedHit, isNull);
    expect(await newerHit, path);
    final persisted = (jsonDecode(store.value!) as List).single as Map;
    expect(persisted['lastAccessedAt'], now.millisecondsSinceEpoch);

    now = now.add(const Duration(minutes: 60));
    await cache.purgeExpired();
    expect(File(path!).existsSync(), isTrue);
    final afterPurge = (jsonDecode(store.value!) as List).single as Map;
    expect(afterPurge['lastAccessedAt'],
        DateTime(2026, 1, 1, 2).millisecondsSinceEpoch);
  });

  test('expired mp3 replaced by flac removes old stable sibling', () async {
    var now = DateTime(2026, 1, 1);
    final transitionCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        final bytes = url.endsWith('.flac')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : <int>[0x49, 0x44, 0x33, ...List<int>.filled(29, 0)];
        await File(savePath).writeAsBytes(bytes);
      },
    );
    await cache.dispose();
    cache = transitionCache;

    final oldPath = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.mp3',
      platform: 'tx',
      songId: 'mp3-to-flac',
      quality: 'same-key',
    );
    now = now.add(const Duration(hours: 2));
    final newPath = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.flac',
      platform: 'tx',
      songId: 'mp3-to-flac',
      quality: 'same-key',
    );

    expect(oldPath, endsWith('.mp3'));
    expect(newPath, endsWith('.flac'));
    expect(File(oldPath!).existsSync(), isFalse);
    expect(File(newPath!).existsSync(), isTrue);
  });

  test('expired flac replaced by mp3 removes old stable sibling', () async {
    var now = DateTime(2026, 1, 1);
    final transitionCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        final bytes = url.endsWith('.flac')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : <int>[0x49, 0x44, 0x33, ...List<int>.filled(29, 0)];
        await File(savePath).writeAsBytes(bytes);
      },
    );
    await cache.dispose();
    cache = transitionCache;

    final oldPath = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.flac',
      platform: 'tx',
      songId: 'flac-to-mp3',
      quality: 'same-key',
    );
    now = now.add(const Duration(hours: 2));
    final newPath = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.mp3',
      platform: 'tx',
      songId: 'flac-to-mp3',
      quality: 'same-key',
    );

    expect(oldPath, endsWith('.flac'));
    expect(newPath, endsWith('.mp3'));
    expect(File(oldPath!).existsSync(), isFalse);
    expect(File(newPath!).existsSync(), isTrue);
  });

  test('format transition never deletes a prefix-related filename', () async {
    var now = DateTime(2026, 1, 1);
    final key = PlaybackCacheService.cacheKey(
      platform: 'tx',
      songId: 'prefix-safe',
      quality: 'same-key',
    );
    final unrelated = File('${tempDir.path}/${key}0.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 9));
    final transitionCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        final bytes = url.endsWith('.flac')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : <int>[0x49, 0x44, 0x33, ...List<int>.filled(29, 0)];
        await File(savePath).writeAsBytes(bytes);
      },
    );
    await cache.dispose();
    cache = transitionCache;

    await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.mp3',
      platform: 'tx',
      songId: 'prefix-safe',
      quality: 'same-key',
    );
    now = now.add(const Duration(hours: 2));
    await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.flac',
      platform: 'tx',
      songId: 'prefix-safe',
      quality: 'same-key',
    );

    expect(unrelated.existsSync(), isTrue);
    expect(unrelated.readAsBytesSync(), List<int>.filled(32, 9));
  });

  test('failed format transition restores old index and file only', () async {
    var now = DateTime(2026, 1, 1);
    final store = _ControlledIndexStore();
    final transitionCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      clock: () => now,
      ttl: const Duration(hours: 1),
      downloader: (url, savePath, {cancelToken}) async {
        final bytes = url.endsWith('.flac')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : <int>[0x49, 0x44, 0x33, ...List<int>.filled(29, 0)];
        await File(savePath).writeAsBytes(bytes);
      },
    );
    await cache.dispose();
    cache = transitionCache;
    final oldPath = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.mp3',
      platform: 'tx',
      songId: 'transition-failure',
      quality: 'same-key',
    );
    now = now.add(const Duration(hours: 2));
    store.failNextWrite();

    final failed = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.flac',
      platform: 'tx',
      songId: 'transition-failure',
      quality: 'same-key',
    );

    expect(failed, isNull);
    expect(File(oldPath!).existsSync(), isTrue);
    expect(File(oldPath.replaceAll('.mp3', '.flac')).existsSync(), isFalse);
    final persisted = (jsonDecode(store.value!) as List).single as Map;
    expect(persisted['path'], oldPath);
  });

  test('format transition leaves physical stable bytes within maxBytes',
      () async {
    var now = DateTime(2026, 1, 1);
    final sizeCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      clock: () => now,
      ttl: const Duration(hours: 1),
      maxBytes: 64,
      downloader: (url, savePath, {cancelToken}) async {
        final bytes = url.endsWith('.flac')
            ? <int>[0x66, 0x4c, 0x61, 0x43, ...List<int>.filled(28, 0)]
            : <int>[0x49, 0x44, 0x33, ...List<int>.filled(29, 0)];
        await File(savePath).writeAsBytes(bytes);
      },
    );
    await cache.dispose();
    cache = sizeCache;
    await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.mp3',
      platform: 'tx',
      songId: 'size-transition',
      quality: 'same-key',
    );
    now = now.add(const Duration(hours: 2));
    await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/song.flac',
      platform: 'tx',
      songId: 'size-transition',
      quality: 'same-key',
    );
    await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/other.mp3',
      platform: 'tx',
      songId: 'other-size',
      quality: 'same-key',
    );

    final stableFiles = tempDir.listSync().whereType<File>().where((file) =>
        RegExp(r'/[0-9a-f]{40}\.(mp3|flac|m4a|aac|ogg|wav|ape)$')
            .hasMatch(file.path));
    final physicalBytes =
        stableFiles.fold<int>(0, (total, file) => total + file.lengthSync());
    expect(physicalBytes, lessThanOrEqualTo(64));
  });

  test('init removes unindexed known stable cache files only', () async {
    final orphanKey = List.filled(40, 'a').join();
    final indexedKey = List.filled(40, 'b').join();
    final orphan = File('${tempDir.path}/$orphanKey.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 1));
    final indexed = File('${tempDir.path}/$indexedKey.flac')
      ..writeAsBytesSync(List<int>.filled(32, 2));
    final unrelated = File('${tempDir.path}/${orphanKey}0.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 3));
    final staging = File('${tempDir.path}/$orphanKey.1.stage.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 4));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: indexedKey, path: indexed.path),
      ]);
    final migrationCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      clock: () => DateTime(2026, 1, 2),
      downloader: (url, savePath, {cancelToken}) async {},
    );
    await cache.dispose();
    cache = migrationCache;

    await cache.init();

    expect(orphan.existsSync(), isFalse);
    expect(indexed.existsSync(), isTrue);
    expect(unrelated.existsSync(), isTrue);
    expect(staging.existsSync(), isTrue);
  });

  test('mismatched persisted key path is dropped without deleting other key',
      () async {
    final keyA = List.filled(40, 'a').join();
    final keyB = List.filled(40, 'b').join();
    final fileB = File('${tempDir.path}/$keyB.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 7));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: keyA, path: fileB.path),
      ]);
    final strictCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = strictCache;

    await cache.init();

    expect(jsonDecode(store.value!) as List, isEmpty);
    expect(fileB.existsSync(), isTrue);
    expect(fileB.readAsBytesSync(), List<int>.filled(32, 7));
  });

  test('persisted stable path must be a direct child with exact basename',
      () async {
    final key = List.filled(40, 'c').join();
    final nested = Directory('${tempDir.path}/nested')..createSync();
    final nestedFile = File('${nested.path}/$key.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 5));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: key, path: nestedFile.path),
      ]);
    final strictCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = strictCache;

    await cache.init();

    expect(jsonDecode(store.value!) as List, isEmpty);
    expect(nestedFile.existsSync(), isTrue);
  });

  test('persisted key must be lowercase forty hex characters', () async {
    final invalidKey = List.filled(40, 'A').join();
    final file = File('${tempDir.path}/$invalidKey.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 4));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: invalidKey, path: file.path),
      ]);
    final strictCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = strictCache;

    await cache.init();

    expect(jsonDecode(store.value!) as List, isEmpty);
    expect(file.existsSync(), isTrue);
  });

  test('exact outside-root symlink is removed without deleting target',
      () async {
    if (Platform.isWindows) return;
    final key = List.filled(40, 'd').join();
    final outside = await Directory.systemTemp.createTemp('cache_link_out_');
    addTearDown(() => outside.deleteSync(recursive: true));
    final target = File('${outside.path}/target.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 8));
    final link = Link('${tempDir.path}/$key.mp3');
    try {
      await link.create(target.path);
    } on FileSystemException {
      return;
    }
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: key, path: link.path),
      ]);
    final strictCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = strictCache;

    await cache.init();

    expect(jsonDecode(store.value!) as List, isEmpty);
    expect(link.existsSync(), isFalse);
    expect(target.existsSync(), isTrue);
  });

  test('exact same-root symlink is removed without deleting target', () async {
    if (Platform.isWindows) return;
    final keyA = List.filled(40, 'e').join();
    final keyB = List.filled(40, 'f').join();
    final targetB = File('${tempDir.path}/$keyB.mp3')
      ..writeAsBytesSync(List<int>.filled(32, 6));
    final linkA = Link('${tempDir.path}/$keyA.mp3');
    try {
      await linkA.create(targetB.path);
    } on FileSystemException {
      return;
    }
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        _entryJson(key: keyA, path: linkA.path),
        _entryJson(key: keyB, path: targetB.path),
      ]);
    final strictCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = strictCache;

    await cache.init();

    final persisted = (jsonDecode(store.value!) as List).cast<Map>();
    expect(persisted.map((entry) => entry['key']), [keyB]);
    expect(linkA.existsSync(), isFalse);
    expect(targetB.existsSync(), isTrue);
    expect(targetB.readAsBytesSync(), List<int>.filled(32, 6));
  });

  test('commit rejects a hostile stable destination symlink', () async {
    if (Platform.isWindows) return;
    const platform = 'tx';
    const songId = 'hostile-destination';
    const quality = '320k';
    final key = PlaybackCacheService.cacheKey(
      platform: platform,
      songId: songId,
      quality: quality,
    );
    final target = File('${tempDir.path}/hostile-target.bin')
      ..writeAsBytesSync(List<int>.filled(32, 9));
    final link = Link('${tempDir.path}/$key.mp3');
    final hostileCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: MemoryPlaybackCacheIndexStore(),
      downloader: (url, savePath, {cancelToken}) async {
        await File(savePath).writeAsBytes([
          0x49,
          0x44,
          0x33,
          ...List<int>.filled(29, 1),
        ]);
        await link.create(target.path);
      },
    );
    await cache.dispose();
    cache = hostileCache;

    final result = await cache.getOrDownload(
      remoteUrl: 'https://cdn.example.com/hostile.mp3',
      platform: platform,
      songId: songId,
      quality: quality,
    );

    expect(result, isNull);
    expect(link.existsSync(), isTrue);
    expect(target.existsSync(), isTrue);
    expect(target.readAsBytesSync(), List<int>.filled(32, 9));
  });

  test('load repairs persisted path and size from physical stable file',
      () async {
    final key = List.filled(40, '1').join();
    final file = File('${tempDir.path}/$key.mp3')
      ..writeAsBytesSync(List<int>.filled(37, 2));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        {
          ..._entryJson(key: key, path: '${tempDir.path}/./$key.mp3'),
          'sizeBytes': 0,
        },
      ]);
    final repairCache = _cacheForPersistedPath(tempDir, store);
    await cache.dispose();
    cache = repairCache;

    await cache.init();

    final repaired = (jsonDecode(store.value!) as List).single as Map;
    expect(repaired['path'], file.path);
    expect(repaired['sizeBytes'], 37);
  });

  test('load ignores huge persisted size and keeps physically small entry',
      () async {
    final key = List.filled(40, '2').join();
    final file = File('${tempDir.path}/$key.mp3')
      ..writeAsBytesSync(List<int>.filled(16, 2));
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        {
          ..._entryJson(key: key, path: file.path),
          'sizeBytes': 999999,
        },
      ]);
    final repairCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      maxBytes: 20,
      clock: () => DateTime(2026, 1, 2),
      downloader: (url, savePath, {cancelToken}) async {},
    );
    await cache.dispose();
    cache = repairCache;

    await cache.init();

    expect(file.existsSync(), isTrue);
    final repaired = (jsonDecode(store.value!) as List).single as Map;
    expect(repaired['sizeBytes'], 16);
  });

  test('load uses physical sizes to evict oldest entry over cap', () async {
    final oldKey = List.filled(40, '3').join();
    final newKey = List.filled(40, '4').join();
    final oldFile = File('${tempDir.path}/$oldKey.mp3')
      ..writeAsBytesSync(List<int>.filled(40, 3));
    final newFile = File('${tempDir.path}/$newKey.flac')
      ..writeAsBytesSync(List<int>.filled(40, 4));
    final oldEntry = _entryJson(key: oldKey, path: oldFile.path);
    final newEntry = {
      ..._entryJson(key: newKey, path: newFile.path),
      'createdAt': DateTime(2026, 1, 2).millisecondsSinceEpoch,
      'lastAccessedAt': DateTime(2026, 1, 2).millisecondsSinceEpoch,
    };
    final store = MemoryPlaybackCacheIndexStore()
      ..value = jsonEncode([
        {...oldEntry, 'sizeBytes': 0},
        {...newEntry, 'sizeBytes': 0},
      ]);
    final repairCache = PlaybackCacheService(
      cacheRootOverride: tempDir.path,
      indexStore: store,
      maxBytes: 50,
      clock: () => DateTime(2026, 1, 2),
      downloader: (url, savePath, {cancelToken}) async {},
    );
    await cache.dispose();
    cache = repairCache;

    await cache.init();

    expect(oldFile.existsSync(), isFalse);
    expect(newFile.existsSync(), isTrue);
    final persisted = (jsonDecode(store.value!) as List).single as Map;
    expect(persisted['key'], newKey);
    expect(persisted['sizeBytes'], 40);
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
