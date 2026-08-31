import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/loop/geo_offsets.dart';
import 'package:randomwalk/nav/polyline_math.dart';

double _bearingBetween(double lat1, double lon1, double lat2, double lon2) {
  final phi1 = lat1 * math.pi / 180;
  final phi2 = lat2 * math.pi / 180;
  final dLambda = (lon2 - lon1) * math.pi / 180;
  final y = math.sin(dLambda) * math.cos(phi2);
  final x = math.cos(phi1) * math.sin(phi2) -
      math.sin(phi1) * math.cos(phi2) * math.cos(dLambda);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

void main() {
  const startLat = 46.52;
  const startLon = 6.63;

  group('destinationPoint', () {
    test('round-trips against metersBetween going north 1000 m', () {
      final (lat, lon) = destinationPoint(startLat, startLon, 0, 1000);
      final d = metersBetween(startLat, startLon, lat, lon);
      expect(d, closeTo(1000, 1));
      // Heading due north should barely change longitude.
      expect(lon, closeTo(startLon, 0.001));
      expect(lat, greaterThan(startLat));
    });

    test('round-trips against metersBetween going east 1000 m at 46 lat',
        () {
      final (lat, lon) = destinationPoint(startLat, startLon, 90, 1000);
      final d = metersBetween(startLat, startLon, lat, lon);
      expect(d, closeTo(1000, 1));
      expect(lat, closeTo(startLat, 0.001));
      expect(lon, greaterThan(startLon));
    });

    test('travelling 0 m returns the same point', () {
      final (lat, lon) = destinationPoint(startLat, startLon, 45, 0);
      expect(lat, closeTo(startLat, 1e-9));
      expect(lon, closeTo(startLon, 1e-9));
    });

    test('wraps longitude to [-180, 180] crossing the antimeridian', () {
      final (lat, lon) = destinationPoint(0, 179.9, 90, 50000);
      expect(lon, inInclusiveRange(-180.0, 180.0));
      // Heading east past 180 should wrap to a small negative longitude.
      expect(lon, lessThan(0));
      expect(lat, closeTo(0, 0.5));
    });
  });

  group('circleWaypoints', () {
    test('count=3 produces bearings spaced 120 degrees apart', () {
      final pts = circleWaypoints(
        lat: startLat,
        lon: startLon,
        radiusM: 500,
        count: 3,
        startBearingDeg: 10,
      );
      expect(pts, hasLength(3));
      final bearings = pts
          .map((p) => _bearingBetween(startLat, startLon, p.$1, p.$2))
          .toList();
      // Expected bearings: 10, 130, 250 (mod 360).
      expect(bearings[0], closeTo(10, 0.5));
      expect(bearings[1], closeTo(130, 0.5));
      expect(bearings[2], closeTo(250, 0.5));
    });

    test('every point sits ~radiusM from the centre', () {
      final pts = circleWaypoints(
        lat: startLat,
        lon: startLon,
        radiusM: 800,
        count: 6,
        startBearingDeg: 0,
      );
      for (final (lat, lon) in pts) {
        final d = metersBetween(startLat, startLon, lat, lon);
        expect(d, closeTo(800, 1));
      }
    });

    test('startBearingDeg rotates the whole set', () {
      final a = circleWaypoints(
          lat: startLat, lon: startLon, radiusM: 400, count: 4, startBearingDeg: 0);
      final b = circleWaypoints(
          lat: startLat, lon: startLon, radiusM: 400, count: 4, startBearingDeg: 45);
      final bearingA0 = _bearingBetween(startLat, startLon, a[0].$1, a[0].$2);
      final bearingB0 = _bearingBetween(startLat, startLon, b[0].$1, b[0].$2);
      // Normalize to (-180, 180] so this is robust to bearingA0 landing on
      // the 0/360 wraparound boundary (e.g. -1e-13 -> 359.999... after the
      // %360 normalization inside _bearingBetween).
      final diff = (bearingB0 - bearingA0 + 540) % 360 - 180;
      expect(diff, closeTo(45, 0.5));
    });
  });

  group('ellipseWaypoints', () {
    final a = (46.520, 6.630);
    final b = (46.520, 6.640); // roughly eastward ~770 m apart

    test('midpoint-ish waypoint sits close to detourM off the axis', () {
      final pts = ellipseWaypoints(
        a: a,
        b: b,
        detourM: 100,
        count: 1,
        mirrored: false,
      );
      expect(pts, hasLength(1));
      final (lat, lon) = pts.single;
      // Cross-track distance from the a-b great circle should be close to
      // detourM (single point sits at t=0.5, the peak of the bulge).
      final g = RouteGeometry([a, b]);
      final proj = projectOntoRoute(g, lat, lon);
      expect(proj.crossTrackM, closeTo(100, 5));
    });

    test('mirrored=true bulges to the opposite side', () {
      final pts = ellipseWaypoints(
        a: a,
        b: b,
        detourM: 100,
        count: 3,
        mirrored: false,
      );
      final mirroredPts = ellipseWaypoints(
        a: a,
        b: b,
        detourM: 100,
        count: 3,
        mirrored: true,
      );
      expect(pts, hasLength(3));
      expect(mirroredPts, hasLength(3));
      for (var i = 0; i < pts.length; i++) {
        // Same latitude approximately mirrored around the a-b axis
        // (axis is ~east-west here, so mirroring flips which side of
        // that latitude band the point falls on).
        final axisLat = (a.$1 + b.$1) / 2;
        final aboveAxis = pts[i].$1 - axisLat;
        final mirroredAboveAxis = mirroredPts[i].$1 - axisLat;
        expect(aboveAxis.sign, isNot(equals(mirroredAboveAxis.sign)));
        expect(aboveAxis.abs(), closeTo(mirroredAboveAxis.abs(), 1e-4));
      }
    });

    test('endpoints are excluded and points progress from a toward b', () {
      final pts = ellipseWaypoints(
        a: a,
        b: b,
        detourM: 50,
        count: 3,
        mirrored: false,
      );
      // Longitude should increase monotonically from a to b (axis heads east).
      expect(pts[0].$2, lessThan(pts[1].$2));
      expect(pts[1].$2, lessThan(pts[2].$2));
      // None of the points should coincide with the foci.
      for (final p in pts) {
        expect(metersBetween(p.$1, p.$2, a.$1, a.$2), greaterThan(1));
        expect(metersBetween(p.$1, p.$2, b.$1, b.$2), greaterThan(1));
      }
    });

    test('total path length a->points->b grows monotonically with detourM',
        () {
      double totalPathLength(double detourM) {
        final pts = ellipseWaypoints(
          a: a,
          b: b,
          detourM: detourM,
          count: 4,
          mirrored: false,
        );
        final chain = [a, ...pts, b];
        var total = 0.0;
        for (var i = 0; i < chain.length - 1; i++) {
          total += metersBetween(
            chain[i].$1,
            chain[i].$2,
            chain[i + 1].$1,
            chain[i + 1].$2,
          );
        }
        return total;
      }

      const detours = [200.0, 500.0, 1000.0, 2000.0];
      final lengths = detours.map(totalPathLength).toList();
      for (var i = 1; i < lengths.length; i++) {
        expect(lengths[i], greaterThan(lengths[i - 1]),
            reason:
                'path length at detour=${detours[i]} should exceed detour=${detours[i - 1]}');
      }
    });

    test('waypoint distances from the foci are plausible (not degenerate)',
        () {
      final pts = ellipseWaypoints(
        a: a,
        b: b,
        detourM: 150,
        count: 5,
        mirrored: false,
      );
      final axisDistanceM = metersBetween(a.$1, a.$2, b.$1, b.$2);
      for (final p in pts) {
        final da = metersBetween(p.$1, p.$2, a.$1, a.$2);
        final db = metersBetween(p.$1, p.$2, b.$1, b.$2);
        // Each waypoint should be no farther from either focus than the
        // full axis length plus the detour (loose sanity bound).
        expect(da, lessThan(axisDistanceM + 300));
        expect(db, lessThan(axisDistanceM + 300));
        expect(da, greaterThan(0));
        expect(db, greaterThan(0));
      }
    });
  });
}
