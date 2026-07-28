import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
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
  Duration? seekResult;
  Object? seekError;
  Object? pauseError;
  _Gate? seekGate;
  _Gate? pauseGate;
  int pauseCalls = 0;
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
  Future<void> pauseForScrub() async {
    pauseCalls++;
    final gate = pauseGate;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    if (pauseError != null) throw pauseError!;
    playing = false;
  }

  @override
  Future<void> resumeAfterScrub() async {
    resumeCalls++;
    playing = true;
  }

  @override
  Future<Duration?> seekConfirmed(Duration requested) async {
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
