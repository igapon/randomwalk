// `TripCelebrationScreen` itself combines real `TripHistoryStore` (sqflite)
// I/O with `flutter_test`'s fake-async pump zone — on this environment that
// combination reliably HUNG the test runner rather than merely running
// slowly (see the class's own doc comment), so it is not pumped here at all
// — same "cannot be widget-tested" situation `TripHistoryDetailScreen`/
// `AdventureScreen`/`MapScreen` already document, for a different
// underlying cause. What's tested instead: [resolveCelebrationEntry] (the
// actual polling logic, both the store call and the delay injected — a
// plain, fully deterministic unit test, no Flutter binding needed at all)
// and [CelebrationStats] (the pure stats card, exactly like
// `trip_history_screen_test.dart` tests `TripHistoryStats` on its own).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/theme/theme.dart';
import 'package:randomwalk/trip/trip_celebration_screen.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  final startedAt = DateTime.utc(2026, 8, 30, 9, 30);

  TripHistoryEntry entryFor(
    DateTime at, {
    double? xpEarned,
    double distanceKm = 2.4,
    Duration duration = const Duration(minutes: 30),
  }) => TripHistoryEntry(
    startedAt: at,
    endedAt: at.add(duration),
    profile: RoutingProfile.walk,
    distanceKm: distanceKm,
    duration: duration,
    avgSpeedKmh: 4.8,
    xpEarned: xpEarned,
  );

  group('resolveCelebrationEntry', () {
    // Never actually waits — proves the polling logic itself without any
    // real (or even fake-clock) delay, so these tests are as fast as any
    // other pure-Dart unit test in this codebase.
    Future<void> noDelay(Duration d) async {}

    test('returns immediately once the first fetch already matches', () async {
      var calls = 0;
      final entry = await resolveCelebrationEntry(
        fetchLatest: () async {
          calls++;
          return entryFor(startedAt);
        },
        startedAt: startedAt,
        delay: noDelay,
      );
      expect(entry, isNotNull);
      expect(entry!.startedAt, startedAt);
      expect(calls, 1);
    });

    test('keeps polling past a non-matching (older) row until the right one '
        'appears', () async {
      var calls = 0;
      final entry = await resolveCelebrationEntry(
        fetchLatest: () async {
          calls++;
          // The first two attempts see yesterday's trip; the third sees
          // this one — e.g. the write genuinely landed a little late.
          return calls < 3
              ? entryFor(startedAt.subtract(const Duration(days: 1)))
              : entryFor(startedAt);
        },
        startedAt: startedAt,
        delay: noDelay,
      );
      expect(entry?.startedAt, startedAt);
      expect(calls, 3);
    });

    test('gives up after maxPolls attempts, returning null rather than '
        'spinning forever', () async {
      var calls = 0;
      final entry = await resolveCelebrationEntry(
        fetchLatest: () async {
          calls++;
          return null;
        },
        startedAt: startedAt,
        maxPolls: 4,
        delay: noDelay,
      );
      expect(entry, isNull);
      expect(calls, 4);
    });

    test('a throwing fetchLatest is treated exactly like "not yet written" — '
        'retried, never surfaced', () async {
      var calls = 0;
      final entry = await resolveCelebrationEntry(
        fetchLatest: () async {
          calls++;
          if (calls < 2) throw StateError('store not ready');
          return entryFor(startedAt);
        },
        startedAt: startedAt,
        delay: noDelay,
      );
      expect(entry?.startedAt, startedAt);
      expect(calls, 2);
    });

    test('waits pollInterval apart between attempts', () async {
      final waited = <Duration>[];
      await resolveCelebrationEntry(
        fetchLatest: () async => null,
        startedAt: startedAt,
        maxPolls: 3,
        pollInterval: const Duration(milliseconds: 50),
        delay: (d) async => waited.add(d),
      );
      expect(waited, [
        const Duration(milliseconds: 50),
        const Duration(milliseconds: 50),
        const Duration(milliseconds: 50),
      ]);
    });
  });

  group('CelebrationStats (the pure stats card)', () {
    Widget app(Widget child) => MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: child),
    );

    FinishedTripCelebration celebration({bool isLoop = false}) =>
        FinishedTripCelebration(
          startedAt: startedAt,
          distanceKm: 2.4,
          duration: const Duration(minutes: 30),
          avgSpeedKmh: 4.8,
          profile: RoutingProfile.walk,
          isLoop: isLoop,
        );

    testWidgets(
      'once resolved, shows the combined exploration+visit XP total via '
      'TripHistoryStats',
      (tester) async {
        await tester.pumpWidget(
          app(
            CelebrationStats(
              // 24 (exploration) + 25 (one landmark visit) = 49.
              entry: entryFor(startedAt, xpEarned: 49),
              celebration: celebration(),
              gaveUp: false,
            ),
          ),
        );

        expect(find.text('2,40 km'), findsOneWidget);
        expect(find.text('30 min'), findsOneWidget);
        expect(find.text('+49'), findsOneWidget);
      },
    );

    testWidgets(
      'while still resolving, shows the synchronously-known stats with XP '
      'pending — never a guessed number',
      (tester) async {
        await tester.pumpWidget(
          app(
            CelebrationStats(
              entry: null,
              celebration: celebration(),
              gaveUp: false,
            ),
          ),
        );

        expect(find.text('2,40 km'), findsOneWidget);
        expect(find.text('30 min'), findsOneWidget);
        expect(find.text('···'), findsOneWidget);
        expect(find.text('+49'), findsNothing);
      },
    );

    testWidgets(
      'gives up gracefully: known stats stay, XP reads as unavailable '
      'rather than spinning forever',
      (tester) async {
        await tester.pumpWidget(
          app(
            CelebrationStats(
              entry: null,
              celebration: celebration(),
              gaveUp: true,
            ),
          ),
        );

        expect(find.text('2,40 km'), findsOneWidget);
        expect(find.text('—'), findsOneWidget);
      },
    );

    testWidgets(
      'nothing synchronous AND nothing resolved yet: a loading indicator, '
      'not a blank screen',
      (tester) async {
        await tester.pumpWidget(
          app(
            const CelebrationStats(
              entry: null,
              celebration: null,
              gaveUp: false,
            ),
          ),
        );

        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
    );

    testWidgets(
      'nothing synchronous, gave up: a graceful "trajet enregistré" message',
      (tester) async {
        await tester.pumpWidget(
          app(
            const CelebrationStats(
              entry: null,
              celebration: null,
              gaveUp: true,
            ),
          ),
        );

        expect(find.text('Trajet enregistré.'), findsOneWidget);
      },
    );
  });
}
