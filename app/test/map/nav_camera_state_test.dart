import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/map/nav_camera_state.dart';

void main() {
  group('shouldShowRecenterButton', () {
    test('hidden while idle, tracking untouched', () {
      expect(
        shouldShowRecenterButton(isNavigating: false, trackingReleased: false),
        isFalse,
      );
    });

    test('hidden while navigating but still tracking', () {
      expect(
        shouldShowRecenterButton(isNavigating: true, trackingReleased: false),
        isFalse,
      );
    });

    test('hidden once tracking is released if no longer navigating', () {
      // e.g. the trip ended right after a gesture released the camera.
      expect(
        shouldShowRecenterButton(isNavigating: false, trackingReleased: true),
        isFalse,
      );
    });

    test('shown while navigating with tracking released by a gesture', () {
      expect(
        shouldShowRecenterButton(isNavigating: true, trackingReleased: true),
        isTrue,
      );
    });
  });
}
