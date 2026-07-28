import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(handler, contains('unawaited(_player.play()'));
  });

  test('lossless scrub uses hard seek via setAudioSource initialPosition', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, contains('bool isLosslessQuality('));
    expect(handler, contains('Future<Duration> hardSeekTo('));
    expect(handler, contains('initialPosition: target'));
    expect(handler, contains('setAudioSource('));

    final seekToDisplay = handler.substring(
      handler.indexOf('Future<Duration> seekToDisplay('),
      handler.indexOf('Future<Duration> waitForSettledPosition('),
    );
    expect(seekToDisplay, contains('isLosslessQuality'));
    expect(seekToDisplay, contains('hardSeekTo('));
  });

  test('scrub does not pin official clock before engine settles', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('Future<void> finish('),
      provider.indexOf('final scrubCoordinatorProvider'),
    );

    expect(scrub, contains('seekToDisplay('));
    expect(scrub, contains('waitForSettledPosition'));
    expect(scrub, contains('unfreeze(settled)'));
    expect(scrub, isNot(contains('unfreeze(position)')));
    // Only one seekToDisplay; play path uses wait-only settle.
    expect(scrub.split('seekToDisplay(').length - 1, 1);
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

  test('auto-next uses seamless and end-of-track position guard', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('skipToNext(seamless: true)'));
    expect(source, contains('pos >= dur - const Duration(milliseconds: 80)'));
  });
}
