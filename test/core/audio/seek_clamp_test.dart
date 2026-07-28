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

  test('seekToDisplay seeks once then waits for stable engine position', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    final method = handler.substring(
      handler.indexOf('Future<Duration> seekToDisplay('),
      handler.indexOf('Future<void> stop() async'),
    );

    expect('await seek('.allMatches(method).length, 1);
    expect(method, contains('waitForSettledPosition'));
    expect(method, contains('stableHits'));
    expect(method, contains('ProcessingState.ready'));
  });

  test('lossless formats get a longer seek settle budget', () {
    final handler = File(
      'lib/core/audio/audio_handler.dart',
    ).readAsStringSync();
    expect(handler, contains('Duration seekBudgetForQuality('));
    expect(handler, contains('flac'));
    expect(handler, contains('milliseconds: 1200'));
  });

  test('scrub keeps display frozen until engine settles after play', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('Future<void> finish('),
      provider.indexOf('final scrubCoordinatorProvider'),
    );

    expect(scrub, contains('seekToDisplay('));
    expect(scrub, contains('seekBudgetForQuality'));
    expect(scrub, contains('await h.play()'));
    // Must not pin UI to target before engine is ready.
    expect(scrub, isNot(contains('posNotifier.unfreeze(position)')));
    expect(scrub, contains('unfreeze(settled)'));
    expect(
      scrub.split('seekToDisplay(').length - 1,
      1,
      reason: 'only one seekToDisplay per scrub finish',
    );
  });

  test('progress UI holds local preview until scrub finish returns', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();

    // Clear seeking only after finishScrub completes.
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
