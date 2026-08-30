import 'package:flutter/material.dart';
import 'tokens.dart';

/// The « balisage » (Swiss trail-waymark) visual identity: explicit
/// ColorSchemes — no `ColorScheme.fromSeed` — so the exact tokens from the
/// task brief land unchanged (fromSeed would derive its own tonal palette
/// and drift from them). Never white-on-yellow: [AppColors.ink] is used as
/// on-primary in both brightnesses.
class AppTheme {
  AppTheme._();

  static final ThemeData light = _build(_lightScheme);
  static final ThemeData dark = _build(_darkScheme);

  static const _lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: AppColors.yellow,
    onPrimary: AppColors.ink,
    primaryContainer: AppColors.yellowPaleLight,
    onPrimaryContainer: AppColors.ink,
    secondary: AppColors.hydro,
    onSecondary: AppColors.paper,
    secondaryContainer: AppColors.hydroPaleLight,
    onSecondaryContainer: AppColors.ink,
    error: AppColors.errorLight,
    onError: AppColors.onErrorLight,
    errorContainer: AppColors.errorContainerLight,
    onErrorContainer: AppColors.onErrorContainerLight,
    surface: AppColors.paper,
    onSurface: AppColors.ink,
    outline: Color(0xFFC9CCC2),
    outlineVariant: Color(0xFFE1E3D9),
  );

  static const _darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: AppColors.darkYellow,
    onPrimary: AppColors.ink,
    primaryContainer: AppColors.yellowPaleDark,
    onPrimaryContainer: AppColors.paper,
    secondary: AppColors.hydro,
    onSecondary: AppColors.paper,
    secondaryContainer: AppColors.hydroPaleDark,
    onSecondaryContainer: AppColors.paper,
    error: AppColors.errorDark,
    onError: AppColors.onErrorDark,
    errorContainer: AppColors.errorContainerDark,
    onErrorContainer: AppColors.onErrorContainerDark,
    surface: AppColors.darkSurface,
    onSurface: AppColors.paper,
    outline: Color(0xFF4A564E),
    outlineVariant: Color(0xFF33413A),
  );

  static ThemeData _build(ColorScheme scheme) {
    final onSurface = scheme.onSurface;
    TextStyle display(double size, FontWeight weight) => TextStyle(
        fontFamily: AppFonts.display,
        fontWeight: weight,
        fontSize: size,
        color: onSurface);
    TextStyle body(double size, FontWeight weight) => TextStyle(
        fontFamily: AppFonts.body,
        fontWeight: weight,
        fontSize: size,
        color: onSurface);
    TextStyle mono(double size, FontWeight weight, double tracking) =>
        TextStyle(
            fontFamily: AppFonts.mono,
            fontWeight: weight,
            fontSize: size,
            letterSpacing: tracking,
            color: onSurface);

    final textTheme = TextTheme(
      // Display: gros chiffres distance/durée, titres d'écrans.
      displayLarge: display(57, FontWeight.w700),
      displayMedium: display(45, FontWeight.w700),
      displaySmall: display(36, FontWeight.w600),
      headlineLarge: display(32, FontWeight.w600),
      headlineMedium: display(28, FontWeight.w600),
      headlineSmall: display(24, FontWeight.w600),
      // Body/UI: Schibsted Grotesk.
      titleLarge: body(22, FontWeight.w600),
      titleMedium: body(16, FontWeight.w600),
      titleSmall: body(14, FontWeight.w600),
      bodyLarge: body(16, FontWeight.w400),
      bodyMedium: body(14, FontWeight.w400),
      bodySmall: body(12, FontWeight.w400),
      // Labels/eyebrows: IBM Plex Mono, tight tracked capitals — margins of
      // a topo map. Callers wanting the "petites capitales" look should
      // render the text itself in upper case.
      labelLarge: mono(14, FontWeight.w500, 0.5),
      labelMedium: mono(12, FontWeight.w500, 0.8),
      labelSmall: mono(11, FontWeight.w500, 1.0),
    );

    final base = ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      textTheme: textTheme,
      fontFamily: AppFonts.body,
    );

    return base.copyWith(
      cardTheme: base.cardTheme.copyWith(
        color: scheme.surface,
        elevation: 1,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.card)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: mono(16, FontWeight.w500, 0.5),
          shape: const StadiumBorder(),
          padding:
              const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: 16),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: mono(16, FontWeight.w500, 0.5),
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface,
          shape: const StadiumBorder(),
        ),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadii.stadium),
          borderSide: BorderSide.none,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.primaryContainer,
        labelTextStyle: WidgetStateProperty.resolveWith((states) => mono(
            11,
            states.contains(WidgetState.selected)
                ? FontWeight.w600
                : FontWeight.w500,
            0.8)),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: display(22, FontWeight.w600),
      ),
    );
  }
}
