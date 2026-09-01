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
    // Brief: fond (scaffold) #12201A, surfaces (cards/sheets/bars) #1C2B25
    // — two distinct tones, not the same color.
    expect(theme.scaffoldBackgroundColor, const Color(0xFF12201A));
    expect(theme.scaffoldBackgroundColor, AppColors.darkBg);
    expect(theme.colorScheme.surface, const Color(0xFF1C2B25));
    expect(theme.colorScheme.surface, AppColors.darkSurface);
    expect(theme.cardTheme.color, AppColors.darkSurface);
    expect(theme.appBarTheme.backgroundColor, AppColors.darkSurface);
    expect(theme.navigationBarTheme.backgroundColor, AppColors.darkSurface);
  });

  test(
    'AppTheme.light scaffold and surfaces both read as paper (no split in light)',
    () {
      final theme = AppTheme.light;
      expect(theme.scaffoldBackgroundColor, AppColors.paper);
      expect(theme.colorScheme.surface, AppColors.paper);
      expect(theme.cardTheme.color, AppColors.paper);
    },
  );

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

    final buttonShape = theme.elevatedButtonTheme.style?.shape?.resolve(
      const <WidgetState>{},
    );
    expect(buttonShape, isA<StadiumBorder>());
  });

  test(
    'NavigationBar indicator is a pale yellow, not the saturated accent',
    () {
      final indicator = AppTheme.light.navigationBarTheme.indicatorColor;
      expect(indicator, isNot(const Color(0xFFF5B800)));
      expect(indicator, AppColors.yellowPaleLight);
    },
  );

  test(
    'progress indicators are legible (never the ~1.7:1 yellow-on-paper default)',
    () {
      expect(
        AppTheme.light.progressIndicatorTheme.color,
        isNot(const Color(0xFFF5B800)),
      );
      expect(AppTheme.light.progressIndicatorTheme.color, AppColors.ink);
      expect(
        AppTheme.dark.progressIndicatorTheme.color,
        isNot(const Color(0xFFE6B800)),
      );
      expect(AppTheme.dark.progressIndicatorTheme.color, AppColors.paper);
    },
  );

  test(
    'bold display/body styles carry a wght FontVariation (variable fonts need it to render bold)',
    () {
      final textTheme = AppTheme.light.textTheme;
      // w700 display style.
      expect(
        textTheme.displayLarge?.fontVariations,
        contains(const FontVariation('wght', 700)),
      );
      // w600 display style.
      expect(
        textTheme.headlineSmall?.fontVariations,
        contains(const FontVariation('wght', 600)),
      );
      // w600 body style.
      expect(
        textTheme.titleMedium?.fontVariations,
        contains(const FontVariation('wght', 600)),
      );
      // w400 body style still carries a matching variation (harmless, and
      // keeps the axis explicit rather than left to the font's own default).
      expect(
        textTheme.bodyMedium?.fontVariations,
        contains(const FontVariation('wght', 400)),
      );
    },
  );

  test(
    'IBM Plex Mono only uses weights the shipped statics provide (no FontVariation)',
    () {
      final textTheme = AppTheme.light.textTheme;
      expect(textTheme.labelSmall?.fontWeight, FontWeight.w500);
      expect(textTheme.labelSmall?.fontVariations, isNull);

      final navLabel = AppTheme.light.navigationBarTheme.labelTextStyle
          ?.resolve(const {WidgetState.selected});
      expect(navLabel?.fontWeight, FontWeight.w500);
    },
  );
}
