import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/core/audio/playback_command_coordinator.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('interruption resumes only playback paused by that interruption', () {
    final policy = AudioInterruptionPolicy();

    expect(
      policy.onBegin(wasPlaying: true),
      InterruptionAction.pausePreservingIntent,
    );
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.resume,
    );
    expect(
      policy.onEnd(userStillWantsPlay: false, mayResume: true),
      InterruptionAction.none,
    );
  });

  test('interruption that did not pause playback cannot resume it', () {
    final policy = AudioInterruptionPolicy();

    expect(
      policy.onBegin(wasPlaying: false),
      InterruptionAction.none,
    );
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );
  });

  test('non-resumable interruption end consumes resume ownership', () {
    final policy = AudioInterruptionPolicy();

    policy.onBegin(wasPlaying: true);

    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: false),
      InterruptionAction.none,
    );
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );
  });

  test('becoming noisy pauses and clears resume intent', () {
    final policy = AudioInterruptionPolicy();

    expect(
      policy.onBecomingNoisy(),
      InterruptionAction.pauseClearingIntent,
    );
  });

  test('pure policy tracks nested interruption depth', () {
    final policy = AudioInterruptionPolicy();

    expect(policy.onBegin(wasPlaying: true),
        InterruptionAction.pausePreservingIntent);
    expect(policy.onBegin(wasPlaying: false), InterruptionAction.none);
    expect(policy.active, isTrue);
    expect(policy.depth, 2);
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );
    expect(policy.active, isTrue);
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.resume,
    );
    expect(policy.active, isFalse);
  });

  test('nested non-resumable end is sticky through final resumable end', () {
    final policy = AudioInterruptionPolicy();

    policy.onBegin(wasPlaying: true);
    policy.onBegin(wasPlaying: false);

    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: false),
      InterruptionAction.none,
    );
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );

    expect(policy.active, isFalse);
  });

  test('pure policy ignores unmatched and repeated ends', () {
    final policy = AudioInterruptionPolicy();

    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );
    policy.onBegin(wasPlaying: true);
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: false),
      InterruptionAction.none,
    );
    expect(
      policy.onEnd(userStillWantsPlay: true, mayResume: true),
      InterruptionAction.none,
    );
  });

  test('handler resumes an owned interruption without changing user intent',
      () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final intentGeneration = handler.userIntentGeneration;

    await handler.beginAudioInterruption();
    expect(player.playing, isFalse);
    expect(handler.userIntentGeneration, intentGeneration);

    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
    expect(handler.userIntentGeneration, intentGeneration);
  });

  test('explicit user pause invalidates interruption resume', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);

    await handler.beginAudioInterruption();
    await handler.pause();
    await handler.endAudioInterruption(mayResume: true);

    expect(player.playing, isFalse);
  });

  test('source change invalidates interruption resume', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);

    await handler.beginAudioInterruption();
    await handler.skipToQueueItem(1, playAfterLoad: false);
    await handler.endAudioInterruption(mayResume: true);

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isFalse);
  });

  test('repeated begin before pause completes initiates one owned pause',
      () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.gateNextPause(pauseGate);

    final firstBegin = handler.beginAudioInterruption();
    await pauseGate.started.future;
    final nestedBegin = handler.beginAudioInterruption();

    expect(handler.interruptionActive, isTrue);
    expect(handler.interruptionDepth, 2);
    expect(player.pauseCalls, 1);
    pauseGate.release.complete();
    await Future.wait([firstBegin, nestedBegin]);

    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isFalse);
    expect(handler.interruptionActive, isTrue);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('queued final end cannot consume a newer interruption begin', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await handler.beginAudioInterruption();

    final oldEnd = handler.endAudioInterruption(mayResume: true);
    final newBegin = handler.beginAudioInterruption();
    await oldEnd;
    await newBegin;

    expect(handler.interruptionActive, isTrue);
    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('final end keeps playback gated until queued pause completes', () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.gateNextPause(pauseGate);

    final begin = handler.beginAudioInterruption();
    await pauseGate.started.future;
    final end = handler.endAudioInterruption(mayResume: true);

    expect(handler.interruptionActive, isTrue);
    final playCalls = player.playCalls;
    await handler.play();
    expect(player.playCalls, playCalls);

    pauseGate.release.complete();
    await begin;
    await end;
  });

  test('unmatched end does not invalidate playback start provenance', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final blockGeneration = handler.playbackStartBlockGeneration;

    await handler.endAudioInterruption(mayResume: false);

    expect(handler.interruptionActive, isFalse);
    expect(handler.playbackStartBlockGeneration, blockGeneration);
    expect(player.playing, isTrue);
  });

  test('final non-resumable end leaves owned playback paused', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);

    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    await handler.endAudioInterruption(mayResume: true);

    expect(handler.interruptionActive, isFalse);
    expect(player.playing, isFalse);
  });

  for (final action
      in <({String name, Future<void> Function(LxAudioHandler) run})>[
    (name: 'pause', run: (handler) => handler.pause()),
    (name: 'stop', run: (handler) => handler.stop()),
    (
      name: 'selection',
      run: (handler) => handler.skipToQueueItem(1),
    ),
  ]) {
    test('explicit ${action.name} during interruption prevents old resume',
        () async {
      final player = _InterruptionAudioPlayer();
      final handler = LxAudioHandler(player: player);
      addTearDown(player.dispose);
      await handler.setPlaylist([_item('A'), _item('B')]);

      await handler.beginAudioInterruption();
      await action.run(handler);
      await handler.endAudioInterruption(mayResume: true);

      expect(player.playing, isFalse);
    });
  }

  test('selection crossing final end cannot inherit old resume authority',
      () async {
    final resolveGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler
        .setPlaylist([_item('A'), const MediaItem(id: 'B', title: 'B')]);
    await pumpEventQueue();
    handler.urlResolver = (id, [extras]) async {
      resolveGate.started.complete();
      await resolveGate.release.future;
      return 'file:///tmp/$id.mp3';
    };
    await handler.beginAudioInterruption();

    final selection = handler.skipToQueueItem(1);
    await resolveGate.started.future;
    await handler.endAudioInterruption(mayResume: true);
    resolveGate.release.complete();
    await selection;

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isFalse);
  });

  test('stale preserving pause cannot restart playback while interrupted',
      () async {
    final stalePause = _Gate();
    final player = _InterruptionAudioPlayer()..gateNextPause(stalePause);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final sourceGeneration = handler.sourceGeneration;
    final intentGeneration = handler.userIntentGeneration;

    final pause = handler.pauseForScrub(
      sourceGeneration: sourceGeneration,
      userIntentGeneration: intentGeneration,
      stillOwnsScrub: () => false,
    );
    await stalePause.started.future;
    final interruption = handler.beginAudioInterruption();
    stalePause.release.complete();
    await pause;
    await interruption;

    expect(handler.interruptionActive, isTrue);
    expect(player.playing, isFalse);
  });

  test('scrub resume is deferred until final interruption end', () async {
    final seekGate = _Gate();
    final player = _InterruptionAudioPlayer()..gateNextSeek(seekGate);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final sourceGeneration = handler.sourceGeneration;
    final intentGeneration = handler.userIntentGeneration;
    final interruptionGeneration = handler.interruptionGeneration;
    final startBlockGeneration = handler.playbackStartBlockGeneration;
    final owner = await handler.pauseForScrub(
      sourceGeneration: sourceGeneration,
      userIntentGeneration: intentGeneration,
      stillOwnsScrub: () => true,
    );

    final seek = handler.seekConfirmed(const Duration(seconds: 30));
    await seekGate.started.future;
    await handler.beginAudioInterruption();
    seekGate.release.complete();
    expect(await seek, const Duration(seconds: 30));
    await handler.releaseAfterScrub(
      owner,
      resumeAfter: true,
      sourceGeneration: sourceGeneration,
      userIntentGeneration: intentGeneration,
      interruptionGeneration: interruptionGeneration,
      startBlockGeneration: startBlockGeneration,
    );

    expect(player.playing, isFalse);
    expect(handler.userIntentGeneration, intentGeneration);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('scrub crossing non-resumable end cannot resume afterward', () async {
    final seekGate = _Gate();
    final player = _InterruptionAudioPlayer()..gateNextSeek(seekGate);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final sourceGeneration = handler.sourceGeneration;
    final intentGeneration = handler.userIntentGeneration;
    final interruptionGeneration = handler.interruptionGeneration;
    final startBlockGeneration = handler.playbackStartBlockGeneration;
    final owner = await handler.pauseForScrub(
      sourceGeneration: sourceGeneration,
      userIntentGeneration: intentGeneration,
      stillOwnsScrub: () => true,
    );

    final seek = handler.seekConfirmed(const Duration(seconds: 30));
    await seekGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    seekGate.release.complete();
    await seek;
    await handler.releaseAfterScrub(
      owner,
      resumeAfter: true,
      sourceGeneration: sourceGeneration,
      userIntentGeneration: intentGeneration,
      interruptionGeneration: interruptionGeneration,
      startBlockGeneration: startBlockGeneration,
    );

    expect(player.playing, isFalse);
  });

  test('interruption during coordinator scrub finish defers resume', () async {
    final seekGate = _Gate();
    final player = _InterruptionAudioPlayer()..gateNextSeek(seekGate);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final coordinator = ScrubCoordinator(
      _InterruptionScrubPlayback(handler),
      _InterruptionScrubPosition(),
    );

    final generation = await coordinator.begin();
    final finish = coordinator.finish(
      generation,
      const Duration(seconds: 30),
      resumeAfter: true,
    );
    await seekGate.started.future;
    await handler.beginAudioInterruption();
    seekGate.release.complete();
    await finish;

    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('interruption during coordinator scrub pause defers finish resume',
      () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer()..gateNextPause(pauseGate);
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final coordinator = ScrubCoordinator(
      _InterruptionScrubPlayback(handler),
      _InterruptionScrubPosition(),
    );

    final begin = coordinator.begin();
    await pauseGate.started.future;
    final interruption = handler.beginAudioInterruption();
    pauseGate.release.complete();
    final generation = await begin;
    await interruption;
    await coordinator.finish(
      generation,
      const Duration(seconds: 30),
      resumeAfter: true,
    );

    expect(player.playing, isFalse);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isTrue);
  });

  test('scrub pause cannot forget a completed interruption cycle', () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.gateNextPause(pauseGate);
    final coordinator = ScrubCoordinator(
      _InterruptionScrubPlayback(handler),
      _InterruptionScrubPosition(),
    );

    final begin = coordinator.begin();
    await pauseGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    pauseGate.release.complete();
    final generation = await begin;
    await coordinator.finish(
      generation,
      const Duration(seconds: 30),
      resumeAfter: true,
    );
    await pumpEventQueue();

    expect(player.playing, isFalse);
  });

  test('public play records intent but cannot start while interrupted',
      () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await handler.beginAudioInterruption();
    final playCalls = player.playCalls;

    await handler.play();

    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('explicit play during interruption starts after resumable final end',
      () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await handler.pause();
    await handler.beginAudioInterruption();
    final playCalls = player.playCalls;

    await handler.play();

    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);

    await handler.endAudioInterruption(mayResume: true);

    expect(player.playCalls, playCalls + 1);
    expect(player.playing, isTrue);
  });

  test('play idle recovery cannot forget a completed interruption cycle',
      () async {
    final sourceGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    await handler.pause();
    player
      ..setProcessingState(ProcessingState.idle)
      ..gateNextSourceInstall(sourceGate);
    final playCalls = player.playCalls;

    final play = handler.play();
    await sourceGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    sourceGate.release.complete();
    await play;
    await pumpEventQueue();

    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('skip halt cannot forget a completed interruption cycle', () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await pumpEventQueue();
    player.gateNextPause(pauseGate);
    final playCalls = player.playCalls;

    final skip = handler.skipToNext();
    await pauseGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    pauseGate.release.complete();
    await skip;
    await pumpEventQueue();

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playCalls, playCalls);
    expect(player.playing, isFalse);
  });

  test('explicit play transfers authority to older paused selection', () async {
    final pauseGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await pumpEventQueue();
    player.gateNextPause(pauseGate);

    final selection = handler.skipToQueueItem(1, playAfterLoad: false);
    await pauseGate.started.future;
    final begin = handler.beginAudioInterruption();
    final end = handler.endAudioInterruption(mayResume: false);
    final play = handler.play();
    pauseGate.release.complete();
    await begin;
    await end;
    await play;
    await selection;
    await pumpEventQueue();

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isTrue);
  });

  test('play completing after interruption pause cannot restart output',
      () async {
    final playGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    await handler.pause();
    player.gateNextPlay(playGate);

    await handler.play();
    await playGate.started.future;
    await handler.beginAudioInterruption();
    playGate.release.complete();
    await pumpEventQueue();

    expect(handler.interruptionActive, isTrue);
    expect(player.playing, isFalse);
  });

  test('play crossing non-resumable interruption end remains paused', () async {
    final playGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    await handler.pause();
    player.gateNextPlay(playGate);

    await handler.play();
    await playGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    playGate.release.complete();
    await pumpEventQueue();

    expect(handler.interruptionActive, isFalse);
    expect(player.playing, isFalse);
  });

  test('stale play completion cannot pause a newer authoritative source',
      () async {
    final playGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await pumpEventQueue();
    await handler.pause();
    player.gateNextPlay(playGate);

    await handler.play();
    await playGate.started.future;
    await handler.skipToQueueItem(1);
    playGate.release.complete();
    await pumpEventQueue();

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isTrue);
  });

  test('old play crossing cycle is side-effect free on newer source', () async {
    final playGate = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await pumpEventQueue();
    await handler.pause();
    player.gateNextPlay(playGate);

    await handler.play();
    await playGate.started.future;
    await handler.beginAudioInterruption();
    await handler.endAudioInterruption(mayResume: false);
    await handler.skipToQueueItem(1);
    expect(player.playing, isFalse);
    final pauseCalls = player.pauseCalls;

    playGate.release.complete();
    await pumpEventQueue();

    expect(handler.mediaItem.value?.id, 'B');
    expect(player.pauseCalls, pauseCalls);
  });

  test('completion cannot auto-advance while interrupted', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A'), _item('B')]);
    await handler.beginAudioInterruption();

    handler.debugEmitTrackCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
    expect(player.playing, isFalse);
  });

  test('becoming noisy performs an explicit normal pause', () async {
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    final intentGeneration = handler.userIntentGeneration;

    await handler.handleBecomingNoisy();

    expect(player.playing, isFalse);
    expect(handler.userIntentGeneration, intentGeneration + 1);
    await handler.endAudioInterruption(mayResume: true);
    expect(player.playing, isFalse);
  });

  test('queued noisy pause cannot defeat newer explicit play', () async {
    final interruptionPause = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.gateNextPause(interruptionPause);

    final interruption = handler.beginAudioInterruption();
    await interruptionPause.started.future;
    final noisy = handler.handleBecomingNoisy();
    await handler.play();
    interruptionPause.release.complete();
    await interruption;
    await noisy;
    await pumpEventQueue();

    expect(player.playing, isTrue);
  });

  test('noisy pause completion reconciles explicit play during native pause',
      () async {
    final noisyPause = _Gate();
    final player = _InterruptionAudioPlayer();
    final handler = LxAudioHandler(player: player);
    addTearDown(player.dispose);
    await handler.setPlaylist([_item('A')]);
    await pumpEventQueue();
    player.gateNextPause(noisyPause);

    final noisy = handler.handleBecomingNoisy();
    await noisyPause.started.future;
    await handler.play();
    noisyPause.release.complete();
    await noisy;
    await pumpEventQueue();

    expect(player.playing, isTrue);
  });

  test('play mode is derived from handler repeat and shuffle state', () {
    expect(
      playModeFromPlaybackState(
        PlaybackState(repeatMode: AudioServiceRepeatMode.one),
      ),
      PlayMode.repeatOne,
    );
    expect(
      playModeFromPlaybackState(
        PlaybackState(shuffleMode: AudioServiceShuffleMode.all),
      ),
      PlayMode.shuffle,
    );
    expect(
      playModeFromPlaybackState(PlaybackState()),
      PlayMode.sequential,
    );
  });
}

