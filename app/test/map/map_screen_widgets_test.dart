// Fix-round regression tests for the small map-screen sub-widgets that were
// promoted from private to public specifically so they could be pumped in
// isolation — MapScreen itself owns a real MapLibreMapController (a
// platform view) and cannot be widget-tested at all, but these Card/FAB
// widgets are plain Flutter and need no map underneath them.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/map_screen.dart';
import 'package:randomwalk/map/plan_mode.dart';
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
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: const Scaffold(body: NavArrivedCard()),
        ),
      );

      final diamond = tester.widget<WaymarkDiamond>(
        find.byType(WaymarkDiamond),
      );
      expect(diamond.color, isNot(equals(AppTheme.dark.colorScheme.surface)));
      // Locks in the actual root cause: raw AppColors.ink WAS exactly the
      // dark surface color, which is why the widget must use a
      // theme-resolved color instead.
      expect(AppColors.ink, equals(AppTheme.dark.colorScheme.surface));
    });

    testWidgets('glyph color is not the light card background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: const Scaffold(body: NavArrivedCard()),
        ),
      );

      final diamond = tester.widget<WaymarkDiamond>(
        find.byType(WaymarkDiamond),
      );
      expect(diamond.color, isNot(equals(AppTheme.light.colorScheme.surface)));
    });
  });

  group('RecenterButton — FAB glyph contrast', () {
    // The default Material 3 FloatingActionButton (no floatingActionButtonTheme
    // override in this app) paints on colorScheme.primaryContainer — raw ink
    // read at ~1.5:1 against dark's yellowPaleDark primaryContainer.
    testWidgets('glyph color is not the dark FAB background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark,
          home: Scaffold(body: RecenterButton(onPressed: () {})),
        ),
      );

      final diamond = tester.widget<WaymarkDiamond>(
        find.byType(WaymarkDiamond),
      );
      expect(
        diamond.color,
        isNot(equals(AppTheme.dark.colorScheme.primaryContainer)),
      );
      expect(
        diamond.color,
        equals(AppTheme.dark.colorScheme.onPrimaryContainer),
      );
    });

    testWidgets('glyph color is not the light FAB background', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(body: RecenterButton(onPressed: () {})),
        ),
      );

      final diamond = tester.widget<WaymarkDiamond>(
        find.byType(WaymarkDiamond),
      );
      expect(
        diamond.color,
        isNot(equals(AppTheme.light.colorScheme.primaryContainer)),
      );
      expect(
        diamond.color,
        equals(AppTheme.light.colorScheme.onPrimaryContainer),
      );
    });
  });

  group('StatsBanner — narrow-phone overflow', () {
    Future<void> pumpAt360(WidgetTester tester, Widget banner) async {
      await tester.binding.setSurfaceSize(const Size(360, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: banner),
          ),
        ),
      );
    }

    testWidgets(
      'distance + duration + remaining + Terminer fit a 360dp phone with '
      'long values',
      (tester) async {
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
      },
    );

    testWidgets('still fits with the arrived (emphasized Terminer) style', (
      tester,
    ) async {
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

  group('MapAttribution — task-8 point 7', () {
    testWidgets('shows the OpenFreeMap/OpenStreetMap credit text', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapAttribution())),
      );

      expect(find.text(kMapAttribution), findsOneWidget);
    });

    testWidgets('renders semi-transparent, not fully opaque', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: MapAttribution())),
      );

      final text = tester.widget<Text>(find.text(kMapAttribution));
      final alpha = text.style?.color?.a;
      expect(alpha, isNotNull);
      expect(alpha, lessThan(1.0));
    });
  });

  group(
    'PlanModeSegmentedButton — task 7: 4-segment narrow-phone overflow',
    () {
      // A plain SegmentedButton lays its segments out like a Row with no
      // wrap/shrink/scroll of its own — four French labels ("Itinéraire",
      // "Distance", "Durée", "Explorer") are wide enough that a bare
      // SegmentedButton overflows a narrow phone's width and throws a real
      // `RenderFlex overflowed` exception. PlanModeSegmentedButton wraps it in
      // a horizontally-scrolling row specifically to avoid that — this group
      // pins the fix at the two widths StatsBanner's own narrow-phone group
      // already treats as the floor worth guarding (320dp: the narrowest
      // common Android width; 360dp: the common baseline).
      Future<void> pumpAt(
        WidgetTester tester,
        double width,
        PlanMode mode,
      ) async {
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light,
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(16),
                child: PlanModeSegmentedButton(
                  selected: mode,
                  onChanged: (_) {},
                ),
              ),
            ),
          ),
        );
      }

      testWidgets('all 4 segments fit a 320dp phone with no overflow', (
        tester,
      ) async {
        await pumpAt(tester, 320, PlanMode.loop);
        expect(tester.takeException(), isNull);
      });

      testWidgets('all 4 segments fit a 360dp phone with no overflow', (
        tester,
      ) async {
        await pumpAt(tester, 360, PlanMode.loop);
        expect(tester.takeException(), isNull);
      });

      testWidgets('every mode label is present and reachable', (tester) async {
        await pumpAt(tester, 320, PlanMode.explore);
        for (final label in ['Itinéraire', 'Distance', 'Durée', 'Explorer']) {
          expect(find.text(label), findsOneWidget);
        }
      });

      testWidgets(
        'tapping a segment reports the tapped mode (scrolled into view '
        'first — this is exactly the 320/360dp reality the wrapper fixes: '
        'Explorer sits off-screen until scrolled to)',
        (tester) async {
          PlanMode? tapped;
          await tester.binding.setSurfaceSize(const Size(360, 800));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.light,
              home: Scaffold(
                body: PlanModeSegmentedButton(
                  selected: PlanMode.loop,
                  onChanged: (m) => tapped = m,
                ),
              ),
            ),
          );

          await tester.ensureVisible(find.text('Explorer'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Explorer'));
          await tester.pumpAndSettle();
          expect(tapped, PlanMode.explore);
        },
      );

      testWidgets('null onChanged disables the selector (recording guard)', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: PlanModeSegmentedButton(
                selected: PlanMode.loop,
                onChanged: null,
              ),
            ),
          ),
        );

        final button = tester.widget<SegmentedButton<PlanMode>>(
          find.byType(SegmentedButton<PlanMode>),
        );
        expect(button.onSelectionChanged, isNull);
      });
    },
  );
}
