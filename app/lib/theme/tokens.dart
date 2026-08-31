import 'package:flutter/material.dart';

/// Design tokens for the « balisage » (Swiss trail-waymark) visual identity
/// (Task 12). Exact values are binding — see the task brief. Kept as a flat
/// set of constants so [theme.dart] and any widget needing a raw value
/// (e.g. the MapLibre route line, drawn outside the widget tree) share one
/// source of truth instead of re-deriving colors from ColorScheme.
class AppColors {
  AppColors._();

  // Light palette.
  static const paper = Color(0xFFF7F8F4);
  static const ink = Color(0xFF1C2B25);
  static const yellow = Color(0xFFF5B800);
  static const hydro = Color(0xFF3D7A8C);

  // Dark palette.
  static const darkBg = Color(0xFF12201A);
  static const darkSurface = Color(0xFF1C2B25);
  static const darkYellow = Color(0xFFE6B800);

  // Pale tints derived from the accents, used for containers / selection
  // states (me-row highlight, NavigationBar indicator) so the saturated
  // yellow itself stays reserved for the handful of "spend it here" spots
  // named in the brief.
  static const yellowPaleLight = Color(0xFFFBEAB0);
  static const yellowPaleDark = Color(0xFF4A3F14);
  static const hydroPaleLight = Color(0xFFD6E8ED);
  static const hydroPaleDark = Color(0xFF23424B);

  /// The « Recalcul… » card shown on the map while a route-bound trip is
  /// off-route and the service is recalculating (Task 7 device-QA
  /// addendum). Deliberately outside the ink/paper/yellow/hydro identity —
  /// this is the one guidance state that needs to read as a warning at a
  /// glance rather than as more trip chrome, in both brightnesses.
  static const recalcOrange = Color(0xFFE8871E);

  // M3 baseline error palette (brief: "erreur M3 par défaut").
  static const errorLight = Color(0xFFB3261E);
  static const onErrorLight = Color(0xFFFFFFFF);
  static const errorContainerLight = Color(0xFFF9DEDC);
  static const onErrorContainerLight = Color(0xFF410E0B);
  static const errorDark = Color(0xFFF2B8B5);
  static const onErrorDark = Color(0xFF601410);
  static const errorContainerDark = Color(0xFF8C1D18);
  static const onErrorContainerDark = Color(0xFFF9DEDC);

  /// Route line colors: a wide ink "casing" drawn under a narrower yellow
  /// line on top (two addLine calls — see map_screen.dart).
  static const routeLineCasing = ink;
  static const routeLine = yellow;

  /// Hex-string forms of the two colors above, for MapLibre's `LineOptions`
  /// (String-typed, not `Color`) — kept alongside so the route line drawn
  /// on the map can't silently drift from these tokens.
  static const routeLineCasingHex = '#1C2B25';
  static const routeLineHex = '#F5B800';

  /// Hex form of [hydro], for the loop/duration candidate preview lines
  /// (task 6) drawn the same MapLibre `LineOptions` way as the route line
  /// above — the unselected candidates' color, at 40% opacity.
  static const hydroHex = '#3D7A8C';
}

class AppRadii {
  AppRadii._();
  static const card = 12.0;
  static const stadium = 999.0;
}

class AppSpacing {
  AppSpacing._();
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

/// Embedded font families (see pubspec.yaml `fonts:` — TTFs bundled under
/// assets/fonts/, not loaded at runtime via google_fonts).
class AppFonts {
  AppFonts._();
  static const display = 'Bricolage Grotesque';
  static const body = 'Schibsted Grotesk';
  static const mono = 'IBM Plex Mono';
}
