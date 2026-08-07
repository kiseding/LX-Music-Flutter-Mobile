import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_command_coordinator.dart';
import 'package:lx_music_flutter/features/player/presentation/fire_and_forget_observer.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loading seek unfreezes to current engine position without resuming',
      () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 17),
      seekResult: null,
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    await coordinator.finish(
      generation,
      const Duration(minutes: 2),
      resumeAfter: true,
    );

    expect(position.unfreezes, [const Duration(seconds: 17)]);
    expect(playback.resumeCalls, 0);
  });

  test('idle seek unfreezes paused scrub to current engine position', () async {
    final playback = _FakeScrubPlayback(
      playing: false,
      position: const Duration(seconds: 9),
      seekResult: null,
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    await coordinator.finish(
      generation,
      const Duration(seconds: 40),
      resumeAfter: false,
    );

    expect(playback.pauseCalls, 0);
    expect(playback.resumeCalls, 0);
    expect(position.unfreezes, [const Duration(seconds: 9)]);
  });

  test('thrown seek still unfreezes owning scrub to actual position', () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 23),
      seekError: StateError('seek failed'),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    await expectLater(
      coordinator.finish(
        generation,
        const Duration(minutes: 1),
        resumeAfter: true,
      ),
      throwsStateError,
    );

    expect(position.unfreezes, [const Duration(seconds: 23)]);
    expect(playback.resumeCalls, 0);
  });

  test('thrown scrub pause still unfreezes owning transaction', () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 6),
      pauseError: StateError('pause failed'),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    await expectLater(coordinator.begin(), throwsStateError);

    expect(position.unfreezes, [const Duration(seconds: 6)]);
  });

  test('older overlapping scrub cannot unfreeze newer transaction', () async {
    final firstSeek = _Gate();
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 12),
      seekResult: const Duration(seconds: 40),
      seekGate: firstSeek,
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final firstGeneration = await coordinator.begin();
    final firstFinish = coordinator.finish(
      firstGeneration,
      const Duration(seconds: 40),
      resumeAfter: true,
    );
    await firstSeek.started.future;
    final secondGeneration = await coordinator.begin();
    playback
      ..seekGate = null
      ..seekResult = const Duration(seconds: 55);
    firstSeek.release.complete();
    await firstFinish;
    expect(position.unfreezes, isEmpty);

    await coordinator.finish(
      secondGeneration,
      const Duration(seconds: 55),
      resumeAfter: false,
    );

    expect(position.unfreezes, [const Duration(seconds: 55)]);
  });

  test('older finish does not wait for newer scrub pause transaction',
      () async {
    final secondPause = _Gate();
    final playback = _FakeScrubPlayback(
      playing: false,
      position: const Duration(seconds: 12),
      seekResult: const Duration(seconds: 40),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final firstGeneration = await coordinator.begin();
    playback
      ..playing = true
      ..pauseGate = secondPause;
    final secondBegin = coordinator.begin();
    await secondPause.started.future;

    final firstFinish = coordinator.finish(
      firstGeneration,
      const Duration(seconds: 40),
      resumeAfter: false,
    );
    var firstFinished = false;
    firstFinish.whenComplete(() => firstFinished = true);
    await pumpEventQueue();

    expect(firstFinished, isTrue);
    expect(position.unfreezes, isEmpty);
    secondPause.release.complete();
    await secondBegin;
  });

  test('source change during seek unfreezes actual new-source position',
      () async {
    final seekGate = _Gate();
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 10),
      seekResult: null,
      seekGate: seekGate,
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    final finish = coordinator.finish(
      generation,
      const Duration(seconds: 40),
      resumeAfter: true,
    );
    await seekGate.started.future;
    playback.sourceGeneration++;
    playback.position = const Duration(seconds: 3);
    seekGate.release.complete();
    await finish;

    expect(position.unfreezes, [const Duration(seconds: 3)]);
    expect(playback.resumeCalls, 0);
  });

  test('source change between begin and finish prevents seek and resume',
      () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 10),
      seekResult: const Duration(seconds: 40),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    playback.sourceGeneration++;
    playback.position = const Duration(seconds: 3);
    await coordinator.finish(
      generation,
      const Duration(seconds: 40),
      resumeAfter: true,
    );

    expect(playback.seekCalls, 0);
    expect(playback.resumeCalls, 0);
    expect(position.unfreezes, [const Duration(seconds: 3)]);
  });

  for (final action in <({String name, void Function(_FakeScrubPlayback) run})>[
    (name: 'pause', run: (playback) => playback.userPause()),
    (name: 'play', run: (playback) => playback.userPlay()),
  ]) {
    test('explicit ${action.name} between begin and finish prevents seek',
        () async {
      final playback = _FakeScrubPlayback(
        playing: true,
        position: const Duration(seconds: 10),
        seekResult: const Duration(seconds: 40),
      );
      final position = _FakeScrubPosition();
      final coordinator = ScrubCoordinator(playback, position);

      final generation = await coordinator.begin();
      action.run(playback);
      await coordinator.finish(
        generation,
        const Duration(seconds: 40),
        resumeAfter: true,
      );

      expect(playback.seekCalls, 0);
      expect(playback.resumeCalls, 0);
      expect(position.unfreezes, [const Duration(seconds: 10)]);
      expect(playback.playing, action.name == 'play');
    });
  }

  for (final change in <({String name, void Function(_FakeScrubPlayback) run})>[
    (
      name: 'source',
      run: (playback) {
        playback.sourceGeneration++;
        playback.position = const Duration(seconds: 3);
      },
    ),
    (name: 'intent', run: (playback) => playback.userPause()),
  ]) {
    test('${change.name} change while begin pause is gated prevents seek',
        () async {
      final pauseGate = _Gate();
      final playback = _FakeScrubPlayback(
        playing: true,
        position: const Duration(seconds: 10),
        seekResult: const Duration(seconds: 40),
      )..pauseGate = pauseGate;
      final position = _FakeScrubPosition();
      final coordinator = ScrubCoordinator(playback, position);

      final begin = coordinator.begin();
      await pauseGate.started.future;
      change.run(playback);
      pauseGate.release.complete();
      final generation = await begin;
      await coordinator.finish(
        generation,
        const Duration(seconds: 40),
        resumeAfter: true,
      );

      expect(playback.seekCalls, 0);
      expect(playback.resumeCalls, 0);
      expect(position.unfreezes, [playback.position]);
    });
  }

  for (final action in <({String name, void Function(_FakeScrubPlayback) run})>[
    (name: 'pause', run: (playback) => playback.userPause()),
    (name: 'play', run: (playback) => playback.userPlay()),
  ]) {
    test('newer user ${action.name} during seek suppresses scrub resume',
        () async {
      final seekGate = _Gate();
      final playback = _FakeScrubPlayback(
        playing: true,
        position: const Duration(seconds: 10),
        seekResult: const Duration(seconds: 40),
        seekGate: seekGate,
      );
      final position = _FakeScrubPosition();
      final coordinator = ScrubCoordinator(playback, position);

      final generation = await coordinator.begin();
      final finish = coordinator.finish(
        generation,
        const Duration(seconds: 40),
        resumeAfter: true,
      );
      await seekGate.started.future;
      action.run(playback);
      seekGate.release.complete();
      await finish;

      expect(position.unfreezes, [const Duration(seconds: 40)]);
      expect(playback.resumeCalls, 0);
      expect(playback.playing, action.name == 'play');
    });
  }

  test('paused successful scrub publishes confirmation without resuming',
      () async {
    final playback = _FakeScrubPlayback(
      playing: false,
      position: const Duration(seconds: 8),
      seekResult: const Duration(seconds: 44),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    await coordinator.finish(
      generation,
      const Duration(seconds: 45),
      resumeAfter: false,
    );

    expect(position.unfreezes, [const Duration(seconds: 44)]);
    expect(playback.pauseCalls, 0);
    expect(playback.resumeCalls, 0);
  });

  test('confirmed seek resumes when source and user ownership are unchanged',
      () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 8),
      seekResult: const Duration(seconds: 44),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final generation = await coordinator.begin();
    await coordinator.finish(
      generation,
      const Duration(seconds: 45),
      resumeAfter: true,
    );

    expect(position.unfreezes, [const Duration(seconds: 44)]);
    expect(playback.pauseCalls, 1);
    expect(playback.resumeCalls, 1);
  });

  test('cancel releases preserving pause once without seeking', () async {
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 18),
      seekResult: const Duration(seconds: 50),
    );
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);
    final generation = await coordinator.begin();

    await coordinator.cancel(generation);
    await coordinator.cancel(generation);

    expect(playback.seekCalls, 0);
    expect(playback.releaseCalls, 1);
    expect(playback.resumeCalls, 1);
    expect(position.unfreezes, [const Duration(seconds: 18)]);
  });

  test('cancel invalidates generation before owner release completes',
      () async {
    final releaseGate = _Gate();
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 18),
      seekResult: const Duration(seconds: 50),
    )..releaseGate = releaseGate;
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);
    final generation = await coordinator.begin();

    final cancellation = coordinator.cancel(generation);
    await releaseGate.started.future;
    final finish = coordinator.finish(
      generation,
      const Duration(seconds: 50),
      resumeAfter: true,
    );
    await pumpEventQueue();

    expect(playback.seekCalls, 0);
    releaseGate.release.complete();
    await Future.wait([cancellation, finish]);
    expect(playback.releaseCalls, 1);
  });

  test('cancelAll releases a pending pause after disposal', () async {
    final pauseGate = _Gate();
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 7),
    )..pauseGate = pauseGate;
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(playback, position);

    final begin = coordinator.begin();
    await pauseGate.started.future;
    final cancellation = coordinator.cancelAll();
    pauseGate.release.complete();
    await Future.wait([begin, cancellation]);

    expect(playback.seekCalls, 0);
    expect(playback.releaseCalls, 1);
    expect(position.unfreezes, [const Duration(seconds: 7)]);
  });

  test('cancelAll pause failure is observed once without escaping', () async {
    final pauseError = StateError('pause failed');
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 7),
      pauseError: pauseError,
    );
    final coordinator = ScrubCoordinator(playback, _FakeScrubPosition());
    final reported = Completer<Object>();
    var reportCalls = 0;
    final observer = FireAndForgetObserver(
      onError: (error, stackTrace) {
        reportCalls++;
        if (!reported.isCompleted) reported.complete(error);
      },
    );

    final begin = coordinator.begin();
    observer(coordinator.cancelAll());

    await expectLater(begin, throwsA(same(pauseError)));
    expect(await reported.future, same(pauseError));
    await pumpEventQueue();
    expect(reportCalls, 1);
  });

  test('cancelAll release failure is observed once without escaping', () async {
    final releaseError = StateError('release failed');
    final playback = _FakeScrubPlayback(
      playing: true,
      position: const Duration(seconds: 7),
    )..releaseError = releaseError;
    final coordinator = ScrubCoordinator(playback, _FakeScrubPosition());
    final reported = Completer<Object>();
    var reportCalls = 0;
    final observer = FireAndForgetObserver(
      onError: (error, stackTrace) {
        reportCalls++;
        if (!reported.isCompleted) reported.complete(error);
      },
    );

    await coordinator.begin();
    observer(coordinator.cancelAll());

    expect(await reported.future, same(releaseError));
    await pumpEventQueue();
    expect(reportCalls, 1);
  });

  test('newer scrub resume survives older preserving pause completion',
      () async {
    final oldPauseGate = _Gate();
    final player = _CoordinatorAudioPlayer(oldPauseGate);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([
      const MediaItem(
        id: 'A',
        title: 'A',
        extras: {
          'url': 'file:///tmp/A.mp3',
          'requestedQuality': '320k',
        },
      )
    ]);
    await pumpEventQueue();
    final position = _FakeScrubPosition();
    final coordinator = ScrubCoordinator(
      _RealHandlerScrubPlayback(handler),
      position,
    );

    final oldBegin = coordinator.begin();
    await oldPauseGate.started.future;
    final newerBegin = coordinator.begin();
    oldPauseGate.release.complete();
    final newerGeneration = await newerBegin;
    await coordinator.finish(
      newerGeneration,
      const Duration(seconds: 30),
      resumeAfter: true,
    );
    await oldBegin;

    expect(player.playing, isTrue);
  });

  test('second begin releases fully acquired first owner exactly once',
      () async {
    final player = _CoordinatorAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([
      const MediaItem(
        id: 'A',
        title: 'A',
        extras: {
          'url': 'file:///tmp/A.mp3',
          'requestedQuality': '320k',
        },
      )
    ]);
    await pumpEventQueue();
    final coordinator = ScrubCoordinator(
      _RealHandlerScrubPlayback(handler),
      _FakeScrubPosition(),
    );

    final firstGeneration = await coordinator.begin();
    final secondGeneration = await coordinator.begin();
    await coordinator.finish(
      firstGeneration,
      const Duration(seconds: 10),
      resumeAfter: true,
    );
    await coordinator.finish(
      secondGeneration,
      const Duration(seconds: 20),
      resumeAfter: false,
    );
    await handler.play();

    expect(player.playing, isTrue);
  });

  test('multiple rapid begins release superseded pending owners', () async {
    final player = _CoordinatorAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([
      const MediaItem(
        id: 'A',
        title: 'A',
        extras: {
          'url': 'file:///tmp/A.mp3',
          'requestedQuality': '320k',
        },
      )
    ]);
    await pumpEventQueue();
    final coordinator = ScrubCoordinator(
      _RealHandlerScrubPlayback(handler),
      _FakeScrubPosition(),
    );

    final firstGeneration = await coordinator.begin();
    final secondPauseGate = _Gate();
    player
      ..setPlayingState(true)
      ..nextPauseGate = secondPauseGate;
    final secondBegin = coordinator.begin();
    await secondPauseGate.started.future;
    final thirdBegin = coordinator.begin();
    secondPauseGate.release.complete();
    final laterGenerations = await Future.wait([
      secondBegin,
      thirdBegin,
    ]);
    await coordinator.finish(
      firstGeneration,
      const Duration(seconds: 10),
      resumeAfter: true,
    );
    await coordinator.finish(
      laterGenerations[0],
      const Duration(seconds: 20),
      resumeAfter: true,
    );
    await coordinator.finish(
      laterGenerations[1],
      const Duration(seconds: 30),
      resumeAfter: false,
    );
    await handler.play();

    expect(player.playing, isTrue);
  });
}

