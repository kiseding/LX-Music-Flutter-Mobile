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
      wasPlaying: false,
    );

    expect(paused.position, const Duration(seconds: 42));
    expect(paused.resumeAfterReload, isFalse);
  });

  test('quality reload clamps position to duration without compensation', () {
    final playing = qualityReloadIntent(
      position: const Duration(minutes: 4),
      duration: const Duration(minutes: 3),
      wasPlaying: true,
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
      playing: false,
    );
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

      expect(player.sourceLoadCalls, sourceLoads + 1);
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
    final gate = _sourceInstallGate;
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
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
