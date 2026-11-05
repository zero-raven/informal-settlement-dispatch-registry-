// Design System for Dispatcher App
// Professional dark theme per user preferences: #0f1115 bg, #2ec4b6 teal accent

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class DSColors {
  // Core brand colors
  static const Color primary = Color(0xFF2EC4B6); // Teal accent
  static const Color primaryLight = Color(0xFF5FE4D6);
  static const Color primaryDark = Color(0xFF1AA896);
  static const Color primaryContainer = Color(0xFF0D4A44);

  // Surface colors (elevation-based)
  static const Color surface0 = Color(0xFF0F1115); // Base background
  static const Color surface1 = Color(0xFF15181E); // Card surface
  static const Color surface2 = Color(0xFF1C2028); // Elevated surface
  static const Color surface3 = Color(0xFF242933); // Highest elevation

  // Semantic colors
  static const Color success = Color(0xFF2ECC71);
  static const Color successContainer = Color(0xFF0A3D1E);
  static const Color warning = Color(0xFFF39C12);
  static const Color warningContainer = Color(0xFF4A3300);
  static const Color error = Color(0xFFE74C3C);
  static const Color errorContainer = Color(0xFF4A1111);
  static const Color info = Color(0xFF3498DB);

  // Text colors
  static const Color textPrimary = Color(0xFFF5F5F5);
  static const Color textSecondary = Color(0xFFB0B3B8);
  static const Color textTertiary = Color(0xFF888C91);
  static const Color textInverse = Color(0xFF0F1115);
  static const Color textOnPrimary = Color(0xFF0F1115);

  // Border & divider
  static const Color border = Color(0xFF2A2E36);
  static const Color divider = Color(0xFF1E222A);
  static const Color focusRing = Color(0xFF2EC4B6);

  // Status colors
  static const Color online = Color(0xFF2ECC71);
  static const Color offline = Color(0xFF888C91);
  static const Color pending = Color(0xFFF39C12);
  static const Color critical = Color(0xFFE74C3C);

  // Gradients
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [primary, primaryLight],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient surfaceGradient = LinearGradient(
    colors: [surface1, surface2],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient heroGradient = LinearGradient(
    colors: [Color(0xFF0F1115), Color(0xFF1A1E28), Color(0xFF0F1115)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );
}

class DSTypography {
  // Use Google Fonts - Inter for UI (available), JetBrains Mono for code
  static TextStyle _inter(TextStyle style) => GoogleFonts.inter(textStyle: style);
  static TextStyle _jetbrainsMono(TextStyle style) => GoogleFonts.jetBrainsMono(textStyle: style);
  static const String fontFamily = 'Inter';

  // Display styles
  static TextStyle get displayLarge => _inter(const TextStyle(
    fontSize: 57,
    fontWeight: FontWeight.w700,
    height: 1.12,
    letterSpacing: -0.25,
    color: DSColors.textPrimary,
  ));

  static TextStyle get displayMedium => _inter(const TextStyle(
    fontSize: 45,
    fontWeight: FontWeight.w700,
    height: 1.16,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  static TextStyle get displaySmall => _inter(const TextStyle(
    fontSize: 36,
    fontWeight: FontWeight.w600,
    height: 1.22,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  // Headline styles
  static TextStyle get headlineLarge => _inter(const TextStyle(
    fontSize: 32,
    fontWeight: FontWeight.w600,
    height: 1.25,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  static TextStyle get headlineMedium => _inter(const TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w600,
    height: 1.29,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  static TextStyle get headlineSmall => _inter(const TextStyle(
    fontSize: 24,
    fontWeight: FontWeight.w600,
    height: 1.33,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  // Title styles
  static TextStyle get titleLarge => _inter(const TextStyle(
    fontSize: 22,
    fontWeight: FontWeight.w600,
    height: 1.27,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  static TextStyle get titleMedium => _inter(const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w500,
    height: 1.5,
    letterSpacing: 0.15,
    color: DSColors.textPrimary,
  ));

  static TextStyle get titleSmall => _inter(const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.43,
    letterSpacing: 0.1,
    color: DSColors.textPrimary,
  ));

  // Body styles
  static TextStyle get bodyLarge => _inter(const TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w400,
    height: 1.5,
    letterSpacing: 0.5,
    color: DSColors.textPrimary,
  ));

  static TextStyle get bodyMedium => _inter(const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
    letterSpacing: 0.25,
    color: DSColors.textSecondary,
  ));

  static TextStyle get bodySmall => _inter(const TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0.4,
    color: DSColors.textTertiary,
  ));

  // Label styles
  static TextStyle get labelLarge => _inter(const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w500,
    height: 1.43,
    letterSpacing: 0.1,
    color: DSColors.textPrimary,
  ));

  static TextStyle get labelMedium => _inter(const TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w500,
    height: 1.33,
    letterSpacing: 0.5,
    color: DSColors.textSecondary,
  ));

  static TextStyle get labelSmall => _inter(const TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w500,
    height: 1.45,
    letterSpacing: 0.5,
    color: DSColors.textTertiary,
  ));

  // Code/mono styles
  static TextStyle get codeMedium => _jetbrainsMono(const TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w400,
    height: 1.43,
    letterSpacing: 0,
    color: DSColors.textPrimary,
  ));

  static TextStyle get codeSmall => _jetbrainsMono(const TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w400,
    height: 1.33,
    letterSpacing: 0,
    color: DSColors.textSecondary,
  ));
}

class DSSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
  static const double xxxl = 64;

  // Component specific
  static const double cardPadding = 20;
  static const double screenPadding = 24;
  static const double sectionGap = 32;
  static const double componentGap = 16;
}

class DSBorderRadius {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double full = 9999;
}

class DSElevation {
  static const double level0 = 0;
  static const double level1 = 2;
  static const double level2 = 8;
  static const double level3 = 16;
  static const double level4 = 24;
  static const double level5 = 32;
}

class DSDurations {
  static const Duration instant = Duration(milliseconds: 0);
  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 350);
  static const Duration slower = Duration(milliseconds: 500);
}

class DSEasing {
  static const Curve standard = Curves.easeInOutCubic;
  static const Curve emphasized = Curves.easeOutCubic;
  static const Curve decelerate = Curves.easeOutQuart;
  static const Curve accelerate = Curves.easeInQuart;
}

class DSShadows {
  static List<BoxShadow> level1 = [
    BoxShadow(
      color: Colors.black.withOpacity( 0.3),
      blurRadius: 4,
      offset: const Offset(0, 1),
    ),
    BoxShadow(
      color: Colors.black.withOpacity( 0.15),
      blurRadius: 2,
      offset: const Offset(0, -1),
    ),
  ];

  static List<BoxShadow> level2 = [
    BoxShadow(
      color: Colors.black.withOpacity( 0.4),
      blurRadius: 16,
      offset: const Offset(0, 4),
    ),
    BoxShadow(
      color: Colors.black.withOpacity( 0.2),
      blurRadius: 8,
      offset: const Offset(0, -2),
    ),
  ];

  static List<BoxShadow> level3 = [
    BoxShadow(
      color: Colors.black.withOpacity( 0.5),
      blurRadius: 32,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: Colors.black.withOpacity( 0.25),
      blurRadius: 16,
      offset: const Offset(0, -4),
    ),
  ];

  static List<BoxShadow> glowPrimary = [
    BoxShadow(
      color: DSColors.primary.withOpacity( 0.3),
      blurRadius: 20,
      offset: const Offset(0, 0),
    ),
    BoxShadow(
      color: DSColors.primary.withOpacity( 0.15),
      blurRadius: 40,
      offset: const Offset(0, 0),
    ),
  ];
}

extension DSColorExtension on Color {
  Color withAlphaValue(double alpha) => withOpacity(alpha);
}

class DSTheme {
  static ThemeData get lightTheme => _buildTheme(Brightness.light);
  static ThemeData get darkTheme => _buildTheme(Brightness.dark);

  static ThemeData _buildTheme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;

    final ColorScheme colorScheme = ColorScheme(
      brightness: brightness,
      primary: DSColors.primary,
      onPrimary: DSColors.textOnPrimary,
      primaryContainer: DSColors.primaryContainer,
      onPrimaryContainer: DSColors.textPrimary,
      secondary: DSColors.primaryLight,
      onSecondary: DSColors.textOnPrimary,
      secondaryContainer: DSColors.surface2,
      onSecondaryContainer: DSColors.textPrimary,
      tertiary: DSColors.info,
      onTertiary: Colors.white,
      tertiaryContainer: DSColors.info.withOpacity( 0.2),
      onTertiaryContainer: DSColors.info,
      error: DSColors.error,
      onError: Colors.white,
      errorContainer: DSColors.errorContainer,
      onErrorContainer: DSColors.error,
      surface: isDark ? DSColors.surface1 : Colors.white,
      onSurface: isDark ? DSColors.textPrimary : Colors.black,
      surfaceContainerHighest: isDark ? DSColors.surface3 : Colors.grey[100]!,
      onSurfaceVariant: isDark ? DSColors.textSecondary : Colors.grey[700]!,
      outline: isDark ? DSColors.border : Colors.grey[400]!,
      outlineVariant: isDark ? DSColors.divider : Colors.grey[300]!,
      shadow: Colors.black,
      scrim: Colors.black.withOpacity( 0.5),
      inverseSurface: isDark ? Colors.white : DSColors.surface0,
      onInverseSurface: isDark ? Colors.black : DSColors.textPrimary,
      inversePrimary: DSColors.primaryDark,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      fontFamily: DSTypography.fontFamily,
      scaffoldBackgroundColor: isDark ? DSColors.surface0 : Colors.white,
      canvasColor: isDark ? DSColors.surface1 : Colors.white,

      // AppBar theme
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? DSColors.surface1 : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: DSElevation.level1,
        centerTitle: true,
        titleTextStyle: DSTypography.titleLarge.copyWith(
          color: isDark ? DSColors.textPrimary : Colors.black,
        ),
        iconTheme: IconThemeData(
          color: isDark ? DSColors.textPrimary : Colors.black,
          size: 24,
        ),
        actionsIconTheme: IconThemeData(
          color: isDark ? DSColors.textSecondary : Colors.grey[700],
          size: 24,
        ),
        shape: const Border(
          bottom: BorderSide(color: DSColors.divider, width: 0.5),
        ),
      ),

      // Card theme
      cardTheme: CardTheme(
        color: isDark ? DSColors.surface1 : Colors.white,
        elevation: DSElevation.level1,
        shadowColor: Colors.black.withOpacity( 0.3),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.lg),
          side: BorderSide(
            color: isDark ? DSColors.border : Colors.grey[300]!,
            width: 0.5,
          ),
        ),
        margin: const EdgeInsets.all(DSSpacing.sm),
      ),

      // Elevated button theme
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: DSColors.primary,
          foregroundColor: DSColors.textOnPrimary,
          elevation: 0,
          shadowColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(
            horizontal: DSSpacing.lg,
            vertical: DSSpacing.md,
          ),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          textStyle: DSTypography.labelLarge.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ).copyWith(
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return DSColors.primaryDark.withOpacity( 0.3);
            }
            if (states.contains(WidgetState.hovered)) {
              return DSColors.primaryLight.withOpacity( 0.2);
            }
            if (states.contains(WidgetState.focused)) {
              return DSColors.focusRing.withOpacity( 0.2);
            }
            return Colors.transparent;
          }),
        ),
      ),

      // Filled button theme
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: DSColors.primary,
          foregroundColor: DSColors.textOnPrimary,
          padding: const EdgeInsets.symmetric(
            horizontal: DSSpacing.lg,
            vertical: DSSpacing.md,
          ),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          textStyle: DSTypography.labelLarge.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ),
      ),

      // Outlined button theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: DSColors.primary,
          side: const BorderSide(color: DSColors.primary, width: 1.5),
          padding: const EdgeInsets.symmetric(
            horizontal: DSSpacing.lg,
            vertical: DSSpacing.md,
          ),
          minimumSize: const Size(double.infinity, 52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          textStyle: DSTypography.labelLarge.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: 0.2,
          ),
        ).copyWith(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return DSColors.primary.withOpacity( 0.15);
            }
            if (states.contains(WidgetState.hovered)) {
              return DSColors.primary.withOpacity( 0.08);
            }
            if (states.contains(WidgetState.focused)) {
              return DSColors.focusRing.withOpacity( 0.15);
            }
            return Colors.transparent;
          }),
        ),
      ),

      // Text button theme
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: DSColors.primary,
          padding: const EdgeInsets.symmetric(
            horizontal: DSSpacing.md,
            vertical: DSSpacing.sm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DSBorderRadius.md),
          ),
          textStyle: DSTypography.labelLarge.copyWith(
            fontWeight: FontWeight.w500,
          ),
        ),
      ),

      // Input decoration theme
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? DSColors.surface0 : Colors.grey[50],
        contentPadding: const EdgeInsets.symmetric(
          horizontal: DSSpacing.md,
          vertical: DSSpacing.md,
        ),
        labelStyle: DSTypography.bodyMedium.copyWith(
          color: DSColors.textTertiary,
        ),
        hintStyle: DSTypography.bodyMedium.copyWith(
          color: DSColors.textTertiary.withOpacity( 0.6),
        ),
        floatingLabelStyle: DSTypography.bodyMedium.copyWith(
          color: DSColors.primary,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: BorderSide(
            color: isDark ? DSColors.border : Colors.grey[300]!,
            width: 1,
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: BorderSide(
            color: isDark ? DSColors.border : Colors.grey[300]!,
            width: 1,
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: const BorderSide(color: DSColors.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: const BorderSide(color: DSColors.error, width: 1),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: const BorderSide(color: DSColors.error, width: 2),
        ),
        disabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
          borderSide: BorderSide(
            color: isDark ? DSColors.border.withOpacity( 0.5) : Colors.grey[200]!,
            width: 1,
          ),
        ),
        errorStyle: DSTypography.bodySmall.copyWith(color: DSColors.error),
        helperStyle: DSTypography.bodySmall.copyWith(color: DSColors.textTertiary),
        prefixIconColor: DSColors.textTertiary,
        suffixIconColor: DSColors.textTertiary,
      ),

      // Text theme
      textTheme: TextTheme(
        displayLarge: DSTypography.displayLarge,
        displayMedium: DSTypography.displayMedium,
        displaySmall: DSTypography.displaySmall,
        headlineLarge: DSTypography.headlineLarge,
        headlineMedium: DSTypography.headlineMedium,
        headlineSmall: DSTypography.headlineSmall,
        titleLarge: DSTypography.titleLarge,
        titleMedium: DSTypography.titleMedium,
        titleSmall: DSTypography.titleSmall,
        bodyLarge: DSTypography.bodyLarge,
        bodyMedium: DSTypography.bodyMedium,
        bodySmall: DSTypography.bodySmall,
        labelLarge: DSTypography.labelLarge,
        labelMedium: DSTypography.labelMedium,
        labelSmall: DSTypography.labelSmall,
      ).apply(
        bodyColor: isDark ? DSColors.textPrimary : Colors.black,
        displayColor: isDark ? DSColors.textPrimary : Colors.black,
      ),

      // Divider theme
      dividerTheme: DividerThemeData(
        color: isDark ? DSColors.divider : Colors.grey[200],
        thickness: 0.5,
        space: 1,
        indent: DSSpacing.md,
        endIndent: DSSpacing.md,
      ),

      // List tile theme
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: DSSpacing.md,
          vertical: DSSpacing.xs,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
        ),
        tileColor: Colors.transparent,
        selectedTileColor: DSColors.primary.withOpacity( 0.1),
        iconColor: DSColors.textSecondary,
        textColor: isDark ? DSColors.textPrimary : Colors.black,
        titleTextStyle: DSTypography.bodyLarge,
        subtitleTextStyle: DSTypography.bodyMedium,
        leadingAndTrailingTextStyle: DSTypography.bodyMedium,
      ),

      // Chip theme
      chipTheme: ChipThemeData(
        backgroundColor: isDark ? DSColors.surface2 : Colors.grey[100],
        disabledColor: isDark ? DSColors.surface2.withOpacity( 0.5) : Colors.grey[200],
        selectedColor: DSColors.primary.withOpacity( 0.15),
        secondarySelectedColor: DSColors.primary,
        padding: const EdgeInsets.symmetric(
          horizontal: DSSpacing.md,
          vertical: DSSpacing.xs,
        ),
        labelStyle: DSTypography.labelMedium,
        secondaryLabelStyle: DSTypography.labelMedium.copyWith(
          color: DSColors.textOnPrimary,
        ),
        brightness: isDark ? Brightness.dark : Brightness.light,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.full),
          side: BorderSide(
            color: isDark ? DSColors.border : Colors.grey[300]!,
            width: 0.5,
          ),
        ),
        side: BorderSide(
          color: isDark ? DSColors.border : Colors.grey[300]!,
          width: 0.5,
        ),
      ),

      // Bottom navigation bar theme
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: isDark ? DSColors.surface1 : Colors.white,
        elevation: DSElevation.level3,
        selectedItemColor: DSColors.primary,
        unselectedItemColor: DSColors.textTertiary,
        selectedLabelStyle: DSTypography.labelSmall.copyWith(
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: DSTypography.labelSmall,
        type: BottomNavigationBarType.fixed,
        showSelectedLabels: true,
        showUnselectedLabels: true,
        landscapeLayout: BottomNavigationBarLandscapeLayout.centered,
      ),

      // Navigation bar theme (Material 3)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? DSColors.surface1 : Colors.white,
        elevation: DSElevation.level3,
        height: 72,
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return DSTypography.labelSmall.copyWith(
              fontWeight: FontWeight.w600,
              color: DSColors.primary,
            );
          }
          return DSTypography.labelSmall.copyWith(
            color: DSColors.textTertiary,
          );
        }),
        indicatorColor: DSColors.primary.withOpacity( 0.12),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(
              color: DSColors.primary,
              size: 24,
            );
          }
          return IconThemeData(
            color: DSColors.textTertiary,
            size: 24,
          );
        }),
      ),

      // Tab bar theme
      tabBarTheme: TabBarTheme(
        labelColor: DSColors.primary,
        unselectedLabelColor: DSColors.textTertiary,
        indicatorColor: DSColors.primary,
        indicatorSize: TabBarIndicatorSize.label,
        dividerColor: Colors.transparent,
        labelStyle: DSTypography.labelLarge.copyWith(fontWeight: FontWeight.w600),
        unselectedLabelStyle: DSTypography.labelLarge,
        overlayColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.pressed)) {
            return DSColors.primary.withOpacity(0.1);
          }
          if (states.contains(WidgetState.hovered)) {
            return DSColors.primary.withOpacity(0.05);
          }
          return Colors.transparent;
        }),
      ),

      // Dialog theme
      dialogTheme: DialogTheme(
        backgroundColor: isDark ? DSColors.surface1 : Colors.white,
        elevation: DSElevation.level4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.xl),
        ),
        titleTextStyle: DSTypography.headlineSmall.copyWith(
          color: isDark ? DSColors.textPrimary : Colors.black,
        ),
        contentTextStyle: DSTypography.bodyMedium.copyWith(
          color: isDark ? DSColors.textSecondary : Colors.grey[700],
        ),
      ),

      // Snack bar theme
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? DSColors.surface2 : Colors.grey[900],
        contentTextStyle: DSTypography.bodyMedium.copyWith(
          color: DSColors.textPrimary,
        ),
        actionTextColor: DSColors.primary,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
        ),
        elevation: DSElevation.level3,
      ),

      // Progress indicator theme
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: DSColors.primary,
        linearTrackColor: DSColors.primary.withOpacity( 0.2),
        circularTrackColor: DSColors.primary.withOpacity( 0.2),
      ),

      // Slider theme
      sliderTheme: SliderThemeData(
        activeTrackColor: DSColors.primary,
        inactiveTrackColor: DSColors.primary.withOpacity( 0.2),
        thumbColor: DSColors.primary,
        overlayColor: DSColors.primary.withOpacity( 0.15),
        valueIndicatorColor: DSColors.primary,
        valueIndicatorTextStyle: DSTypography.labelSmall.copyWith(
          color: DSColors.textOnPrimary,
        ),
        trackHeight: 4,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      ),

      // Switch theme
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return DSColors.primary;
          }
          return isDark ? DSColors.textTertiary : Colors.grey[400];
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return DSColors.primary.withOpacity( 0.4);
          }
          return isDark ? DSColors.border : Colors.grey[300];
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return Colors.transparent;
          }
          return isDark ? DSColors.border : Colors.grey[300];
        }),
      ),

      // Checkbox theme
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return DSColors.primary;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(DSColors.textOnPrimary),
        side: BorderSide(
          color: isDark ? DSColors.border : Colors.grey[400]!,
          width: 1.5,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.sm),
        ),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),

      // Radio theme
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return DSColors.primary;
          }
          return isDark ? DSColors.textTertiary : Colors.grey[400];
        }),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
      ),

      // Floating action button theme
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: DSColors.primary,
        foregroundColor: DSColors.textOnPrimary,
        elevation: DSElevation.level3,
        focusElevation: DSElevation.level4,
        hoverElevation: DSElevation.level4,
        highlightElevation: DSElevation.level4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.full),
        ),
        extendedTextStyle: DSTypography.labelLarge.copyWith(
          fontWeight: FontWeight.w600,
        ),
      ),

      // Expansion tile theme
      expansionTileTheme: ExpansionTileThemeData(
        backgroundColor: isDark ? DSColors.surface1 : Colors.white,
        collapsedBackgroundColor: Colors.transparent,
        textColor: isDark ? DSColors.textPrimary : Colors.black,
        collapsedTextColor: isDark ? DSColors.textPrimary : Colors.black,
        iconColor: DSColors.textSecondary,
        collapsedIconColor: DSColors.textTertiary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
        ),
        collapsedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
        ),
      ),

      // Popup menu theme
      popupMenuTheme: PopupMenuThemeData(
        color: isDark ? DSColors.surface1 : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: DSElevation.level3,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DSBorderRadius.md),
        ),
        textStyle: DSTypography.bodyMedium.copyWith(
          color: isDark ? DSColors.textPrimary : Colors.black,
        ),
      ),

      // Tooltip theme
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? DSColors.surface3 : Colors.grey[900],
          borderRadius: BorderRadius.circular(DSBorderRadius.sm),
          border: Border(
            top: BorderSide(
              color: isDark ? DSColors.border : Colors.grey[700]!,
              width: 0.5,
            ),
            bottom: BorderSide(
              color: isDark ? DSColors.border : Colors.grey[700]!,
              width: 0.5,
            ),
            left: BorderSide(
              color: isDark ? DSColors.border : Colors.grey[700]!,
              width: 0.5,
            ),
            right: BorderSide(
              color: isDark ? DSColors.border : Colors.grey[700]!,
              width: 0.5,
            ),
          ),
        ),
        textStyle: DSTypography.bodySmall.copyWith(
          color: DSColors.textPrimary,
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: DSSpacing.md,
          vertical: DSSpacing.sm,
        ),
        verticalOffset: 8,
        preferBelow: true,
      ),

      // Page transitions theme
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}