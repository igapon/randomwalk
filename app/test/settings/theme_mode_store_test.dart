import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/theme_mode_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('encodeThemeMode / decodeThemeMode', () {
    test('round-trips every ThemeMode value', () {
      for (final mode in ThemeMode.values) {
        expect(decodeThemeMode(encodeThemeMode(mode)), mode);
      }
    });

    test('decodeThemeMode defaults to Système for null/missing/corrupted '
        'values — never throws on a foreign or stale pref', () {
      expect(decodeThemeMode(null), ThemeMode.system);
      expect(decodeThemeMode(''), ThemeMode.system);
      expect(decodeThemeMode('nuit'), ThemeMode.system); // French label, not
      // the stored key — must not be mistaken for a valid value.
      expect(decodeThemeMode('DARK'), ThemeMode.system); // case-sensitive.
      expect(kThemeModeDefault, ThemeMode.system);
    });
  });

  group('ThemeModeStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('defaults to Système (today\'s only behavior before this task) '
        'when nothing was ever saved', () async {
      expect(await ThemeModeStore().load(), ThemeMode.system);
    });

    test('round-trips a saved Jour choice', () async {
      final store = ThemeModeStore();
      await store.save(ThemeMode.light);
      expect(await store.load(), ThemeMode.light);
    });

    test('round-trips a saved Nuit choice', () async {
      final store = ThemeModeStore();
      await store.save(ThemeMode.dark);
      expect(await store.load(), ThemeMode.dark);
    });

    test('round-trips switching back to Système explicitly (not just the '
        'unsaved default)', () async {
      final store = ThemeModeStore();
      await store.save(ThemeMode.dark);
      await store.save(ThemeMode.system);
      expect(await store.load(), ThemeMode.system);
    });

    test('persists across separate store instances (a cold start reads the '
        'same SharedPreferences-backed value)', () async {
      await ThemeModeStore().save(ThemeMode.dark);
      expect(await ThemeModeStore().load(), ThemeMode.dark);
    });
  });
}
