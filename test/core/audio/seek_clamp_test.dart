import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('local progressive sources request precise darwin timing for flac seek',
      () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, contains('ProgressiveAudioSource('));
    expect(handler, contains('preferPreciseDurationAndTiming: true'));
    expect(handler, contains('DarwinAssetOptions'));
  });

  test('seek path has no settle polling or timing compensation', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, isNot(contains('waitForSettledPosition')));
    expect(handler, isNot(contains('hardSeekTo')));
    expect(handler, isNot(contains('seekToDisplay')));
    expect(handler, isNot(contains('seekBudgetForQuality')));
  });

  test('play starts asynchronously instead of waiting for playback to end', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    final play = handler.substring(
      handler.indexOf('Future<void> play() async'),
      handler.indexOf('/// 供测试：模拟当前曲播放完成'),
    );
    expect(play, contains('_commands.explicitPlay()'));
    expect(play, isNot(contains('await _player.play()')));
  });

  test('progress UI holds local preview until scrub finish returns', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    final fullEnd = full.substring(full.indexOf('onHorizontalDragEnd:'));
    final miniEnd = mini.substring(mini.indexOf('onHorizontalDragEnd:'));
    expect(
      fullEnd.indexOf('finishScrubProvider'),
      lessThan(fullEnd.indexOf('_seeking = false')),
    );
    expect(
      miniEnd.indexOf('finishScrubProvider'),
      lessThan(miniEnd.indexOf('_seeking = false')),
    );
  });

  test('completion uses only the native completed processing state', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('state != ProcessingState.completed'));
    expect(source, isNot(contains('skipToNext(seamless: true)')));
    expect(
      source,
      isNot(contains('pos >= dur - const Duration(milliseconds: 80)')),
    );
  });

  test('confirmed seek returns and publishes actual clamped engine position',
      () async {
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      engineDuration: const Duration(minutes: 3),
      confirmedPosition: const Duration(minutes: 2, seconds: 59),
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);

    final confirmed = await handler.seekConfirmed(const Duration(minutes: 4));

    expect(player.requestedPositions, [
      const Duration(minutes: 2, seconds: 59, milliseconds: 920),
    ]);
    expect(confirmed, const Duration(minutes: 2, seconds: 59));
    expect(
      handler.playbackState.value.updatePosition,
      const Duration(minutes: 2, seconds: 59),
    );
  });

  for (final confirmation in <({
    String name,
    Duration enginePosition,
    Duration expected,
  })>[
    (
      name: 'negative',
      enginePosition: const Duration(seconds: -4),
      expected: Duration.zero,
    ),
    (
      name: 'beyond duration',
      enginePosition: const Duration(minutes: 4),
      expected: const Duration(minutes: 3),
    ),
  ]) {
    test('${confirmation.name} engine confirmation publishes clamped position',
        () async {
      final player = _SeekAudioPlayer(
        processingState: ProcessingState.ready,
        engineDuration: const Duration(minutes: 3),
        confirmedPosition: confirmation.enginePosition,
      );
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);

      final confirmed = await handler.seekConfirmed(const Duration(minutes: 2));

      expect(confirmed, confirmation.expected);
      expect(handler.playbackState.value.updatePosition, confirmed);
    });
  }

  test('loading seek failure returns null without publishing target', () async {
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.loading,
      engineDuration: const Duration(minutes: 3),
      position: const Duration(seconds: 17),
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);

    final confirmed = await handler.seekConfirmed(const Duration(minutes: 2));

    expect(confirmed, isNull);
    expect(player.requestedPositions, isEmpty);
    expect(handler.playbackState.value.updatePosition,
        isNot(const Duration(minutes: 2)));
  });

  test('native seek failure returns null and publishes actual engine state',
      () async {
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      engineDuration: const Duration(minutes: 3),
      position: const Duration(seconds: 17),
      failedSeekPosition: const Duration(seconds: 19),
      seekError: StateError('native seek failed'),
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);

    final confirmed = await handler.seekConfirmed(const Duration(minutes: 2));

    expect(confirmed, isNull);
    expect(handler.playbackState.value.updatePosition,
        const Duration(seconds: 19));
  });

  for (final failure in ['null', 'throw', 'stale']) {
    test('real scrub $failure seek stays paused until later explicit play',
        () async {
      final seekGate = failure == 'stale' ? _Gate() : null;
      final player = _SeekAudioPlayer(
        processingState:
            failure == 'null' ? ProcessingState.loading : ProcessingState.ready,
        engineDuration: const Duration(minutes: 3),
        seekError: failure == 'throw' ? StateError('native seek failed') : null,
        seekGate: seekGate,
      );
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      await handler.setPlaylist([_item('A'), _item('B')]);
      final sourceGeneration = handler.sourceGeneration;
      final userIntentGeneration = handler.userIntentGeneration;
      final owner = await handler.pauseForScrub(
        sourceGeneration: sourceGeneration,
        userIntentGeneration: userIntentGeneration,
        stillOwnsScrub: () => true,
      );
      if (failure == 'null') {
        player.engineProcessingState = ProcessingState.loading;
      }

      final seek = handler.seekConfirmed(const Duration(seconds: 40));
      if (seekGate != null) {
        await seekGate.started.future;
        final selection = handler.skipToQueueItem(1);
        seekGate.release.complete();
        await selection;
      }
      expect(await seek, isNull);
      await handler.releaseAfterScrub(owner, resumeAfter: false);

      expect(player.playing, isFalse);
      await handler.play();
      expect(player.playing, isTrue);
    });
  }

  test('real confirmed scrub release reconciles playback', () async {
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      engineDuration: const Duration(minutes: 3),
      confirmedPosition: const Duration(seconds: 40),
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final owner = await handler.pauseForScrub(
      sourceGeneration: handler.sourceGeneration,
      userIntentGeneration: handler.userIntentGeneration,
      stillOwnsScrub: () => true,
    );

    expect(
      await handler.seekConfirmed(const Duration(seconds: 40)),
      const Duration(seconds: 40),
    );
    await handler.releaseAfterScrub(owner, resumeAfter: true);

    expect(player.playing, isTrue);
  });

  test('newer source generation wins while seek is in flight', () async {
    final seekGate = _Gate();
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      engineDuration: const Duration(minutes: 3),
      seekGate: seekGate,
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);

    final staleSeek = handler.seekConfirmed(const Duration(seconds: 40));
    await seekGate.started.future;
    final newerSelection = handler.skipToQueueItem(1);
    seekGate.release.complete();

    expect(await staleSeek, isNull);
    await newerSelection;
    expect(handler.mediaItem.value?.id, 'B');
    expect((player.audioSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.position, Duration.zero);
  });

  test('stale native seek failure cannot publish over newer source', () async {
    final seekGate = _Gate();
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      engineDuration: const Duration(minutes: 3),
      failedSeekPosition: const Duration(seconds: 19),
      seekError: StateError('native seek failed'),
      seekGate: seekGate,
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);

    final staleSeek = handler.seekConfirmed(const Duration(seconds: 40));
    await seekGate.started.future;
    final newerSelection = handler.skipToQueueItem(1);
    seekGate.release.complete();

    expect(await staleSeek, isNull);
    expect(handler.playbackState.value.updatePosition,
        isNot(const Duration(seconds: 19)));
    await newerSelection;
    expect(handler.mediaItem.value?.id, 'B');
    expect(handler.playbackState.value.updatePosition, Duration.zero);
  });

  test('explicit play during stale scrub pause is restored', () async {
    final pauseGate = _Gate();
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      pauseGate: pauseGate,
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    final sourceGeneration = handler.sourceGeneration;
    final userIntentGeneration = handler.userIntentGeneration;

    final scrubPause = handler.pauseForScrub(
      sourceGeneration: sourceGeneration,
      userIntentGeneration: userIntentGeneration,
      stillOwnsScrub: () => true,
    );
    await pauseGate.started.future;
    await handler.play();
    pauseGate.release.complete();
    await scrubPause;

    expect(player.playing, isTrue);
  });

  test('newer source selection survives stale scrub pause', () async {
    final pauseGate = _Gate();
    final player = _SeekAudioPlayer(
      processingState: ProcessingState.ready,
      pauseGate: pauseGate,
    );
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await pumpEventQueue();

    final scrubPause = handler.pauseForScrub(
      sourceGeneration: handler.sourceGeneration,
      userIntentGeneration: handler.userIntentGeneration,
      stillOwnsScrub: () => true,
    );
    await pauseGate.started.future;
    final selection = handler.skipToQueueItem(1);
    pauseGate.release.complete();
    await selection;
    await scrubPause;

    expect(handler.mediaItem.value?.id, 'B');
    expect((player.audioSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.playing, isTrue);
  });

  for (final action
      in <({String name, Future<void> Function(LxAudioHandler) run})>[
    (name: 'pause', run: (handler) => handler.pause()),
    (name: 'stop', run: (handler) => handler.stop()),
  ]) {
    test('newer explicit ${action.name} is not revived by stale scrub pause',
        () async {
      final pauseGate = _Gate();
      final player = _SeekAudioPlayer(
        processingState: ProcessingState.ready,
        pauseGate: pauseGate,
      );
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      await handler.setPlaylist([_item('A')]);
      await pumpEventQueue();

      final scrubPause = handler.pauseForScrub(
        sourceGeneration: handler.sourceGeneration,
        userIntentGeneration: handler.userIntentGeneration,
        stillOwnsScrub: () => true,
      );
      await pauseGate.started.future;
      await action.run(handler);
      pauseGate.release.complete();
      await scrubPause;

      expect(player.playing, isFalse);
    });
  }
}

