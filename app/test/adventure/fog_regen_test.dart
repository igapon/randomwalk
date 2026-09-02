import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/fog_regen.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 31, 12, 0, 0);

  bool decide({
    DateTime? lastGen,
    required DateTime now,
    int lastRevealedVersion = 0,
    int revealedVersion = 0,
  }) => shouldRegenFog(
    lastGen: lastGen,
    now: now,
    lastRevealedVersion: lastRevealedVersion,
    revealedVersion: revealedVersion,
  );

  test('never generated yet: always regenerates', () {
    expect(decide(lastGen: null, now: t0), isTrue);
  });

  test('within the 2s throttle: never regenerates, even if the revealed set '
      'changed', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(milliseconds: 500)),
      lastRevealedVersion: 0,
      revealedVersion: 99,
    );
    expect(result, isFalse);
  });

  test('exactly at the throttle boundary counts as "elapsed"', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 2)),
      revealedVersion: 1,
      lastRevealedVersion: 0,
    );
    expect(result, isTrue);
  });

  test('throttle elapsed, nothing changed: no regen', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastRevealedVersion: 5,
      revealedVersion: 5,
    );
    expect(result, isFalse);
  });

  test('throttle elapsed, revealed set changed: regenerates', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastRevealedVersion: 5,
      revealedVersion: 6,
    );
    expect(result, isTrue);
  });

  test('panning the camera alone (no revealed-set change) never triggers a '
      'regen — Task 2h: the fog geometry no longer depends on the viewport '
      'at all, so this function has nothing left to say about camera '
      'movement', () {
    // Simulate many camera-idle callbacks firing well past the throttle,
    // all with the exact same revealed-set version: every single one
    // must decline to regenerate.
    for (var i = 1; i <= 5; i++) {
      final result = decide(
        lastGen: t0,
        now: t0.add(Duration(seconds: 2 + i)),
        lastRevealedVersion: 3,
        revealedVersion: 3,
      );
      expect(result, isFalse, reason: 'iteration $i');
    }
  });
}
