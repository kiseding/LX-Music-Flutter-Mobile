import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_cache_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('just_audio processing states map to audio_service states', () {
    expect(
      audioProcessingState(ProcessingState.idle),
      AudioProcessingState.idle,
    );
    expect(
      audioProcessingState(ProcessingState.loading),
      AudioProcessingState.loading,
    );
    expect(
      audioProcessingState(ProcessingState.buffering),
      AudioProcessingState.buffering,
    );
    expect(
      audioProcessingState(ProcessingState.ready),
      AudioProcessingState.ready,
    );
    expect(
      audioProcessingState(ProcessingState.completed),
      AudioProcessingState.completed,
    );
  });

  test('initial playback state publishes the empty logical queue index', () {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);

    expect(handler.currentQueueIndex, -1);
    expect(handler.playbackState.value.queueIndex, -1);
  });

  test('player events publish one complete playback state', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.updateQueue([
      const MediaItem(id: 'A', title: 'A'),
      const MediaItem(id: 'B', title: 'B'),
    ]);
    await handler.setRepeatMode(AudioServiceRepeatMode.all);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);

    player.emit(
      processingState: ProcessingState.ready,
      playing: true,
      position: const Duration(seconds: 12),
      bufferedPosition: const Duration(seconds: 34),
      speed: 1.25,
    );
    await pumpEventQueue();

    final state = handler.playbackState.value;
    expect(state.processingState, AudioProcessingState.ready);
    expect(state.playing, isTrue);
    expect(state.updatePosition, const Duration(seconds: 12));
    expect(state.bufferedPosition, const Duration(seconds: 34));
    expect(state.speed, 1.25);
    expect(state.queueIndex, 0);
    expect(state.repeatMode, AudioServiceRepeatMode.all);
    expect(state.shuffleMode, AudioServiceShuffleMode.all);
    expect(state.controls, contains(MediaControl.pause));
    expect(state.controls, isNot(contains(MediaControl.play)));
  });

  test('engine state recovers manual buffering to ready and completed',
      () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    handler.urlResolver = (id, [extras]) async {
      resolverStarted.complete();
      await releaseResolver.future;
      return 'file:///tmp/$id.mp3';
    };

    final loading = handler.setPlaylist([
      const MediaItem(id: 'A', title: 'A'),
    ]);
    await resolverStarted.future;
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.buffering,
    );

    player.emit(processingState: ProcessingState.ready);
    await pumpEventQueue();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );

    player.emit(processingState: ProcessingState.completed);
    await pumpEventQueue();
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.completed,
    );

    releaseResolver.complete();
    await loading;
  });

  test('previous at queue start does not halt or latch buffering', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.updateQueue([
      const MediaItem(id: 'A', title: 'A'),
      const MediaItem(id: 'B', title: 'B'),
    ]);
    player.emit(processingState: ProcessingState.ready, playing: true);
    await pumpEventQueue();

    await handler.skipToPrevious();

    expect(player.pauseCalls, 0);
    expect(handler.currentQueueIndex, 0);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('single-item null resolver restores actual engine state', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => null;
    player.emit(processingState: ProcessingState.ready, playing: true);
    await pumpEventQueue();

    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);

    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, player.playing);
  });

  test('single-item resolver error restores actual engine state', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => throw StateError('resolve');
    player.emit(processingState: ProcessingState.ready, playing: true);
    await pumpEventQueue();

    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);

    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('stale resolver restores engine state while it owns buffering',
      () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    handler.urlResolver = (id, [extras]) async {
      resolverStarted.complete();
      await releaseResolver.future;
      return null;
    };
    await handler.updateQueue([
      const MediaItem(id: 'A', title: 'A'),
      const MediaItem(
        id: 'B',
        title: 'B',
        extras: {'url': 'file:///tmp/B.mp3', 'requestedQuality': '320k'},
      ),
    ]);
    player.emit(processingState: ProcessingState.ready, playing: true);
    await pumpEventQueue();

    final staleLoad = handler.skipToQueueItem(0);
    await resolverStarted.future;
    await handler.skipToQueueItem(1);
    releaseResolver.complete();
    await staleLoad;

    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, player.playing);
  });

  test('seamless completion buffers as playing when engine completed false',
      () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    handler.urlResolver = (id, [extras]) async {
      resolverStarted.complete();
      await releaseResolver.future;
      return 'file:///tmp/$id.mp3';
    };
    await handler.setPlaylist([
      const MediaItem(
        id: 'A',
        title: 'A',
        extras: {'url': 'file:///tmp/A.mp3', 'requestedQuality': '320k'},
      ),
      const MediaItem(id: 'B', title: 'B'),
    ]);

    player.emit(processingState: ProcessingState.completed, playing: false);
    await resolverStarted.future;

    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.buffering,
    );
    expect(handler.playbackState.value.playing, isTrue);

    releaseResolver.complete();
    await pumpEventQueue();
  });

  test('successful source install reconciles state without playback event',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    player.emit(processingState: ProcessingState.completed, playing: false);
    await pumpEventQueue();

    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);

    expect(player.sourceLoadCalls, 1);
    expect(player.playCalls, 1);
    expect(player.processingState, ProcessingState.ready);
    expect(player.playing, isTrue);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
  });

  test('selection pauses old source before publishing selected buffering UI',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final selectedResolverStarted = Completer<void>();
    final releaseSelectedResolver = Completer<void>();
    handler.urlResolver = (id, [extras]) async {
      if (id == 'B') {
        selectedResolverStarted.complete();
        await releaseSelectedResolver.future;
      }
      return 'file:///tmp/$id.mp3';
    };
    await handler.setPlaylist(const [
      MediaItem(id: 'A', title: 'A'),
      MediaItem(id: 'B', title: 'B'),
    ]);
    expect(player.playing, isTrue);

    final selection = handler.skipToQueueItem(1);
    await selectedResolverStarted.future;

    expect(player.pauseCalls, 1);
    // Native player is paused during resolve, but system now-playing stays
    // playing=true so lock-screen / Control Center skips do not kill the session.
    expect(player.playing, isFalse);
    expect(handler.mediaItem.value?.id, 'B');
    expect(handler.currentQueueIndex, 1);
    expect(handler.playbackState.value.queueIndex, 1);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.buffering,
    );
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.updatePosition, Duration.zero);

    releaseSelectedResolver.complete();
    await selection;
    expect(player.playing, isTrue);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('selection does not publish metadata before native pause completes',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    await handler.setPlaylist(const [
      MediaItem(id: 'A', title: 'A'),
      MediaItem(id: 'B', title: 'B'),
    ]);
    final publishedIds = <String?>[];
    final subscription = handler.mediaItem.listen(
      (item) => publishedIds.add(item?.id),
    );
    addTearDown(subscription.cancel);
    final pauseGate = player.gateNextPause();

    final selection = handler.skipToQueueItem(1);
    await pauseGate.started.future;

    expect(handler.mediaItem.value?.id, 'A');
    expect(publishedIds, isNot(contains('B')));

    pauseGate.release.complete();
    await selection;

    expect(handler.mediaItem.value?.id, 'B');
    expect(publishedIds, contains('B'));
  });

  test('direct selection releases preserving owner after null resolver',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    const item = MediaItem(id: 'A', title: 'A');
    await handler.setPlaylist(const [item]);
    await handler.updateQueue(const [item]);
    handler.urlResolver = (id, [extras]) async => null;

    await handler.skipToQueueItem(0);

    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    await handler.skipToQueueItem(0, playAfterLoad: false);
    final playCalls = player.playCalls;
    await handler.play();
    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('direct selection releases preserving owner after resolver throws',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    const item = MediaItem(id: 'A', title: 'A');
    await handler.setPlaylist(const [item]);
    await handler.updateQueue(const [item]);
    handler.urlResolver =
        (id, [extras]) async => throw StateError('resolver failure');

    await handler.skipToQueueItem(0);

    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    await handler.skipToQueueItem(0, playAfterLoad: false);
    final playCalls = player.playCalls;
    await handler.play();
    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('direct selection releases preserving owner after source install fails',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    const item = MediaItem(id: 'A', title: 'A');
    await handler.setPlaylist(const [item]);
    await handler.updateQueue(const [item]);
    player.failNextSourceInstall = true;

    await handler.skipToQueueItem(0);

    await handler.skipToQueueItem(0, playAfterLoad: false);
    final playCalls = player.playCalls;
    await handler.play();
    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('stale direct selection releases preserving owner', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final staleResolverStarted = Completer<void>();
    final releaseStaleResolver = Completer<void>();
    handler.urlResolver = (id, [extras]) async {
      if (id == 'B') {
        staleResolverStarted.complete();
        await releaseStaleResolver.future;
      }
      return 'file:///tmp/$id.mp3';
    };
    await handler.setPlaylist(const [
      MediaItem(id: 'A', title: 'A'),
      MediaItem(id: 'B', title: 'B'),
      MediaItem(id: 'C', title: 'C'),
    ]);

    final staleSelection = handler.skipToQueueItem(1);
    await staleResolverStarted.future;
    await handler.skipToQueueItem(2, playAfterLoad: false);
    releaseStaleResolver.complete();
    await staleSelection;

    final playCalls = player.playCalls;
    await handler.play();
    expect(handler.mediaItem.value?.id, 'C');
    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('authoritative play failure reconciles forced playing state', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final playFailure = player.gateNextPlayFailure();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';

    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);
    await playFailure.started.future;
    expect(handler.playbackState.value.playing, isTrue);

    playFailure.release.complete();
    await pumpEventQueue();

    expect(player.playing, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.controls, contains(MediaControl.play));
  });

  test('stale play failure cannot overwrite newer source state', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final stalePlayFailure = player.gateNextPlayFailure();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';

    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);
    await stalePlayFailure.started.future;
    await handler.setPlaylist([const MediaItem(id: 'B', title: 'B')]);
    expect(handler.mediaItem.value?.id, 'B');
    expect(handler.playbackState.value.playing, isTrue);

    stalePlayFailure.release.complete();
    await pumpEventQueue();

    expect(handler.mediaItem.value?.id, 'B');
    expect(handler.playbackState.value.playing, isTrue);
    expect(handler.playbackState.value.controls, contains(MediaControl.pause));
  });

  test('cached source install failure clears navigation buffering', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    const items = [
      MediaItem(
        id: 'A',
        title: 'A',
        extras: {'url': 'file:///tmp/A.mp3', 'requestedQuality': '320k'},
      ),
      MediaItem(
        id: 'B',
        title: 'B',
        extras: {'url': 'file:///tmp/B.mp3', 'requestedQuality': '320k'},
      ),
    ];
    await handler.setPlaylist(items);
    player.failNextSourceInstall = true;

    await handler.skipToNext();

    expect(handler.currentQueueIndex, 1);
    expect(player.processingState, ProcessingState.ready);
    expect(player.playing, isFalse);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isFalse);
  });

  test('authoritative source install failure reports and falls back once',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final errors = <String>[];
    handler.onError = errors.add;
    const items = [
      MediaItem(
        id: 'A',
        title: 'A',
        extras: {'url': 'file:///tmp/A.mp3', 'requestedQuality': '320k'},
      ),
      MediaItem(
        id: 'B',
        title: 'B',
        extras: {'url': 'file:///tmp/B.mp3', 'requestedQuality': '320k'},
      ),
      MediaItem(
        id: 'C',
        title: 'C',
        extras: {'url': 'file:///tmp/C.mp3', 'requestedQuality': '320k'},
      ),
    ];
    await handler.setPlaylist(items);
    player.failNextSourceInstall = true;

    final navigation = handler.skipToNext();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 2);
    expect(handler.mediaItem.value?.id, 'C');
    expect(errors, hasLength(1));
    await navigation;
  });

  test('stale source install failure is silent and cannot fall back', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    final errors = <String>[];
    handler.onError = errors.add;
    const items = [
      MediaItem(
        id: 'A',
        title: 'A',
        extras: {'url': 'file:///tmp/A.mp3', 'requestedQuality': '320k'},
      ),
      MediaItem(
        id: 'B',
        title: 'B',
        extras: {'url': 'file:///tmp/B.mp3', 'requestedQuality': '320k'},
      ),
      MediaItem(
        id: 'C',
        title: 'C',
        extras: {'url': 'file:///tmp/C.mp3', 'requestedQuality': '320k'},
      ),
    ];
    await handler.setPlaylist(items);
    final staleFailure = player.gateNextSourceInstallFailure();

    final staleNavigation = handler.skipToNext();
    await staleFailure.started.future;
    final currentNavigation = handler.skipToQueueItem(2);
    staleFailure.release.complete();
    await Future.wait([staleNavigation, currentNavigation]);

    expect(handler.currentQueueIndex, 2);
    expect(handler.mediaItem.value?.id, 'C');
    expect(errors, isEmpty);
    expect(player.sourceLoadCalls, 3);
  });

  test('handler disposal cancels streams and disposes native player once',
      () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    var cacheCancellationCalls = 0;
    handler.attachPlaybackCache(
      cancelAllTrackedCacheWork: () => cacheCancellationCalls++,
    );

    final first = handler.dispose();
    final second = handler.dispose();
    await Future.wait([first, second]);

    expect(identical(first, second), isTrue);
    expect(cacheCancellationCalls, 1);
    expect(player.disposeCalls, 1);
    expect(player.playbackEventListenCancels, 1);
    expect(player.processingStateListenCancels, 1);
  });

  test('handler disposal releases resolver and error callback bindings',
      () async {
    final handler = LxAudioHandler(player: _PlaybackStateAudioPlayer());
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    handler.onError = (_) {};

    await handler.dispose();

    expect(handler.urlResolver, isNull);
    expect(handler.onError, isNull);
  });

  test('handler disposal awaits pending playback lease release', () async {
    final handler = LxAudioHandler(player: _PlaybackStateAudioPlayer());
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    final leaseReleaseStarted = Completer<void>();
    final releaseLease = Completer<void>();
    final lease = PlaybackCacheLease.test(
      '/tmp/A.mp3',
      'file:///tmp/A.mp3',
      () async {
        leaseReleaseStarted.complete();
        await releaseLease.future;
      },
    );
    handler.urlResolver = (id, [extras]) async {
      handler.acceptResolvedPlayback(
        mediaId: id,
        generation: extras!['_playbackGeneration'] as int,
        resolution: CachedPlayback(lease, const {}),
      );
      resolverStarted.complete();
      await releaseResolver.future;
      return lease.playableUri;
    };
    final loading = handler.setPlaylist([
      const MediaItem(id: 'A', title: 'A'),
    ]);
    await resolverStarted.future;

    var disposeCompleted = false;
    final disposing = handler.dispose().then((_) => disposeCompleted = true);
    await pumpEventQueue();

    expect(disposeCompleted, isFalse);
    releaseResolver.complete();
    await leaseReleaseStarted.future;
    releaseLease.complete();
    await disposing;
    await loading;
  });

  test('handler disposal waits for a queued source mutation', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    final sourceGate = player.gateNextSourceInstall();
    final loading = handler.setPlaylist([
      const MediaItem(id: 'A', title: 'A'),
    ]);
    await sourceGate.started.future;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();

    expect(disposed, isFalse);
    expect(player.disposeCalls, 0);
    sourceGate.release.complete();
    await Future.wait([loading, disposing]);
    expect(player.disposeCalls, 1);
  });

  test('handler disposal waits for a queued pause mutation', () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);
    final pauseGate = player.gateNextPause();
    final pausing = handler.pause();
    await pauseGate.started.future;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();

    expect(disposed, isFalse);
    expect(player.disposeCalls, 0);
    pauseGate.release.complete();
    await Future.wait([pausing, disposing]);
    expect(player.disposeCalls, 1);
  });

  test('handler disposal continues after every cleanup class fails', () async {
    final callbackFailure = StateError('callback cancellation');
    final playbackSubscriptionFailure = StateError('playback subscription');
    final processingSubscriptionFailure = StateError('processing subscription');
    final stopFailure = StateError('stop');
    final playerDisposeFailure = StateError('player dispose');
    final player = _PlaybackStateAudioPlayer()
      ..playbackCancelError = playbackSubscriptionFailure
      ..processingCancelError = processingSubscriptionFailure
      ..stopError = stopFailure
      ..disposeError = playerDisposeFailure;
    final handler = LxAudioHandler(player: player);
    player.emit(processingState: ProcessingState.ready);
    handler.attachPlaybackCache(
      cancelAllTrackedCacheWork: () => throw callbackFailure,
    );

    await expectLater(handler.dispose(), throwsA(same(callbackFailure)));

    expect(player.playbackEventListenCancels, 1);
    expect(player.processingStateListenCancels, 1);
    expect(player.stopCalls, 1);
    expect(player.disposeCalls, 1);
    await expectLater(handler.dispose(), throwsA(same(callbackFailure)));
    expect(player.disposeCalls, 1);
  });

  test('handler disposal continues from pending lease failure to active lease',
      () async {
    final pendingFailure = StateError('pending lease');
    var activeReleases = 0;
    var pendingReleases = 0;
    final activeLease = PlaybackCacheLease.test(
      '/tmp/A.mp3',
      'file:///tmp/A.mp3',
      () async => activeReleases++,
    );
    final pendingLease = PlaybackCacheLease.test(
      '/tmp/B.mp3',
      'file:///tmp/B.mp3',
      () async {
        pendingReleases++;
        throw pendingFailure;
      },
    );
    final pendingAccepted = Completer<void>();
    final releaseResolver = Completer<void>();
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async {
      final lease = id == 'A' ? activeLease : pendingLease;
      handler.acceptResolvedPlayback(
        mediaId: id,
        generation: extras!['_playbackGeneration'] as int,
        resolution: CachedPlayback(lease, const {}),
      );
      if (id == 'B') {
        pendingAccepted.complete();
        await releaseResolver.future;
      }
      return lease.playableUri;
    };
    await handler.setPlaylist(const [
      MediaItem(id: 'A', title: 'A'),
      MediaItem(id: 'B', title: 'B'),
    ]);
    final loadingPending = handler.skipToQueueItem(1);
    final loadingExpectation =
        expectLater(loadingPending, throwsA(same(pendingFailure)));
    await pendingAccepted.future;

    final disposing = handler.dispose();
    await pumpEventQueue();
    releaseResolver.complete();
    await expectLater(disposing, throwsA(same(pendingFailure)));

    expect(pendingReleases, 1);
    expect(activeReleases, 1);
    expect(player.disposeCalls, 1);
    await loadingExpectation;
  });

  test('public handler commands are inert after disposal', () async {
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    await handler.dispose();
    final calls = (
      play: player.playCalls,
      pause: player.pauseCalls,
      stop: player.stopCalls,
      source: player.sourceLoadCalls,
    );

    await handler.play();
    await handler.pause();
    await handler.seek(const Duration(seconds: 2));
    await handler.stop();
    await handler.skipToQueueItem(0);
    await handler.setPlaylist([const MediaItem(id: 'A', title: 'A')]);
    await handler.updateQueue([const MediaItem(id: 'B', title: 'B')]);
    await handler.addQueueItem(const MediaItem(id: 'C', title: 'C'));
    await handler.removeQueueItem(const MediaItem(id: 'C', title: 'C'));
    await handler.setRepeatMode(AudioServiceRepeatMode.one);
    await handler.setShuffleMode(AudioServiceShuffleMode.all);
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: true);
    await handler.handleBecomingNoisy();
    await handler.applyPreferredQuality('flac');

    expect(player.playCalls, calls.play);
    expect(player.pauseCalls, calls.pause);
    expect(player.stopCalls, calls.stop);
    expect(player.sourceLoadCalls, calls.source);
  });

  test('handler disposal drains a gated resolver before player disposal',
      () async {
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async {
      resolverStarted.complete();
      await releaseResolver.future;
      return 'file:///tmp/$id.mp3';
    };
    final loading = handler.setPlaylist([
      const MediaItem(id: 'A', title: 'A'),
    ]);
    await resolverStarted.future;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();

    expect(disposed, isFalse);
    expect(player.disposeCalls, 0);
    releaseResolver.complete();
    await Future.wait([loading, disposing]);
    expect(player.disposeCalls, 1);
    expect(player.sourceLoadCalls, 0);
  });

  test('handler disposal drains classification and awaits its late lease',
      () async {
    final classificationStarted = Completer<void>();
    final releaseClassification = Completer<void>();
    final leaseReleaseStarted = Completer<void>();
    final releaseLease = Completer<void>();
    final lease = PlaybackCacheLease.test(
      '/tmp/A.mp3',
      'file:///tmp/A.mp3',
      () async {
        leaseReleaseStarted.complete();
        await releaseLease.future;
      },
    );
    final player = _PlaybackStateAudioPlayer();
    final handler = LxAudioHandler(player: player);
    handler.attachPlaybackCache(
      classifyExisting: (_) async {
        classificationStarted.complete();
        await releaseClassification.future;
        return LeasedPlaybackCachePath(lease);
      },
    );
    final loading = handler.setPlaylist(const [
      MediaItem(
        id: 'A',
        title: 'A',
        extras: {'url': 'file:///tmp/A.mp3', 'requestedQuality': '320k'},
      ),
    ]);
    await classificationStarted.future;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();
    expect(disposed, isFalse);
    releaseClassification.complete();
    await leaseReleaseStarted.future;
    await pumpEventQueue();
    expect(disposed, isFalse);
    expect(player.disposeCalls, 0);
    releaseLease.complete();
    await Future.wait([loading, disposing]);
    expect(player.disposeCalls, 1);
  });

  test('handler disposal drains a gated preload resolver', () async {
    final preloadStarted = Completer<void>();
    final releasePreload = Completer<void>();
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async {
      if (id == 'B') {
        preloadStarted.complete();
        await releasePreload.future;
      }
      return 'https://cdn.example/$id.mp3';
    };
    await handler.setPlaylist(const [
      MediaItem(
        id: 'A',
        title: 'A',
        extras: {
          'url': 'https://cdn.example/A.mp3',
          'requestedQuality': '320k',
        },
      ),
      MediaItem(id: 'B', title: 'B'),
    ]);
    await preloadStarted.future;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();

    expect(disposed, isFalse);
    expect(player.disposeCalls, 0);
    releasePreload.complete();
    await disposing;
    expect(player.disposeCalls, 1);
  });

  test('removeQueueItem cannot mutate queue after dispose begins during halt',
      () async {
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.mp3';
    const first = MediaItem(id: 'A', title: 'A');
    const second = MediaItem(id: 'B', title: 'B');
    await handler.setPlaylist([first, second]);
    final pauseGate = player.gateNextPause();
    final removing = handler.removeQueueItem(first);
    await pauseGate.started.future;
    final queueBeforeDispose = handler.queueItems;
    final mediaBeforeDispose = handler.mediaItem.value;

    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);
    pauseGate.release.complete();
    await Future.wait([removing, disposing]);

    expect(handler.queueItems, queueBeforeDispose);
    expect(handler.mediaItem.value, same(mediaBeforeDispose));
    expect(player.sourceLoadCalls, 1);
  });

  test('empty playlist cannot submit stop after disposal begins during release',
      () async {
    final releaseStarted = Completer<void>();
    final releaseLease = Completer<void>();
    final lease = PlaybackCacheLease.test(
      '/tmp/A.mp3',
      'file:///tmp/A.mp3',
      () async {
        releaseStarted.complete();
        await releaseLease.future;
      },
    );
    final player = _PlaybackStateAudioPlayer()
      ..sourceInstallProcessingState = ProcessingState.ready;
    final handler = LxAudioHandler(player: player);
    handler.urlResolver = (id, [extras]) async {
      handler.acceptResolvedPlayback(
        mediaId: id,
        generation: extras!['_playbackGeneration'] as int,
        resolution: CachedPlayback(lease, const {}),
      );
      return lease.playableUri;
    };
    await handler.setPlaylist(const [MediaItem(id: 'A', title: 'A')]);

    final stopGate = player.gateNextStop();
    var cleared = false;
    final clearing = handler.setPlaylist(const []).then((_) => cleared = true);
    await releaseStarted.future;
    final queueAtShutdown = handler.queueItems;
    final mediaAtShutdown = handler.mediaItem.value;
    var disposed = false;
    final disposing = handler.dispose().then((_) => disposed = true);
    await pumpEventQueue();

    expect(disposed, isFalse);
    expect(player.stopCalls, 0);
    releaseLease.complete();
    await stopGate.started.future;
    expect(cleared, isTrue);
    expect(disposed, isFalse);
    stopGate.release.complete();
    await Future.wait([clearing, disposing]);

    expect(player.stopCalls, 1);
    expect(player.sourceLoadCalls, 1);
    expect(handler.queueItems, queueAtShutdown);
    expect(handler.mediaItem.value, same(mediaAtShutdown));
  });
}

