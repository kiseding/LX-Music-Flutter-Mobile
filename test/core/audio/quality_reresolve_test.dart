import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cached play url is reused only when requested quality matches', () {
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.flac',
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isTrue,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.mp3',
        cachedRequestedQuality: '320k',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'file:///tmp/a.mp3',
        cachedRequestedQuality: null,
        currentRequestedQuality: '320k',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: null,
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
    expect(
      shouldReuseCachedPlayUrl(
        cachedUrl: 'data:audio/wav;base64,xx',
        cachedRequestedQuality: 'flac',
        currentRequestedQuality: 'flac',
      ),
      isFalse,
    );
  });

  test('quality string map covers settings options', () {
    expect(playQualityToken(AudioQualityToken.low), '128k');
    expect(playQualityToken(AudioQualityToken.high), '320k');
    expect(playQualityToken(AudioQualityToken.lossless), 'flac');
    expect(playQualityToken(AudioQualityToken.lossless24), 'flac24bit');
    expect(playQualityToken(AudioQualityToken.hires), 'hires');
  });

  test('quality reload retains engine position and actual play state', () {
    final paused = qualityReloadIntent(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      desiredPlayingIntent: false,
    );

    expect(paused.position, const Duration(seconds: 42));
    expect(paused.resumeAfterReload, isFalse);
  });

  test('quality reload clamps position to duration without compensation', () {
    final playing = qualityReloadIntent(
      position: const Duration(minutes: 4),
      duration: const Duration(minutes: 3),
      desiredPlayingIntent: true,
    );

    expect(playing.position, const Duration(minutes: 3));
    expect(playing.resumeAfterReload, isTrue);
  });

  test('paused quality change reloads at engine position without resuming',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    await handler.pause();
    final playCalls = player.playCalls;

    await handler.applyPreferredQuality('flac');

    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('playing quality change pauses, reloads position, and resumes',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final playCalls = player.playCalls;

    await handler.applyPreferredQuality('flac');

    expect(player.pauseCalls, 1);
    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('quality begun during interruption resumes new quality after end',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    await handler.beginAudioInterruption();

    await handler.applyPreferredQuality('flac');

    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(handler.queueItems.single.extras?['requestedQuality'], 'flac');
    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('quality begun during interruption stays paused after denied end',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    await handler.beginAudioInterruption();

    await handler.applyPreferredQuality('flac');
    await handler.endAudioInterruption(mayResume: false);

    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(handler.queueItems.single.extras?['requestedQuality'], 'flac');
    expect(player.playing, isFalse);
  });

  test('explicit pause during interruption keeps quality reload paused',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    await handler.beginAudioInterruption();
    await handler.pause();

    await handler.applyPreferredQuality('flac');
    await handler.endAudioInterruption(mayResume: true);

    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(handler.queueItems.single.extras?['requestedQuality'], 'flac');
    expect(player.playing, isFalse);
  });

  test('newer pause wins while quality URL is resolving', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id-320k.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final resolveGate = _Gate();
    handler.urlResolver = (id, [extras]) async {
      resolveGate.started.complete();
      await resolveGate.release.future;
      return 'file:///tmp/$id-flac.mp3';
    };

    final reload = handler.applyPreferredQuality('flac');
    await resolveGate.started.future;
    await handler.pause();
    resolveGate.release.complete();
    await reload;

    expect(player.playing, isFalse);
  });

  test('newer pause wins while quality source is installing', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final installGate = player.gateNextSourceInstall();

    final reload = handler.applyPreferredQuality('flac');
    await installGate.started.future;
    await handler.pause();
    installGate.release.complete();
    await reload;

    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(player.sourceLoadCalls, 2);
    expect(player.playing, isFalse);
  });

  test('newer queue selection wins while quality URL is resolving', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id-320k.mp3';
    await handler.setPlaylist([_item('A'), _item('B')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final resolveGate = _Gate();
    handler.urlResolver = (id, [extras]) async {
      if (id == 'A') {
        resolveGate.started.complete();
        await resolveGate.release.future;
      }
      return 'file:///tmp/$id-flac.mp3';
    };

    final reload = handler.applyPreferredQuality('flac');
    await resolveGate.started.future;
    await handler.skipToQueueItem(1);
    resolveGate.release.complete();
    await reload;

    expect(handler.mediaItem.value?.id, 'B');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.initialPositions.last, Duration.zero);
    expect(player.playing, isTrue);
  });

  for (final selection in <({
    String name,
    int initialIndex,
    int targetIndex,
    Future<void> Function(LxAudioHandler) run,
  })>[
    (
      name: 'queue item',
      initialIndex: 0,
      targetIndex: 1,
      run: (handler) => handler.skipToQueueItem(1),
    ),
    (
      name: 'next',
      initialIndex: 0,
      targetIndex: 1,
      run: (handler) => handler.skipToNext(),
    ),
    (
      name: 'previous',
      initialIndex: 1,
      targetIndex: 0,
      run: (handler) => handler.skipToPrevious(),
    ),
  ]) {
    test('newer pause owns ${selection.name} URL resolution', () async {
      final player = _QualityAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      final items = [_item('A'), _item('B')];
      items[selection.targetIndex] =
          const MediaItem(id: 'target', title: 'target');
      await handler.setPlaylist(items, initialIndex: selection.initialIndex);
      await pumpEventQueue();
      final resolveGate = _Gate();
      handler.urlResolver = (id, [extras]) async {
        resolveGate.started.complete();
        await resolveGate.release.future;
        return 'file:///tmp/$id-320k.mp3';
      };
      final sourceLoads = player.sourceLoadCalls;

      final load = selection.run(handler);
      await resolveGate.started.future;
      await handler.pause();
      resolveGate.release.complete();
      await load;

      expect(
        player.sourceLoadCalls,
        sourceLoads + (selection.name == 'queue item' ? 1 : 2),
      );
      expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'target');
      expect(player.playing, isFalse);
    });

    test('newer pause owns ${selection.name} source installation', () async {
      final player = _QualityAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      await handler.setPlaylist(
        [_item('A'), _item('B')],
        initialIndex: selection.initialIndex,
      );
      final installGate = player.gateNextSourceInstall();
      final playCalls = player.playCalls;

      final load = selection.run(handler);
      await installGate.started.future;
      await handler.pause();
      installGate.release.complete();
      await load;

      expect(player.playCalls, playCalls);
      expect(player.playing, isFalse);
    });
  }

  test('explicit playAfterLoad false owns paused selection intent', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    final playCalls = player.playCalls;

    await handler.skipToQueueItem(1, playAfterLoad: false);
    handler.debugEmitTrackCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 1);
    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('newer play during explicit false halt keeps selected item', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    final sourceLoads = player.sourceLoadCalls;
    final pauseGate = player.gateNextPause();

    final selection = handler.skipToQueueItem(1, playAfterLoad: false);
    await pauseGate.started.future;
    await handler.play();
    pauseGate.release.complete();
    await selection;

    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.sourceLoadCalls, sourceLoads + 1);
    expect(player.playing, isTrue);
  });

  test('newer pause during explicit false halt keeps selected item', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    final sourceLoads = player.sourceLoadCalls;
    final pauseGate = player.gateNextPause();

    final selection = handler.skipToQueueItem(1, playAfterLoad: false);
    await pauseGate.started.future;
    await handler.pause();
    pauseGate.release.complete();
    await selection;

    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.sourceLoadCalls, sourceLoads + 1);
    expect(player.playing, isFalse);
  });

  test('newer queue selection cancels explicit false selection during halt',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B'), _item('C')]);
    final pauseGate = player.gateNextPause();

    final staleSelection = handler.skipToQueueItem(1, playAfterLoad: false);
    await pauseGate.started.future;
    final newerSelection = handler.skipToQueueItem(2);
    pauseGate.release.complete();
    await newerSelection;
    await staleSelection;

    expect(handler.currentQueueIndex, 2);
    expect(handler.mediaItem.value?.id, 'C');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'C');
    expect(player.playing, isTrue);
  });

  test('newer pause during quality halt preserves quality and reloads paused',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A'), _item('B')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final sourceLoads = player.sourceLoadCalls;
    final pauseGate = player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    await handler.pause();
    pauseGate.release.complete();
    await reload;

    expect(handler.preferredQuality, 'flac');
    expect(handler.queueItems[1].extras?['requestedQuality'], 'flac');
    expect(handler.queueItems[1].extras?['url'], isNull);
    expect(player.sourceLoadCalls, sourceLoads + 1);
    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(player.playing, isFalse);
  });

  test('newer play during quality halt preserves quality and reloads playing',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A'), _item('B')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final sourceLoads = player.sourceLoadCalls;
    final pauseGate = player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    await handler.play();
    pauseGate.release.complete();
    await reload;

    expect(handler.preferredQuality, 'flac');
    expect(handler.queueItems[1].extras?['requestedQuality'], 'flac');
    expect(handler.queueItems[1].extras?['url'], isNull);
    expect(player.sourceLoadCalls, sourceLoads + 1);
    expect(player.initialPositions.last, const Duration(seconds: 42));
    expect(player.playing, isTrue);
  });

  test('same-item selection during quality halt owns source and position',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final pauseGate = player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    final selection = handler.skipToQueueItem(
      0,
      initialPosition: const Duration(seconds: 7),
    );
    final sourceLoads = player.sourceLoadCalls;
    pauseGate.release.complete();
    await selection;
    await reload;

    expect(handler.preferredQuality, 'flac');
    expect(handler.queueItems.single.extras?['requestedQuality'], 'flac');
    expect(player.sourceLoadCalls, sourceLoads + 1);
    expect(player.position, const Duration(seconds: 7));
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
    expect(player.playing, isTrue);
  });

  test('stop during quality halt prevents stale source installation', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final pauseGate = player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    await handler.stop();
    final sourceLoads = player.sourceLoadCalls;
    pauseGate.release.complete();
    await reload;

    expect(handler.preferredQuality, 'flac');
    expect(handler.queueItems.single.extras?['requestedQuality'], 'flac');
    expect(handler.queueItems.single.extras?['url'], isNull);
    expect(player.sourceLoadCalls, sourceLoads);
    expect(player.playing, isFalse);
  });

  test('interruption during quality pause defers reload start', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final pauseGate = player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    final interruption = handler.beginAudioInterruption();
    pauseGate.release.complete();
    await reload;
    await interruption;

    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('quality pause cannot forget a completed interruption cycle', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final pauseGate = player.gateNextPause();
    final playCalls = player.playCalls;

    final reload = handler.applyPreferredQuality('flac');
    await pauseGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    pauseGate.release.complete();
    await reload;
    await pumpEventQueue();

    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('interruption during quality resolution defers reload start', () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id-320k.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final resolveGate = _Gate();
    handler.urlResolver = (id, [extras]) async {
      resolveGate.started.complete();
      await resolveGate.release.future;
      return 'file:///tmp/$id-flac.mp3';
    };

    final reload = handler.applyPreferredQuality('flac');
    await resolveGate.started.future;
    await handler.beginAudioInterruption();
    resolveGate.release.complete();
    await reload;

    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('complete resumable cycle during resolution starts after install',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id-320k.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final resolveGate = _Gate();
    handler.urlResolver = (id, [extras]) async {
      resolveGate.started.complete();
      await resolveGate.release.future;
      return 'file:///tmp/$id-flac.mp3';
    };

    final reload = handler.applyPreferredQuality('flac');
    await resolveGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: true);
    resolveGate.release.complete();
    await reload;
    await pumpEventQueue();

    expect(player.playing, isTrue);
  });

  test('non-resumable end during quality resolution prevents later start',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id-320k.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final resolveGate = _Gate();
    handler.urlResolver = (id, [extras]) async {
      resolveGate.started.complete();
      await resolveGate.release.future;
      return 'file:///tmp/$id-flac.mp3';
    };

    final reload = handler.applyPreferredQuality('flac');
    await resolveGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    resolveGate.release.complete();
    await reload;

    expect(player.playing, isFalse);
  });

  test('interruption during quality installation defers reload start',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final installGate = player.gateNextSourceInstall();

    final reload = handler.applyPreferredQuality('flac');
    await installGate.started.future;
    await handler.beginAudioInterruption();
    installGate.release.complete();
    await reload;

    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('complete resumable cycle during installation starts afterward',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final installGate = player.gateNextSourceInstall();

    final reload = handler.applyPreferredQuality('flac');
    await installGate.started.future;
    final begin = handler.beginAudioInterruption();
    final end = handler.endAudioInterruption(mayResume: true);
    installGate.release.complete();
    await begin;
    await end;
    await reload;
    await pumpEventQueue();

    expect(player.playing, isTrue);
  });

  test('non-resumable end during quality installation prevents later start',
      () async {
    final player = _QualityAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    await handler.setPlaylist([_item('A')]);
    player.setEngineState(
      position: const Duration(seconds: 42),
      duration: const Duration(minutes: 3),
      playing: true,
    );
    final installGate = player.gateNextSourceInstall();

    final reload = handler.applyPreferredQuality('flac');
    await installGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    installGate.release.complete();
    await reload;

    expect(player.playing, isFalse);
  });

  for (final releaseQualityFirst in [true, false]) {
    test(
        'overlapping quality and scrub owners wait when ${releaseQualityFirst ? 'quality' : 'scrub'} releases first',
        () async {
      final player = _QualityAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      handler.urlResolver = (id, [extras]) async =>
          'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
      await handler.setPlaylist([_item('A')]);
      player.setEngineState(
        position: const Duration(seconds: 42),
        duration: const Duration(minutes: 3),
        playing: true,
      );
      final resolveGate = _Gate();
      handler.urlResolver = (id, [extras]) async {
        resolveGate.started.complete();
        await resolveGate.release.future;
        return 'file:///tmp/$id-flac.mp3';
      };

      final reload = handler.applyPreferredQuality('flac');
      await resolveGate.started.future;
      final scrubSourceGeneration = handler.sourceGeneration;
      final scrubUserIntentGeneration = handler.userIntentGeneration;
      final scrubOwner = await handler.pauseForScrub(
        sourceGeneration: scrubSourceGeneration,
        userIntentGeneration: scrubUserIntentGeneration,
        stillOwnsScrub: () => true,
      );
      expect(scrubOwner, isNotNull);

      if (releaseQualityFirst) {
        resolveGate.release.complete();
        await reload;
        expect(player.playing, isFalse);
        await handler.releaseAfterScrub(
          scrubOwner!,
          resumeAfter: true,
          sourceGeneration: scrubSourceGeneration,
          userIntentGeneration: scrubUserIntentGeneration,
        );
      } else {
        await handler.releaseAfterScrub(
          scrubOwner!,
          resumeAfter: true,
          sourceGeneration: scrubSourceGeneration,
          userIntentGeneration: scrubUserIntentGeneration,
        );
        expect(player.playing, isFalse);
        resolveGate.release.complete();
        await reload;
      }

      expect(player.playing, isTrue);
    });
  }
}