MediaItem _item(String id) => MediaItem(
      id: id,
      title: id,
      extras: {
        'url': 'file:///tmp/$id.mp3',
        'requestedQuality': '320k',
      },
    );

class _InterruptionAudioPlayer extends AudioPlayer {
  final _events = StreamController<PlaybackEvent>.broadcast();
  final _processingStates = StreamController<ProcessingState>.broadcast();
  AudioSource? _source;
  bool _playing = false;
  ProcessingState _processingState = ProcessingState.ready;
  Duration _position = Duration.zero;
  final List<_Gate> _pauseGates = [];
  final List<_Gate> _playGates = [];
  final List<_Gate> _sourceGates = [];
  _Gate? _seekGate;
  _Gate? _stopGate;
  int pauseCalls = 0;
  int playCalls = 0;

  void gateNextPause(_Gate gate) => _pauseGates.add(gate);

  void gateNextPlay(_Gate gate) => _playGates.add(gate);

  void gateNextSourceInstall(_Gate gate) => _sourceGates.add(gate);

  void gateNextSeek(_Gate gate) => _seekGate = gate;

  void gateNextStop(_Gate gate) => _stopGate = gate;

  void setProcessingState(ProcessingState state) => _processingState = state;

  @override
  AudioSource? get audioSource => _source;

