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

  test('scrub path is a single pause-seek-play without settle polling', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, isNot(contains('waitForSettledPosition')));
    expect(handler, isNot(contains('hardSeekTo')));
    expect(handler, isNot(contains('seekToDisplay')));
    expect(handler, isNot(contains('seekBudgetForQuality')));

    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('Future<void> finish('),
      provider.indexOf('final scrubCoordinatorProvider'),
    );
    expect(
        scrub, contains('final confirmed = await h.seekConfirmed(position)'));
    expect(scrub, contains('unfreeze(confirmed ?? h.player.position)'));
    expect(scrub, isNot(contains('unfreeze(position)')));
    expect(scrub, isNot(contains('waitForSettledPosition')));
    expect(scrub, isNot(contains('seekToDisplay')));
  });

  test('play starts asynchronously instead of waiting for playback to end', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    final play = handler.substring(
      handler.indexOf('Future<void> play() async'),
      handler.indexOf('/// 供测试：模拟当前曲播放完成'),
    );
    expect(play, contains('_startPlayer();'));
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
  final _Gate? seekGate;
  final requestedPositions = <Duration>[];
  AudioSource? loadedSource;
  bool _playing = false;

  _SeekAudioPlayer({
    required ProcessingState processingState,
    this.engineDuration,
    Duration position = Duration.zero,
    this.confirmedPosition,
    this.seekGate,
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
