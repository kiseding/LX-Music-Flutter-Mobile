import 'package:flutter/material.dart';
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
}
