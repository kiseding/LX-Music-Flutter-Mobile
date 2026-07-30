import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/widgets/play_pulse_button.dart';
import 'package:lx_music_flutter/core/widgets/pressable.dart';

void main() {
  testWidgets('Pressable exposes button state and activates from Enter',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Pressable(
      semanticLabel: '下一首',
      onTap: () => taps++,
      child: const Icon(Icons.skip_next),
    ))));

    final semantics = tester.getSemantics(find.bySemanticsLabel('下一首'));
    expect(semantics.hasFlag(SemanticsFlag.isButton), isTrue);
    await tester.tap(find.bySemanticsLabel('下一首'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 2);
  });

  testWidgets('play button reports toggled state and activates from Space',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: PlayPulseButton(
      isPlaying: true,
      onPressed: () => taps++,
    ))));

    final semantics = tester.getSemantics(find.bySemanticsLabel('暂停'));
    expect(semantics.hasFlag(SemanticsFlag.isButton), isTrue);
    expect(semantics.hasFlag(SemanticsFlag.isToggled), isTrue);
    await tester.tap(find.bySemanticsLabel('暂停'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(taps, 2);
  });
}
