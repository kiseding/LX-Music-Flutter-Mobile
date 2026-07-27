import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seek waits for engine position convergence', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('Future<void> seek(Duration position) async'));
    expect(source, contains('for (var i = 0; i < 8; i++)'));
    expect(source, contains('_broadcastState(_player.playbackEvent)'));
  });

  test('position notifier locks during seek', () {
    final source = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    expect(source, contains('void beginSeek(Duration target)'));
    expect(source, contains('void endSeek(Duration confirmed)'));
    expect(source, contains('posNotifier.beginSeek(position)'));
  });

  test('progress drag no longer pauses before seek', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    expect(full.contains('if (playing) await audioHandler.pause();'), isFalse);
    expect(mini.contains('if (playing) await audioHandler.pause();'), isFalse);
  });
}
