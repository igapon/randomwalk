import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/tracking/adaptive_gps.dart';

void main() {
  group('adaptiveDistanceFilter', () {
    test('unknown distance stays at the tight (pre-nav) filter', () {
      expect(adaptiveDistanceFilter(null), kNavCloseDistanceFilterM);
    });

    test('tight filter well within the threshold', () {
      expect(adaptiveDistanceFilter(50), kNavCloseDistanceFilterM);
    });

    test('tight filter right up to (but not including) the threshold', () {
      expect(adaptiveDistanceFilter(499.9), kNavCloseDistanceFilterM);
    });

    test('coarse filter exactly at the threshold', () {
      expect(adaptiveDistanceFilter(500), kNavFarDistanceFilterM);
    });

    test('coarse filter well beyond the threshold', () {
      expect(adaptiveDistanceFilter(2000), kNavFarDistanceFilterM);
    });
  });

  group('AdaptiveGpsRateLimiter', () {
    test('allows the first change with nothing recorded yet', () {
      final limiter = AdaptiveGpsRateLimiter(clock: () => DateTime.utc(2026));
      expect(
        limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
        isTrue,
      );
    });

    test('refuses when the filter has not actually changed', () {
      final limiter = AdaptiveGpsRateLimiter(clock: () => DateTime.utc(2026));
      expect(
        limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 3),
        isFalse,
      );
    });

    test('refuses a second change inside the cooldown', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final limiter = AdaptiveGpsRateLimiter(clock: () => now);

      expect(
        limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
        isTrue,
      );
      limiter.recordChange();

      now = now.add(const Duration(seconds: 59));
      expect(
        limiter.shouldResubscribe(currentFilter: 12, desiredFilter: 3),
        isFalse,
      );
    });

    test('allows a change again once the cooldown elapses', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final limiter = AdaptiveGpsRateLimiter(clock: () => now);

      expect(
        limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
        isTrue,
      );
      limiter.recordChange();

      now = now.add(const Duration(seconds: 60));
      expect(
        limiter.shouldResubscribe(currentFilter: 12, desiredFilter: 3),
        isTrue,
      );
    });

    test(
      'a would-be change that is never recorded does not spend the budget',
      () {
        var now = DateTime.utc(2026, 1, 1, 10, 0, 0);
        final limiter = AdaptiveGpsRateLimiter(clock: () => now);

        expect(
          limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
          isTrue,
        );
        // Deliberately not calling recordChange().

        now = now.add(const Duration(seconds: 1));
        expect(
          limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
          isTrue,
        );
      },
    );

    test('respects a custom minInterval', () {
      var now = DateTime.utc(2026, 1, 1, 10, 0, 0);
      final limiter = AdaptiveGpsRateLimiter(
        minInterval: const Duration(seconds: 5),
        clock: () => now,
      );

      expect(
        limiter.shouldResubscribe(currentFilter: 3, desiredFilter: 12),
        isTrue,
      );
      limiter.recordChange();

      now = now.add(const Duration(seconds: 4));
      expect(
        limiter.shouldResubscribe(currentFilter: 12, desiredFilter: 3),
        isFalse,
      );

      now = now.add(const Duration(seconds: 1));
      expect(
        limiter.shouldResubscribe(currentFilter: 12, desiredFilter: 3),
        isTrue,
      );
    });
  });
}
