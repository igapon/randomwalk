import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/tracking/motion_policy.dart';

void main() {
  group('MotionPolicy — sustained stillness', () {
    test('a still spell shorter than the threshold never pauses '
        '(a red light must never suspend)', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();

      // Red light: 90 s of stillness, then movement again.
      now = now.add(const Duration(seconds: 90));
      expect(policy.tick(), MotionAction.none);
      expect(policy.stillExited(), MotionAction.none);
      expect(policy.isPaused, isFalse);

      // Even ticking well past the 3 min mark now finds nothing running.
      now = now.add(const Duration(minutes: 5));
      expect(policy.tick(), MotionAction.none);
      expect(policy.isPaused, isFalse);
    });

    test('pauses exactly once the 3 min threshold is reached', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();

      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.none);
      expect(policy.isPaused, isFalse);

      now = now.add(const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.pause);
      expect(policy.isPaused, isTrue);
    });

    test('a later still-entered call does not push the countdown back', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      // A second "still" fix five seconds later must not reset the timer.
      now = now.add(const Duration(seconds: 5));
      policy.stillEntered();

      now = DateTime.utc(2026, 8, 31, 9, 3, 0);
      expect(policy.tick(), MotionAction.pause);
    });

    test('navGuided doubles the threshold to 6 minutes', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(navGuided: true, clock: () => now);
      policy.stillEntered();

      now = now.add(const Duration(minutes: 3));
      expect(
        policy.tick(),
        MotionAction.none,
        reason: 'the free-trip threshold must not apply while nav-guided',
      );
      now = DateTime.utc(2026, 8, 31, 9, 5, 59);
      expect(policy.tick(), MotionAction.none);
      now = DateTime.utc(2026, 8, 31, 9, 6, 0);
      expect(policy.tick(), MotionAction.pause);
    });

    test('stillExited with no timer running, and not paused, is a no-op', () {
      final policy = MotionPolicy(clock: () => DateTime.utc(2026, 8, 31, 9));
      expect(policy.stillExited(), MotionAction.none);
      expect(policy.isPaused, isFalse);
    });

    test('tick with nothing running stays quiet', () {
      final policy = MotionPolicy(clock: () => DateTime.utc(2026, 8, 31, 9));
      expect(policy.tick(), MotionAction.none);
    });

    test('isStillTimerRunning reflects the running countdown', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      expect(policy.isStillTimerRunning, isFalse);
      policy.stillEntered();
      expect(policy.isStillTimerRunning, isTrue);
      now = now.add(const Duration(seconds: 10));
      policy.stillExited();
      expect(policy.isStillTimerRunning, isFalse);
    });

    test('fix round 1 (I5): a skewed sample.time has no effect on the 3 min '
        'window — the policy clock is the only time authority', () {
      // Regression for the cross-clock bug: previously stillEntered/
      // stillExited/tick each took an explicit DateTime from whatever
      // clock the caller happened to have (a GPS fix's own provider
      // timestamp vs. the framework's own timestamp). Now MotionPolicy
      // reads only its own injected clock — a caller passing along a
      // wildly skewed fix timestamp (simulated here by simply never
      // reading it) cannot shorten or lengthen the threshold at all.
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);

      // A "GPS fix" arrives whose own device-provider timestamp claims
      // this is already 9:10 — 10 minutes in the future relative to the
      // policy's real clock. Nothing in the public API even accepts that
      // timestamp any more (stillEntered() is niladic), which is itself
      // the fix: there is no longer a parameter through which skew could
      // enter.
      policy.stillEntered();

      // Only 2:59 have passed on the policy's own clock — must not have
      // pause, even though a skewed fix timestamp of "9:10" would imply
      // the threshold was crossed ten minutes ago.
      now = DateTime.utc(2026, 8, 31, 9, 2, 59);
      expect(policy.tick(), MotionAction.none);

      now = DateTime.utc(2026, 8, 31, 9, 3, 0);
      expect(policy.tick(), MotionAction.pause);
    });
  });

  group('MotionPolicy — resume', () {
    test('stillExited while paused resumes immediately, regardless of the '
        'safety-fix schedule', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      policy.tick();
      expect(policy.isPaused, isTrue);

      // Only a few seconds into the pause — long before any safety fix.
      now = now.add(const Duration(seconds: 5));
      expect(policy.stillExited(), MotionAction.resume);
      expect(policy.isPaused, isFalse);
    });

    test('after a resume, a fresh still spell must reach the full '
        'threshold again before pausing', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      policy.tick();
      now = now.add(const Duration(seconds: 5));
      policy.stillExited();

      now = DateTime.utc(2026, 8, 31, 9, 10, 0);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.none);
      now = now.add(const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.pause);
    });
  });

  group('MotionPolicy — safety fix cadence', () {
    test('no safety fix before the interval elapses', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      expect(policy.tick(), MotionAction.pause);

      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.none);
    });

    test('one safety fix every 3 minutes while paused', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      expect(policy.tick(), MotionAction.pause);

      now = now.add(const Duration(minutes: 3));
      expect(policy.tick(), MotionAction.takeSafetyFix);
      expect(
        policy.isPaused,
        isTrue,
        reason: 'a safety fix alone must not resume',
      );

      // Nothing again until another full interval has passed.
      now = now.add(const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.none);

      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 1));
      expect(policy.tick(), MotionAction.takeSafetyFix);
    });

    test('a resume cancels the pending safety-fix schedule', () {
      var now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      final policy = MotionPolicy(clock: () => now);
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      policy.tick();
      now = now.add(const Duration(seconds: 30));
      policy.stillExited();

      // A tick at what would have been the 3 min safety-fix mark must not
      // fire one — there is nothing left to guard, the trip already resumed.
      now = now.add(const Duration(minutes: 3) - const Duration(seconds: 30));
      expect(policy.tick(), MotionAction.none);
    });
  });

  group('GpsStillnessTracker', () {
    late DateTime now;
    late MotionPolicy policy;
    late GpsStillnessTracker tracker;

    setUp(() {
      now = DateTime.utc(2026, 8, 31, 9, 0, 0);
      policy = MotionPolicy(clock: () => now);
      tracker = GpsStillnessTracker(policy, distance: metersBetween);
    });

    test('the first fix ever fed seeds the anchor and reads as still', () {
      expect(tracker.onFix(46.5, 6.6), MotionAction.none);
      expect(policy.isStillTimerRunning, isTrue);
    });

    test('a fix within the threshold of the anchor keeps reading still, '
        'eventually pausing', () {
      tracker.onFix(46.5, 6.6);
      // A few metres of GPS jitter, same spot.
      now = now.add(const Duration(seconds: 30));
      tracker.onFix(46.500002, 6.6);
      now = DateTime.utc(2026, 8, 31, 9, 3, 0);
      expect(policy.tick(), MotionAction.pause);
    });

    test('a fix beyond the threshold reads as moved and resets the anchor', () {
      tracker.onFix(46.5, 6.6);
      // ~100 m north — well past the 15 m threshold.
      now = now.add(const Duration(seconds: 30));
      final moved = tracker.onFix(46.5009, 6.6);
      expect(moved, MotionAction.none); // was not paused, so just resets
      expect(policy.isStillTimerRunning, isFalse);

      // The clock reaching the original 3 min mark (from the first fix)
      // must not pause — the timer only restarted at the moved fix's own
      // moment.
      now = DateTime.utc(2026, 8, 31, 9, 3, 0);
      expect(policy.tick(), MotionAction.none);
    });

    test('seed() sets the anchor without triggering a transition', () {
      tracker.seed(46.5, 6.6);
      expect(policy.isStillTimerRunning, isFalse);
      expect(policy.isPaused, isFalse);
    });

    test('a safety fix beyond the threshold resumes a paused policy', () {
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      policy.tick();
      expect(policy.isPaused, isTrue);

      tracker.seed(46.5, 6.6);
      now = now.add(const Duration(minutes: 3));
      // ~100 m away: the walker moved, but the STILL-exit broadcast for it
      // never arrived — this is exactly what the safety fix guards against.
      final action = tracker.onFix(46.5009, 6.6);
      expect(action, MotionAction.resume);
      expect(policy.isPaused, isFalse);
    });

    test('a safety fix within the threshold leaves the pause untouched', () {
      policy.stillEntered();
      now = now.add(const Duration(minutes: 3));
      policy.tick();

      tracker.seed(46.5, 6.6);
      now = now.add(const Duration(minutes: 3));
      final action = tracker.onFix(46.500002, 6.6);
      expect(action, MotionAction.none);
      expect(policy.isPaused, isTrue);
    });

    test('a custom movement threshold is honoured', () {
      final looseTracker = GpsStillnessTracker(
        policy,
        distance: metersBetween,
        movementThresholdM: 200,
      );
      looseTracker.onFix(46.5, 6.6);
      // ~100 m — inside the loosened 200 m threshold, so still reads as
      // "still" rather than the default tracker's "moved".
      now = now.add(const Duration(seconds: 30));
      final action = looseTracker.onFix(46.5009, 6.6);
      expect(action, MotionAction.none);
      expect(policy.isStillTimerRunning, isTrue);
    });
  });
}
