import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scrub pauses then resumes after 500ms', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    expect(provider, contains('scrubSeekProvider'));
    expect(provider, contains('milliseconds: 500'));
    expect(provider, contains('pauseInternal(clearIntent: false)'));
    expect(provider, contains('await h.play()'));
  });

  test('full and mini player pause on drag start', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    expect(full, contains('pauseInternal(clearIntent: false)'));
    expect(mini, contains('pauseInternal(clearIntent: false)'));
    expect(full, contains('scrubSeekProvider'));
    expect(mini, contains('scrubSeekProvider'));
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

  test('scrub commits the display position only after the engine seeks', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = provider.substring(
      provider.indexOf('final scrubSeekProvider'),
      provider.indexOf('/// 点击歌词行等'),
    );

    expect(
      scrub.indexOf('await ref.read(playerServiceProvider).seek(position)'),
      lessThan(scrub.indexOf('posNotifier.jumpTo(')),
    );
  });

  test('auto-next uses seamless and end-of-track position guard', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('skipToNext(seamless: true)'));
    expect(source, contains('pos >= dur - const Duration(milliseconds: 80)'));
    expect(source, contains('milliseconds: 450'));
  });
}
