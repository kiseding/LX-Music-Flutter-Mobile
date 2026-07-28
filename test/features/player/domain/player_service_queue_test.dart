import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/player/domain/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  audioHandler = BaseAudioHandler();

  late AudioHandler originalAudioHandler;
  late LxAudioHandler handler;
  late _RecordingAudioPlayer player;

  setUp(() {
    originalAudioHandler = audioHandler;
    player = _RecordingAudioPlayer();
    handler = LxAudioHandler(player: player);
  });

  tearDown(() async {
    audioHandler = originalAudioHandler;
    await handler.player.dispose();
  });

  test('player service has no independently mutable queue', () {
    final source = File('lib/features/player/domain/player_service.dart')
        .readAsStringSync();
    expect(source, isNot(contains('final List<MediaItem> _playQueue')));
    expect(source, isNot(contains('int _currentIndex')));
    expect(source, contains('handler.queueItems'));
    expect(source, contains('handler.currentQueueIndex'));
  });

  test('queue metadata updates never replace the active audio source', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    final update = source.substring(
      source.indexOf('Future<void> updateQueue('),
      source.indexOf('Future<void> addQueueItem('),
    );
    expect(update, isNot(contains('ConcatenatingAudioSource')));
    expect(update, isNot(contains('setAudioSource')));
  });

  test('playNext inserts a removed duplicate after the current item', () async {
    audioHandler = handler;
    const currentId = 'B';
    MediaItem item(String id) => MediaItem(id: id, title: id);
    await handler.updateQueue([item(currentId)]);
    await handler.updateQueue([item('A'), item(currentId), item('C')]);

    await PlayerService().playNext(MusicItem(
      id: 'A',
      name: 'A',
      singer: '',
      source: 'test',
    ));

    expect(handler.queueItems.map((item) => item.id), ['B', 'A', 'C']);
  });

  test('in-flight queue load follows active item after metadata move',
      () async {
    final resolverStarted = Completer<void>();
    final releaseResolver = Completer<void>();
    final errors = <String>[];
    MediaItem item(String id) => MediaItem(id: id, title: id);
    await handler.updateQueue([item('A'), item('B')]);
    handler.onError = errors.add;
    handler.urlResolver = (id, [extras]) async {
      resolverStarted.complete();
      await releaseResolver.future;
      return null;
    };

    final load = handler.skipToQueueItem(1);
    await resolverStarted.future;
    await handler.updateQueue([item('B')]);
    releaseResolver.complete();
    await load;

    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'B');
    expect(errors, hasLength(1));
  });

  test('removing before current preserves current item and shifts index',
      () async {
    MediaItem item(String id) => MediaItem(id: id, title: id);
    await handler.updateQueue([item('B')]);
    await handler.updateQueue([item('A'), item('B'), item('C')]);

    await handler.removeQueueItem(item('A'));

    expect(handler.queueItems.map((item) => item.id), ['B', 'C']);
    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'B');
  });

  test('removing current selects the item now at the same index', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('B')]);
    await handler.updateQueue([item('A'), item('B'), item('C')]);

    await handler.removeQueueItem(item('B'));

    expect(handler.queueItems.map((item) => item.id), ['A', 'C']);
    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'C');
  });

  test('removing current last item selects the preceding item', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('C')]);
    await handler.updateQueue([item('A'), item('B'), item('C')]);

    await handler.removeQueueItem(item('C'));

    expect(handler.queueItems.map((item) => item.id), ['A', 'B']);
    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
  });

  test('removing a non-current last item preserves current state', () async {
    MediaItem item(String id) => MediaItem(id: id, title: id);
    await handler.updateQueue([item('B')]);
    await handler.updateQueue([item('A'), item('B'), item('C')]);

    await handler.removeQueueItem(item('C'));

    expect(handler.queueItems.map((item) => item.id), ['A', 'B']);
    expect(handler.currentQueueIndex, 1);
    expect(handler.mediaItem.value?.id, 'B');
  });

  test('removing sole item clears authoritative queue state', () async {
    final item = MediaItem(id: 'A', title: 'A');
    await handler.updateQueue([item]);

    await handler.removeQueueItem(item);

    expect(handler.queueItems, isEmpty);
    expect(handler.currentQueueIndex, -1);
    expect(handler.mediaItem.value, isNull);
  });

  for (final paused in [false, true]) {
    test(
        'removing loaded current middle replaces source with next item '
        'when ${paused ? 'paused' : 'playing'}', () async {
      MediaItem item(String id) => MediaItem(
            id: id,
            title: id,
            extras: {
              'url': 'file:///tmp/$id.mp3',
              'requestedQuality': '320k',
            },
          );
      final current = item('B');
      await handler.updateQueue([item('A'), current, item('C')]);
      await handler.skipToQueueItem(1);
      if (paused) await handler.pause();

      await handler.removeQueueItem(current);

      expect(handler.currentQueueIndex, 1);
      expect(handler.mediaItem.value?.id, 'C');
      expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'C');
      expect(player.playing, !paused);
    });

    test(
        'removing loaded current last replaces source with previous item '
        'when ${paused ? 'paused' : 'playing'}', () async {
      MediaItem item(String id) => MediaItem(
            id: id,
            title: id,
            extras: {
              'url': 'file:///tmp/$id.mp3',
              'requestedQuality': '320k',
            },
          );
      final current = item('C');
      await handler.updateQueue([item('A'), item('B'), current]);
      await handler.skipToQueueItem(2);
      if (paused) await handler.pause();

      await handler.removeQueueItem(current);

      expect(handler.currentQueueIndex, 1);
      expect(handler.mediaItem.value?.id, 'B');
      expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
      expect(player.playing, !paused);
    });
  }

  test('current removal relocates target after suspended pause', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current, item('C')]);
    await handler.skipToQueueItem(1);
    player.gateNextPause();

    final removal = handler.removeQueueItem(current);
    await player.pauseStarted.future;
    await handler.updateQueue([current, item('A'), item('C')]);
    player.releasePause.complete();
    await removal;

    expect(handler.queueItems.map((item) => item.id), ['A', 'C']);
    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'A');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
  });

  for (final replacementId in [null, 'D']) {
    test(
        'source load aborts when active item is '
        '${replacementId == null ? 'removed' : 'replaced'}', () async {
      MediaItem item(String id) => MediaItem(
            id: id,
            title: id,
            extras: {
              'url': 'file:///tmp/$id.mp3',
              'requestedQuality': '320k',
            },
          );
      final current = item('B');
      await handler.updateQueue([item('A'), current, item('C')]);
      player.gateNextSourceLoad();

      final load = handler.skipToQueueItem(1);
      await player.sourceLoadStarted.future;
      await handler.updateQueue([
        item('A'),
        if (replacementId != null) item(replacementId),
        item('C'),
      ]);
      player.releaseSourceLoad.complete();
      await load;

      expect(player.playedSourceIds, isNot(contains('B')));
      expect(handler.mediaItem.value?.id, 'A');
      expect(handler.queueItems.map((item) => item.id),
          replacementId == null ? ['A', 'C'] : ['A', 'D', 'C']);
    });
  }

  test('source load follows active item when metadata merely moves it',
      () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current, item('C')]);
    player.gateNextSourceLoad();

    final load = handler.skipToQueueItem(1);
    await player.sourceLoadStarted.future;
    await handler.updateQueue([current, item('A'), item('C')]);
    player.releaseSourceLoad.complete();
    await load;

    expect(player.playCalls, 1);
    expect(handler.currentQueueIndex, 0);
    expect(handler.mediaItem.value?.id, 'B');
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
  });

  test('post-load identity check guards play and preload', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    final transaction = source.substring(
      source.indexOf('await _player.setAudioSource('),
      source.indexOf(
          '} catch (e) {', source.indexOf('await _player.setAudioSource(')),
    );
    final validation = transaction.indexOf('activeItemIndex()');
    expect(validation, greaterThanOrEqualTo(0));
    expect(
      validation,
      lessThan(transaction.indexOf('_startPlayer(stillOwnsStart:')),
    );
    expect(validation, lessThan(transaction.indexOf('_schedulePreload();')));
  });

  for (final replacementId in [null, 'D']) {
    test(
        'stale installed source is recovered when item is '
        '${replacementId == null ? 'removed' : 'replaced'}', () async {
      MediaItem item(String id) => MediaItem(
            id: id,
            title: id,
            extras: {
              'url': 'file:///tmp/$id.mp3',
              'requestedQuality': '320k',
            },
          );
      final current = item('B');
      await handler.updateQueue([item('A'), current, item('C')]);
      player.gateNextSourceLoad();

      final load = handler.skipToQueueItem(1);
      await player.sourceLoadStarted.future;
      await handler.updateQueue([
        item('A'),
        if (replacementId != null) item(replacementId),
        item('C'),
      ]);
      player.releaseSourceLoad.complete();
      await load;
      player.playedSourceIds.clear();

      await handler.play();

      expect(player.playedSourceIds, ['A']);
      expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
      expect(handler.mediaItem.value?.id, 'A');
    });
  }

  test('new user play wins during paused current-item removal', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current, item('C')]);
    await handler.skipToQueueItem(1);
    await handler.pause();
    player.gateNextSourceLoad();

    final removal = handler.removeQueueItem(current);
    await player.sourceLoadStarted.future;
    final userPlay = handler.play();
    player.releaseSourceLoad.complete();
    await userPlay;
    await removal;

    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'C');
  });

  test('new user pause wins during playing current-item removal', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current, item('C')]);
    await handler.skipToQueueItem(1);
    player.gateNextSourceLoad();

    final removal = handler.removeQueueItem(current);
    await player.sourceLoadStarted.future;
    await handler.pause();
    player.releaseSourceLoad.complete();
    await removal;
    final loadsAfterRemoval = player.sourceLoadCalls;
    handler.urlResolver = (id, [extras]) async => 'file:///tmp/$id.flac';

    await handler.applyPreferredQuality('flac');

    expect(player.playing, isFalse);
    expect(player.sourceLoadCalls, loadsAfterRemoval + 1);
  });

  test('older stale install cannot stop a newer authoritative install',
      () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('A'), item('B')]);
    final olderGate = player.queueSourceLoadGate();
    final olderLoad = handler.skipToQueueItem(0);
    await olderGate.started.future;
    final newerGate = player.queueSourceLoadGate();
    final newerLoad = handler.skipToQueueItem(1);
    expect(player.sourceLoadCalls, 1);
    olderGate.release.complete();
    await newerGate.started.future;
    newerGate.release.complete();
    await newerLoad;
    final stopsAfterNewer = player.stopCalls;

    await olderLoad;

    expect(player.stopCalls, stopsAfterNewer);
    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(handler.mediaItem.value?.id, 'B');
  });

  test('stale non-recovering install cannot stop a newer source', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('A'), item('B'), item('C')]);
    final staleGate = player.queueSourceLoadGate();
    final staleLoad = handler.skipToQueueItem(1);
    await staleGate.started.future;
    final recoveryGate = player.queueSourceLoadGate();
    await handler.updateQueue([item('A'), item('C')]);
    staleGate.release.complete();
    await recoveryGate.started.future;
    final newerGate = player.queueSourceLoadGate();
    final newerLoad = handler.skipToQueueItem(1);
    expect(player.sourceLoadCalls, 2);
    recoveryGate.release.complete();
    await newerGate.started.future;
    newerGate.release.complete();
    await newerLoad;
    final stopsAfterNewer = player.stopCalls;

    await staleLoad;

    expect(player.stopCalls, stopsAfterNewer);
    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'C');
    expect(handler.mediaItem.value?.id, 'C');
  });

  test('explicit same-item selection wins during paused removal load',
      () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current, item('C')]);
    await handler.skipToQueueItem(1);
    await handler.pause();
    final removalGate = player.queueSourceLoadGate();
    final removal = handler.removeQueueItem(current);
    await removalGate.started.future;

    final userSelection = handler.skipToQueueItem(1);
    removalGate.release.complete();
    await userSelection;
    await removal;

    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'C');
    expect(handler.mediaItem.value?.id, 'C');
  });

  test('explicit terminal next wins during paused removal load', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    final current = item('B');
    await handler.updateQueue([item('A'), current]);
    await handler.skipToQueueItem(1);
    await handler.pause();
    final removalGate = player.queueSourceLoadGate();
    final removal = handler.removeQueueItem(current);
    await removalGate.started.future;

    await handler.skipToNext();
    removalGate.release.complete();
    await removal;

    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
    expect(handler.mediaItem.value?.id, 'A');
  });

  test('newer install waits for stale recovery stop and remains current',
      () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('A'), item('B')]);
    final staleInstall = player.queueSourceLoadGate();
    final staleLoad = handler.skipToQueueItem(0);
    await staleInstall.started.future;
    await handler.updateQueue([item('B')]);
    final recoveryStop = player.gateNextStop();
    staleInstall.release.complete();
    await recoveryStop.started.future;

    final newerLoad = handler.skipToQueueItem(0);
    expect(player.sourceLoadCalls, 1);
    recoveryStop.release.complete();
    await staleLoad;
    await newerLoad;

    expect(player.sourceLoadCalls, 2);
    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'B');
    expect(handler.mediaItem.value?.id, 'B');
  });

  test('bounded non-recovering stale stop releases source gate', () async {
    MediaItem item(String id) => MediaItem(
          id: id,
          title: id,
          extras: {
            'url': 'file:///tmp/$id.mp3',
            'requestedQuality': '320k',
          },
        );
    await handler.updateQueue([item('A'), item('B')]);
    final staleInstall = player.queueSourceLoadGate();
    final staleLoad = handler.skipToQueueItem(0);
    await staleInstall.started.future;
    await handler.updateQueue([item('B')]);
    final recoveryInstall = player.queueSourceLoadGate();
    staleInstall.release.complete();
    await recoveryInstall.started.future;
    await handler.updateQueue([item('A')]);
    final boundedStop = player.gateNextStop();
    recoveryInstall.release.complete();
    await boundedStop.started.future;

    final newerLoad = handler.skipToQueueItem(0);
    expect(player.sourceLoadCalls, 2);
    boundedStop.release.complete();
    await staleLoad;
    await newerLoad;

    expect(player.sourceLoadCalls, 3);
    expect(player.playing, isTrue);
    expect((player.loadedSource as ProgressiveAudioSource).tag.id, 'A');
    expect(handler.mediaItem.value?.id, 'A');
  });
}