class _PlaybackStateAudioPlayer extends AudioPlayer {
  late final StreamController<PlaybackEvent> _events =
      StreamController<PlaybackEvent>.broadcast(
    onCancel: () => playbackEventListenCancels++,
  );
  late final StreamController<ProcessingState> _processingStates =
      StreamController<ProcessingState>.broadcast(
    onCancel: () => processingStateListenCancels++,
  );
  PlaybackEvent _event = PlaybackEvent();
  bool _playing = false;
  double _speed = 1.0;
  bool _shuffleModeEnabled = false;
  int pauseCalls = 0;
  int playCalls = 0;
  int sourceLoadCalls = 0;
  int playbackEventListenCancels = 0;
  int processingStateListenCancels = 0;
  int disposeCalls = 0;
  int stopCalls = 0;
  Object? playbackCancelError;
  Object? processingCancelError;
  Object? stopError;
  Object? disposeError;
  ProcessingState? sourceInstallProcessingState;
  bool failNextSourceInstall = false;
  final _playFailureGates = <_PlayFailureGate>[];
  final _sourceFailureGates = <_PlayFailureGate>[];
  final _sourceInstallGates = <_PlayFailureGate>[];
  final _pauseGates = <_PlayFailureGate>[];
  final _stopGates = <_PlayFailureGate>[];

