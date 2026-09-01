// AdventureScreen itself owns a real MapLibreMapController (a platform
// view) and cannot be widget-tested at all — same story as MapScreen (see
// map_screen_widgets_test.dart's own doc comment). These are the pure
// pieces promoted to public widgets specifically so they can be pumped in
// isolation: the HUD, the empty-state banner, and the badges sheet, plus
// the pure `isAdventureEmpty` predicate that decides when the banner shows.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/adventure_screen.dart';
import 'package:randomwalk/game/reducers.dart';
import 'package:randomwalk/theme/theme.dart';

void main() {
  group('isAdventureEmpty', () {
    test('the zero GameState is empty', () {
      expect(isAdventureEmpty(const GameState()), isTrue);
    });

    test('any distance walked makes it non-empty', () {
      expect(isAdventureEmpty(const GameState(totalKm: 0.1)), isFalse);
    });

    test('any cell revealed makes it non-empty', () {
      expect(isAdventureEmpty(const GameState(cellsRevealed: 1)), isFalse);
    });

    test('any landmark visited makes it non-empty', () {
      expect(isAdventureEmpty(const GameState(landmarksVisited: 1)), isFalse);
    });

    test('coins/xp/energy alone (no ground activity) still reads as empty', () {
      // Not reachable through the real reducers without also touching one
      // of totalKm/cellsRevealed/landmarksVisited, but pinned here as the
      // predicate's actual contract.
      expect(isAdventureEmpty(const GameState(coins: 50, xp: 10)), isTrue);
    });
  });

  group('AdventureHud', () {
    Widget app(Widget child) =>
        MaterialApp(theme: AppTheme.light, home: Scaffold(body: child));

    testWidgets('shows coins and level', (tester) async {
      await tester.pumpWidget(app(const AdventureHud(
        coins: 1234,
        energy: 80,
        xp: 150,
        level: 2,
      )));

      expect(find.text('1 234'), findsOneWidget);
      expect(find.text('Niveau 2'), findsOneWidget);
    });

    testWidgets('tapping invokes onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(app(AdventureHud(
        coins: 0,
        energy: 100,
        xp: 0,
        level: 0,
        onTap: () => tapped = true,
      )));

      await tester.tap(find.byType(AdventureHud));
      expect(tapped, isTrue);
    });

    testWidgets('energy bar reflects the energy fraction', (tester) async {
      await tester.pumpWidget(app(const AdventureHud(
        coins: 0,
        energy: 50,
        xp: 0,
        level: 0,
      )));

      final bars = tester.widgetList<LinearProgressIndicator>(
          find.byType(LinearProgressIndicator));
      expect(bars.first.value, closeTo(0.5, 1e-9));
    });
  });

  group('AdventureEmptyBanner', () {
    testWidgets('shows the discreet French copy', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        theme: null,
        home: Scaffold(body: AdventureEmptyBanner()),
      ));
      expect(find.text('Explorez en marchant !'), findsOneWidget);
    });
  });

  group('BadgesSheet', () {
    Widget app(Widget child) =>
        MaterialApp(theme: AppTheme.light, home: Scaffold(body: child));

    testWidgets('shows all 8 badges, and stats', (tester) async {
      await tester.pumpWidget(app(BadgesSheet(
        unlockedBadges: {GameBadges.firstTrip, GameBadges.km10},
        streakDays: 3,
        totalKm: 12.5,
        cellsRevealed: 42,
        quartierPercent: 0.25,
      )));

      expect(find.text('Badges'), findsOneWidget);
      expect(find.text('Premier trajet'), findsOneWidget);
      expect(find.text('10 km parcourus'), findsOneWidget);
      expect(find.text('Série de jours'), findsOneWidget);
      expect(find.text('3 j'), findsOneWidget);
      expect(find.text('12.5 km'), findsOneWidget);
      expect(find.text('42'), findsOneWidget);
      expect(find.text('25 %'), findsOneWidget);
    });

    testWidgets('unlocked and locked badges render distinct icons',
        (tester) async {
      await tester.pumpWidget(app(BadgesSheet(
        unlockedBadges: const {GameBadges.firstTrip},
        streakDays: 0,
        totalKm: 0,
        cellsRevealed: 0,
        quartierPercent: 0,
      )));

      expect(find.byIcon(Icons.emoji_events), findsOneWidget);
      expect(find.byIcon(Icons.lock_outline), findsNWidgets(7));
    });
  });
}
