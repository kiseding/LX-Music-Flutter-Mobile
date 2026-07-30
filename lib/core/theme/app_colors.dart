import 'package:flutter/material.dart';

/// 深色：接近 iOS 纯黑；浅色：完整反色映射
abstract final class AppColors {
  // Dark — 比 #0A0A0A 更接近系统纯黑
  static const Color bg = Color(0xFF000000);
  static const Color surface = Color(0x14FFFFFF); // 8%
  static const Color surface2 = Color(0x1FFFFFFF); // 12%
  static const Color border = Color(0x1AFFFFFF);

  static const Color amber = Color(0xFF1ED760);
  static const Color amberDim = Color(0x331ED760);

  static const Color textPrimary = Color(0xFFF5F5F7);
  static const Color textSecondary = Color(0x99FFFFFF);
  static const Color textMuted = Color(0x66FFFFFF);

  static const Color white = Color(0xFFFFFFFF);
  static const Color black = Color(0xFF000000);

  static const Color success = Color(0xFF1ED760);
  static const Color error = Color(0xFFFF453A); // iOS system red
  static const Color info = Color(0xFF0A84FF);

  static const Color surfaceDark = Color(0xFF1C1C1E); // iOS secondary system bg
  static const Color surfaceVariant = Color(0xFF2C2C2E);

  // Light — 全面反色
  static const Color lightBg = Color(0xFFF2F2F7); // iOS grouped bg
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightSurface2 = Color(0xFFF2F2F7);
  static const Color lightText = Color(0xFF000000);
  static const Color lightTextSecondary = Color(0x993C3C43);
  static const Color lightTextMuted = Color(0x4D3C3C43);
  static const Color lightBorder = Color(0x1A3C3C43);
  static const Color lightAccent = Color(0xFF1DB954);
  static const Color lightMiniBar = Color(0xF2FFFFFF);
  static const Color lightSurfaceVariant = Color(0xFFE5E5EA);

  static bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

  static Color scaffold(BuildContext c) => isDark(c) ? bg : lightBg;
  static Color onScaffold(BuildContext c) => isDark(c) ? textPrimary : lightText;
  static Color secondaryText(BuildContext c) => isDark(c) ? textSecondary : lightTextSecondary;
  static Color mutedText(BuildContext c) => isDark(c) ? textMuted : lightTextMuted;
  static Color card(BuildContext c) => isDark(c) ? surfaceDark : lightSurface;
  static Color cardAlt(BuildContext c) => isDark(c) ? surfaceVariant : lightSurfaceVariant;
  static Color cardBorder(BuildContext c) => isDark(c) ? border : lightBorder;
  static Color fill(BuildContext c) => isDark(c) ? surface : const Color(0x14787880);
  static Color fill2(BuildContext c) => isDark(c) ? surface2 : const Color(0x29787880);
  static Color accentOf(BuildContext c) => Theme.of(c).colorScheme.primary;
  static Color miniBar(BuildContext c) => isDark(c) ? const Color(0xF21C1C1E) : lightMiniBar;
  static Color dialogBg(BuildContext c) => isDark(c) ? surfaceDark : lightSurface;
}
