// Fix-round regression tests for the small map-screen sub-widgets that were
// promoted from private to public specifically so they could be pumped in
// isolation — MapScreen itself owns a real MapLibreMapController (a
// platform view) and cannot be widget-tested at all, but these Card/FAB
// widgets are plain Flutter and need no map underneath them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/map_screen.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/theme/tokens.dart';
import 'package:randomwalk/theme/waymark_glyph.dart';

void main() {
  group('NavArrivedCard — dark-mode glyph contrast', () {
    // The bug this guards against: AppColors.ink (#1C2B25) is byte-identical
    // to AppTheme.dark's ColorScheme.surface (also #1C2B25, see tokens.dart),
    // which is also the Card's own background — a raw-ink glyph on it is
    // literally invisible at 1.00:1 contrast.
    testWidgets('glyph color is not the dark card background', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: const Scaffold(body: NavArrivedCard()),
      ));

      final diamond = tester.widget<WaymarkDiamond>(find.byType(WaymarkDiamond));
      expect(diamond.color, isNot(equals(AppTheme.dark.colorScheme.surface)));
      // Locks in the actual root cause: raw AppColors.ink WAS exactly the
      // dark surface color, which is why the widget must use a
      // theme-resolved color instead.
      expect(AppColors.ink, equals(AppTheme.dark.colorScheme.surface));
    });

    testWidgets('glyph color is not the light card background', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: NavArrivedCard()),
      ));

      final diamond = tester.widget<WaymarkDiamond>(find.byType(WaymarkDiamond));
      expect(diamond.color, isNot(equals(AppTheme.light.colorScheme.surface)));
    });
  });

  group('RecenterButton — FAB glyph contrast', () {
    // The default Material 3 FloatingActionButton (no floatingActionButtonTheme
    // override in this app) paints on colorScheme.primaryContainer — raw ink
    // read at ~1.5:1 against dark's yellowPaleDark primaryContainer.
    testWidgets('glyph color is not the dark FAB background', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.dark,
        home: Scaffold(body: RecenterButton(onPressed: () {})),
      ));

      final diamond = tester.widget<WaymarkDiamond>(find.byType(WaymarkDiamond));
      expect(diamond.color, isNot(equals(AppTheme.dark.colorScheme.primaryContainer)));
      expect(diamond.color, equals(AppTheme.dark.colorScheme.onPrimaryContainer));
    });

    testWidgets('glyph color is not the light FAB background', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: RecenterButton(onPressed: () {})),
      ));

      final diamond = tester.widget<WaymarkDiamond>(find.byType(WaymarkDiamond));
      expect(diamond.color, isNot(equals(AppTheme.light.colorScheme.primaryContainer)));
      expect(diamond.color, equals(AppTheme.light.colorScheme.onPrimaryContainer));
    });
  });

  group('StatsBanner — narrow-phone overflow', () {
    Future<void> pumpAt360(WidgetTester tester, Widget banner) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: Padding(padding: const EdgeInsets.all(16), child: banner),
        ),
      ));
    }

    testWidgets(
        'distance + duration + remaining + Terminer fit a 360dp phone with '
        'long values', (tester) async {
      await pumpAt360(
        tester,
        StatsBanner(
          distanceKm: 12.34,
          elapsed: '1h 05',
          remaining: '12,4 km · ~2h 05',
          onStop: () {},
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('still fits with the arrived (emphasized Terminer) style',
        (tester) async {
      await pumpAt360(
        tester,
        StatsBanner(
          distanceKm: 12.34,
          elapsed: '1h 05',
          remaining: '12,4 km · ~2h 05',
          arrived: true,
          onStop: () {},
        ),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('fits with no remaining/ETA (free trip) too', (tester) async {
      await pumpAt360(
        tester,
        StatsBanner(distanceKm: 12.34, elapsed: '1h 05', onStop: () {}),
      );

      expect(tester.takeException(), isNull);
    });
  });
}
