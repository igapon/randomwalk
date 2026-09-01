import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/explore_planner.dart';
import 'package:randomwalk/game/grid.dart';
import 'package:randomwalk/loop/geo_offsets.dart';

/// Smallest positive angular difference between two bearings, in degrees
/// (0-180) — used to check bearings are "spread apart" without caring about
/// wraparound at 360/0.
double _angularDistance(double a, double b) {
  final diff = (a - b).abs() % 360;
  return diff > 180 ? 360 - diff : diff;
}

void main() {
  // A fixed, arbitrary Swiss-ish start point — the exact location never
  // matters, only the geometry relative to it.
  const start = (46.5, 6.6);
  const targetKm = 5.0;
  final radiusM = targetKm * 1000 / (2 * math.pi);

  group('exploreBearings — virgin state (nothing revealed)', () {
    test('returns `count` distinct bearings, not the same sector jittered '
        'three times', () {
      final bearings = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 7,
      );

      expect(bearings, hasLength(3));
      for (var i = 0; i < bearings.length; i++) {
        for (var j = i + 1; j < bearings.length; j++) {
          // Sectors are 45° apart (default 8 sectors) and jitter is only
          // ±15°, so two draws from the *same* sector could never end up
          // more than 30° apart — anything past that proves distinct base
          // sectors were chosen.
          expect(
            _angularDistance(bearings[i], bearings[j]),
            greaterThan(30),
            reason:
                'bearings $i and $j look like the same sector jittered '
                'twice: $bearings',
          );
        }
      }
    });

    test('every returned bearing is within [0, 360)', () {
      final bearings = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 3,
      );
      for (final b in bearings) {
        expect(b, greaterThanOrEqualTo(0));
        expect(b, lessThan(360));
      }
    });

    test('same seed reproduces the same bearings', () {
      final a = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 42,
      );
      final b = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 42,
      );
      expect(a, equals(b));
    });

    test('different seeds vary the tie-break order', () {
      final a = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 1,
      );
      final b = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 2,
      );
      expect(a, isNot(equals(b)));
    });
  });

  group('exploreBearings — biased toward the unrevealed side (DoD test)', () {
    test('biased bearings point toward the unrevealed side given a '
        'half-revealed disc', () {
      // Reveal a mesh covering the eastern half of the loop disc (bearings
      // 0..180, i.e. everything from due north clockwise through due
      // south) out to the loop radius, leaving the western half (180..360)
      // untouched.
      final revealed = <String>{};
      for (var bearingDeg = 0; bearingDeg <= 180; bearingDeg += 5) {
        for (var distM = 25.0; distM <= radiusM; distM += 25.0) {
          final (lat, lon) = destinationPoint(
            start.$1,
            start.$2,
            bearingDeg.toDouble(),
            distM,
          );
          revealed.add(cellIdFor(lat, lon).key);
        }
      }

      final bearings = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: revealed,
        count: 3,
        seed: 42,
      );

      expect(bearings, hasLength(3));
      for (final b in bearings) {
        final distToEast = _angularDistance(b, 90);
        final distToWest = _angularDistance(b, 270);
        expect(
          distToWest,
          lessThan(distToEast),
          reason:
              'bearing $b should favour the unrevealed (west) side, '
              'not the fully-revealed east side',
        );
      }
    });

    test('a fully-revealed disc still returns `count` bearings (never '
        'empty, even with nothing left to prefer)', () {
      final revealed = <String>{};
      for (var bearingDeg = 0; bearingDeg < 360; bearingDeg += 5) {
        for (var distM = 25.0; distM <= radiusM; distM += 25.0) {
          final (lat, lon) = destinationPoint(
            start.$1,
            start.$2,
            bearingDeg.toDouble(),
            distM,
          );
          revealed.add(cellIdFor(lat, lon).key);
        }
      }

      final bearings = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: revealed,
        count: 3,
        seed: 1,
      );
      expect(bearings, hasLength(3));
    });
  });

  group('exploreBearings — injected rng', () {
    test('accepts a seeded rng factory the same way LoopPlanner does', () {
      final calls = <int>[];
      final bearings = exploreBearings(
        start: start,
        targetKm: targetKm,
        revealedCellKeys: const {},
        count: 3,
        seed: 5,
        rng: (seed) {
          calls.add(seed);
          return math.Random(seed);
        },
      );
      expect(bearings, hasLength(3));
      expect(calls, isNotEmpty);
    });
  });
}
