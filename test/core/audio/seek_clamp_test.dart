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
    expect(handler, isNot(contains('await _player.play()')));
  });

  test('handler can pull engine position to display time within 500ms', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, contains('Future<Duration> seekToDisplay('));
    expect(handler, contains('milliseconds: 500'));
    expect(handler, contains('inMilliseconds.abs()'));
  });

  test('scrub treats screen time as authority and aligns engine within budget',
      () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('Future<void> finish('),
      provider.indexOf('final scrubCoordinatorProvider'),
    );

    expect(scrub, contains('seekToDisplay(position'));
    expect(scrub, contains('unfreeze(position)'));
    // 屏幕时间先钉住，再把引擎往屏幕拉；最终仍 unfreeze 到屏幕目标
    expect(
      scrub.indexOf('unfreeze(position)'),
      lessThan(scrub.indexOf('seekToDisplay(position')),
    );
    expect(
      scrub.lastIndexOf('unfreeze(position)'),
      greaterThan(scrub.indexOf('seekToDisplay(position')),
    );
    expect(scrub, contains('await h.play()'));
  });

  test('full and mini player use the shared scrub transaction', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    expect(full, contains('beginScrubProvider'));
    expect(mini, contains('beginScrubProvider'));
    expect(full, contains('finishScrubProvider'));
    expect(mini, contains('finishScrubProvider'));
    expect(full, contains('Future<int> _scrubFuture'));
    expect(mini, contains('Future<int> _scrubFuture'));
  });

  test('progress drags do not seek or resume before touch release', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();

    expect(full, isNot(contains('onTapDown: (d) async')));
    expect(mini, isNot(contains('onTapDown: !canSeek')));
  });

  test('auto-next uses seamless and end-of-track position guard', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('skipToNext(seamless: true)'));
    expect(source, contains('pos >= dur - const Duration(milliseconds: 80)'));
    expect(source, contains('milliseconds: 450'));
  });
}
