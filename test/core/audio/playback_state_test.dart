import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

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
}

class _PlaybackStateAudioPlayer extends AudioPlayer {
  final _events = StreamController<PlaybackEvent>.broadcast();
  final _processingStates = StreamController<ProcessingState>.broadcast();
  PlaybackEvent _event = PlaybackEvent();
  bool _playing = false;
  double _speed = 1.0;
  bool _shuffleModeEnabled = false;
  int pauseCalls = 0;
  int playCalls = 0;
  int sourceLoadCalls = 0;
  ProcessingState? sourceInstallProcessingState;
  bool failNextSourceInstall = false;
  final _playFailureGates = <_PlayFailureGate>[];

  _PlayFailureGate gateNextPlayFailure() {
    final gate = _PlayFailureGate();
    _playFailureGates.add(gate);
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
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  ProcessingState get processingState => _event.processingState;

  @override
  Stream<ProcessingState> get processingStateStream => _processingStates.stream;

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
    _playing = false;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _processingStates.close();
    await super.dispose();
  }
}

class _PlayFailureGate {
  final started = Completer<void>();
  final release = Completer<void>();
}
