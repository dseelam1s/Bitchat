import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  // ── Accent ────────────────────────────────────────────────────────────────
  static const Color primary       = Color(0xFFEBDE73);  // sunny yellow — light mode accent
  static const Color primaryDark   = Color(0xFFFFFFFF);  // white — dark mode

  // ── Legacy aliases (existing screens compile unchanged) ───────────────────
  static const Color teal      = primary;
  static const Color tealLight = Color(0xFF333333);
  static const Color tealSoft  = Color(0xFF333333);
  static const Color mint      = primary;
  static const Color mintDark  = Color(0xFF333333);
  static const Color mintSoft  = Color(0xFF333333);
  static const Color blue      = primary;
  static const Color blueDark  = Color(0xFF333333);
  static const Color amber     = Color(0xFFFF9500);
  static const Color amberSoft = Color(0xFFFFB340);

  // ── Light theme ───────────────────────────────────────────────────────────
  static const Color bg            = Color(0xFFFFFFFF);  // pure cold white
  static const Color surface       = Color(0xFFFAFAFA);
  static const Color card          = Color(0xFFF5F5F5);
  static const Color cardHover     = Color(0xFFEFEFEF);
  static const Color divider       = Color(0xFFE8E8E8);
  static const Color inputBg       = Color(0xFFF2F2F2);
  static const Color textPrimary   = Color(0xFF000000);
  static const Color textSecondary = Color(0xFF333333);
  static const Color textMuted     = Color(0xFF8E8E8E);

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

  // ── Dark theme (iOS-style pure black) ─────────────────────────────────────
  static const Color darkBg            = Color(0xFF000000);
  static const Color darkSurface       = Color(0xFF1C1C1E);
  static const Color darkCard          = Color(0xFF2C2C2E);
  static const Color darkCardHover     = Color(0xFF3A3A3C);
  static const Color darkDivider       = Color(0xFF38383A);
  static const Color darkInputBg       = Color(0xFF1C1C1E);
  static const Color darkTextPrimary   = Color(0xFFFFFFFF);
  static const Color darkTextSecondary = Color(0xFFAEAEB2);
  static const Color darkTextMuted     = Color(0xFF636366);

  // ── Status ────────────────────────────────────────────────────────────────
  static const Color online    = Color(0xFF34C759);  // iOS green
  static const Color offline   = Color(0xFF8E8E8E);
  static const Color delivered = primary;
  static const Color error     = Color(0xFFFF3B30);  // iOS red
  static const Color signal    = error;
  static const Color signalSoft = Color(0xFFFF6961);
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
        onPrimary: isDark ? Colors.black : Colors.white,
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
        indicatorColor: Colors.transparent,  // no pill
        height: 56,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: textPrimary, size: 24);
          }
          return IconThemeData(color: textMuted, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.inter(
              color: textPrimary,
              fontSize: 10,
              fontWeight: FontWeight.w600,
            );
          }
          return GoogleFonts.inter(color: textMuted, fontSize: 10);
        }),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: isDark ? Colors.black : Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
        valueIndicatorTextStyle: TextStyle(
          color: isDark ? Colors.black : Colors.white,
          fontWeight: FontWeight.w600,
        ),
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
