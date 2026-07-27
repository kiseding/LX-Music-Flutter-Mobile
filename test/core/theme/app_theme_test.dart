import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lx_music_flutter/core/theme/app_theme.dart';
import 'package:lx_music_flutter/core/theme/app_colors.dart';

void main() {
  group('AppTheme', () {
    test('darkTheme returns valid ThemeData', () {
      final theme = AppTheme.darkTheme();
      expect(theme.brightness, Brightness.dark);
      expect(theme.useMaterial3, true);
    });

    test('darkTheme has correct scaffold background', () {
      final theme = AppTheme.darkTheme();
      expect(theme.scaffoldBackgroundColor, AppColors.bg);
    });

    test('darkTheme has correct primary color', () {
      final theme = AppTheme.darkTheme();
      expect(theme.colorScheme.primary, AppColors.amber);
    });

    test('light input fields keep a visible edge on white surfaces', () {
      final theme = AppTheme.lightTheme();
      final input = theme.inputDecorationTheme;
      expect(input.filled, isTrue);
      expect(input.fillColor, isNot(AppColors.lightSurface));
      final border = input.enabledBorder ?? input.border;
      expect(border, isA<OutlineInputBorder>());
      final side = (border as OutlineInputBorder).borderSide;
      expect(side.style, isNot(BorderStyle.none));
      expect(side.color.alpha, greaterThan(0));
    });
  });
}
