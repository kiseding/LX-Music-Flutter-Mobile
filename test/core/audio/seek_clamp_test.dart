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

  test('scrub freezes display and resumes without artificial delay', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    expect(provider, contains('void freeze()'));
    expect(provider, contains('void unfreeze('));
    expect(provider, contains('beginScrubProvider'));
    expect(provider, contains('finishScrubProvider'));
    expect(provider, isNot(contains('milliseconds: 500')));
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
    expect(full, isNot(contains('scrubSeekProvider')));
    expect(mini, isNot(contains('scrubSeekProvider')));
    expect(full, contains('Future<int> _scrubFuture'));
    expect(mini, contains('Future<int> _scrubFuture'));
    expect(full, contains('await _scrubFuture'));
    expect(mini, contains('await _scrubFuture'));
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

  test('scrub unfreezes only after seek and play command', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('Future<void> finish('),
      provider.indexOf('final scrubCoordinatorProvider'),
    );

    expect(
      scrub.indexOf('await _ref.read(playerServiceProvider).seek(position)'),
      lessThan(scrub.indexOf('.unfreeze(')),
    );
    expect(scrub, contains('await h.play()'));
  });

  test('auto-next uses seamless and end-of-track position guard', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('skipToNext(seamless: true)'));
    expect(source, contains('pos >= dur - const Duration(milliseconds: 80)'));
    expect(source, contains('milliseconds: 450'));
  });
}