MediaItem _item(String id) => MediaItem(
      id: id,
      title: id,
      extras: {
        'url': 'file:///tmp/$id-320k.mp3',
        'requestedQuality': '320k',
      },
    );

class _QualityAudioPlayer extends AudioPlayer {
  AudioSource? loadedSource;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration? _duration;
  int pauseCalls = 0;
  int playCalls = 0;
  int sourceLoadCalls = 0;
  final initialPositions = <Duration>[];
  _Gate? _sourceInstallGate;
  _Gate? _pauseGate;

  _Gate gateNextSourceInstall() {
    final gate = _Gate();
    _sourceInstallGate = gate;
    return gate;
  }

  _Gate gateNextPause() {
    final gate = _Gate();
    _pauseGate = gate;
    return gate;
  }

  void setEngineState({
    required Duration position,
    required Duration duration,
    required bool playing,
  }) {
    _position = position;
    _duration = duration;
    _playing = playing;
  }

  @override
  AudioSource? get audioSource => loadedSource;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => _duration;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sourceLoadCalls++;
    loadedSource = source;
    _position = initialPosition ?? Duration.zero;
    initialPositions.add(_position);
    final gate = source is SilenceAudioSource ? null : _sourceInstallGate;
    if (gate != null) {
      _sourceInstallGate = null;
      gate.started.complete();
      await gate.release.future;
    }
    return _duration;
  }

  @override
  Future<void> play() async {
    playCalls++;
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    _playing = false;
    final gate = _pauseGate;
    if (gate != null) {
      _pauseGate = null;
      gate.started.complete();
      await gate.release.future;
    }
  }

  @override
  Future<void> stop() async {
    _playing = false;
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
