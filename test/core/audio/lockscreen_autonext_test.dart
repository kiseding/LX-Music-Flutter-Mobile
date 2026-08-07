import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LxAudioHandler handler;
  late _CompletionAudioPlayer player;

  setUp(() {
    player = _CompletionAudioPlayer();
    handler = LxAudioHandler(player: player);
  });

  tearDown(() async {
    await handler.player.dispose();
  });

  MediaItem item(String id) => MediaItem(
        id: id,
        title: id,
        extras: {
          'url': 'file:///tmp/$id.mp3',
          'requestedQuality': '320k',
        },
      );

  test('duplicate completion advances only once', () async {
    await handler.setPlaylist([item('A'), item('B'), item('C')]);
    final loadsBeforeCompletion = player.sourceLoadCalls;

    player.emitCompleted();
    player.emitCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
    expect(player.sourceLoadCalls, greaterThan(loadsBeforeCompletion));
  });

  test('completion from replaced source cannot advance newly installed item',
      () async {
    await handler.setPlaylist([item('A'), item('B')]);
    await handler.updateQueue([item('B'), item('C')]);
    final loadsBeforeCompletion = player.sourceLoadCalls;

    handler.debugEmitTrackCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'B');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.sourceLoadCalls, loadsBeforeCompletion + 1);
  });

  test('explicit pause wins after completion is claimed', () async {
    await handler.setPlaylist([item('A'), item('B')]);
    final loadsBeforeCompletion = player.sourceLoadCalls;

    handler.debugEmitTrackCompleted();
    await handler.pause();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
    expect(player.sourceLoadCalls, loadsBeforeCompletion);
    expect(player.playing, isFalse);
  });

  test('explicit pause wins during seamless completion load', () async {
    await handler.setPlaylist([item('A'), item('B')]);
    player.gateNextSourceLoad();

    handler.debugEmitTrackCompleted();
    await player.sourceLoadStarted.future;
    await handler.pause();
    player.releaseSourceLoad.complete();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isFalse);
  });

  test('completion keeps a tagged native source alive while resolving next',
      () async {
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    final next = MediaItem(id: 'B', title: 'B');
    handler.urlResolver = (id, [extras]) async {
      if (id == 'B') {
        resolverStarted.complete();
        await releaseResolver.future;
      }
      return 'file:///tmp/$id.mp3';
    };
    await handler.setPlaylist([item('A'), next]);

    handler.debugEmitTrackCompleted();
    await resolverStarted.future;

    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
    expect(player.playing, isTrue);
    expect(player.loadedSource, isA<SilenceAudioSource>());
    expect((player.loadedSource as SilenceAudioSource).tag.id, 'B');

    releaseResolver.complete();
    await pumpEventQueue();

    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(player.playing, isTrue);
  });

  test('repeat one completion reloads the current item', () async {
    await handler.setPlaylist([item('A'), item('B')]);
    await handler.setRepeatMode(AudioServiceRepeatMode.one);

    handler.debugEmitTrackCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
  });

  test('pending quality source request makes old completion inert', () async {
    await handler.setPlaylist([item('A'), item('B')]);
    handler.urlResolver = (id, [extras]) async =>
        'file:///tmp/$id-${extras?['requestedQuality']}.mp3';
    player.gateNextPause();

    final reload = handler.applyPreferredQuality('flac');
    await player.pauseStarted.future;
    final loadsBeforeCompletion = player.sourceLoadCalls;
    player.emitCompleted();
    await pumpEventQueue();

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
    expect(player.sourceLoadCalls, loadsBeforeCompletion);

    player.releasePause.complete();
    await reload;

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
  });

  test('completion uses one native signal and no position threshold', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('state != ProcessingState.completed'));
    expect(
      RegExp(r'processingStateStream\.listen').allMatches(source),
      hasLength(1),
    );
    expect(source, isNot(contains('_player.positionStream.listen')));
    expect(source, isNot(contains('_player.currentIndexStream.listen')));
    expect(source, isNot(contains("_onTrackCompleted('position-end')")));
  });

  test('seamless queue-item command remains available for background use', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(
      source,
      contains('Duration initialPosition = Duration.zero'),
    );
    expect(source, contains('bool playAfterLoad = true'));
    expect(source, isNot(contains('_skipToNextInternal(seamless: true)')));
    // 拖进度 pause 不清除播放意图
    expect(source, contains('pauseInternal({bool clearIntent = true})'));
  });

  test('repeat is owned by completion policy rather than native source loop',
      () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    final repeatMode = source.substring(
      source.indexOf('Future<void> setRepeatMode('),
      source.indexOf('Future<void> setShuffleMode('),
    );
    expect(repeatMode, contains('setLoopMode(LoopMode.off)'));
    expect(repeatMode, isNot(contains('setLoopMode(LoopMode.one)')));
    expect(repeatMode, isNot(contains('setLoopMode(LoopMode.all)')));
  });
}

class _CompletionAudioPlayer extends AudioPlayer {
  final _processingStates = StreamController<ProcessingState>.broadcast();
  AudioSource? loadedSource;
  bool _playing = false;
  int sourceLoadCalls = 0;
  Completer<void>? _sourceLoadStarted;
  Completer<void>? _releaseSourceLoad;
  Completer<void>? _pauseStarted;
  Completer<void>? _releasePause;

  void emitCompleted() => _processingStates.add(ProcessingState.completed);

  Completer<void> get sourceLoadStarted => _sourceLoadStarted!;
  Completer<void> get releaseSourceLoad => _releaseSourceLoad!;
  Completer<void> get pauseStarted => _pauseStarted!;
  Completer<void> get releasePause => _releasePause!;

  void gateNextSourceLoad() {
    _sourceLoadStarted = Completer<void>();
    _releaseSourceLoad = Completer<void>();
  }

  void gateNextPause() {
    _pauseStarted = Completer<void>();
    _releasePause = Completer<void>();
  }

  @override
  Stream<ProcessingState> get processingStateStream => _processingStates.stream;

  @override
  AudioSource? get audioSource => loadedSource;

  @override
  bool get playing => _playing;

  @override
  Future<Duration?> setAudioSource(
    AudioSource source, {
    bool preload = true,
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    sourceLoadCalls++;
    loadedSource = source;
    final started = _sourceLoadStarted;
    final release = _releaseSourceLoad;
    if (started != null && release != null) {
      started.complete();
      await release.future;
      _sourceLoadStarted = null;
      _releaseSourceLoad = null;
    }
    return null;
  }

  @override
  Future<void> play() async {
    _playing = true;
  }

  @override
  Future<void> pause() async {
    final started = _pauseStarted;
    final release = _releasePause;
    if (started != null && release != null) {
      started.complete();
      await release.future;
      _pauseStarted = null;
      _releasePause = null;
    }
    _playing = false;
  }

  @override
  Future<void> stop() async {
    _playing = false;
  }

  @override
  Future<void> dispose() async {
    await _processingStates.close();
    await super.dispose();
  }
}
