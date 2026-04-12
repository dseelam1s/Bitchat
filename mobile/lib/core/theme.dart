import 'package:flutter/material.dart';

class AppColors {
  // ── Brand palette ─────────────────────────────────────────────────────────
  // Primary: Deep Teal — trust, depth, calm
  static const Color teal      = Color(0xFF1A6B6B);
  static const Color tealLight = Color(0xFF218F8F);
  static const Color tealSoft  = Color(0xFF2AADAD);

  // Accent: Warm Amber — human warmth, a signal in the dark
  static const Color amber     = Color(0xFFE89B2D);
  static const Color amberSoft = Color(0xFFF0B455);

  // Legacy aliases so existing code that references AppColors.mint / AppColors.blue
  // continues to compile without changes.
  static const Color mint     = teal;
  static const Color mintDark = tealLight;
  static const Color mintSoft = tealSoft;
  static const Color blue     = teal;
  static const Color blueDark = tealLight;

  // ── Dark theme palette (default) ──────────────────────────────────────────
  // Night sky — signals are most visible in the dark
  static const Color bg            = Color(0xFF0F1923);  // near black, deep slate
  static const Color surface       = Color(0xFF1C2B35);  // dark slate
  static const Color card          = Color(0xFF1F303C);  // lifted surface
  static const Color cardHover     = Color(0xFF253743);
  static const Color divider       = Color(0xFF263545);
  static const Color inputBg       = Color(0xFF17262F);
  static const Color textPrimary   = Color(0xFFEDF2F4);  // soft white
  static const Color textSecondary = Color(0xFF8BA3AE);
  static const Color textMuted     = Color(0xFF4F6472);

  // ── Light theme palette ───────────────────────────────────────────────────
  static const Color lightBg            = Color(0xFFF0F4F6);
  static const Color lightSurface       = Color(0xFFFFFFFF);
  static const Color lightCard          = Color(0xFFFFFFFF);
  static const Color lightCardHover     = Color(0xFFE8EFF3);
  static const Color lightDivider       = Color(0xFFD0DCE3);
  static const Color lightInputBg       = Color(0xFFE8EFF3);
  static const Color lightTextPrimary   = Color(0xFF0D1B22);
  static const Color lightTextSecondary = Color(0xFF4F6472);
  static const Color lightTextMuted     = Color(0xFF8BA3AE);

  // ── Status — shared ───────────────────────────────────────────────────────
  static const Color online    = Color(0xFF2AADAD);   // tealSoft — reachable
  static const Color offline   = Color(0xFF4F6472);   // muted — not reachable
  static const Color delivered = Color(0xFF2AADAD);
  static const Color error     = Color(0xFFE05252);
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
      primaryColor: AppColors.teal,
      fontFamily: 'Inter',
      textTheme: TextTheme(
        displayLarge:   TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
        displayMedium:  TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
        displaySmall:   TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        headlineLarge:  TextStyle(color: textPrimary, fontWeight: FontWeight.w700),
        headlineMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        headlineSmall:  TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        titleLarge:     TextStyle(color: textPrimary, fontWeight: FontWeight.w600),
        titleMedium:    TextStyle(color: textPrimary, fontWeight: FontWeight.w500),
        titleSmall:     TextStyle(color: textSecondary, fontWeight: FontWeight.w500),
        bodyLarge:      TextStyle(color: textPrimary),
        bodyMedium:     TextStyle(color: textPrimary),
        bodySmall:      TextStyle(color: textSecondary),
        labelLarge:     TextStyle(color: textSecondary),
        labelMedium:    TextStyle(color: textSecondary),
        labelSmall:     TextStyle(color: textMuted),
      ),
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: AppColors.teal,
        onPrimary: Colors.white,
        secondary: AppColors.amber,
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
          fontFamily: 'Inter',
        ),
        iconTheme: IconThemeData(color: textSecondary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppColors.teal.withAlpha(25),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.teal);
          }
          return IconThemeData(color: textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const TextStyle(
              color: AppColors.teal,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              fontFamily: 'Inter',
            );
          }
          return TextStyle(color: textMuted, fontSize: 11, fontFamily: 'Inter');
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.teal,
        foregroundColor: Colors.white,
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
          fontFamily: 'Inter',
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
          borderSide: const BorderSide(color: AppColors.teal, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.teal,
        inactiveTrackColor: divider,
        thumbColor: AppColors.teal,
        overlayColor: AppColors.teal.withAlpha(25),
        valueIndicatorColor: AppColors.teal,
        valueIndicatorTextStyle: const TextStyle(
          color: Colors.white,
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
        style: TextButton.styleFrom(foregroundColor: AppColors.teal),
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
