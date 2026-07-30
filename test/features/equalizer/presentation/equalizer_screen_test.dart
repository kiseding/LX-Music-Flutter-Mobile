import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lx_music_flutter/core/theme/app_theme.dart';
import 'package:lx_music_flutter/features/equalizer/presentation/equalizer_screen.dart';

void main() {
  testWidgets('shows the equalizer control panel in light and dark themes',
      (tester) async {
    for (final theme in [AppTheme.lightTheme(), AppTheme.darkTheme()]) {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: theme, home: const EqualizerScreen()),
        ),
      );

      expect(find.text('均衡器状态'), findsOneWidget);
      expect(find.text('当前预设'), findsOneWidget);
      expect(find.text('10 段频率调节'), findsOneWidget);
      expect(find.text('低频'), findsOneWidget);
      expect(find.text('高频'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    }
  });

  testWidgets('enabled frequency band exposes adjustable dB semantics',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: EqualizerScreen()),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pump();
    final band = find.bySemanticsLabel('32 Hz');
    final node = tester.getSemantics(band);
    final before = node.value;

    node.owner!.performAction(node.id, SemanticsAction.increase);
    await tester.pump();

    expect(before, '0 dB');
    expect(tester.getSemantics(band).value, '+1 dB');
    expect(tester.getSemantics(band).hasFlag(SemanticsFlag.isSlider), isTrue);
  });
}