  _PlayFailureGate gateNextPlayFailure() {
    final gate = _PlayFailureGate();
    _playFailureGates.add(gate);
    return gate;
  }

  _PlayFailureGate gateNextSourceInstallFailure() {
    final gate = _PlayFailureGate();
    _sourceFailureGates.add(gate);
    return gate;
  }

  _PlayFailureGate gateNextSourceInstall() {
    final gate = _PlayFailureGate();
    _sourceInstallGates.add(gate);
    return gate;
  }

  _PlayFailureGate gateNextPause() {
    final gate = _PlayFailureGate();
    _pauseGates.add(gate);
    return gate;
  }

  _PlayFailureGate gateNextStop() {
    final gate = _PlayFailureGate();
    _stopGates.add(gate);
    return gate;
  }

  void emit({
    required ProcessingState processingState,
    bool? playing,
    Duration? position,
    Duration? bufferedPosition,
    double? speed,
  }) {
    _playing = playing ?? _playing;
    _speed = speed ?? _speed;
    _event = PlaybackEvent(
      processingState: processingState,
      updatePosition: position ?? _event.updatePosition,
      bufferedPosition: bufferedPosition ?? _event.bufferedPosition,
    );
    _events.add(_event);
    _processingStates.add(processingState);
  }

  @override
  PlaybackEvent get playbackEvent => _event;

