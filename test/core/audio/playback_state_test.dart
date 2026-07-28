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
}

class _PlaybackStateAudioPlayer extends AudioPlayer {
  final _events = StreamController<PlaybackEvent>.broadcast();
  final _processingStates = StreamController<ProcessingState>.broadcast();
  PlaybackEvent _event = PlaybackEvent();
  bool _playing = false;
  double _speed = 1.0;
  bool _shuffleModeEnabled = false;
  int pauseCalls = 0;

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
  }) async =>
      null;

  @override
  Future<void> play() async {
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
