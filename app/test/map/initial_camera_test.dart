import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/initial_camera.dart';

void main() {
  group('resolveInitialCameraCenter', () {
    test('uses the last-known position when there is one', () async {
      final center =
          await resolveInitialCameraCenter(() async => (46.9481, 7.4474));
      expect(center.latitude, closeTo(46.9481, 1e-9));
      expect(center.longitude, closeTo(7.4474, 1e-9));
    });

    test('falls back to Geneva when there is no last-known position',
        () async {
      final center = await resolveInitialCameraCenter(() async => null);
      expect(center, same(kDefaultCameraCenter));
      expect(center.latitude, closeTo(46.2044, 1e-9));
      expect(center.longitude, closeTo(6.1432, 1e-9));
    });

    test('falls back to Geneva — not Lausanne — on a platform failure',
        () async {
      final center = await resolveInitialCameraCenter(
          () async => throw StateError('no permission yet'));
      expect(center, same(kDefaultCameraCenter));
    });
  });
}
