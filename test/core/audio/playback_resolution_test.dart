import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';
import 'package:lx_music_flutter/core/network/play_url_result.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';

MusicItem _item({
  String id = 'song-a',
  String songmid = 'mid-a',
  String platform = 'tx',
}) {
  return MusicItem(
    id: id,
    name: 'Track $id',
    singer: 'Artist',
    source: platform,
    platform: platform,
    songmid: songmid,
  );
}

PlayUrlResult _playResult({
  String url = 'https://cdn.example/a.mp3',
  String quality = '320k',
  String platform = 'tx',
}) {
  return PlayUrlResult(
    url: url,
    requestedQuality: quality,
    actualQuality: quality,
    platform: platform,
  );
}

class _FakeLease {
  _FakeLease(this.path, this.key, this.onRelease);

  final String path;
  final String key;
  final void Function(String key) onRelease;
  var releaseCount = 0;

  PlaybackCacheLease asLease() {
    return PlaybackCacheLease.test(
      path,
      PlaybackCacheService.toPlayableUri(path),
      () async {
        releaseCount++;
        onRelease(key);
      },
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlaybackUrlResolver', () {
    test('validated remote URL streams when cache write fails', () async {
      final cancelled = <String>[];
      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async =>
            null,
        cancelCacheKey: cancelled.add,
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final result = await resolver.resolve(
        _item(),
        preferredQuality: '320k',
      );

      expect(result, isA<StreamingPlayback>());
      expect(
          (result as StreamingPlayback).remoteUrl, 'https://cdn.example/a.mp3');
      expect(result.playableUrl, 'https://cdn.example/a.mp3');
      expect(result.qualityExtras['remoteUrl'], 'https://cdn.example/a.mp3');
      expect(result.qualityExtras['actualQuality'], '320k');
    });

    test('invalid remote URL fails without streaming', () async {
      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(url: 'https://wx.music.tc.qq.com/'),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async =>
            fail('cache must not run for invalid remote'),
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final result = await resolver.resolve(
        _item(),
        preferredQuality: '320k',
      );

      expect(result, isNull);
    });

    test('null quality resolution fails without streaming', () async {
      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async => null,
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async =>
            fail('cache must not run without remote'),
        songIdFor: (music) => music.songmid ?? music.id,
      );

      expect(
        await resolver.resolve(_item(), preferredQuality: '320k'),
        isNull,
      );
    });

    test('successful cache returns CachedPlayback with lease uri', () async {
      final fake = _FakeLease('/tmp/a.mp3', 'key-a', (_) {});
      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async =>
            fake.asLease(),
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final result = await resolver.resolve(
        _item(),
        preferredQuality: '320k',
      );

      expect(result, isA<CachedPlayback>());
      final cached = result as CachedPlayback;
      expect(cached.playableUrl, 'file:///tmp/a.mp3');
      expect(identical(cached.lease, result.leaseOrNull), isTrue);
      expect(result.qualityExtras['url'], 'file:///tmp/a.mp3');
      expect(result.qualityExtras['remoteUrl'], 'https://cdn.example/a.mp3');
    });

    test('track switch cancels previous cache key generation', () async {
      final cancelled = <String>[];
      final gate = Completer<void>();
      final firstStarted = Completer<void>();
      final leases = <_FakeLease>[];

      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(
          url: 'https://cdn.example/${music.id}.mp3',
        ),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async {
          final key = PlaybackCacheService.cacheKey(
            platform: platform,
            songId: songId,
            quality: quality,
          );
          if (songId == 'mid-a') {
            firstStarted.complete();
            await gate.future;
            return null;
          }
          final fake = _FakeLease('/tmp/$songId.mp3', key, (_) {});
          leases.add(fake);
          return fake.asLease();
        },
        cancelCacheKey: cancelled.add,
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final first = resolver.resolve(
        _item(),
        preferredQuality: '320k',
        exclusive: true,
      );
      await firstStarted.future;
      final second = await resolver.resolve(
        _item(id: 'song-b', songmid: 'mid-b'),
        preferredQuality: '320k',
        exclusive: true,
      );
      gate.complete();
      final firstResult = await first;

      expect(firstResult, isNull);
      expect(second, isA<CachedPlayback>());
      expect(
        cancelled,
        contains(
          PlaybackCacheService.cacheKey(
            platform: 'tx',
            songId: 'mid-a',
            quality: '320k',
          ),
        ),
      );
    });

    test('preload generation cancel drops obsolete cache work', () async {
      final cancelled = <String>[];
      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(url: 'https://cdn.example/${music.id}.mp3'),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async =>
            null,
        cancelCacheKey: cancelled.add,
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final gen = resolver.beginGeneration();
      final key = PlaybackCacheService.cacheKey(
        platform: 'tx',
        songId: 'mid-a',
        quality: '320k',
      );
      resolver.noteCacheKey(gen, key);
      resolver.cancelGeneration(gen);

      expect(cancelled, [key]);
      expect(resolver.isGenerationCurrent(gen), isFalse);
    });

    test('non-exclusive resolves do not cancel sibling work', () async {
      final cancelled = <String>[];
      final gateA = Completer<void>();
      final gateB = Completer<void>();
      final startedA = Completer<void>();
      final startedB = Completer<void>();

      final resolver = PlaybackUrlResolver<MusicItem>(
        resolvePlayableUrl: (music, {required preferredQuality}) async =>
            _playResult(url: 'https://cdn.example/${music.id}.mp3'),
        acquireOrDownload: ({
          required remoteUrl,
          required platform,
          required songId,
          required quality,
        }) async {
          if (songId == 'mid-a') {
            startedA.complete();
            await gateA.future;
          } else {
            startedB.complete();
            await gateB.future;
          }
          return null;
        },
        cancelCacheKey: cancelled.add,
        songIdFor: (music) => music.songmid ?? music.id,
      );

      final first = resolver.resolve(_item(), preferredQuality: '320k');
      await startedA.future;
      final second = resolver.resolve(
        _item(id: 'song-b', songmid: 'mid-b'),
        preferredQuality: '320k',
      );
      await startedB.future;
      gateA.complete();
      gateB.complete();
      expect(await first, isA<StreamingPlayback>());
      expect(await second, isA<StreamingPlayback>());
      expect(cancelled, isEmpty);
    });
  });

  group('PlaybackLeaseSession', () {
    test('old lease retained until newer source commit, then released once',
        () async {
      final released = <String>[];
      final oldFake = _FakeLease('/tmp/old.mp3', 'old', released.add);
      final newFake = _FakeLease('/tmp/new.mp3', 'new', released.add);
      final oldLease = oldFake.asLease();
      final newLease = newFake.asLease();
      final session = PlaybackLeaseSession();

      session.holdPending(oldLease);
      expect(released, isEmpty);

      await session.commitAuthoritative(oldLease);
      expect(released, isEmpty);
      expect(session.activeLease?.path, '/tmp/old.mp3');

      session.holdPending(newLease);
      expect(released, isEmpty);
      expect(session.activeLease?.path, '/tmp/old.mp3');

      await session.commitAuthoritative(newLease);
      expect(released, ['old']);
      expect(session.activeLease?.path, '/tmp/new.mp3');
      expect(oldFake.releaseCount, 1);
    });

    test('stop and removal release active and pending leases once', () async {
      final released = <String>[];
      final active = _FakeLease('/tmp/active.mp3', 'active', released.add);
      final pending = _FakeLease('/tmp/pending.mp3', 'pending', released.add);
      final activeLease = active.asLease();
      final pendingLease = pending.asLease();
      final session = PlaybackLeaseSession();

      await session.commitAuthoritative(activeLease);
      session.holdPending(pendingLease);

      await session.releaseAll();
      await session.releaseAll();

      expect(released.toSet(), {'active', 'pending'});
      expect(active.releaseCount, 1);
      expect(pending.releaseCount, 1);
      expect(session.activeLease, isNull);
    });

    test('stale pending discard releases only the discarded lease', () async {
      final released = <String>[];
      final active = _FakeLease('/tmp/active.mp3', 'active', released.add);
      final pending = _FakeLease('/tmp/pending.mp3', 'pending', released.add);
      final activeLease = active.asLease();
      final held = pending.asLease();
      final session = PlaybackLeaseSession();

      await session.commitAuthoritative(activeLease);
      session.holdPending(held);
      await session.discardPending(held);

      expect(released, ['pending']);
      expect(session.activeLease?.path, '/tmp/active.mp3');
      expect(pending.releaseCount, 1);
      expect(active.releaseCount, 0);
    });

    test('streaming commit keeps previous lease until releaseAll', () async {
      final released = <String>[];
      final active = _FakeLease('/tmp/active.mp3', 'active', released.add);
      final pending = _FakeLease('/tmp/pending.mp3', 'pending', released.add);
      final activeLease = active.asLease();
      final pendingLease = pending.asLease();
      final session = PlaybackLeaseSession();

      await session.commitAuthoritative(activeLease);
      session.holdPending(pendingLease);
      await session.commitAuthoritative(null);
      expect(released, containsAllInOrder(['pending', 'active']));
      expect(session.activeLease, isNull);
      expect(session.pendingLease, isNull);
    });

    test('generation race: only matching commit adopts lease', () async {
      final released = <String>[];
      final first = _FakeLease('/tmp/first.mp3', 'first', released.add);
      final second = _FakeLease('/tmp/second.mp3', 'second', released.add);
      final session = PlaybackLeaseSession();

      final firstLease = first.asLease();
      final secondLease = second.asLease();
      session.holdPending(firstLease);
      session.holdPending(secondLease);

      final adopted = await session.commitIfGeneration(
        generation: 1,
        currentGeneration: () => 2,
        lease: firstLease,
      );
      expect(adopted, isFalse);
      expect(released, ['first']);
      expect(session.activeLease, isNull);

      final adoptedSecond = await session.commitIfGeneration(
        generation: 2,
        currentGeneration: () => 2,
        lease: secondLease,
      );
      expect(adoptedSecond, isTrue);
      expect(session.activeLease?.path, '/tmp/second.mp3');
      expect(second.releaseCount, 0);
    });
  });

  group('LxAudioHandler cached file reuse', () {
    test('preloaded cached file is re-leased before authoritative reuse',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final lease = _FakeLease('/cache/preloaded.mp3', 'preloaded', (_) {});
      final acquired = <String>[];
      handler.attachPlaybackCache(
        acquireExisting: (path) async {
          acquired.add(path);
          return lease.asLease();
        },
      );

      await handler.setPlaylist([_cachedItem('preloaded', lease.path)]);

      expect(acquired, [lease.path]);
      expect(player.sourceInstallCount, 1);
      expect(lease.releaseCount, 0);
    });

    test('stop then replay re-leases a persisted cached file URL', () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final path = '/cache/replay.mp3';
      final leases = <_FakeLease>[];
      handler.attachPlaybackCache(
        acquireExisting: (candidate) async {
          final lease = _FakeLease(candidate, 'lease-${leases.length}', (_) {});
          leases.add(lease);
          return lease.asLease();
        },
      );

      await handler.setPlaylist([_cachedItem('replay', path)]);
      await handler.stop();
      await handler.setPlaylist([_cachedItem('replay', path)]);

      expect(leases, hasLength(2));
      expect(leases.first.releaseCount, 1);
      expect(leases.last.releaseCount, 0);
    });

    test('old active lease releases only after replacement source commits',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final releasedAtInstall = <int>[];
      final old = _FakeLease('/cache/old.mp3', 'old', (_) {
        releasedAtInstall.add(player.sourceInstallCount);
      });
      final replacement = _FakeLease('/cache/new.mp3', 'new', (_) {});
      handler.attachPlaybackCache(
        acquireExisting: (path) async =>
            path == old.path ? old.asLease() : replacement.asLease(),
      );

      await handler.setPlaylist([
        _cachedItem('old', old.path),
        _cachedItem('new', replacement.path),
      ]);
      await handler.skipToQueueItem(1);

      expect(player.sourceInstallCount, 2);
      expect(releasedAtInstall, [2]);
      expect(old.releaseCount, 1);
      expect(replacement.releaseCount, 0);
    });

    test('local file outside the cache does not acquire a lease', () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      var acquireCalls = 0;
      handler.attachPlaybackCache(
        acquireExisting: (path) async {
          acquireCalls++;
          return null;
        },
      );

      await handler.setPlaylist([_cachedItem('local', '/tmp/local.mp3')]);

      expect(acquireCalls, 1);
      expect(player.sourceInstallCount, 1);
    });

    test('rejected cache candidate is not installed and re-resolves once',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      var resolveCalls = 0;
      handler.attachPlaybackCache(
        classifyExisting: (path) async => const RejectedPlaybackCachePath(),
      );
      handler.urlResolver = (id, [extras]) async {
        resolveCalls++;
        expect(extras?['url'], isNull);
        expect(extras?['remoteUrl'], isNull);
        return null;
      };

      await handler.setPlaylist([
        _cachedItem('rejected', '/cache/rejected-stable.mp3'),
      ]);

      expect(resolveCalls, 1);
      expect(player.sourceInstallCount, 0);
    });

    test('ordinary local file installs without a cache lease', () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      handler.attachPlaybackCache(
        classifyExisting: (path) async => const NonCacheLocalPlaybackPath(),
      );

      await handler
          .setPlaylist([_cachedItem('local-boundary', '/tmp/local.mp3')]);

      expect(player.sourceInstallCount, 1);
    });

    test('resolver cached lease commits as active ownership', () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final lease = _FakeLease('/cache/resolved.mp3', 'resolved', (_) {});
      var classificationCalls = 0;
      final errors = <String>[];
      handler.attachPlaybackCache(
        classifyExisting: (path) async {
          classificationCalls++;
          throw StateError('LRU persistence failed');
        },
      );
      handler.onError = errors.add;
      handler.urlResolver = (id, [extras]) async {
        final resolved = CachedPlayback(lease.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(lease.path),
        });
        handler.noteResolvedPlayback(
          id,
          resolved,
          generation: extras!['_playbackGeneration'] as int,
        );
        return resolved.playableUrl;
      };

      await handler.setPlaylist([_unresolvedItem('resolved')]);

      expect(classificationCalls, 0);
      expect(player.sourceInstallCount, 1);
      expect(errors, isEmpty);
      expect(lease.releaseCount, 0);

      await handler.stop();

      expect(lease.releaseCount, 1);
    });

    test(
        'stale pending lease releases before rejected file re-resolves to stream',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final stale = _FakeLease('/cache/stale.mp3', 'stale', (_) {});
      final staleUrl = PlaybackCacheService.toPlayableUri(stale.path);
      final replacementUrl =
          PlaybackCacheService.toPlayableUri('/cache/new.mp3');
      const remoteUrl = 'https://cdn.example/fallback.mp3';
      var classifyCalls = 0;
      var resolveCalls = 0;
      handler.attachPlaybackCache(
        classifyExisting: (path) async {
          classifyCalls++;
          expect(path, '/cache/new.mp3');
          return const RejectedPlaybackCachePath();
        },
      );
      handler.urlResolver = (id, [extras]) async {
        resolveCalls++;
        if (resolveCalls == 1) {
          handler.noteResolvedPlayback(
            id,
            CachedPlayback(stale.asLease(), {'url': staleUrl}),
            generation: extras!['_playbackGeneration'] as int,
          );
          return replacementUrl;
        }
        expect(stale.releaseCount, 1);
        handler.noteResolvedPlayback(
          id,
          const StreamingPlayback(remoteUrl, {'url': remoteUrl}),
          generation: extras!['_playbackGeneration'] as int,
        );
        return remoteUrl;
      };

      await handler.setPlaylist([_unresolvedItem('stale')]);

      expect(classifyCalls, 1);
      expect(resolveCalls, 2);
      expect(player.sourceInstallCount, 1);
      expect(stale.releaseCount, 1);
      expect(handler.mediaItem.value?.extras?['url'], remoteUrl);
    });

    test('failed cached source install releases the newly acquired lease',
        () async {
      final player = _ReuseAudioPlayer()
        ..sourceInstallError = StateError('fail');
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final lease = _FakeLease('/cache/fails.mp3', 'fails', (_) {});
      handler.attachPlaybackCache(
        acquireExisting: (path) async => lease.asLease(),
      );

      await handler.setPlaylist([_cachedItem('fails', lease.path)]);

      expect(lease.releaseCount, 1);
    });

    test(
        'stopping a pending cached resolution releases it and replay reacquires',
        () async {
      final player = _GatedReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final pending = _FakeLease('/cache/pending.mp3', 'pending', (_) {});
      final replayLeases = <_FakeLease>[];
      handler.attachPlaybackCache(
        acquireExisting: (path) async {
          final lease = _FakeLease(
            path,
            'replay-${replayLeases.length}',
            (_) {},
          );
          replayLeases.add(lease);
          return lease.asLease();
        },
      );
      handler.urlResolver = (id, [extras]) async {
        final resolution = CachedPlayback(pending.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(pending.path),
        });
        handler.noteResolvedPlayback(
          id,
          resolution,
          generation: extras!['_playbackGeneration'] as int,
        );
        return resolution.playableUrl;
      };

      final firstLoad = handler.setPlaylist([_unresolvedItem('pending')]);
      await player.firstSourceStarted.future;
      final stop = handler.stop();
      expect(pending.releaseCount, 1);
      player.allowFirstSource.complete();
      await Future.wait([firstLoad, stop]);

      await handler.setPlaylist([_cachedItem('pending', pending.path)]);

      expect(replayLeases, isNotEmpty);
      expect(replayLeases.last.releaseCount, 0);
    });

    test('late cached resolution after stop releases without becoming pending',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final started = Completer<int>();
      final resolve = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        started.complete(extras!['_playbackGeneration'] as int);
        return resolve.future;
      };

      final load = handler.setPlaylist([_unresolvedItem('late')]);
      final generation = await started.future;
      await handler.stop();
      final late = _FakeLease('/cache/late.mp3', 'late', (_) {});
      handler.noteResolvedPlayback(
        'late',
        CachedPlayback(late.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(late.path),
        }),
        generation: generation,
      );
      resolve.complete(null);
      await load;

      expect(late.releaseCount, 1);
    });

    test('streaming resolution discards an earlier pending cached lease',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final cached = _FakeLease('/cache/streaming.mp3', 'cached', (_) {});
      const remoteUrl = 'https://cdn.example/streaming.mp3';
      handler.urlResolver = (id, [extras]) async {
        final generation = extras!['_playbackGeneration'] as int;
        handler.noteResolvedPlayback(
          id,
          CachedPlayback(cached.asLease(), {
            'url': PlaybackCacheService.toPlayableUri(cached.path),
          }),
          generation: generation,
        );
        handler.noteResolvedPlayback(
          id,
          const StreamingPlayback(remoteUrl, {'url': remoteUrl}),
          generation: generation,
        );
        return remoteUrl;
      };

      await handler.setPlaylist([_unresolvedItem('streaming')]);

      expect(cached.releaseCount, 1);
      expect(player.sourceInstallCount, 1);
      expect(handler.mediaItem.value?.extras?['url'], remoteUrl);
    });

    test('source switch rejects and releases the prior pending resolution',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final firstStarted = Completer<int>();
      final firstResult = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        if (id == 'first') {
          firstStarted.complete(extras!['_playbackGeneration'] as int);
          return firstResult.future;
        }
        return 'https://cdn.example/$id.mp3';
      };

      final firstLoad = handler.setPlaylist([_unresolvedItem('first')]);
      final firstGeneration = await firstStarted.future;
      await handler.setPlaylist([_unresolvedItem('second')]);
      final stale = _FakeLease('/cache/first.mp3', 'first', (_) {});
      handler.noteResolvedPlayback(
        'first',
        CachedPlayback(stale.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(stale.path),
        }),
        generation: firstGeneration,
      );
      firstResult.complete(null);
      await firstLoad;

      expect(stale.releaseCount, 1);
      expect(handler.mediaItem.value?.id, 'second');
    });

    test('late cached A resolution after B switch cannot publish A extras',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final started = Completer<int>();
      final lateResult = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        if (id == 'A') {
          started.complete(extras!['_playbackGeneration'] as int);
          return lateResult.future;
        }
        return 'https://cdn.example/B.mp3';
      };

      final loadingA = handler.setPlaylist([
        _unresolvedItem('A'),
        _unresolvedItem('B'),
      ]);
      final generationA = await started.future;
      await handler.skipToQueueItem(1, playAfterLoad: false);
      final leaseA = _FakeLease('/cache/A.mp3', 'A', (_) {});
      final accepted = handler.acceptResolvedPlayback(
        mediaId: 'A',
        generation: generationA,
        resolution: CachedPlayback(leaseA.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(leaseA.path),
          'actualQuality': 'flac',
        }),
      );
      lateResult.complete(null);
      await loadingA;

      expect(accepted, isFalse);
      expect(leaseA.releaseCount, 1);
      expect(handler.queueItems[0].extras?['url'], isNull);
      expect(handler.queueItems[0].extras?['actualQuality'], isNull);
      expect(handler.mediaItem.value?.id, 'B');
    });

    test('stale streaming resolution cannot publish metadata', () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final started = Completer<int>();
      final lateResult = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        if (id == 'A') {
          started.complete(extras!['_playbackGeneration'] as int);
          return lateResult.future;
        }
        return 'https://cdn.example/B.mp3';
      };

      final loadingA = handler.setPlaylist([
        _unresolvedItem('A'),
        _unresolvedItem('B'),
      ]);
      final generationA = await started.future;
      await handler.skipToQueueItem(1, playAfterLoad: false);
      final accepted = handler.acceptResolvedPlayback(
        mediaId: 'A',
        generation: generationA,
        resolution: const StreamingPlayback('https://cdn.example/A.mp3', {
          'url': 'https://cdn.example/A.mp3',
          'actualQuality': 'flac',
        }),
      );
      lateResult.complete(null);
      await loadingA;

      expect(accepted, isFalse);
      expect(handler.queueItems[0].extras?['url'], isNull);
      expect(handler.queueItems[0].extras?['actualQuality'], isNull);
    });

    test('current resolution atomically publishes extras and stages its lease',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final lease = _FakeLease('/cache/current.mp3', 'current', (_) {});
      handler.urlResolver = (id, [extras]) async {
        final resolution = CachedPlayback(lease.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(lease.path),
          'actualQuality': 'flac',
        });
        expect(
          handler.acceptResolvedPlayback(
            mediaId: id,
            generation: extras!['_playbackGeneration'] as int,
            resolution: resolution,
          ),
          isTrue,
        );
        return resolution.playableUrl;
      };

      await handler.setPlaylist([_unresolvedItem('current')]);

      expect(handler.mediaItem.value?.extras?['actualQuality'], 'flac');
      expect(handler.queueItems.single.extras?['actualQuality'], 'flac');
      expect(lease.releaseCount, 0);
      await handler.stop();
      expect(lease.releaseCount, 1);
    });

    test(
        'foreground resolution installs and plays the active duplicate occurrence only',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      handler.urlResolver = (id, [extras]) async {
        final resolution = const StreamingPlayback(
          'https://cdn.example/duplicate.mp3',
          {
            'url': 'https://cdn.example/duplicate.mp3',
            'actualQuality': 'flac',
          },
        );
        expect(
          handler.acceptResolvedPlayback(
            mediaId: id,
            generation: extras!['_playbackGeneration'] as int,
            resolution: resolution,
          ),
          isTrue,
        );
        return resolution.playableUrl;
      };

      await handler.setPlaylist(
        [_unresolvedItem('duplicate'), _unresolvedItem('duplicate')],
        initialIndex: 1,
      );

      expect(handler.queueItems[0].extras?['actualQuality'], isNull);
      expect(handler.queueItems[0].extras?['url'], isNull);
      expect(handler.queueItems[1].extras?['actualQuality'], 'flac');
      expect(handler.mediaItem.value?.extras?['actualQuality'], 'flac');
      expect(player.sourceInstallCount, 1);
      expect(player.lastInstalledUri, 'https://cdn.example/duplicate.mp3');
      expect(player.lastInstalledTag, same(handler.queueItems[1]));
      expect(player.playing, isTrue);
    });

    test('preload resolution patches the requested second duplicate occurrence',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      var preloadCount = 0;
      handler.urlResolver = (id, [extras]) async {
        final requestToken = extras?['_preloadRequestToken'];
        if (requestToken is! int) return 'https://cdn.example/$id.mp3';
        preloadCount++;
        if (preloadCount == 1) return 'https://cdn.example/first.mp3';
        final resolution = const StreamingPlayback(
          'https://cdn.example/second.mp3',
          {
            'url': 'https://cdn.example/second.mp3',
            'actualQuality': 'flac',
          },
        );
        expect(
          handler.acceptPreloadedPlayback(
            mediaId: id,
            requestToken: requestToken,
            resolution: resolution,
          ),
          isTrue,
        );
        return resolution.playableUrl;
      };

      await handler.setPlaylist([
        _cachedItem('current', '/tmp/current.mp3'),
        _unresolvedItem('duplicate'),
        _unresolvedItem('duplicate'),
      ]);
      await pumpEventQueue();

      expect(handler.queueItems[1].extras?['actualQuality'], isNull);
      expect(handler.queueItems[2].extras?['actualQuality'], 'flac');
    });

    test('stale foreground resolution cannot patch a replaced duplicate',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final started = Completer<int>();
      final result = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        started.complete(extras!['_playbackGeneration'] as int);
        return result.future;
      };

      final loading = handler.setPlaylist([_unresolvedItem('duplicate')]);
      final generation = await started.future;
      await handler.updateQueue([_unresolvedItem('duplicate')]);
      final lease = _FakeLease('/cache/duplicate.mp3', 'duplicate', (_) {});

      final accepted = handler.acceptResolvedPlayback(
        mediaId: 'duplicate',
        generation: generation,
        resolution: CachedPlayback(lease.asLease(), {
          'url': PlaybackCacheService.toPlayableUri(lease.path),
          'actualQuality': 'flac',
        }),
      );
      result.complete(null);
      await loading;

      expect(accepted, isFalse);
      expect(lease.releaseCount, 1);
      expect(handler.queueItems.single.extras?['actualQuality'], isNull);
    });

    test('stale foreground resolution cannot patch a moved duplicate',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final started = Completer<int>();
      final result = Completer<String?>();
      handler.urlResolver = (id, [extras]) async {
        started.complete(extras!['_playbackGeneration'] as int);
        return result.future;
      };

      final loading = handler.setPlaylist(
        [
          _cachedItem('duplicate', '/tmp/first.mp3'),
          _unresolvedItem('duplicate')
        ],
        initialIndex: 1,
      );
      final generation = await started.future;
      final first = handler.queueItems[0];
      final active = handler.queueItems[1];
      await handler.updateQueue([active, first]);

      final accepted = handler.acceptResolvedPlayback(
        mediaId: 'duplicate',
        generation: generation,
        resolution:
            const StreamingPlayback('https://cdn.example/duplicate.mp3', {
          'url': 'https://cdn.example/duplicate.mp3',
          'actualQuality': 'flac',
        }),
      );
      result.complete(null);
      await loading;

      expect(accepted, isFalse);
      expect(handler.queueItems[0].extras?['actualQuality'], isNull);
      expect(handler.queueItems[1].extras?['actualQuality'], isNull);
    });

    test('late preload cannot overwrite an item after it becomes current',
        () async {
      final player = _ReuseAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final preloadStarted = Completer<int>();
      final allowPreload = Completer<void>();
      final lease = _FakeLease('/cache/B.mp3', 'B', (_) {});
      handler.urlResolver = (id, [extras]) async {
        final preloadToken = extras?['_preloadRequestToken'];
        if (preloadToken is int) {
          preloadStarted.complete(preloadToken);
          await allowPreload.future;
          final resolution = CachedPlayback(lease.asLease(), {
            'url': PlaybackCacheService.toPlayableUri(lease.path),
            'actualQuality': 'flac',
          });
          expect(
            handler.acceptPreloadedPlayback(
              mediaId: id,
              requestToken: preloadToken,
              resolution: resolution,
            ),
            isFalse,
          );
          return resolution.playableUrl;
        }
        return 'https://cdn.example/$id.mp3';
      };

      await handler.setPlaylist([
        _cachedItem('A', '/tmp/A.mp3'),
        _unresolvedItem('B'),
      ]);
      await preloadStarted.future;
      await handler.skipToQueueItem(1, playAfterLoad: false);
      allowPreload.complete();
      await pumpEventQueue();

      expect(lease.releaseCount, 1);
      expect(handler.mediaItem.value?.id, 'B');
      expect(handler.queueItems[1].extras?['actualQuality'], isNull);
      expect(handler.queueItems[1].extras?['url'], 'https://cdn.example/B.mp3');
    });
  });
}

