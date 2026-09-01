// Task 2b brief item 3e: unit tests for the boot-time coverage preload
// trigger — fake position + fake coverage, called at boot; not called when
// a trip was restored active; silent on failure; the 24h guard.

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/boot_preload.dart';

void main() {
  group('BootCoveragePreloader', () {
    late List<(double, double)> ensureCalls;
    late bool tripActive;
    late DateTime? lastRun;
    late DateTime now;
    late bool throwOnEnsure;

    BootCoveragePreloader preloader({
      (double, double)? lastKnown,
      (double, double)? current,
    }) => BootCoveragePreloader(
      getLastKnownPosition: () async => lastKnown,
      getCurrentPosition: () async => current,
      ensureCoverage: (lat, lon, {onProgress}) async {
        if (throwOnEnsure) throw Exception('boom');
        ensureCalls.add((lat, lon));
        onProgress?.call(1, 1);
      },
      isTripActive: () => tripActive,
      lastRunAt: () async => lastRun,
      markRanAt: (t) async => lastRun = t,
      clock: () => now,
    );

    setUp(() {
      ensureCalls = [];
      tripActive = false;
      lastRun = null;
      now = DateTime.utc(2026, 9, 1, 8);
      throwOnEnsure = false;
    });

    test('calls ensureCoverage with the last-known position at boot', () async {
      await preloader(lastKnown: (46.5, 6.6)).maybeRun();
      expect(ensureCalls, [(46.5, 6.6)]);
      expect(lastRun, now);
    });

    test(
      'falls back to the current position when there is no last known one',
      () async {
        await preloader(current: (46.2, 6.1)).maybeRun();
        expect(ensureCalls, [(46.2, 6.1)]);
      },
    );

    test('gives up silently when no position is available at all', () async {
      await preloader().maybeRun();
      expect(ensureCalls, isEmpty);
      expect(lastRun, isNull);
    });

    test(
      'skips entirely when a trip is active (recording or interrupted)',
      () async {
        tripActive = true;
        await preloader(lastKnown: (46.5, 6.6)).maybeRun();
        expect(ensureCalls, isEmpty);
      },
    );

    test(
      'a failed coverage fetch is silent and does not mark the guard',
      () async {
        throwOnEnsure = true;
        await preloader(lastKnown: (46.5, 6.6)).maybeRun();
        expect(lastRun, isNull);
      },
    );

    test('the 24h guard skips a re-run within the window', () async {
      lastRun = now.subtract(const Duration(hours: 5));
      await preloader(lastKnown: (46.5, 6.6)).maybeRun();
      expect(ensureCalls, isEmpty);
    });

    test('runs again once the 24h guard has elapsed', () async {
      lastRun = now.subtract(const Duration(hours: 25));
      await preloader(lastKnown: (46.5, 6.6)).maybeRun();
      expect(ensureCalls, [(46.5, 6.6)]);
    });

    test('reports progress via onProgress', () async {
      ({int done, int total})? seen;
      await preloader(lastKnown: (46.5, 6.6)).maybeRun(
        onProgress: (done, total) => seen = (done: done, total: total),
      );
      expect(seen, (done: 1, total: 1));
    });
  });
}
