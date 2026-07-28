import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(scrub, contains('await h.seek(position)'));
    expect(scrub, contains('unfreeze(position)'));
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
}
