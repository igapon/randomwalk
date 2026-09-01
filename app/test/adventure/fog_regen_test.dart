import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/adventure/fog_regen.dart';

void main() {
  final t0 = DateTime.utc(2026, 8, 31, 12, 0, 0);
  const geneva = FogViewport((46.20, 6.14), (46.21, 6.15));

  bool decide({
    DateTime? lastGen,
    required DateTime now,
    FogViewport? lastViewport,
    FogViewport viewport = geneva,
    int lastRevealedVersion = 0,
    int revealedVersion = 0,
  }) =>
      shouldRegenFog(
        lastGen: lastGen,
        now: now,
        lastViewport: lastViewport,
        viewport: viewport,
        lastRevealedVersion: lastRevealedVersion,
        revealedVersion: revealedVersion,
      );

  test('never generated yet: always regenerates', () {
    expect(decide(lastGen: null, now: t0, lastViewport: null), isTrue);
  });

  test('within the 2s throttle: never regenerates, even if everything else changed', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(milliseconds: 500)),
      lastViewport: geneva,
      viewport: const FogViewport((47.0, 7.0), (47.01, 7.01)), // far away
      lastRevealedVersion: 0,
      revealedVersion: 99,
    );
    expect(result, isFalse);
  });

  test('exactly at the throttle boundary counts as "elapsed"', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 2)),
      lastViewport: geneva,
      revealedVersion: 1,
      lastRevealedVersion: 0,
    );
    expect(result, isTrue);
  });

  test('throttle elapsed, nothing changed: no regen', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastViewport: geneva,
      viewport: geneva,
      lastRevealedVersion: 5,
      revealedVersion: 5,
    );
    expect(result, isFalse);
  });

  test('throttle elapsed, revealed set changed: regenerates', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastViewport: geneva,
      viewport: geneva,
      lastRevealedVersion: 5,
      revealedVersion: 6,
    );
    expect(result, isTrue);
  });

  test('throttle elapsed, viewport moved past the ~1-cell threshold: regenerates', () {
    // ~150m north is well past one 150m cell.
    final moved = FogViewport((46.2014, 6.14), (46.2114, 6.15));
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastViewport: geneva,
      viewport: moved,
    );
    expect(result, isTrue);
  });

  test('throttle elapsed, viewport moved only a few meters: no regen', () {
    // ~5m north — well under the 150m cell threshold.
    final barelyMoved = FogViewport((46.200045, 6.14), (46.210045, 6.15));
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastViewport: geneva,
      viewport: barelyMoved,
    );
    expect(result, isFalse);
  });

  test('throttle elapsed, no last viewport recorded: treated as moved', () {
    final result = decide(
      lastGen: t0,
      now: t0.add(const Duration(seconds: 3)),
      lastViewport: null,
    );
    expect(result, isTrue);
  });

  test('FogViewport.center is the midpoint of sw/ne', () {
    const vp = FogViewport((46.0, 6.0), (46.2, 6.2));
    expect(vp.center, (46.1, 6.1));
  });

  test('FogViewport equality/hashCode by value', () {
    expect(const FogViewport((1, 2), (3, 4)),
        const FogViewport((1, 2), (3, 4)));
    expect(const FogViewport((1, 2), (3, 4)).hashCode,
        const FogViewport((1, 2), (3, 4)).hashCode);
  });
}
