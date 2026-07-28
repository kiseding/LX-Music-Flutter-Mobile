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

  _Gate gateNextSourceInstall() {
    final gate = _Gate();
    _sourceInstallGate = gate;
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
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
