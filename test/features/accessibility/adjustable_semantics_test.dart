import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adjustable progress invokes clamped increase and decrease',
      (tester) async {
    var value = const Duration(seconds: 5);
    await tester.pumpWidget(MaterialApp(home: StatefulBuilder(
      builder: (context, setState) {
        final seconds = value.inSeconds;
        return Semantics(
          label: '播放进度',
          slider: true,
          value: '$seconds',
          increasedValue: '${(seconds + 10).clamp(0, 20)}',
          decreasedValue: '${(seconds - 10).clamp(0, 20)}',
          onIncrease: () => setState(() {
            value = Duration(seconds: (value.inSeconds + 10).clamp(0, 20));
          }),
          onDecrease: () => setState(() {
            value = Duration(seconds: (value.inSeconds - 10).clamp(0, 20));
          }),
          child: const SizedBox(width: 100, height: 20),
        );
      },
    )));

    final finder = find.bySemanticsLabel('播放进度');
    final node = tester.getSemantics(finder);
    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();
    expect(value, const Duration(seconds: 15));
    node.owner!.performAction(node.id, SemanticsAction.decrease);
    await tester.pump();
    expect(value, const Duration(seconds: 5));
  });

  test('production progress and lyric controls expose adjustable actions', () {
    final player = File(
      'lib/features/player/presentation/player_screen.dart',
    ).readAsStringSync();
    final mini = File(
      'lib/features/player/presentation/widgets/mini_player.dart',
    ).readAsStringSync();
    final lyric = File(
      'lib/features/lyric/presentation/lyric_view.dart',
    ).readAsStringSync();
    final playerProgress =
        player.substring(player.indexOf('class _PlayerProgress'));
    final miniProgress = mini.substring(mini.indexOf('class _MiniProgress'));

    for (final source in [playerProgress, miniProgress]) {
      expect(source, contains("label: '播放进度'"));
      expect(source, contains('onIncrease:'));
      expect(source, contains('onDecrease:'));
      expect(source, contains('seekProvider'));
    }
    expect(lyric, contains("label: '歌词'"));
    expect(lyric, contains('selected: isCurrent'));
    expect(lyric, contains('onIncrease:'));
    expect(lyric, contains('onDecrease:'));
  });
}