  @override
  bool get playing => _playing;

  @override
  Duration get position => _position;

  @override
  ProcessingState get processingState => _processingState;

  @override
  Stream<PlaybackEvent> get playbackEventStream => _events.stream;

  @override
  Stream<ProcessingState> get processingStateStream => _processingStates.stream;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    final gate = _sourceGates.isEmpty ? null : _sourceGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _source = source;
    _processingState = ProcessingState.ready;
    return null;
  }

  @override
  Future<void> play() async {
    playCalls++;
    final gate = _playGates.isEmpty ? null : _playGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = true;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
    final gate = _pauseGates.isEmpty ? null : _pauseGates.removeAt(0);
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = false;
  }

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    final gate = _seekGate;
    _seekGate = null;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    if (position != null) _position = position;
  }

  @override
  Future<void> stop() async {
    final gate = _stopGate;
    _stopGate = null;
    if (gate != null) {
      gate.started.complete();
      await gate.release.future;
    }
    _playing = false;
    _processingState = ProcessingState.idle;
  }

  @override
  Future<void> dispose() async {
    await _events.close();
    await _processingStates.close();
    await super.dispose();
  }
}

class _Gate {
  final started = Completer<void>();
  final release = Completer<void>();
}

class _InterruptionScrubPlayback implements ScrubPlayback {
  final LxAudioHandler handler;

  _InterruptionScrubPlayback(this.handler);

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

class _InterruptionScrubPosition implements ScrubPosition {
  @override
  void freeze() {}

  @override
  void unfreeze(Duration position) {}
}
