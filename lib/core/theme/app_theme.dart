import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';

abstract final class AppTheme {
  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      canvasColor: AppColors.bg,
      dialogBackgroundColor: AppColors.surfaceDark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.amber,
        onPrimary: Color(0xFF000000),
        primaryContainer: AppColors.amberDim,
        secondary: AppColors.amber,
        surface: AppColors.surfaceDark,
        onSurface: AppColors.textPrimary,
        onSurfaceVariant: AppColors.textSecondary,
        outline: AppColors.border,
        error: AppColors.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.bg,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.bg,
        selectedItemColor: AppColors.amber,
        unselectedItemColor: AppColors.textMuted,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceDark,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.textSecondary,
        textColor: AppColors.textPrimary,
        subtitleTextStyle: TextStyle(color: AppColors.textMuted, fontSize: 12),
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecondary),
      primaryIconTheme: const IconThemeData(color: AppColors.textPrimary),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: AppColors.textPrimary),
        bodyMedium: TextStyle(color: AppColors.textPrimary),
        bodySmall: TextStyle(color: AppColors.textMuted),
        titleLarge: TextStyle(color: AppColors.textPrimary),
        titleMedium: TextStyle(color: AppColors.textPrimary),
        titleSmall: TextStyle(color: AppColors.textSecondary),
        labelLarge: TextStyle(color: AppColors.textPrimary),
        labelMedium: TextStyle(color: AppColors.textSecondary),
        labelSmall: TextStyle(color: AppColors.textMuted),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hintStyle: const TextStyle(color: AppColors.textMuted),
        labelStyle: const TextStyle(color: AppColors.textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.surfaceDark,
        textStyle: TextStyle(color: AppColors.textPrimary),
        // 弹出无缩放/淡入动效（按钮侧再设 popUpAnimationStyle.noAnimation）
        position: PopupMenuPosition.under,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.surfaceDark,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: AppColors.surfaceVariant,
        contentTextStyle: TextStyle(color: AppColors.textPrimary),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.amber,
        unselectedLabelColor: AppColors.textSecondary,
        indicatorColor: AppColors.amber,
        dividerColor: Colors.transparent,
        dividerHeight: 0,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.amber
                : AppColors.textMuted),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.amberDim
                : AppColors.surface2),
      ),
      dividerTheme:
          const DividerThemeData(color: AppColors.border, thickness: 0.5),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: AppColors.amber),
    );
  }

  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: AppColors.lightBg,
      canvasColor: AppColors.lightBg,
      dialogBackgroundColor: AppColors.lightSurface,
      colorScheme: const ColorScheme.light(
        primary: AppColors.lightAccent,
        onPrimary: Color(0xFFFFFFFF),
        primaryContainer: Color(0x331DB954),
        secondary: AppColors.lightAccent,
        surface: AppColors.lightSurface,
        onSurface: AppColors.lightText,
        onSurfaceVariant: AppColors.lightTextSecondary,
        outline: AppColors.lightBorder,
        error: AppColors.error,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightBg,
        foregroundColor: AppColors.lightText,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.lightBg,
        selectedItemColor: AppColors.lightAccent,
        unselectedItemColor: AppColors.lightTextMuted,
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.lightBorder),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: AppColors.lightTextSecondary,
        textColor: AppColors.lightText,
        subtitleTextStyle:
            TextStyle(color: AppColors.lightTextMuted, fontSize: 12),
      ),
      iconTheme: const IconThemeData(color: AppColors.lightTextSecondary),
      primaryIconTheme: const IconThemeData(color: AppColors.lightText),
      textTheme: const TextTheme(
        bodyLarge: TextStyle(color: AppColors.lightText),
        bodyMedium: TextStyle(color: AppColors.lightText),
        bodySmall: TextStyle(color: AppColors.lightTextMuted),
        titleLarge: TextStyle(color: AppColors.lightText),
        titleMedium: TextStyle(color: AppColors.lightText),
        titleSmall: TextStyle(color: AppColors.lightTextSecondary),
        labelLarge: TextStyle(color: AppColors.lightText),
        labelMedium: TextStyle(color: AppColors.lightTextSecondary),
        labelSmall: TextStyle(color: AppColors.lightTextMuted),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.lightSurface,
        hintStyle: const TextStyle(color: AppColors.lightTextMuted),
        labelStyle: const TextStyle(color: AppColors.lightTextSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      popupMenuTheme: const PopupMenuThemeData(
        color: AppColors.lightSurface,
        textStyle: TextStyle(color: AppColors.lightText),
        position: PopupMenuPosition.under,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: AppColors.lightSurface,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xFF3A3A3C),
        contentTextStyle: TextStyle(color: Colors.white),
      ),
      tabBarTheme: const TabBarThemeData(
        labelColor: AppColors.lightAccent,
        unselectedLabelColor: AppColors.lightTextSecondary,
        indicatorColor: AppColors.lightAccent,
        dividerColor: Colors.transparent,
        dividerHeight: 0,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? AppColors.lightAccent
                : AppColors.lightTextMuted),
        trackColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected)
                ? const Color(0x331DB954)
                : const Color(0x1A000000)),
      ),
      dividerTheme:
          const DividerThemeData(color: AppColors.lightBorder, thickness: 0.5),
      progressIndicatorTheme:
          const ProgressIndicatorThemeData(color: AppColors.lightAccent),
    );
  }
}
