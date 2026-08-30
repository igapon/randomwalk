import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/theme/tokens.dart';

void main() {
  test('AppTheme.light builds and exposes the exact binding tokens', () {
    final theme = AppTheme.light;
    expect(theme.brightness, Brightness.light);
    expect(theme.colorScheme.primary, const Color(0xFFF5B800));
    // Never white-on-yellow: on-primary must be the ink color.
    expect(theme.colorScheme.onPrimary, AppColors.ink);
    expect(theme.colorScheme.onPrimary, const Color(0xFF1C2B25));
    expect(theme.colorScheme.surface, const Color(0xFFF7F8F4));
    expect(theme.colorScheme.secondary, const Color(0xFF3D7A8C));
  });

  test('AppTheme.dark builds and exposes the exact binding tokens', () {
    final theme = AppTheme.dark;
    expect(theme.brightness, Brightness.dark);
    expect(theme.colorScheme.primary, const Color(0xFFE6B800));
    // Dark mode keeps ink-on-yellow too — never white/paper on yellow.
    expect(theme.colorScheme.onPrimary, AppColors.ink);
    expect(theme.colorScheme.surface, const Color(0xFF1C2B25));
    expect(theme.scaffoldBackgroundColor, const Color(0xFF1C2B25));
  });

  test('text theme maps display/body/label to the three embedded families', () {
    final textTheme = AppTheme.light.textTheme;
    expect(textTheme.displayMedium?.fontFamily, AppFonts.display);
    expect(textTheme.headlineMedium?.fontFamily, AppFonts.display);
    expect(textTheme.bodyMedium?.fontFamily, AppFonts.body);
    expect(textTheme.titleMedium?.fontFamily, AppFonts.body);
    expect(textTheme.labelSmall?.fontFamily, AppFonts.mono);
    expect(textTheme.labelSmall!.letterSpacing!, greaterThan(0));
  });

  test('shapes: cards radius 12, buttons stadium', () {
    final theme = AppTheme.light;
    final cardShape = theme.cardTheme.shape as RoundedRectangleBorder;
    expect(cardShape.borderRadius, BorderRadius.circular(AppRadii.card));

    final buttonShape = theme.elevatedButtonTheme.style?.shape
        ?.resolve(const <WidgetState>{});
    expect(buttonShape, isA<StadiumBorder>());
  });

  test('NavigationBar indicator is a pale yellow, not the saturated accent', () {
    final indicator = AppTheme.light.navigationBarTheme.indicatorColor;
    expect(indicator, isNot(const Color(0xFFF5B800)));
    expect(indicator, AppColors.yellowPaleLight);
  });
}
