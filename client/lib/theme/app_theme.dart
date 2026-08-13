import 'package:flutter/material.dart';

enum AppThemeMode { dark, light }

/// AppColors.mode переключает ВСЕ геттеры ниже разом. Обновляется только
/// через ThemeStore.setMode (пишет в постоянное хранилище и уведомляет
/// ThemeStore.notifier — на него подписаны экраны, см. ThemeReactive).
/// Здесь — намеренно НЕ ValueNotifier сам по себе: AppColors.primary и
/// прочие поля читаются в сотнях мест по всему приложению как обычные
/// статические геттеры, без BuildContext под рукой, поэтому статическое
/// поле проще и переносится без изменений везде, где раньше был константный
/// цвет — просто убрать const в месте использования.
class AppColors {
  static AppThemeMode mode = AppThemeMode.dark;

  static Color get primary =>
      mode == AppThemeMode.dark ? _darkPrimary : _lightPrimary;
  static Color get primaryDark =>
      mode == AppThemeMode.dark ? _darkPrimaryDark : _lightPrimaryDark;
  static Color get background =>
      mode == AppThemeMode.dark ? _darkBackground : _lightBackground;
  static Color get surface =>
      mode == AppThemeMode.dark ? _darkSurface : _lightSurface;
  static Color get textPrimary =>
      mode == AppThemeMode.dark ? _darkTextPrimary : _lightTextPrimary;
  static Color get textMuted =>
      mode == AppThemeMode.dark ? _darkTextMuted : _lightTextMuted;

  static const Color _darkPrimary = Color(0xFF2AABEE);
  static const Color _darkPrimaryDark = Color(0xFF229ED9);
  static const Color _darkBackground = Color(0xFF17212B);
  static const Color _darkSurface = Color(0xFF242F3D);
  static const Color _darkTextPrimary = Colors.white;
  static const Color _darkTextMuted = Color(0xFF8E99A4);

  // Светлая тема — холодные светлые тона, тот же primary (голубой),
  // чтобы акцентный цвет узнавался в обеих темах.
  static const Color _lightPrimary = Color(0xFF2AABEE);
  static const Color _lightPrimaryDark = Color(0xFF1D8FC7);
  static const Color _lightBackground = Color(0xFFEEF2F7);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightTextPrimary = Color(0xFF17212B);
  static const Color _lightTextMuted = Color(0xFF6B7A88);
}

ThemeData buildAppTheme() {
  final isDark = AppColors.mode == AppThemeMode.dark;
  return ThemeData(
    brightness: isDark ? Brightness.dark : Brightness.light,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: isDark ? Brightness.dark : Brightness.light,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.textPrimary,
      elevation: 0,
      centerTitle: true,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      hintStyle: TextStyle(color: AppColors.textMuted),
    ),
    textTheme: TextTheme(
      bodyLarge: TextStyle(color: AppColors.textPrimary),
      bodyMedium: TextStyle(color: AppColors.textPrimary),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(double.infinity, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
    ),
  );
}
