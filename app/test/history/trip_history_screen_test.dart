// `TripHistoryDetailScreen` itself owns a real `MapLibreMapController` (a
// platform view) and cannot be widget-tested — same story as
// `AdventureScreen`/`MapScreen` (see `adventure_screen_test.dart`'s own
// doc comment). These tests cover the pieces that don't need it: the list
// screen (`TripHistoryList`/`TripHistoryTile`/`TripHistoryEmptyState`) and
// the detail screen's extracted pure stats card (`TripHistoryStats`).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_detail_screen.dart';
import 'package:randomwalk/history/trip_history_screen.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  Widget app(Widget child) => MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(body: child),
  );

  TripHistoryEntry entry({
    DateTime? startedAt,
    RoutingProfile profile = RoutingProfile.walk,
    double distanceKm = 4.2,
    Duration duration = const Duration(minutes: 42),
    double? xpEarned,
  }) => TripHistoryEntry(
    startedAt: startedAt ?? DateTime(2026, 8, 30, 9),
    endedAt: (startedAt ?? DateTime(2026, 8, 30, 9)).add(duration),
    profile: profile,
    distanceKm: distanceKm,
    duration: duration,
    avgSpeedKmh: 6,
    xpEarned: xpEarned,
    track: const [(46.2, 6.1), (46.21, 6.11)],
  );

  group('TripHistoryEmptyState', () {
    testWidgets('shows an inviting French message', (tester) async {
      await tester.pumpWidget(app(const TripHistoryEmptyState()));
      expect(find.text('Aucun trajet pour le moment'), findsOneWidget);
    });
  });

  group('TripHistoryList / TripHistoryTile', () {
    testWidgets('renders one tile per entry, newest first as given', (
      tester,
    ) async {
      final entries = [
        entry(startedAt: DateTime(2026, 8, 30, 9), distanceKm: 4.2),
        entry(
          startedAt: DateTime(2026, 8, 28, 9),
          distanceKm: 1.5,
          profile: RoutingProfile.bike,
        ),
      ];
      await tester.pumpWidget(app(TripHistoryList(entries: entries)));

      expect(find.text('30 août 2026'), findsOneWidget);
      expect(find.text('28 août 2026'), findsOneWidget);
      expect(find.byIcon(Icons.directions_walk), findsOneWidget);
      expect(find.byIcon(Icons.directions_bike), findsOneWidget);
    });

    testWidgets('shows distance and duration on each tile', (tester) async {
      await tester.pumpWidget(
        app(
          TripHistoryTile(
            entry: entry(
              distanceKm: 4.2,
              duration: const Duration(minutes: 42),
            ),
          ),
        ),
      );
      expect(find.textContaining('4,20 km'), findsOneWidget);
      expect(find.textContaining('42 min'), findsOneWidget);
    });

    testWidgets('shows XP only when it is known', (tester) async {
      await tester.pumpWidget(app(TripHistoryTile(entry: entry(xpEarned: 35))));
      expect(find.textContaining('35 XP'), findsOneWidget);

      await tester.pumpWidget(
        app(TripHistoryTile(entry: entry(xpEarned: null))),
      );
      expect(find.textContaining('XP'), findsNothing);
    });

    testWidgets('tapping a tile is wired to open the detail screen', (
      tester,
    ) async {
      await tester.pumpWidget(app(TripHistoryTile(entry: entry())));
      final inkWell = tester.widget<InkWell>(find.byType(InkWell));
      expect(inkWell.onTap, isNotNull);
    });
  });

  group('TripHistoryStats (the detail screen\'s pure stats card)', () {
    testWidgets('shows date, distance, duration and speed', (tester) async {
      await tester.pumpWidget(
        app(
          TripHistoryStats(
            entry: entry(
              distanceKm: 4.2,
              duration: const Duration(minutes: 42),
            ),
          ),
        ),
      );
      expect(find.text('30 août 2026'), findsOneWidget);
      expect(find.text('4,20 km'), findsOneWidget);
      expect(find.text('42 min'), findsOneWidget);
      expect(find.byIcon(Icons.directions_walk), findsOneWidget);
    });

    testWidgets('shows XP only when it is known', (tester) async {
      await tester.pumpWidget(
        app(TripHistoryStats(entry: entry(xpEarned: 12))),
      );
      expect(find.text('+12'), findsOneWidget);

      await tester.pumpWidget(
        app(TripHistoryStats(entry: entry(xpEarned: null))),
      );
      expect(find.text('XP'), findsNothing);
    });
  });
}
