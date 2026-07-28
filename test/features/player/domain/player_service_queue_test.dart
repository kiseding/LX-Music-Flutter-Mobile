import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/audio/audio_handler.dart';
import 'package:lx_music_flutter/features/player/domain/music_item.dart';
import 'package:lx_music_flutter/features/player/domain/player_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    final handler = LxAudioHandler();
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
}