MediaItem _item(String id) => MediaItem(
      id: id,
      title: id,
      extras: {
        'url': 'file:///tmp/$id.mp3',
        'requestedQuality': '320k',
      },
    );

class _SeekAudioPlayer extends AudioPlayer {
  ProcessingState engineProcessingState;
  Duration? engineDuration;
  Duration enginePosition;
  final Duration? confirmedPosition;
  final Duration? failedSeekPosition;
  final Object? seekError;
  final _Gate? seekGate;
  _Gate? pauseGate;
  final requestedPositions = <Duration>[];
  AudioSource? loadedSource;
  bool _playing = false;

  _SeekAudioPlayer({
    required ProcessingState processingState,
    this.engineDuration,
    Duration position = Duration.zero,
    this.confirmedPosition,
    this.failedSeekPosition,
    this.seekError,
    this.seekGate,
    this.pauseGate,
  })  : engineProcessingState = processingState,
        enginePosition = position;

  @override
  ProcessingState get processingState => engineProcessingState;

  @override
  Duration? get duration => engineDuration;

  @override
  Duration get position => enginePosition;

  @override
  bool get playing => _playing;

  @override
  AudioSource? get audioSource => loadedSource;

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    if (position == null) return;
    requestedPositions.add(position);
    final gate = seekGate;
    if (gate != null && !gate.started.isCompleted) {
      gate.started.complete();
      await gate.release.future;
    }
    if (seekError != null) {
      enginePosition = failedSeekPosition ?? enginePosition;
      throw seekError!;
    }
    enginePosition = confirmedPosition ?? position;
  }

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    loadedSource = source;
    enginePosition = initialPosition ?? Duration.zero;
    engineProcessingState = ProcessingState.ready;
    return engineDuration;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    final gate = pauseGate;
    pauseGate = null;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
    engineProcessingState = ProcessingState.idle;
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}
