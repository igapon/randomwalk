import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/guidance_text.dart';

void main() {
  group('formatManeuver', () {
    test('rounds to the nearest 10 m under 100 m', () {
      expect(
        formatManeuver('tournez à gauche', 34),
        'Dans 30 m, tournez à gauche',
      );
      expect(
        formatManeuver('tournez à gauche', 45),
        'Dans 50 m, tournez à gauche',
      );
    });

    test('rounds to the nearest 50 m at or above 100 m', () {
      expect(
        formatManeuver('tournez à droite', 137),
        'Dans 150 m, tournez à droite',
      );
      expect(
        formatManeuver('tournez à droite', 100),
        'Dans 100 m, tournez à droite',
      );
    });

    test('switches to kilometres past 1000 m', () {
      expect(
        formatManeuver('continuez tout droit', 1500),
        'Dans 1,5 km, continuez tout droit',
      );
    });

    test('carries the instruction text through unchanged', () {
      expect(
        formatManeuver('Tournez à gauche sur la rue de Bourg', 20),
        'Dans 20 m, Tournez à gauche sur la rue de Bourg',
      );
    });
  });

  group('formatRemaining', () {
    test('French decimal comma, with an approximate ETA', () {
      expect(
        formatRemaining(2.4, const Duration(minutes: 32)),
        '2,4 km · ~32 min',
      );
    });

    test('rounds seconds to the nearest minute', () {
      expect(
        formatRemaining(1.0, const Duration(seconds: 89)),
        '1,0 km · ~1 min',
      );
      expect(
        formatRemaining(1.0, const Duration(seconds: 91)),
        '1,0 km · ~2 min',
      );
    });

    test('no ETA yet — distance only, no fabricated minutes', () {
      expect(formatRemaining(0.8, null), '0,8 km');
    });

    test('zero remaining still reads as a value, not blank', () {
      expect(formatRemaining(0, const Duration(seconds: 0)), '0,0 km · ~0 min');
    });
  });
}
