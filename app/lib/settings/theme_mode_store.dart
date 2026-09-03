/// Task 2l brief item 2 (owner: "ajoute un mode jour"): a manual override
/// for the app's day/night rendering — Système (platform brightness, the
/// only behavior before this task) / Jour (always light) / Nuit (always
/// dark) — persisted so it survives a cold start, same
/// `shared_preferences`-backed pattern as `game_layer_toggle_store.dart`'s
/// `GameLayerToggleStore`/`plan_mode.dart`'s `PlanModeStore`.
///
/// Deliberately reuses Flutter's own [ThemeMode] rather than a bespoke enum:
/// it already has exactly the three values this setting needs, is what
/// `MaterialApp.themeMode` (`main.dart`) consumes directly, and every screen
/// that renders theme-reactively (`map_screen.dart`'s style-URL choice,
/// `GameLayer`/`FogLayer`'s brightness-keyed paint) already reads
/// `Theme.of(context).brightness` — which Flutter itself resolves from
/// `themeMode` — so wiring this setting through `themeMode` is enough to
/// make ALL of that follow the manual choice too, with no separate
/// "resolved brightness" plumbing needed anywhere else. See
/// `theme_mode_provider.dart` for the live (no-restart) application.
library;

import 'package:flutter/material.dart' show ThemeMode;
import 'package:shared_preferences/shared_preferences.dart';

const kThemeModePrefsKey = 'theme_mode_preference';

/// "Système" — matches the app's behavior before this task.
const kThemeModeDefault = ThemeMode.system;

String encodeThemeMode(ThemeMode mode) => switch (mode) {
  ThemeMode.system => 'system',
  ThemeMode.light => 'light',
  ThemeMode.dark => 'dark',
};

/// Any unrecognised/missing value decodes to [kThemeModeDefault] — a
/// pure function, so this is exercised directly for a corrupted/foreign
/// pref value without needing `SharedPreferences` at all.
ThemeMode decodeThemeMode(String? value) => switch (value) {
  'light' => ThemeMode.light,
  'dark' => ThemeMode.dark,
  'system' => ThemeMode.system,
  _ => kThemeModeDefault,
};

class ThemeModeStore {
  Future<ThemeMode> load() async {
    final prefs = await SharedPreferences.getInstance();
    return decodeThemeMode(prefs.getString(kThemeModePrefsKey));
  }

  Future<void> save(ThemeMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kThemeModePrefsKey, encodeThemeMode(mode));
  }
}