class _FakeScrubPlayback implements ScrubPlayback {
  @override
  bool playing;
  @override
  Duration position;
  @override
  int sourceGeneration = 1;
  @override
  int userIntentGeneration = 1;
  @override
  int interruptionGeneration = 0;
  @override
  int playbackStartBlockGeneration = 0;
  Duration? seekResult;
  Object? seekError;
  Object? pauseError;
  Object? releaseError;
  _Gate? seekGate;
  _Gate? pauseGate;
  _Gate? releaseGate;
  int pauseCalls = 0;
  int seekCalls = 0;
  int releaseCalls = 0;
  int resumeCalls = 0;

  _FakeScrubPlayback({
    required this.playing,
    required this.position,
    this.seekResult,
    this.seekError,
    this.pauseError,
    this.seekGate,
  });

  void userPause() {
    userIntentGeneration++;
    playing = false;
  }

  void userPlay() {
    userIntentGeneration++;
    playing = true;
  }

  @override
  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) async {
    pauseCalls++;
    final gate = pauseGate;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    if (pauseError != null) throw pauseError!;
    playing = false;
    return null;
  }

  @override
  Future<void> releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    required int interruptionGeneration,
    required int startBlockGeneration,
  }) async {
    releaseCalls++;
    final gate = releaseGate;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    if (releaseError != null) throw releaseError!;
    if (resumeAfter) {
      resumeCalls++;
      playing = true;
    }
  }

  @override
  Future<Duration?> seekConfirmed(Duration requested) async {
    seekCalls++;
    final gate = seekGate;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    if (seekError != null) throw seekError!;
    if (seekResult != null) position = seekResult!;
    return seekResult;
  }
}

