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
    final pause = coordinator.recordExplicitPauseIntent();

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

    await coordinator.recordExplicitPlayIntent();
    await oldPlay.started.future;
    await coordinator.recordExplicitPauseIntent();
    await coordinator.recordExplicitPlayIntent();
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

    await coordinator.recordExplicitPlayIntent();
    expect(player.playCalls, 1);

    final owner = await coordinator.pausePreservingIntent();
    await pumpEventQueue();

    expect(player.playing, isFalse);
    expect(player.playCalls, 1);

    await coordinator.releasePreservingIntent(owner);

    expect(player.playing, isTrue);
    expect(player.playCalls, 2);
  });

  test('preserving desired state cannot clear non-resumable denial', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();
    await coordinator.beginInterruption();
    await coordinator.endInterruption(mayResume: false);

    await coordinator.setDesiredPlayingPreservingIntent(false);
    await coordinator.setDesiredPlayingPreservingIntent(true);

    expect(player.playing, isFalse);
    await coordinator.recordExplicitPlayIntent();
    expect(player.playing, isTrue);
  });

  for (final releaseFirst in ['first', 'second']) {
    test(
        'overlapping preserving owners block until $releaseFirst releases last',
        () async {
      final player = _LifecycleAudioPlayer();
      final coordinator = PlaybackCommandCoordinator(player);
      addTearDown(player.dispose);
      await _install(coordinator);
      await coordinator.recordExplicitPlayIntent();
      final first = await coordinator.pausePreservingIntent();
      final second = await coordinator.pausePreservingIntent();

      await coordinator.recordExplicitPlayIntent();
      await coordinator.releasePreservingIntent(
        releaseFirst == 'first' ? first : second,
      );
      expect(player.playing, isFalse);

      await coordinator.releasePreservingIntent(
        releaseFirst == 'first' ? second : first,
      );
      expect(player.playing, isTrue);
    });
  }

  test('explicit pause remains denied after preserving owner release',
      () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();
    final first = await coordinator.pausePreservingIntent();
    final second = await coordinator.pausePreservingIntent();

    await coordinator.recordExplicitPauseIntent();
    await coordinator.releasePreservingIntent(first);
    await coordinator.releasePreservingIntent(second);

    expect(player.playing, isFalse);
  });

  test('stop remains denied after preserving owner release', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();
    final first = await coordinator.pausePreservingIntent();
    final second = await coordinator.pausePreservingIntent();

    await coordinator.stop();
    await coordinator.releasePreservingIntent(first);
    await coordinator.releasePreservingIntent(second);

    expect(player.playing, isFalse);
    expect(player.processingState, ProcessingState.idle);
  });

  test('natural completion does not replay the current source', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();

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
    await coordinator.recordExplicitPlayIntent();

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
    await coordinator.recordExplicitPlayIntent();
    await oldPlay.started.future;

    await coordinator.recordExplicitPauseIntent();
    await coordinator.recordExplicitPlayIntent();
    oldPlay.release.completeError(StateError('stale play'));
    await pumpEventQueue();

    expect(player.playing, isTrue);
    expect(errors, isEmpty);
  });

  test('superseded source play error is inert before replacement commit',
      () async {
    final player = _LifecycleAudioPlayer();
    final errors = <String>[];
    var publications = 0;
    final coordinator = PlaybackCommandCoordinator(
      player,
      onError: (operation, _, __) => errors.add(operation),
      onStateChanged: () => publications++,
    );
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();
    coordinator.requestSource(
      mediaId: 'B',
      queueIndex: 1,
      position: Duration.zero,
    );
    await coordinator.settled;
    final calls = player.calls.toList();
    final publicationsBeforeError = publications;

    player.failCurrentPlay();
    await pumpEventQueue();

    expect(errors, isEmpty);
    expect(publications, publicationsBeforeError);
    expect(player.calls, calls);
  });

  test('superseded source play completion is inert before replacement commit',
      () async {
    final player = _LifecycleAudioPlayer();
    var publications = 0;
    final coordinator = PlaybackCommandCoordinator(
      player,
      onStateChanged: () => publications++,
    );
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();
    coordinator.requestSource(
      mediaId: 'B',
      queueIndex: 1,
      position: Duration.zero,
    );
    await coordinator.settled;
    final calls = player.calls.toList();
    final publicationsBeforeCompletion = publications;

    player.completeCurrentPlay();
    await pumpEventQueue();

    expect(publications, publicationsBeforeCompletion);
    expect(player.calls, calls);
  });

  test('current source play error still reports once', () async {
    final player = _LifecycleAudioPlayer();
    final errors = <String>[];
    final coordinator = PlaybackCommandCoordinator(
      player,
      onError: (operation, _, __) => errors.add(operation),
    );
    addTearDown(player.dispose);
    await _install(coordinator);
    await coordinator.recordExplicitPlayIntent();

    player.failCurrentPlay();
    await pumpEventQueue();

    expect(errors, ['play']);
  });

  test('source commit reports installed and stale outcomes', () async {
    final player = _LifecycleAudioPlayer();
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    final stale = coordinator.requestSource(
      mediaId: 'A',
      queueIndex: 0,
      position: Duration.zero,
    );
    final current = coordinator.requestSource(
      mediaId: 'B',
      queueIndex: 1,
      position: Duration.zero,
    );

    expect(
      await coordinator.commitSource(
        stale,
        AudioSource.uri(Uri.parse('file:///tmp/A.mp3')),
      ),
      isA<SourceCommitStale>(),
    );
    expect(
      await coordinator.commitSource(
        current,
        AudioSource.uri(Uri.parse('file:///tmp/B.mp3')),
      ),
      isA<SourceCommitInstalled>(),
    );
  });

  test('authoritative source commit returns its install error', () async {
    final error = StateError('source install');
    final player = _LifecycleAudioPlayer()..sourceInstallError = error;
    final coordinator = PlaybackCommandCoordinator(player);
    addTearDown(player.dispose);
    final request = coordinator.requestSource(
      mediaId: 'A',
      queueIndex: 0,
      position: Duration.zero,
    );

    final result = await coordinator.commitSource(
      request,
      AudioSource.uri(Uri.parse('file:///tmp/A.mp3')),
    );

    expect(result, isA<SourceCommitFailed>());
    expect((result as SourceCommitFailed).error, same(error));
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
    await coordinator.recordExplicitPlayIntent();

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
  Object? sourceInstallError;
  final calls = <String>[];

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
    calls.add('source');
    final error = sourceInstallError;
    if (error != null) throw error;
    _processingState = ProcessingState.ready;
    return null;
  }

  @override
  Future<void> play() {
    calls.add('play');
    playCalls++;
    _playing = true;
    _processingState = ProcessingState.ready;
    _playLifecycle = Completer<void>();
    return _playLifecycle!.future;
  }

  @override
  Future<void> pause() async {
    calls.add('pause');
    _playing = false;
    _completePlayLifecycle();
  }

  @override
  Future<void> stop() async {
    calls.add('stop');
    _playing = false;
    _processingState = ProcessingState.idle;
    _completePlayLifecycle();
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    calls.add('seek');
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

  void completeCurrentPlay() => _completePlayLifecycle();

  void failCurrentPlay() {
    final lifecycle = _playLifecycle;
    _playLifecycle = null;
    if (lifecycle != null && !lifecycle.isCompleted) {
      lifecycle.completeError(StateError('play'));
    }
  }

  void _completePlayLifecycle() {
    final lifecycle = _playLifecycle;
    _playLifecycle = null;
    if (lifecycle != null && !lifecycle.isCompleted) lifecycle.complete();
  }
}
