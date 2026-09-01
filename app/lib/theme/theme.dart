import 'package:flutter/material.dart';
import 'tokens.dart';

/// The « balisage » (Swiss trail-waymark) visual identity: explicit
/// ColorSchemes — no `ColorScheme.fromSeed` — so the exact tokens from the
/// task brief land unchanged (fromSeed would derive its own tonal palette
/// and drift from them). Never white-on-yellow: [AppColors.ink] is used as
/// on-primary in both brightnesses.
class AppTheme {
  AppTheme._();

  static final ThemeData light = _build(_lightScheme, AppColors.paper);
  static final ThemeData dark = _build(_darkScheme, AppColors.darkBg);

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

  /// [background] is the scaffold color: brief distinguishes it from
  /// [ColorScheme.surface] in dark mode only (fond `#12201A` vs. surfaces
  /// `#1C2B25` — cards/sheets/bars all read `scheme.surface` below, or fall
  /// back to it via ColorScheme's surfaceContainer* getters, so they stay
  /// on the lighter dark-surface tone while the scaffold itself sits on
  /// the darker background).
  static ThemeData _build(ColorScheme scheme, Color background) {
    final onSurface = scheme.onSurface;
    // Bricolage Grotesque and Schibsted Grotesk ship as single variable-font
    // assets (see pubspec.yaml) spanning the weights used here. `fontWeight`
    // alone only selects among *declared* per-weight font assets — with one
    // variable asset registered, Flutter renders it at its default instance
    // regardless of the requested weight, so anything above w400 came out
    // visually flat instead of bold. `FontVariation('wght', ...)` drives the
    // font's own weight axis; `fontWeight` is kept alongside it so a
    // fallback/synthesis path (e.g. if the asset were ever swapped for a
    // static font) still lands on a sane weight.
    List<FontVariation> wght(FontWeight weight) => [
      FontVariation('wght', weight.value.toDouble()),
    ];
    TextStyle display(double size, FontWeight weight) => TextStyle(
      fontFamily: AppFonts.display,
      fontWeight: weight,
      fontVariations: wght(weight),
      fontSize: size,
      color: onSurface,
    );
    TextStyle body(double size, FontWeight weight) => TextStyle(
      fontFamily: AppFonts.body,
      fontWeight: weight,
      fontVariations: wght(weight),
      fontSize: size,
      color: onSurface,
    );
    // IBM Plex Mono ships as separate static TTFs (Regular/Medium only, see
    // pubspec.yaml) — no variable-font axis, so no FontVariation here. Only
    // request weights the shipped statics actually provide.
    TextStyle mono(double size, FontWeight weight, double tracking) =>
        TextStyle(
          fontFamily: AppFonts.mono,
          fontWeight: weight,
          fontSize: size,
          letterSpacing: tracking,
          color: onSurface,
        );

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
      scaffoldBackgroundColor: background,
      textTheme: textTheme,
      fontFamily: AppFonts.body,
    );

    return base.copyWith(
      cardTheme: base.cardTheme.copyWith(
        color: scheme.surface,
        elevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.card),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          textStyle: mono(16, FontWeight.w500, 0.5),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 16,
          ),
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
        // Both states use w500: IBM Plex Mono only ships Regular/Medium
        // statics (see pubspec.yaml), so w600 isn't available — selection is
        // still conveyed by the indicator pill, not by a heavier weight.
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => mono(11, FontWeight.w500, 0.8),
        ),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        titleTextStyle: display(22, FontWeight.w600),
      ),
      // Default CircularProgressIndicator color is colorScheme.primary —
      // the saturated yellow reads at ~1.7:1 on paper (near-invisible).
      // onSurface is ink in light / paper in dark, both legible. Note
      // this does NOT reach RefreshIndicator (it reads colorScheme.primary
      // directly, not this theme extension), so every RefreshIndicator
      // call site must also pass `color: colorScheme.onSurface` itself.
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.onSurface,
      ),
    );
  }
}
