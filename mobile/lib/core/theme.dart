import 'package:flutter/material.dart';

class AppColors {
  // BitMesh signature colors (same in both themes)
  static const Color mint     = Color(0xFF00B894);
  static const Color mintDark = Color(0xFF00A87D);
  static const Color mintSoft = Color(0xFF00D9A6);
  static const Color blue     = Color(0xFF3B82F6);
  static const Color blueDark = Color(0xFF2563EB);
  static const Color amber    = Color(0xFFF59E0B);

  // ── Dark theme palette ──
  static const Color bg            = Color(0xFF080C14);
  static const Color surface       = Color(0xFF0F1520);
  static const Color card          = Color(0xFF151D2B);
  static const Color cardHover     = Color(0xFF1A2436);
  static const Color divider       = Color(0xFF1E2A3A);
  static const Color inputBg       = Color(0xFF111827);
  static const Color textPrimary   = Color(0xFFE8ECF1);
  static const Color textSecondary = Color(0xFF8B95A5);
  static const Color textMuted     = Color(0xFF4F5B6B);

  // ── Light theme palette ──
  static const Color lightBg            = Color(0xFFF4F6FA);
  static const Color lightSurface       = Color(0xFFFFFFFF);
  static const Color lightCard          = Color(0xFFFFFFFF);
  static const Color lightCardHover     = Color(0xFFF0F2F7);
  static const Color lightDivider       = Color(0xFFDDE2ED);
  static const Color lightInputBg       = Color(0xFFF0F2F7);
  static const Color lightTextPrimary   = Color(0xFF0D1117);
  static const Color lightTextSecondary = Color(0xFF5A6478);
  static const Color lightTextMuted     = Color(0xFF9BA5B5);

  // Status — shared
  static const Color online    = Color(0xFF00B894);
  static const Color offline   = Color(0xFF4F5B6B);
  static const Color delivered = Color(0xFF00B894);
  static const Color error     = Color(0xFFEF4444);
}

class AppTheme {
  static ThemeData get darkTheme => _build(
        brightness: Brightness.dark,
        bg: AppColors.bg,
        surface: AppColors.surface,
        card: AppColors.card,
        divider: AppColors.divider,
        inputBg: AppColors.inputBg,
        textPrimary: AppColors.textPrimary,
        textSecondary: AppColors.textSecondary,
        textMuted: AppColors.textMuted,
      );

  static ThemeData get lightTheme => _build(
        brightness: Brightness.light,
        bg: AppColors.lightBg,
        surface: AppColors.lightSurface,
        card: AppColors.lightCard,
        divider: AppColors.lightDivider,
        inputBg: AppColors.lightInputBg,
        textPrimary: AppColors.lightTextPrimary,
        textSecondary: AppColors.lightTextSecondary,
        textMuted: AppColors.lightTextMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color bg,
    required Color surface,
    required Color card,
    required Color divider,
    required Color inputBg,
    required Color textPrimary,
    required Color textSecondary,
    required Color textMuted,
  }) {
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      primaryColor: AppColors.mint,
      textTheme: TextTheme(
        displayLarge:  TextStyle(color: textPrimary),
        displayMedium: TextStyle(color: textPrimary),
        displaySmall:  TextStyle(color: textPrimary),
        headlineLarge: TextStyle(color: textPrimary),
        headlineMedium:TextStyle(color: textPrimary),
        headlineSmall: TextStyle(color: textPrimary),
        titleLarge:    TextStyle(color: textPrimary),
        titleMedium:   TextStyle(color: textPrimary),
        titleSmall:    TextStyle(color: textSecondary),
        bodyLarge:     TextStyle(color: textPrimary),
        bodyMedium:    TextStyle(color: textPrimary),
        bodySmall:     TextStyle(color: textSecondary),
        labelLarge:    TextStyle(color: textSecondary),
        labelMedium:   TextStyle(color: textSecondary),
        labelSmall:    TextStyle(color: textMuted),
      ),
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: AppColors.mint,
        onPrimary: brightness == Brightness.dark ? AppColors.bg : Colors.white,
        secondary: AppColors.blue,
        onSecondary: Colors.white,
        surface: surface,
        onSurface: textPrimary,
        error: AppColors.error,
        onError: Colors.white,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        iconTheme: IconThemeData(color: textSecondary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.mint.withAlpha(20),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.mint);
          }
          return IconThemeData(color: textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(color: AppColors.mint, fontSize: 11, fontWeight: FontWeight.w600);
          }
          return TextStyle(color: textMuted, fontSize: 11);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.mint,
        foregroundColor: brightness == Brightness.dark ? AppColors.bg : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: card,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBg,
        hintStyle: TextStyle(color: textMuted),
        labelStyle: TextStyle(color: textSecondary),
        prefixIconColor: textSecondary,
        suffixIconColor: textSecondary,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: divider.withAlpha(120)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: divider.withAlpha(120)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.mint, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.mint,
        inactiveTrackColor: divider,
        thumbColor: AppColors.mint,
        overlayColor: AppColors.mint.withAlpha(25),
        valueIndicatorColor: AppColors.mint,
        valueIndicatorTextStyle: TextStyle(
          color: brightness == Brightness.dark ? AppColors.bg : Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: card,
        contentTextStyle: TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: AppColors.mint),
      ),
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 0.5,
        space: 0,
      ),
      useMaterial3: true,
    );
  }
}
