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
}

class _RecordingAudioPlayer extends AudioPlayer {
  AudioSource? loadedSource;
  bool _playing = false;

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
    loadedSource = source;
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
  }
}
