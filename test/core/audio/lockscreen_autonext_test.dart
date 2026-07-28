import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completion has one authoritative generation-safe path', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('state != ProcessingState.completed'));
    expect(source, contains('_lastHandledCompletionGeneration'));
    expect(source, contains('_installedPlaybackGeneration'));
    expect(
      source,
      contains('_installedPlaybackGeneration != _playGeneration'),
    );
    expect(source, isNot(contains('_player.positionStream.listen')));
    expect(source, isNot(contains('_player.currentIndexStream.listen')));
    expect(source, isNot(contains("_onTrackCompleted('position-end')")));
  });

  test('auto-next and repeat-one reload use seamless queue-item skip', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(
      source,
      contains('skipToQueueItem(int index, {bool seamless = false})'),
    );
    expect(source, contains('skipToQueueItem(target, seamless: true)'));
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
