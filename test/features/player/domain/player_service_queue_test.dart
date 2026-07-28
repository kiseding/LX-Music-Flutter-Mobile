import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
