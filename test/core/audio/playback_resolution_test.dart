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

class _ReuseAudioPlayer extends AudioPlayer {
  bool _playing = false;
  Object? sourceInstallError;
  var sourceInstallCount = 0;

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
