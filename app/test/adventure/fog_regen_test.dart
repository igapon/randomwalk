import 'dart:async';

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

  group('SingleFlightCoalescer (task 2l review fix round 1)', () {
    test('N identical-set triggers arriving during an in-flight compute '
        'cause exactly ONE regen call total — never N', () async {
      var callCount = 0;
      Completer<void>? gate;
      final coalescer = SingleFlightCoalescer<int, int>(
        regen: (payload, version, target) async {
          callCount++;
          gate = Completer<void>();
          await gate!.future;
        },
      );

      // Starts the in-flight call — synchronous up to the `await
      // gate!.future` inside `regen`, so both `isInFlight` and
      // `callCount` already reflect it the instant this line returns.
      final firstDone = coalescer.request(1, 1, 0);
      expect(coalescer.isInFlight, isTrue);
      expect(callCount, 1);

      // 10 more triggers, every one for the EXACT SAME version — the
      // review's own "identical-set triggers coalesce to nothing"
      // requirement.
      for (var i = 0; i < 10; i++) {
        await coalescer.request(1, 1, 0);
      }
      expect(callCount, 1, reason: 'still just the one in-flight call');

      gate!.complete();
      await firstDone;

      expect(
        callCount,
        1,
        reason: 'nothing ever actually changed, so no follow-up runs',
      );
      expect(coalescer.regenCallCount, 1);
      expect(coalescer.isInFlight, isFalse);
    });

    test('several DIFFERENT triggers arriving during an in-flight compute '
        'cause exactly ONE follow-up — never one per trigger — and the '
        'follow-up runs for the LATEST pending value (latest-wins)', () async {
      final gates = <Completer<void>>[];
      final seenPayloads = <int>[];
      final coalescer = SingleFlightCoalescer<int, int>(
        regen: (payload, version, target) async {
          seenPayloads.add(payload);
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
        },
      );

      final firstDone = coalescer.request(1, 1, 0);
      // Belt-and-braces: the synchronous-prefix guarantee above already
      // makes this true without any await, but yielding once here keeps
      // this test robust even if that internal detail ever changed.
      await Future<void>.delayed(Duration.zero);
      expect(coalescer.isInFlight, isTrue);
      expect(gates, hasLength(1));

      // Three DISTINCT requests arrive while the first is still gated —
      // only the LAST one may survive as the follow-up.
      await coalescer.request(2, 2, 0);
      await coalescer.request(3, 3, 0);
      await coalescer.request(4, 4, 0);
      expect(
        coalescer.regenCallCount,
        1,
        reason: 'still just the original in-flight call',
      );

      gates[0].complete(); // release the first regen.
      await Future<void>.delayed(Duration.zero); // let the chain proceed.

      expect(
        gates,
        hasLength(2),
        reason: 'exactly one follow-up started, not three',
      );
      expect(coalescer.regenCallCount, 2);
      expect(coalescer.isInFlight, isTrue); // now in-flight on the follow-up.

      gates[1].complete();
      await firstDone; // resolves once the whole chain has settled.

      expect(
        seenPayloads,
        [1, 4],
        reason:
            'the follow-up ran for the LATEST pending payload, not '
            '2 or 3, and not more than one follow-up total',
      );
      expect(coalescer.regenCallCount, 2);
      expect(coalescer.isInFlight, isFalse);
    });

    test('a request during an in-flight compute for the SAME version the '
        'in-flight call is already handling does not even queue a pending '
        'entry', () async {
      final gates = <Completer<void>>[];
      final coalescer = SingleFlightCoalescer<int, int>(
        regen: (payload, version, target) async {
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
        },
      );

      final firstDone = coalescer.request(5, 5, 0);
      await coalescer.request(5, 5, 0); // same version as in-flight.

      gates[0].complete();
      await firstDone;

      expect(gates, hasLength(1)); // no follow-up.
      expect(coalescer.regenCallCount, 1);
    });
  });
}
