import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Brand palette ─────────────────────────────────────────────────────────
  // Primary: Electric Indigo — vivid, digital, alive — not corporate blue
  static const Color primary       = Color(0xFF4F6FFF);  // electric blue-indigo
  static const Color primaryBright = Color(0xFF6B88FF);  // hover / lighter
  static const Color primarySoft   = Color(0xFF3352CC);  // pressed / deeper

  // Danger/Alert: Signal Red — calls, errors, alerts
  static const Color signal     = Color(0xFFFF4455);
  static const Color signalSoft = Color(0xFFFF6B78);

  // Legacy aliases — existing screens continue to compile unchanged
  static const Color teal      = primary;
  static const Color tealLight = primaryBright;
  static const Color tealSoft  = primaryBright;
  static const Color mint      = primary;
  static const Color mintDark  = primaryBright;
  static const Color mintSoft  = primaryBright;
  static const Color blue      = primary;
  static const Color blueDark  = primaryBright;
  static const Color amber     = signal;      // badge / highlight fallback
  static const Color amberSoft = signalSoft;

  // ── Dark theme palette ────────────────────────────────────────────────────
  // Deep navy — not pure black, has blue depth so primary color glows in it
  static const Color bg            = Color(0xFF0C1120);  // midnight navy
  static const Color surface       = Color(0xFF131B2E);  // dark panel
  static const Color card          = Color(0xFF192035);  // lifted card
  static const Color cardHover     = Color(0xFF1F2840);
  static const Color divider       = Color(0xFF263051);
  static const Color inputBg       = Color(0xFF101626);
  static const Color textPrimary   = Color(0xFFEEF0FF);  // blue-white — feels in-universe
  static const Color textSecondary = Color(0xFF7B8DB0);
  static const Color textMuted     = Color(0xFF3D4D6E);

  // ── Light theme palette ───────────────────────────────────────────────────
  static const Color lightBg            = Color(0xFFF4F6FF);  // slight blue tint
  static const Color lightSurface       = Color(0xFFFFFFFF);
  static const Color lightCard          = Color(0xFFFFFFFF);
  static const Color lightCardHover     = Color(0xFFECEFFF);
  static const Color lightDivider       = Color(0xFFD6DAEE);
  static const Color lightInputBg       = Color(0xFFECEFFF);
  static const Color lightTextPrimary   = Color(0xFF0C1120);
  static const Color lightTextSecondary = Color(0xFF4A5A80);
  static const Color lightTextMuted     = Color(0xFF8A9BBF);

  // ── Status — shared ───────────────────────────────────────────────────────
  static const Color online    = Color(0xFF22C55E);   // green — reachable
  static const Color offline   = Color(0xFF3D4D6E);   // muted — not reachable
  static const Color delivered = primary;
  static const Color error     = signal;
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
    final baseTextTheme = GoogleFonts.interTextTheme().copyWith(
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
    );

    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      primaryColor: AppColors.primary,
      textTheme: baseTextTheme,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: AppColors.primary,
        onPrimary: Colors.white,
        secondary: AppColors.signal,
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
        titleTextStyle: GoogleFonts.inter(
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
        indicatorColor: AppColors.primary.withAlpha(30),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: AppColors.primary);
          }
          return IconThemeData(color: textMuted);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.inter(
              color: AppColors.primary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            );
          }
          return GoogleFonts.inter(color: textMuted, fontSize: 11);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
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
        titleTextStyle: GoogleFonts.inter(
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
          borderSide: BorderSide(color: divider.withAlpha(140)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: divider.withAlpha(140)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: divider,
        thumbColor: AppColors.primary,
        overlayColor: AppColors.primary.withAlpha(25),
        valueIndicatorColor: AppColors.primary,
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
        style: TextButton.styleFrom(foregroundColor: AppColors.primary),
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
