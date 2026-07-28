import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
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

  @override
  AudioSource? get audioSource => _source;

  @override
  bool get playing => _playing;

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
    _source = source;
    _processingState = ProcessingState.ready;
    return null;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
  }

  @override
  Future<void> stop() async {
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
