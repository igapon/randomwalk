import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:randomwalk/loop/speed_history.dart';
import 'package:randomwalk/valhalla/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('defaults with no history', () {
    test('walk defaults to 4.5 km/h', () async {
      final store = SpeedHistoryStore();
      expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
    });

    test('bike defaults to 16.0 km/h', () async {
      final store = SpeedHistoryStore();
      expect(await store.speedKmh(RoutingProfile.bike), closeTo(16.0, 1e-9));
    });
  });

  group('EMA convergence', () {
    test(
      'one session moves the EMA by exactly alpha toward the sample',
      () async {
        final store = SpeedHistoryStore();
        // 6 km in 1h -> 6 km/h, a plausible walking speed.
        await store.recordSession(
          RoutingProfile.walk,
          6.0,
          const Duration(hours: 1),
        );

        // ema = 0.3*6 + 0.7*4.5 = 4.95
        expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.95, 1e-9));
      },
    );

    test('repeated sessions at a steady pace converge toward it', () async {
      final store = SpeedHistoryStore();
      for (var i = 0; i < 50; i++) {
        await store.recordSession(
          RoutingProfile.walk,
          6.0,
          const Duration(hours: 1),
        );
      }
      expect(await store.speedKmh(RoutingProfile.walk), closeTo(6.0, 0.01));
    });

    test('walk and bike histories are independent', () async {
      final store = SpeedHistoryStore();
      await store.recordSession(
        RoutingProfile.walk,
        6.0,
        const Duration(hours: 1),
      );

      expect(await store.speedKmh(RoutingProfile.bike), closeTo(16.0, 1e-9));
    });
  });

  group('plausibility bounds', () {
    test('a walking session faster than 10 km/h is ignored', () async {
      final store = SpeedHistoryStore();
      // 12 km in 1h -> 12 km/h, outside [2,10] for walk.
      await store.recordSession(
        RoutingProfile.walk,
        12.0,
        const Duration(hours: 1),
      );
      expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
    });

    test('a walking session slower than 2 km/h is ignored', () async {
      final store = SpeedHistoryStore();
      // 1 km in 1h -> 1 km/h, outside [2,10] for walk.
      await store.recordSession(
        RoutingProfile.walk,
        1.0,
        const Duration(hours: 1),
      );
      expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
    });

    test('a bike session faster than 35 km/h is ignored', () async {
      final store = SpeedHistoryStore();
      // 40 km in 1h -> 40 km/h, outside [8,35] for bike.
      await store.recordSession(
        RoutingProfile.bike,
        40.0,
        const Duration(hours: 1),
      );
      expect(await store.speedKmh(RoutingProfile.bike), closeTo(16.0, 1e-9));
    });

    test('a bike session slower than 8 km/h is ignored', () async {
      final store = SpeedHistoryStore();
      // 5 km in 1h -> 5 km/h, outside [8,35] for bike.
      await store.recordSession(
        RoutingProfile.bike,
        5.0,
        const Duration(hours: 1),
      );
      expect(await store.speedKmh(RoutingProfile.bike), closeTo(16.0, 1e-9));
    });

    test('a plausible bike session updates the EMA', () async {
      final store = SpeedHistoryStore();
      // 20 km in 1h -> 20 km/h, inside [8,35] for bike.
      await store.recordSession(
        RoutingProfile.bike,
        20.0,
        const Duration(hours: 1),
      );
      // ema = 0.3*20 + 0.7*16 = 17.2
      expect(await store.speedKmh(RoutingProfile.bike), closeTo(17.2, 1e-9));
    });
  });

  group('short-session ignore', () {
    test(
      'a session of 300 m or less is ignored regardless of duration',
      () async {
        final store = SpeedHistoryStore();
        await store.recordSession(
          RoutingProfile.walk,
          0.3,
          const Duration(hours: 1),
        );
        expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
      },
    );

    test(
      'a session of 3 minutes or less is ignored regardless of distance',
      () async {
        final store = SpeedHistoryStore();
        await store.recordSession(
          RoutingProfile.walk,
          5.0,
          const Duration(minutes: 3),
        );
        expect(await store.speedKmh(RoutingProfile.walk), closeTo(4.5, 1e-9));
      },
    );

    test('a session just over both thresholds is recorded', () async {
      final store = SpeedHistoryStore();
      // 0.31 km in 3:01 -> plausible-ish walking speed within bounds.
      await store.recordSession(
        RoutingProfile.walk,
        0.31,
        const Duration(minutes: 3, seconds: 1),
      );
      expect(
        await store.speedKmh(RoutingProfile.walk),
        isNot(closeTo(4.5, 1e-9)),
      );
    });
  });

  group('persistence', () {
    test(
      'the EMA survives a new store instance reading the same prefs',
      () async {
        final store = SpeedHistoryStore();
        await store.recordSession(
          RoutingProfile.walk,
          6.0,
          const Duration(hours: 1),
        );

        final reopened = SpeedHistoryStore();
        expect(
          await reopened.speedKmh(RoutingProfile.walk),
          closeTo(4.95, 1e-9),
        );
      },
    );

    test('it is stored under the documented shared_preferences keys', () async {
      final store = SpeedHistoryStore();
      await store.recordSession(
        RoutingProfile.walk,
        6.0,
        const Duration(hours: 1),
      );
      await store.recordSession(
        RoutingProfile.bike,
        20.0,
        const Duration(hours: 1),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('speed_ema_walk'), closeTo(4.95, 1e-9));
      expect(prefs.getDouble('speed_ema_bike'), closeTo(17.2, 1e-9));
    });
  });
}
