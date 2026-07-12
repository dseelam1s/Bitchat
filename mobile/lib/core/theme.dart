import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Accent (Beacon: cobalt hero, coral for presence/nearby) ──────────────
  static const Color primary     = Color(0xFF2544FF);  // cobalt — light mode
  static const Color primaryDark = Color(0xFF5C74FF);  // lifted cobalt — dark mode
  static const Color coral       = Color(0xFFFF5C39);  // nearby / BLE presence
  static const Color coralSoft   = Color(0xFFFF8A6E);

  // ── Legacy aliases (existing screens compile unchanged) ───────────────────
  static const Color teal      = primary;
  static const Color tealLight = primaryDark;
  static const Color tealSoft  = Color(0xFFD9E0FF);
  static const Color mint      = primary;
  static const Color mintDark  = primaryDark;
  static const Color mintSoft  = Color(0xFFD9E0FF);
  static const Color blue      = primary;
  static const Color blueDark  = primaryDark;
  static const Color amber     = Color(0xFFFF9500);
  static const Color amberSoft = Color(0xFFFFB340);

  // ── Light theme (white ground, lavender surfaces, navy ink) ──────────────
  static const Color bg            = Color(0xFFFFFFFF);
  static const Color surface       = Color(0xFFF4F6FF);
  static const Color card          = Color(0xFFEEF1FF);
  static const Color cardHover     = Color(0xFFE2E7FF);
  static const Color divider       = Color(0xFFE3E7F7);
  static const Color inputBg       = Color(0xFFEEF1FF);
  static const Color textPrimary   = Color(0xFF14183C);
  static const Color textSecondary = Color(0xFF3E4568);
  static const Color textMuted     = Color(0xFF9AA3C8);

  // Legacy light aliases
  static const Color lightBg            = bg;
  static const Color lightSurface       = surface;
  static const Color lightCard          = card;
  static const Color lightCardHover     = cardHover;
  static const Color lightDivider       = divider;
  static const Color lightInputBg       = inputBg;
  static const Color lightTextPrimary   = textPrimary;
  static const Color lightTextSecondary = textSecondary;
  static const Color lightTextMuted     = textMuted;

  // ── Dark theme (deep navy, not black — Beacon night) ─────────────────────
  static const Color darkBg            = Color(0xFF0B0E22);
  static const Color darkSurface       = Color(0xFF131735);
  static const Color darkCard          = Color(0xFF1B2045);
  static const Color darkCardHover     = Color(0xFF242A58);
  static const Color darkDivider       = Color(0xFF262C5A);
  static const Color darkInputBg       = Color(0xFF131735);
  static const Color darkTextPrimary   = Color(0xFFEEF1FF);
  static const Color darkTextSecondary = Color(0xFFB9C0E4);
  static const Color darkTextMuted     = Color(0xFF6E77A8);

  // ── Status ────────────────────────────────────────────────────────────────
  static const Color online     = Color(0xFF34C759);
  static const Color offline    = Color(0xFF9AA3C8);
  static const Color delivered  = primary;
  static const Color error      = Color(0xFFFF3B30);
  static const Color signal     = coral;      // BLE / nearby presence
  static const Color signalSoft = coralSoft;
}

class AppTheme {
  static ThemeData get lightTheme => _build(
        brightness: Brightness.light,
        primaryColor: AppColors.primary,
        bg: AppColors.bg,
        surface: AppColors.surface,
        card: AppColors.card,
        divider: AppColors.divider,
        inputBg: AppColors.inputBg,
        textPrimary: AppColors.textPrimary,
        textSecondary: AppColors.textSecondary,
        textMuted: AppColors.textMuted,
      );

  static ThemeData get darkTheme => _build(
        brightness: Brightness.dark,
        primaryColor: AppColors.primaryDark,
        bg: AppColors.darkBg,
        surface: AppColors.darkSurface,
        card: AppColors.darkCard,
        divider: AppColors.darkDivider,
        inputBg: AppColors.darkInputBg,
        textPrimary: AppColors.darkTextPrimary,
        textSecondary: AppColors.darkTextSecondary,
        textMuted: AppColors.darkTextMuted,
      );

  static ThemeData _build({
    required Brightness brightness,
    required Color primaryColor,
    required Color bg,
    required Color surface,
    required Color card,
    required Color divider,
    required Color inputBg,
    required Color textPrimary,
    required Color textSecondary,
    required Color textMuted,
  }) {
    final isDark = brightness == Brightness.dark;

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
      primaryColor: primaryColor,
      textTheme: baseTextTheme,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primaryColor,
        onPrimary: Colors.white,  // cobalt carries white text in both themes
        secondary: AppColors.error,
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
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: Colors.transparent,
        height: 56,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: primaryColor, size: 24);
          }
          return IconThemeData(color: textMuted, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.inter(color: primaryColor, fontSize: 10, fontWeight: FontWeight.w600);
          }
          return GoogleFonts.inter(color: textMuted, fontSize: 10);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      cardTheme: CardThemeData(
        color: card,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? AppColors.darkCard : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        titleTextStyle: GoogleFonts.inter(
          color: textPrimary,
          fontSize: 17,
          fontWeight: FontWeight.w600,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBg,
        hintStyle: TextStyle(color: textMuted, fontSize: 15),
        labelStyle: TextStyle(color: textSecondary),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: primaryColor, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primaryColor,
        inactiveTrackColor: divider,
        thumbColor: primaryColor,
        overlayColor: primaryColor.withAlpha(20),
        valueIndicatorColor: primaryColor,
        valueIndicatorTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? AppColors.darkCard : AppColors.textPrimary,
        contentTextStyle: TextStyle(
          color: isDark ? AppColors.darkTextPrimary : Colors.white,
          fontSize: 13,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        behavior: SnackBarBehavior.floating,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primaryColor),
      ),
      dividerTheme: DividerThemeData(
        color: divider,
        thickness: 0.5,
        space: 0,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return isDark ? AppColors.darkTextMuted : Colors.white;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return primaryColor;
          return isDark ? AppColors.darkDivider : AppColors.divider;
        }),
      ),
      useMaterial3: true,
    );
  }
}
