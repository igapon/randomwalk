import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/battery_optimization.dart';

void main() {
  group('isAggressiveBatteryOem', () {
    test('null manufacturer is not aggressive', () {
      expect(isAggressiveBatteryOem(null), isFalse);
    });

    test('an unlisted manufacturer (e.g. Google) is not aggressive', () {
      expect(isAggressiveBatteryOem('Google'), isFalse);
      expect(isAggressiveBatteryOem('motorola'), isFalse);
    });

    for (final oem in kAggressiveBatteryOems) {
      test('$oem is aggressive, case-insensitively', () {
        expect(isAggressiveBatteryOem(oem), isTrue);
        expect(isAggressiveBatteryOem(oem.toUpperCase()), isTrue);
        expect(
            isAggressiveBatteryOem(
                oem[0].toUpperCase() + oem.substring(1)),
            isTrue);
      });
    }
  });
}
