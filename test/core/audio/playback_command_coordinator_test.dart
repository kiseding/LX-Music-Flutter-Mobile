import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/playback_command_coordinator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('awaited native mutations never overlap', () async {
    final player = _SerializedAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    final sourceGate = player.gateNextMutation();
    final request = coordinator.requestSource(
      mediaId: 'A',
      queueIndex: 0,
      position: Duration.zero,
    );

    final install = coordinator.commitSource(
      request,
      AudioSource.uri(Uri.parse('file:///tmp/A.mp3')),
    );
    await sourceGate.started.future;
    final seek = coordinator.seek(const Duration(seconds: 12));
    final pause = coordinator.explicitPause();

    expect(player.maxConcurrentMutations, 1);
    sourceGate.release.complete();
    await Future.wait([install, seek, pause]);

    expect(player.maxConcurrentMutations, 1);
  });

  test('loop and shuffle apply in coordinator order without overlap', () async {
    final player = _SerializedAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    final gate = player.gateNextMutation();

    final loop = coordinator.setLoopMode(LoopMode.off);
    await gate.started.future;
    final shuffle = coordinator.setShuffleModeEnabled(true);

    expect(player.calls, ['loop:off']);
    gate.release.complete();
    await Future.wait([loop, shuffle]);

    expect(player.calls, ['loop:off', 'shuffle:true']);
    expect(player.maxConcurrentMutations, 1);
  });

  test('stale same-source play lifecycle completion has no pause side effect',
      () async {
    final player = _SerializedAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    final request = coordinator.requestSource(
      mediaId: 'A',
      queueIndex: 0,
      position: Duration.zero,
    );
    await coordinator.commitSource(
      request,
      AudioSource.uri(Uri.parse('file:///tmp/A.mp3')),
    );
    final oldPlay = player.gateNextPlayLifecycle();

    await coordinator.explicitPlay();
    await oldPlay.started.future;
    await coordinator.explicitPause();
    await coordinator.explicitPlay();
    final pauses = player.pauseCalls;

    oldPlay.release.complete();
    await pumpEventQueue();

    expect(player.pauseCalls, pauses);
    expect(player.playing, isTrue);
  });

  test('preserving pause stays paused until preserving resume', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);

    await coordinator.explicitPlay();
    expect(player.playCalls, 1);

    await coordinator.pausePreservingIntent();
    await pumpEventQueue();

    expect(player.playing, isFalse);
    expect(player.playCalls, 1);

    await coordinator.resumePreservingIntent();

    expect(player.playing, isTrue);
    expect(player.playCalls, 2);
  });

  test('natural completion does not replay the current source', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.explicitPlay();

    player.completeNaturally();
    await pumpEventQueue();

    expect(player.processingState, ProcessingState.completed);
    expect(player.playCalls, 1);
  });

  test('stop lifecycle completion cannot restart playback', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.explicitPlay();

    await coordinator.stop();
    await pumpEventQueue();

    expect(player.processingState, ProcessingState.idle);
    expect(player.playing, isFalse);
    expect(player.playCalls, 1);
  });

  test('stale play error is side-effect free for newer desired play', () async {
    final player = _SerializedAudioPlayer();
    final errors = <String>[];
    final coordinator = PlaybackCommandCoordinator(
      player,
      onError: (operation, _, __) => errors.add(operation),
    );
    addTearDown(player.dispose);
    await _install(coordinator);
    final oldPlay = player.gateNextPlayLifecycle();
    await coordinator.explicitPlay();
    await oldPlay.started.future;

    await coordinator.explicitPause();
    await coordinator.explicitPlay();
    oldPlay.release.completeError(StateError('stale play'));
    await pumpEventQueue();

    expect(player.playing, isTrue);
    expect(errors, isEmpty);
  });

  test('failed seek is consumed before a later interruption pause', () async {
    final errors = <String>[];
    final player = _LifecycleAudioPlayer()..failNextSeek = true;
    final coordinator = PlaybackCommandCoordinator(
      player,
      onError: (operation, _, __) => errors.add(operation),
    );
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.explicitPlay();

    expect(await coordinator.seek(const Duration(seconds: 20)), isFalse);
    await coordinator.beginInterruption();
    await coordinator.settled;

    expect(player.seekCalls, 1);
    expect(errors, ['seek']);
    expect(player.playing, isFalse);
  });

  test('new explicit seek retries after a consumed seek failure', () async {
    final player = _LifecycleAudioPlayer()..failNextSeek = true;
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);

    expect(await coordinator.seek(const Duration(seconds: 20)), isFalse);
    expect(await coordinator.seek(const Duration(seconds: 30)), isTrue);

    expect(player.seekCalls, 2);
  });
}