  @override
  Stream<PlaybackEvent> get playbackEventStream => _CancelFailingStream(
        _events.stream,
        playbackCancelError,
      );

  @override
  ProcessingState get processingState => _event.processingState;

  @override
  Stream<ProcessingState> get processingStateStream => _CancelFailingStream(
        _processingStates.stream,
        processingCancelError,
      );

  @override
  bool get playing => _playing;

  @override
  Duration get position => _event.updatePosition;

  @override
  Duration get bufferedPosition => _event.bufferedPosition;

  @override
  double get speed => _speed;

  @override
  bool get shuffleModeEnabled => _shuffleModeEnabled;

  @override
  Future<void> setShuffleModeEnabled(bool enabled) async {
    _shuffleModeEnabled = enabled;
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sourceLoadCalls++;
    final sourceGate =
        _sourceInstallGates.isEmpty ? null : _sourceInstallGates.removeAt(0);
    if (sourceGate != null) {
      sourceGate.started.complete();
      await sourceGate.release.future;
    }
    final failureGate =
        _sourceFailureGates.isEmpty ? null : _sourceFailureGates.removeAt(0);
    if (failureGate != null) {
      failureGate.started.complete();
      await failureGate.release.future;
      throw StateError('source install');
    }
    if (failNextSourceInstall) {
      failNextSourceInstall = false;
      throw StateError('source install');
    }
    final state = sourceInstallProcessingState;
    if (state != null) {
      _event = PlaybackEvent(
        processingState: state,
        updatePosition: initialPosition ?? Duration.zero,
      );
    }
    return null;
  }

