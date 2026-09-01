import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/pois.dart';
import 'package:randomwalk/game/visits.dart';
import 'package:randomwalk/nav/polyline_math.dart';

void main() {
  final church = const GamePoi(
      id: 'church', kind: PoiKind.reveal, lat: 46.5, lon: 6.6, name: 'Église');
  // ~10m north of church.
  final bank = const GamePoi(
      id: 'bank', kind: PoiKind.coins, lat: 46.50009, lon: 6.6, name: 'Banque');

  final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);

  group('VisitDetector — dwell', () {
    test('no visit before the dwell threshold', () {
      final detector = VisitDetector([church]);
      expect(detector.onFix(46.5, 6.6, t0), isNull);
      expect(detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 4))),
          isNull);
    });

    test('visit fires the instant dwell reaches exactly 5s (inclusive)', () {
      final detector = VisitDetector([church]);
      detector.onFix(46.5, 6.6, t0);
      final visit =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 5)));
      expect(visit, isNotNull);
      expect(visit!.poi.id, 'church');
      expect(visit.ts, t0.add(const Duration(seconds: 5)));
    });

    test('just under 5s does not fire', () {
      final detector = VisitDetector([church]);
      detector.onFix(46.5, 6.6, t0);
      final visit = detector.onFix(
          46.5, 6.6, t0.add(const Duration(milliseconds: 4999)));
      expect(visit, isNull);
    });

    test('leaving range resets the dwell clock', () {
      final detector = VisitDetector([church]);
      detector.onFix(46.5, 6.6, t0); // enter
      // Far away — out of range.
      detector.onFix(47.0, 7.0, t0.add(const Duration(seconds: 3)));
      // Back in range: dwell must restart from here, not from t0.
      detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 4)));
      final tooSoon = detector.onFix(
          46.5, 6.6, t0.add(const Duration(seconds: 8, milliseconds: 999)));
      expect(tooSoon, isNull);
      final visit =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 9)));
      expect(visit, isNotNull);
    });
  });

  group('VisitDetector — radius boundary (inclusive at 25m)', () {
    // A pure north-south offset matches `metersBetween`'s own great-circle
    // formula exactly (distance = earthRadiusM * dLatRadians for dLon = 0),
    // so these fixtures land within a fraction of a millimeter of the
    // intended distance rather than relying on an approximate
    // meters-per-degree constant that could land on the wrong side of a
    // knife-edge 25.0m boundary due to rounding.
    double latOffsetForMeters(double meters) =>
        (meters / 6371000.0) * 180 / 3.14159265358979323846;

    test('just within 25m counts as in range', () {
      final poi = GamePoi(
          id: 'edge',
          kind: PoiKind.reveal,
          lat: latOffsetForMeters(24.9),
          lon: 0.0);
      // Confirm the fixture is actually inside the radius before trusting
      // the detector's answer about it.
      expect(metersBetween(0.0, 0.0, poi.lat, poi.lon),
          lessThan(kVisitRadiusM));
      final detector = VisitDetector([poi]);
      detector.onFix(0.0, 0.0, t0);
      final visit = detector.onFix(0.0, 0.0, t0.add(const Duration(seconds: 5)));
      expect(visit, isNotNull);
    });

    test('just beyond 25m never starts a dwell', () {
      final poi = GamePoi(
          id: 'far',
          kind: PoiKind.reveal,
          lat: latOffsetForMeters(25.1),
          lon: 0.0);
      expect(metersBetween(0.0, 0.0, poi.lat, poi.lon),
          greaterThan(kVisitRadiusM));
      final detector = VisitDetector([poi]);
      detector.onFix(0.0, 0.0, t0);
      final visit =
          detector.onFix(0.0, 0.0, t0.add(const Duration(seconds: 10)));
      expect(visit, isNull);
    });
  });

  group('VisitDetector — one per session', () {
    test('a landmark already detected never fires again', () {
      final detector = VisitDetector([church]);
      detector.onFix(46.5, 6.6, t0);
      final first =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 5)));
      expect(first, isNotNull);

      // Keep dwelling right there — must not re-fire.
      final second =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 20)));
      expect(second, isNull);
      final third =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 40)));
      expect(third, isNull);
    });
  });

  group('VisitDetector — nearest wins', () {
    test('only the nearer of two in-range landmarks accumulates dwell', () {
      // church is at (46.5, 6.6); bank ~10m north of it. A fix taken AT
      // bank's own coordinates has bank at distance 0 and church at ~10m —
      // both within the 25m radius, so only the nearer (bank) should ever
      // start dwelling.
      final detector = VisitDetector([church, bank]);
      detector.onFix(bank.lat, bank.lon, t0);
      final visit =
          detector.onFix(bank.lat, bank.lon, t0.add(const Duration(seconds: 5)));
      expect(visit, isNotNull);
      expect(visit!.poi.id, 'bank');
    });

    test('switching nearest restarts the dwell clock for the new one', () {
      // Two landmarks 40m apart; the walker starts near A, then moves to
      // stand exactly on B before 5s at A elapses.
      final a = const GamePoi(id: 'a', kind: PoiKind.reveal, lat: 0.0, lon: 0.0);
      const latPer15m = 15.0 / 110540.0;
      final b =
          GamePoi(id: 'b', kind: PoiKind.reveal, lat: latPer15m, lon: 0.0);
      final detector = VisitDetector([a, b]);

      // At (0,0): only 'a' is in range (b is ~15m away, also within 25m —
      // so actually both are in range here; use a point where only 'a' is
      // near enough and 'b' is out of range, to isolate the switch).
      detector.onFix(0.0, 0.0, t0); // nearest: whichever is closer (a, dist 0)
      // Move to stand exactly on b before a's dwell would complete.
      final maybeEarly =
          detector.onFix(latPer15m, 0.0, t0.add(const Duration(seconds: 2)));
      expect(maybeEarly, isNull); // switched to b, dwell restarted

      // Continuing to dwell at b for 5s from the switch (t0+2s) completes.
      final tooSoon =
          detector.onFix(latPer15m, 0.0, t0.add(const Duration(seconds: 6)));
      expect(tooSoon, isNull);
      final visit =
          detector.onFix(latPer15m, 0.0, t0.add(const Duration(seconds: 7)));
      expect(visit, isNotNull);
      expect(visit!.poi.id, 'b');
    });
  });

  group('VisitDetector — edge cases', () {
    test('empty POI list never detects anything', () {
      final detector = VisitDetector(const []);
      expect(detector.onFix(46.5, 6.6, t0), isNull);
      expect(
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 10))),
          isNull);
    });

    test('two distinct landmarks can each be detected once, independently',
        () {
      final far = const GamePoi(
          id: 'far', kind: PoiKind.energy, lat: 10.0, lon: 10.0);
      final detector = VisitDetector([church, far]);
      detector.onFix(46.5, 6.6, t0);
      final churchVisit =
          detector.onFix(46.5, 6.6, t0.add(const Duration(seconds: 5)));
      expect(churchVisit!.poi.id, 'church');

      detector.onFix(10.0, 10.0, t0.add(const Duration(seconds: 6)));
      final farVisit =
          detector.onFix(10.0, 10.0, t0.add(const Duration(seconds: 11)));
      expect(farVisit!.poi.id, 'far');
    });
  });
}