class _FakeScrubPosition implements ScrubPosition {
  int freezeCalls = 0;
  final unfreezes = <Duration>[];

  @override
  void freeze() => freezeCalls++;

  @override
  void unfreeze(Duration position) => unfreezes.add(position);
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}

class _RealHandlerScrubPlayback implements ScrubPlayback {
  final LxAudioHandler handler;

  _RealHandlerScrubPlayback(this.handler);

  @override
  bool get playing => handler.player.playing;

  @override
  Duration get position => handler.player.position;

  @override
  int get sourceGeneration => handler.sourceGeneration;

  @override
  int get userIntentGeneration => handler.userIntentGeneration;

  @override
  int get interruptionGeneration => handler.interruptionGeneration;

  @override
  int get playbackStartBlockGeneration => handler.playbackStartBlockGeneration;

  @override
  Future<PreservingPauseOwner?> pauseForScrub({
    required int sourceGeneration,
    required int userIntentGeneration,
    required bool Function() stillOwnsScrub,
  }) =>
      handler.pauseForScrub(
        sourceGeneration: sourceGeneration,
        userIntentGeneration: userIntentGeneration,
        stillOwnsScrub: stillOwnsScrub,
      );

  @override
  Future<Duration?> seekConfirmed(Duration position) =>
      handler.seekConfirmed(position);

