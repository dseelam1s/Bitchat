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

/// Depth, gradients and motion — the tokens that separate a designed app
/// from a themed one. Flat Material surfaces read as unfinished; these give
/// elevation without the muddy grey drop-shadows of stock Material.
class AppDepth {
  /// Coloured ambient shadow for cards/avatars on light grounds.
  static List<BoxShadow> soft(Color tint, {double opacity = 0.13}) => [
        BoxShadow(
          color: tint.withValues(alpha: opacity),
          blurRadius: 22,
          offset: const Offset(0, 8),
          spreadRadius: -4,
        ),
      ];

  /// Pressed/raised state for primary actions — tighter, stronger.
  static List<BoxShadow> lift(Color tint) => [
        BoxShadow(
          color: tint.withValues(alpha: 0.32),
          blurRadius: 18,
          offset: const Offset(0, 6),
          spreadRadius: -2,
        ),
      ];

  /// Hero gradient for the brand mark / primary surfaces.
  static const LinearGradient cobalt = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4B63FF), AppColors.primary],
  );

  /// Presence gradient — the warm one, for anything "near you".
  static const LinearGradient ember = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [AppColors.coralSoft, AppColors.coral],
  );

  /// Shared motion language: everything eases the same way.
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration base = Duration(milliseconds: 320);
  static const Curve curve = Curves.easeOutCubic;
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

    // Plus Jakarta Sans: geometric-humanist, tight display tracking —
    // the "designed, not defaulted" face. One family everywhere.
    final baseTextTheme =
        GoogleFonts.plusJakartaSansTextTheme().copyWith(
      displayLarge:   TextStyle(color: textPrimary, fontWeight: FontWeight.w800, letterSpacing: -1.0),
      displayMedium:  TextStyle(color: textPrimary, fontWeight: FontWeight.w800, letterSpacing: -0.8),
      displaySmall:   TextStyle(color: textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.6),
      headlineLarge:  TextStyle(color: textPrimary, fontWeight: FontWeight.w800, letterSpacing: -0.7),
      headlineMedium: TextStyle(color: textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.5),
      headlineSmall:  TextStyle(color: textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge:     TextStyle(color: textPrimary, fontWeight: FontWeight.w700, letterSpacing: -0.3),
      titleMedium:    TextStyle(color: textPrimary, fontWeight: FontWeight.w600, letterSpacing: -0.2),
      titleSmall:     TextStyle(color: textSecondary, fontWeight: FontWeight.w600),
      bodyLarge:      TextStyle(color: textPrimary, height: 1.45),
      bodyMedium:     TextStyle(color: textPrimary, height: 1.45),
      bodySmall:      TextStyle(color: textSecondary, height: 1.4),
      labelLarge:     TextStyle(color: textSecondary, fontWeight: FontWeight.w600),
      labelMedium:    TextStyle(color: textSecondary, fontWeight: FontWeight.w600),
      labelSmall:     TextStyle(color: textMuted, fontWeight: FontWeight.w600, letterSpacing: 0.3),
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
        titleTextStyle: GoogleFonts.plusJakartaSans(
          color: textPrimary,
          fontSize: 21,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.7,
        ),
        iconTheme: IconThemeData(color: textPrimary, size: 23),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: bg,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        // A soft tinted pill behind the active tab — the single detail that
        // separates a designed nav bar from the Material default.
        indicatorColor: primaryColor.withAlpha(isDark ? 46 : 26),
        indicatorShape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: primaryColor, size: 24);
          }
          return IconThemeData(color: textMuted, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return GoogleFonts.plusJakartaSans(
                color: primaryColor, fontSize: 11, fontWeight: FontWeight.w700);
          }
          return GoogleFonts.plusJakartaSans(
              color: textMuted, fontSize: 11, fontWeight: FontWeight.w600);
        }),
      ),
      // ── Buttons: tall, pill-shaped, confident type ───────────────────────
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          minimumSize: const Size(0, 52),
          padding: const EdgeInsets.symmetric(horizontal: 24),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          minimumSize: const Size(0, 52),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: textPrimary,
          minimumSize: const Size(0, 52),
          side: BorderSide(color: divider, width: 1.5),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        ),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? AppColors.darkCard : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titleTextStyle: GoogleFonts.plusJakartaSans(
          color: textPrimary,
          fontSize: 19,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.4,
        ),
      ),
      // Bottom sheets carry a lot of this app's UI — give them real radius.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: isDark ? AppColors.darkCard : Colors.white,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: isDark ? AppColors.darkCard : Colors.white,
        elevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        dragHandleColor: divider,
        dragHandleSize: const Size(40, 4),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: inputBg,
        hintStyle: GoogleFonts.plusJakartaSans(
            color: textMuted, fontSize: 15, fontWeight: FontWeight.w500),
        labelStyle: TextStyle(color: textSecondary),
        prefixIconColor: textMuted,
        suffixIconColor: textMuted,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: primaryColor, width: 1.8),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
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
        backgroundColor: isDark ? AppColors.darkCardHover : AppColors.textPrimary,
        contentTextStyle: GoogleFonts.plusJakartaSans(
          color: isDark ? AppColors.darkTextPrimary : Colors.white,
          fontSize: 13.5,
          fontWeight: FontWeight.w600,
        ),
        actionTextColor: AppColors.coralSoft,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        behavior: SnackBarBehavior.floating,
        insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryColor,
          textStyle: GoogleFonts.plusJakartaSans(
              fontSize: 14.5, fontWeight: FontWeight.w700),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: card,
        side: BorderSide.none,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        labelStyle: GoogleFonts.plusJakartaSans(
            fontSize: 12.5, fontWeight: FontWeight.w600, color: textSecondary),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 15.5, fontWeight: FontWeight.w600, color: textPrimary),
        subtitleTextStyle: GoogleFonts.plusJakartaSans(
            fontSize: 13, fontWeight: FontWeight.w500, color: textMuted),
      ),
      // Smooth, modern page transitions instead of the dated Android slide.
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      }),
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