Future<void> _install(PlaybackCommandCoordinator coordinator) async {
  final request = coordinator.requestSource(
    mediaId: 'A',
    queueIndex: 0,
    position: Duration.zero,
  );
  await coordinator.commitSource(
    request,
    AudioSource.uri(Uri.parse('file:///tmp/A.mp3')),
  );
}

class _SerializedAudioPlayer extends AudioPlayer {
  bool _playing = false;
  int _concurrentMutations = 0;
  int maxConcurrentMutations = 0;
  int pauseCalls = 0;
  final calls = <String>[];
  final _mutationGates = <_Gate>[];
  final _playGates = <_Gate>[];

  _Gate gateNextMutation() {
    final gate = _Gate();
    _mutationGates.add(gate);
    return gate;
  }

  _Gate gateNextPlayLifecycle() {
    final gate = _Gate();
    _playGates.add(gate);
    return gate;
  }

  Future<void> _mutate(String call, FutureOr<void> Function() mutation) async {
    calls.add(call);
    _concurrentMutations++;
    maxConcurrentMutations = maxConcurrentMutations < _concurrentMutations
        ? _concurrentMutations
        : maxConcurrentMutations;
    final gate = _mutationGates.isEmpty ? null : _mutationGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    await mutation();
    _concurrentMutations--;
  }

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
    await _mutate('source', () {});
    return null;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) => _mutate('seek', () {});

  @override
  Future<void> pause() => _mutate('pause', () {
        pauseCalls++;
        _playing = false;
      });

  @override
  Future<void> stop() => _mutate('stop', () => _playing = false);

  @override
  Future<void> setLoopMode(LoopMode mode) =>
      _mutate('loop:${mode.name}', () {});

  @override
  Future<void> setShuffleModeEnabled(bool enabled) =>
      _mutate('shuffle:$enabled', () {});

  @override
  Future<void> play() async {
    calls.add('play');
    _playing = true;
    final gate = _playGates.isEmpty ? null : _playGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}

class _LifecycleAudioPlayer extends AudioPlayer {
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.ready;
  Completer<void>? _playLifecycle;
  int playCalls = 0;
  int seekCalls = 0;
  bool failNextSeek = false;

  @override
  bool get playing => _playing;

  @override
  ProcessingState get processingState => _processingState;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _processingState = ProcessingState.ready;
    return null;
  }

  @override
  Future<void> play() {
    playCalls++;
    _playing = true;
    _processingState = ProcessingState.ready;
    _playLifecycle = Completer<void>();
    return _playLifecycle!.future;
  }

  @override
  Future<void> pause() async {
    _playing = false;
    _completePlayLifecycle();
  }

  @override
  Future<void> stop() async {
    _playing = false;
    _processingState = ProcessingState.idle;
    _completePlayLifecycle();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    seekCalls++;
    if (failNextSeek) {
      failNextSeek = false;
      throw StateError('seek');
    }
  }

  void completeNaturally() {
    _playing = false;
    _processingState = ProcessingState.completed;
    _completePlayLifecycle();
  }

  void _completePlayLifecycle() {
    final lifecycle = _playLifecycle;
    _playLifecycle = null;
    if (lifecycle != null && !lifecycle.isCompleted) lifecycle.complete();
  }
}
