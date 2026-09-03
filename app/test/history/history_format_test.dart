import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/history/history_format.dart';

void main() {
  group('formatHistoryDate', () {
    test('formats a local calendar date in French', () {
      expect(formatHistoryDate(DateTime(2026, 8, 30)), '30 août 2026');
    });

    test('a single-digit day is not zero-padded', () {
      expect(formatHistoryDate(DateTime(2026, 1, 5)), '5 janvier 2026');
    });
  });

  group('formatTripDuration', () {
    test('under an hour shows minutes only', () {
      expect(formatTripDuration(const Duration(minutes: 24)), '24 min');
    });

    test('an hour or more shows "H h MM"', () {
      expect(
        formatTripDuration(const Duration(hours: 1, minutes: 4)),
        '1 h 04',
      );
    });

    test('exactly on the hour shows zero minutes', () {
      expect(formatTripDuration(const Duration(hours: 2)), '2 h 00');
    });
  });

  group('formatTripDistance', () {
    test('uses a comma decimal separator', () {
      expect(formatTripDistance(4.2), '4,20 km');
    });

    test('rounds to two decimals', () {
      expect(formatTripDistance(3.14159), '3,14 km');
    });
  });

  group('formatTripSpeed', () {
    test('uses a comma decimal separator and one decimal place', () {
      expect(formatTripSpeed(11.42), '11,4 km/h');
    });
  });
}
