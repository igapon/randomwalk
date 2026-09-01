import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/hud_format.dart';

void main() {
  group('xpThresholdForLevel', () {
    test('level 0 requires 0 XP', () {
      expect(xpThresholdForLevel(0), 0);
    });

    test('matches the reducers.dart formula 100 * n^1.5', () {
      expect(xpThresholdForLevel(1), closeTo(100.0, 1e-9));
      expect(xpThresholdForLevel(4), closeTo(800.0, 1e-9)); // 100*4^1.5=800
    });
  });

  group('xpProgressFraction', () {
    test('at the exact lower threshold: 0.0', () {
      expect(xpProgressFraction(0, 0), 0.0);
    });

    test('halfway between level thresholds: 0.5', () {
      // level 0 -> level 1 spans [0, 100).
      expect(xpProgressFraction(50, 0), closeTo(0.5, 1e-9));
    });

    test(
      'at/just under the next threshold: clamps to 1.0, never overshoots',
      () {
        expect(xpProgressFraction(100, 0), 1.0);
        expect(xpProgressFraction(1000000, 0), 1.0);
      },
    );

    test(
      'never goes negative for an XP value below the level\'s own floor',
      () {
        expect(xpProgressFraction(-10, 1), 0.0);
      },
    );
  });

  group('energyFraction', () {
    test('0 -> 0.0, 100 -> 1.0, 50 -> 0.5', () {
      expect(energyFraction(0), 0.0);
      expect(energyFraction(100), 1.0);
      expect(energyFraction(50), 0.5);
    });

    test('clamps out-of-range values defensively', () {
      expect(energyFraction(150), 1.0);
      expect(energyFraction(-10), 0.0);
    });
  });

  group('formatWholeNumber', () {
    test('small numbers pass through unchanged', () {
      expect(formatWholeNumber(0), '0');
      expect(formatWholeNumber(42), '42');
    });

    test('thousands get a thin-space separator', () {
      expect(formatWholeNumber(1234), '1 234');
      expect(formatWholeNumber(1234567), '1 234 567');
    });

    test('rounds a fractional input', () {
      expect(formatWholeNumber(12.6), '13');
    });
  });

  group('formatPercent', () {
    test('rounds to the nearest whole percent', () {
      expect(formatPercent(0.256), '26 %');
      expect(formatPercent(0.0), '0 %');
      expect(formatPercent(1.0), '100 %');
    });

    test('clamps out-of-range fractions', () {
      expect(formatPercent(1.5), '100 %');
      expect(formatPercent(-0.5), '0 %');
    });
  });
}