  @override
  Future<void> releaseAfterScrub(
    PreservingPauseOwner? owner, {
    required bool resumeAfter,
    required int sourceGeneration,
    required int userIntentGeneration,
    required int interruptionGeneration,
    required int startBlockGeneration,
  }) =>
      handler.releaseAfterScrub(
        owner,
        resumeAfter: resumeAfter,
        sourceGeneration: sourceGeneration,
        userIntentGeneration: userIntentGeneration,
        interruptionGeneration: interruptionGeneration,
        startBlockGeneration: startBlockGeneration,
      );
}

class _CoordinatorAudioPlayer extends AudioPlayer {
  _Gate? nextPauseGate;
  bool _playing = false;
  Duration _position = Duration.zero;
  AudioSource? _source;

  _CoordinatorAudioPlayer([this.nextPauseGate]);

  void setPlayingState(bool playing) => _playing = playing;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  @override
  Duration? get duration => const Duration(minutes: 3);

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  AudioSource? get audioSource => _source;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _source = source;
    _position = initialPosition ?? Duration.zero;
    return duration;
  }

  @override
  Future<void> play() async => _playing = true;

  @override
  Future<void> pause() async {
    final gate = nextPauseGate;
    nextPauseGate = null;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = false;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position != null) _position = position;
  }

  @override
  Future<void> stop() async => _playing = false;
}
