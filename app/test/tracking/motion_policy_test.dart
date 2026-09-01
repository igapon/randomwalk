import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/tracking/motion_policy.dart';

void main() {
  group('MotionPolicy — sustained stillness', () {
    test('a still spell shorter than the threshold never pauses '
        '(a red light must never suspend)', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);

      // Red light: 90 s of stillness, then movement again.
      expect(
        policy.tick(t0.add(const Duration(seconds: 90))),
        MotionAction.none,
      );
      expect(
        policy.stillExited(t0.add(const Duration(seconds: 90))),
        MotionAction.none,
      );
      expect(policy.isPaused, isFalse);

      // Even ticking well past the 3 min mark now finds nothing running.
      expect(
        policy.tick(t0.add(const Duration(minutes: 5))),
        MotionAction.none,
      );
      expect(policy.isPaused, isFalse);
    });

    test('pauses exactly once the 3 min threshold is reached', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);

      expect(
        policy.tick(
          t0.add(const Duration(minutes: 3) - const Duration(seconds: 1)),
        ),
        MotionAction.none,
      );
      expect(policy.isPaused, isFalse);

      expect(
        policy.tick(t0.add(const Duration(minutes: 3))),
        MotionAction.pause,
      );
      expect(policy.isPaused, isTrue);
    });

    test('a later still-entered call does not push the countdown back', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      // A second "still" fix five seconds later must not reset the timer.
      policy.stillEntered(t0.add(const Duration(seconds: 5)));

      expect(
        policy.tick(t0.add(const Duration(minutes: 3))),
        MotionAction.pause,
      );
    });

    test('navGuided doubles the threshold to 6 minutes', () {
      final policy = MotionPolicy(navGuided: true);
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);

      expect(
        policy.tick(t0.add(const Duration(minutes: 3))),
        MotionAction.none,
        reason: 'the free-trip threshold must not apply while nav-guided',
      );
      expect(
        policy.tick(
          t0.add(const Duration(minutes: 6) - const Duration(seconds: 1)),
        ),
        MotionAction.none,
      );
      expect(
        policy.tick(t0.add(const Duration(minutes: 6))),
        MotionAction.pause,
      );
    });

    test('stillExited with no timer running, and not paused, is a no-op', () {
      final policy = MotionPolicy();
      expect(
        policy.stillExited(DateTime.utc(2026, 8, 31, 9, 0, 0)),
        MotionAction.none,
      );
      expect(policy.isPaused, isFalse);
    });

    test('tick with nothing running stays quiet', () {
      final policy = MotionPolicy();
      expect(
        policy.tick(DateTime.utc(2026, 8, 31, 9, 0, 0)),
        MotionAction.none,
      );
    });

    test('isStillTimerRunning reflects the running countdown', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      expect(policy.isStillTimerRunning, isFalse);
      policy.stillEntered(t0);
      expect(policy.isStillTimerRunning, isTrue);
      policy.stillExited(t0.add(const Duration(seconds: 10)));
      expect(policy.isStillTimerRunning, isFalse);
    });
  });

  group('MotionPolicy — resume', () {
    test('stillExited while paused resumes immediately, regardless of the '
        'safety-fix schedule', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      policy.tick(t0.add(const Duration(minutes: 3)));
      expect(policy.isPaused, isTrue);

      // Only a few seconds into the pause — long before any safety fix.
      expect(
        policy.stillExited(t0.add(const Duration(minutes: 3, seconds: 5))),
        MotionAction.resume,
      );
      expect(policy.isPaused, isFalse);
    });

    test('after a resume, a fresh still spell must reach the full '
        'threshold again before pausing', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      policy.tick(t0.add(const Duration(minutes: 3)));
      policy.stillExited(t0.add(const Duration(minutes: 3, seconds: 5)));

      final t1 = t0.add(const Duration(minutes: 10));
      policy.stillEntered(t1);
      expect(
        policy.tick(
          t1.add(const Duration(minutes: 3) - const Duration(seconds: 1)),
        ),
        MotionAction.none,
      );
      expect(
        policy.tick(t1.add(const Duration(minutes: 3))),
        MotionAction.pause,
      );
    });
  });

  group('MotionPolicy — safety fix cadence', () {
    test('no safety fix before the interval elapses', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      final pauseAt = t0.add(const Duration(minutes: 3));
      expect(policy.tick(pauseAt), MotionAction.pause);

      expect(
        policy.tick(
          pauseAt.add(const Duration(minutes: 3) - const Duration(seconds: 1)),
        ),
        MotionAction.none,
      );
    });

    test('one safety fix every 3 minutes while paused', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      final pauseAt = t0.add(const Duration(minutes: 3));
      expect(policy.tick(pauseAt), MotionAction.pause);

      final firstFixAt = pauseAt.add(const Duration(minutes: 3));
      expect(policy.tick(firstFixAt), MotionAction.takeSafetyFix);
      expect(
        policy.isPaused,
        isTrue,
        reason: 'a safety fix alone must not resume',
      );

      // Nothing again until another full interval has passed.
      expect(
        policy.tick(firstFixAt.add(const Duration(seconds: 1))),
        MotionAction.none,
      );
      expect(
        policy.tick(firstFixAt.add(const Duration(minutes: 3))),
        MotionAction.takeSafetyFix,
      );
    });

    test('a resume cancels the pending safety-fix schedule', () {
      final policy = MotionPolicy();
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      final pauseAt = t0.add(const Duration(minutes: 3));
      policy.tick(pauseAt);
      policy.stillExited(pauseAt.add(const Duration(seconds: 30)));

      // A tick at what would have been the 3 min safety-fix mark must not
      // fire one — there is nothing left to guard, the trip already resumed.
      expect(
        policy.tick(pauseAt.add(const Duration(minutes: 3))),
        MotionAction.none,
      );
    });
  });

  group('GpsStillnessTracker', () {
    late MotionPolicy policy;
    late GpsStillnessTracker tracker;

    setUp(() {
      policy = MotionPolicy();
      tracker = GpsStillnessTracker(policy, distance: metersBetween);
    });

    test('the first fix ever fed seeds the anchor and reads as still', () {
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      expect(tracker.onFix(46.5, 6.6, t0), MotionAction.none);
      expect(policy.isStillTimerRunning, isTrue);
    });

    test('a fix within the threshold of the anchor keeps reading still, '
        'eventually pausing', () {
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      tracker.onFix(46.5, 6.6, t0);
      // A few metres of GPS jitter, same spot.
      tracker.onFix(46.500002, 6.6, t0.add(const Duration(seconds: 30)));
      expect(
        policy.tick(t0.add(const Duration(minutes: 3))),
        MotionAction.pause,
      );
    });

    test('a fix beyond the threshold reads as moved and resets the anchor', () {
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      tracker.onFix(46.5, 6.6, t0);
      // ~100 m north — well past the 15 m threshold.
      final moved = tracker.onFix(
        46.5009,
        6.6,
        t0.add(const Duration(seconds: 30)),
      );
      expect(moved, MotionAction.none); // was not paused, so just resets
      expect(policy.isStillTimerRunning, isFalse);

      // The clock reaching the original 3 min mark (from t0) must not pause
      // — the timer only restarted at the moved fix's own timestamp.
      expect(
        policy.tick(t0.add(const Duration(minutes: 3))),
        MotionAction.none,
      );
    });

    test('seed() sets the anchor without triggering a transition', () {
      tracker.seed(46.5, 6.6);
      expect(policy.isStillTimerRunning, isFalse);
      expect(policy.isPaused, isFalse);
    });

    test('a safety fix beyond the threshold resumes a paused policy', () {
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      final pauseAt = t0.add(const Duration(minutes: 3));
      policy.tick(pauseAt);
      expect(policy.isPaused, isTrue);

      tracker.seed(46.5, 6.6);
      final safetyFixAt = pauseAt.add(const Duration(minutes: 3));
      // ~100 m away: the walker moved, but the STILL-exit broadcast for it
      // never arrived — this is exactly what the safety fix guards against.
      final action = tracker.onFix(46.5009, 6.6, safetyFixAt);
      expect(action, MotionAction.resume);
      expect(policy.isPaused, isFalse);
    });

    test('a safety fix within the threshold leaves the pause untouched', () {
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy.stillEntered(t0);
      final pauseAt = t0.add(const Duration(minutes: 3));
      policy.tick(pauseAt);

      tracker.seed(46.5, 6.6);
      final safetyFixAt = pauseAt.add(const Duration(minutes: 3));
      final action = tracker.onFix(46.500002, 6.6, safetyFixAt);
      expect(action, MotionAction.none);
      expect(policy.isPaused, isTrue);
    });

    test('a custom movement threshold is honoured', () {
      final looseTracker = GpsStillnessTracker(
        policy,
        distance: metersBetween,
        movementThresholdM: 200,
      );
      final t0 = DateTime.utc(2026, 8, 31, 9, 0, 0);
      looseTracker.onFix(46.5, 6.6, t0);
      // ~100 m — inside the loosened 200 m threshold, so still reads as
      // "still" rather than the default tracker's "moved".
      final action = looseTracker.onFix(
        46.5009,
        6.6,
        t0.add(const Duration(seconds: 30)),
      );
      expect(action, MotionAction.none);
      expect(policy.isStillTimerRunning, isTrue);
    });
  });
}