MediaItem _cachedItem(String id, String path) => MediaItem(
      id: id,
      title: id,
      extras: {
        'url': PlaybackCacheService.toPlayableUri(path),
        'requestedQuality': '320k',
      },
    );

MediaItem _unresolvedItem(String id) => MediaItem(
      id: id,
      title: id,
      extras: const {'requestedQuality': '320k'},
    );

class _ReuseAudioPlayer extends AudioPlayer {
  bool _playing = false;
  Object? sourceInstallError;
  var sourceInstallCount = 0;
  String? lastInstalledUri;
  MediaItem? lastInstalledTag;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sourceInstallCount++;
    if (source is ProgressiveAudioSource) {
      lastInstalledUri = source.uri.toString();
      lastInstalledTag = source.tag as MediaItem?;
    } else {
      lastInstalledUri = null;
      lastInstalledTag = null;
    }
    final error = sourceInstallError;
    if (error != null) throw error;
    return null;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
  }
}

class _GatedReuseAudioPlayer extends _ReuseAudioPlayer {
  final firstSourceStarted = Completer<void>();
  final allowFirstSource = Completer<void>();

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sourceInstallCount++;
    if (sourceInstallCount == 1) {
      firstSourceStarted.complete();
      await allowFirstSource.future;
    }
    final error = sourceInstallError;
    if (error != null) throw error;
    return null;
  }
}
