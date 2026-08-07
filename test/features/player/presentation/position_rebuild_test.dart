import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/features/player/presentation/player_provider.dart';

void main() {
  test('PositionNotifier publishes only effective position changes', () {
    final notifier = PositionNotifier(null);
    addTearDown(notifier.dispose);
    var notifications = 0;
    notifier.addListener((_) => notifications++, fireImmediately: false);

    notifier.update(Duration.zero);
    notifier.update(const Duration(seconds: 1));
    notifier.update(const Duration(seconds: 1));

    expect(notifier.state, const Duration(seconds: 1));
    expect(notifications, 1);
  });

  test('high-frequency watches live only in narrow presentation widgets', () {
    final player = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    final lyric = File(
      'lib/features/lyric/presentation/lyric_view.dart',
    ).readAsStringSync();

    expect(player.indexOf('class _PlayerProgress'), isNonNegative);
    expect(player.substring(0, player.indexOf('class _PlayerProgress')),
        isNot(contains('ref.watch(playerPositionProvider)')));
    expect(mini.indexOf('class _MiniProgress'), isNonNegative);
    expect(mini.substring(0, mini.indexOf('class _MiniProgress')),
        isNot(contains('ref.watch(positionProvider)')));
    expect(lyric.indexOf('class _PositionedKtvLyricLine'), isNonNegative);
    expect(lyric.substring(0, lyric.indexOf('class _PositionedKtvLyricLine')),
        isNot(contains('ref.watch(playerPositionProvider)')));
  });
}
