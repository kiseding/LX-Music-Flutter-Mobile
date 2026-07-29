import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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
      expect((result as StreamingPlayback).remoteUrl, 'https://cdn.example/a.mp3');
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
      final activeLease = active.asLease();
      final session = PlaybackLeaseSession();

      await session.commitAuthoritative(activeLease);
      await session.commitAuthoritative(null);
      expect(released, ['active']);
      expect(session.activeLease, isNull);
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
}
