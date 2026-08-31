import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/initial_camera.dart';

void main() {
  group('resolveInitialCameraCenter', () {
    // A `wait` that never resolves takes the timeout side of the race in
    // resolveInitialCameraCenter's Future.any out of contention entirely,
    // so these three tests deterministically exercise only the position
    // lookup — see the doc comment on resolveInitialCameraCenter for why a
    // real Timer here would otherwise race unpredictably under
    // `flutter test`'s virtual clock (triggered by importing `maplibre_gl`).
    Future<void> neverWaits(Duration _) => Completer<void>().future;

    test('uses the last-known position when there is one', () async {
      final center = await resolveInitialCameraCenter(
        () async => (46.9481, 7.4474),
        wait: neverWaits,
      );
      expect(center.latitude, closeTo(46.9481, 1e-9));
      expect(center.longitude, closeTo(7.4474, 1e-9));
    });

    test('falls back to Geneva when there is no last-known position',
        () async {
      final center = await resolveInitialCameraCenter(
        () async => null,
        wait: neverWaits,
      );
      expect(center, same(kDefaultCameraCenter));
      expect(center.latitude, closeTo(46.2044, 1e-9));
      expect(center.longitude, closeTo(6.1432, 1e-9));
    });

    test('falls back to Geneva — not Lausanne — on a platform failure',
        () async {
      final center = await resolveInitialCameraCenter(
        () async => throw StateError('no permission yet'),
        wait: neverWaits,
      );
      expect(center, same(kDefaultCameraCenter));
    });

    test('falls back to Geneva rather than hanging forever on a wedged call',
        () async {
      // A never-completing position lookup — the wedged-platform-channel
      // scenario the timeout exists for. Only the (real, default) delay
      // side of the race can ever resolve here, so this is deterministic
      // regardless of Timer/microtask ordering; a short override just
      // keeps the test fast.
      final center = await resolveInitialCameraCenter(
        () => Completer<(double, double)?>().future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(center, same(kDefaultCameraCenter));
    });
  });
}