  @override
  Future<void> play() async {
    playCalls++;
    final failureGate =
        _playFailureGates.isEmpty ? null : _playFailureGates.removeAt(0);
    if (failureGate != null) {
      failureGate.started.complete();
      await failureGate.release.future;
      _playing = false;
      throw StateError('play');
    }
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    final gate = _pauseGates.isEmpty ? null : _pauseGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = false;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    final gate = _stopGates.isEmpty ? null : _stopGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    final error = stopError;
    if (error != null) throw error;
    _playing = false;
    _event = PlaybackEvent(processingState: ProcessingState.idle);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await _events.close();
    await _processingStates.close();
    final error = disposeError;
    if (error != null) throw error;
    await super.dispose();
  }
}

class _PlayFailureGate {
  final started = Completer<void>();
  final release = Completer<void>();
}

final class _CancelFailingStream<T> extends Stream<T> {
  _CancelFailingStream(this._source, this._cancelError);

  final Stream<T> _source;
  final Object? _cancelError;

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _CancelFailingSubscription(
      _source.listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      ),
      _cancelError,
    );
  }
}

final class _CancelFailingSubscription<T> implements StreamSubscription<T> {
  _CancelFailingSubscription(this._delegate, this._cancelError);

  final StreamSubscription<T> _delegate;
  final Object? _cancelError;

  @override
  Future<void> cancel() async {
    await _delegate.cancel();
    final error = _cancelError;
    if (error != null) throw error;
  }

  @override
  void onData(void Function(T data)? handleData) =>
      _delegate.onData(handleData);

  @override
  void onError(Function? handleError) => _delegate.onError(handleError);

  @override
  void onDone(void Function()? handleDone) => _delegate.onDone(handleDone);

  @override
  void pause([Future<void>? resumeSignal]) => _delegate.pause(resumeSignal);

  @override
  void resume() => _delegate.resume();

  @override
  bool get isPaused => _delegate.isPaused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => _delegate.asFuture(futureValue);
}
