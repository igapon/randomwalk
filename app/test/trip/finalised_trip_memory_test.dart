// Direct coverage of PrefsFinalisedTripMemory — the shared_preferences-backed
// FinalisedTripMemory implementation `TripController` uses in production
// (`trip_controller_test.dart` exercises the *behaviour* this class enables
// via TripController's own tests, with MemoryFinalisedTripMemory standing
// in; this file tests the real prefs-backed storage on its own).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/trip/finalised_trip_memory.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final startedAt = DateTime.utc(2026, 8, 30, 9, 30);
  const stats = PendingCelebrationStats(
    distanceKm: 2.4,
    duration: Duration(minutes: 30),
    avgSpeedKmh: 4.8,
    profile: RoutingProfile.walk,
    isLoop: false,
  );

  group('pendingCelebration (M5 final review, Important I1)', () {
    test('round-trips a stored marker', () async {
      final memory = PrefsFinalisedTripMemory();
      await memory.setPendingCelebration(startedAt, stats);

      final pending = await memory.pendingCelebration();

      expect(pending, isNotNull);
      expect(pending!.$1, startedAt);
      expect(pending.$2.distanceKm, 2.4);
    });

    test(
      'returns null, with no marker to speak of, when none was set',
      () async {
        final memory = PrefsFinalisedTripMemory();
        expect(await memory.pendingCelebration(), isNull);
      },
    );

    test('a corrupt payload (not valid JSON) is treated as "nothing pending" '
        'AND the key is removed — before this fix it survived forever, since '
        '_checkPendingCelebration (main.dart) early-returns on a null result '
        'without ever calling clearPendingCelebration', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_trip_celebration', 'not json at all');

      final memory = PrefsFinalisedTripMemory();
      expect(await memory.pendingCelebration(), isNull);
      expect(prefs.getString('pending_trip_celebration'), isNull);
    });

    test('a payload that parses as JSON but has a corrupt stats sub-object is '
        'also treated as "nothing pending" AND removed', () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'pending_trip_celebration',
        '{"startedAt":"${startedAt.toIso8601String()}","stats":"not a map"}',
      );

      final memory = PrefsFinalisedTripMemory();
      expect(await memory.pendingCelebration(), isNull);
      expect(prefs.getString('pending_trip_celebration'), isNull);
    });

    test(
      'a valid marker is left untouched by a read that finds it intact',
      () async {
        final memory = PrefsFinalisedTripMemory();
        await memory.setPendingCelebration(startedAt, stats);

        await memory.pendingCelebration();

        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('pending_trip_celebration'), isNotNull);
      },
    );
  });

  group(
    'clearFinalisedTripMemoryPrefs (M5 final review, Important I1 / F1)',
    () {
      test(
        'removes both finalised_trip_ids and pending_trip_celebration',
        () async {
          final memory = PrefsFinalisedTripMemory();
          await memory.markFinalised(startedAt);
          await memory.setPendingCelebration(startedAt, stats);

          await clearFinalisedTripMemoryPrefs();

          expect(await memory.wasFinalised(startedAt), isFalse);
          expect(await memory.pendingCelebration(), isNull);
        },
      );

      test('is harmless when neither key was ever set', () async {
        await clearFinalisedTripMemoryPrefs();
        final memory = PrefsFinalisedTripMemory();
        expect(await memory.pendingCelebration(), isNull);
      });
    },
  );
}