class _RecordingAudioPlayer extends AudioPlayer {
  AudioSource? loadedSource;
  bool _playing = false;
  Completer<void>? _pauseStarted;
  Completer<void>? _releasePause;
  Completer<void>? _sourceLoadStarted;
  Completer<void>? _releaseSourceLoad;
  final _sourceLoadGates = <_SourceLoadGate>[];
  _SourceLoadGate? _stopGate;
  int playCalls = 0;
  int sourceLoadCalls = 0;
  int stopCalls = 0;
  final playedSourceIds = <String>[];

  Completer<void> get pauseStarted => _pauseStarted!;
  Completer<void> get releasePause => _releasePause!;
  Completer<void> get sourceLoadStarted => _sourceLoadStarted!;
  Completer<void> get releaseSourceLoad => _releaseSourceLoad!;

  void gateNextPause() {
    _pauseStarted = Completer<void>();
    _releasePause = Completer<void>();
  }

  void gateNextSourceLoad() {
    _sourceLoadStarted = Completer<void>();
    _releaseSourceLoad = Completer<void>();
  }

  _SourceLoadGate queueSourceLoadGate() {
    final gate = _SourceLoadGate();
    _sourceLoadGates.add(gate);
    return gate;
  }

  _SourceLoadGate gateNextStop() {
    final gate = _SourceLoadGate();
    _stopGate = gate;
    return gate;
  }

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
    final queuedGate =
        _sourceLoadGates.isEmpty ? null : _sourceLoadGates.removeAt(0);
    if (queuedGate != null) {
      queuedGate.started.complete();
      await queuedGate.release.future;
    }
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
    playCalls++;
    final source = loadedSource;
    if (source is ProgressiveAudioSource) {
      playedSourceIds.add((source.tag as MediaItem).id);
    }
    _playing = true;
  }

  @override
  Future<void> pause() async {
    _playing = false;
    final started = _pauseStarted;
    final release = _releasePause;
    if (started != null && release != null) {
      started.complete();
      await release.future;
      _pauseStarted = null;
      _releasePause = null;
    }
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _playing = false;
    final gate = _stopGate;
    if (gate != null) {
      _stopGate = null;
      gate.started.complete();
      await gate.release.future;
    }
  }
}

class _SourceLoadGate {
  final started = Completer<void>();
  final release = Completer<void>();
}
