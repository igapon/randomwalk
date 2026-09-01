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

  group('shouldReengageTrackingOnRemount', () {
    test('idle: never re-engages', () {
      expect(
        shouldReengageTrackingOnRemount(
          isRecording: false,
          isRouteBound: false,
          trackingReleased: false,
        ),
        isFalse,
      );
    });

    test('recording a free (not route-bound) trip: never re-engages', () {
      expect(
        shouldReengageTrackingOnRemount(
          isRecording: true,
          isRouteBound: false,
          trackingReleased: false,
        ),
        isFalse,
      );
    });

    test('navigating, tracking never released: re-engages', () {
      expect(
        shouldReengageTrackingOnRemount(
          isRecording: true,
          isRouteBound: true,
          trackingReleased: false,
        ),
        isTrue,
      );
    });

    test('navigating, tracking released by a gesture: does NOT re-engage — '
        'the fix-round regression this guards against', () {
      expect(
        shouldReengageTrackingOnRemount(
          isRecording: true,
          isRouteBound: true,
          trackingReleased: true,
        ),
        isFalse,
      );
    });

    test(
      'tracking released but no longer navigating: stays false either way',
      () {
        expect(
          shouldReengageTrackingOnRemount(
            isRecording: false,
            isRouteBound: true,
            trackingReleased: true,
          ),
          isFalse,
        );
      },
    );
  });
}
