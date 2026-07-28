import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('scrub publishes confirmed engine position, not requested target', () {
    final source = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    expect(
        source, contains('final confirmed = await h.seekConfirmed(position)'));
    expect(source, contains('unfreeze(confirmed ?? h.player.position)'));
    expect(source, isNot(contains('unfreeze(position)')));
  });

  test('scrub resume requires confirmed seek and transaction ownership', () {
    final source = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = source.substring(
      source.indexOf('class ScrubCoordinator'),
      source.indexOf('final scrubCoordinatorProvider'),
    );

    expect(scrub, contains('confirmed != null'));
    expect(scrub, contains('ownsScrubTransaction'));
    expect(scrub, contains('sourceGeneration'));
    expect(scrub, contains('userIntentGeneration'));
  });

  test('newer scrub generation guards publication after seek', () {
    final source = File(
      'lib/features/player/presentation/player_provider.dart',
    ).readAsStringSync();
    final scrub = source.substring(
      source.indexOf('final confirmed = await h.seekConfirmed(position)'),
      source.indexOf('final scrubCoordinatorProvider'),
    );

    expect(scrub, contains('if (generation != _generation) return;'));
    expect(
      scrub.indexOf('if (generation != _generation) return;'),
      lessThan(scrub.indexOf('unfreeze(confirmed ?? h.player.position)')),
    );
  });
}
