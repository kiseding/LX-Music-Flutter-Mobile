import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('seek waits out loading state before applying', () {
    final source = File('lib/core/audio/audio_handler.dart').readAsStringSync();
    expect(source, contains('Future<void> seek(Duration position) async'));
    expect(source, contains('ProcessingState.loading'));
    expect(source, contains('seek skipped'));
  });

  test('single position clock drives progress and lyrics', () {
    final provider = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    expect(provider, contains('positionDiscontinuityStream'));
    expect(provider, contains('positionStream.listen'));
    expect(provider, isNot(contains('beginSeek')));
    expect(provider, isNot(contains('_seekLockTarget')));
  });

  test('progress UI does not keep pending seek after finger up', () {
    final full = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    expect(full.contains('_pendingSeek'), isFalse);
    expect(mini.contains('_pendingSeek'), isFalse);
    expect(full.contains('if (playing) await audioHandler.pause();'), isFalse);
    expect(mini.contains('if (playing) await audioHandler.pause();'), isFalse);
  });
}
