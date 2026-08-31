import 'package:maplibre_gl/maplibre_gl.dart';

/// Geneva — the app's home city — used whenever no last-known position is
/// available (a fresh install, or a device with location permission not yet
/// granted). Owner device-QA addendum, point 1: never Lausanne, which had
/// been hardcoded here before.
const kDefaultCameraCenter = LatLng(46.2044, 6.1432);

/// Resolves where [MapScreen]'s camera should start.
///
/// [getLastKnownPosition] is expected to wrap
/// `Geolocator.getLastKnownPosition()` — a cached read with no permission
/// prompt of its own, returning null harmlessly when the app has never been
/// granted location access. A plain `(lat, lon)` record rather than a
/// `Position`, so this stays testable without constructing geolocator's
/// full (and mostly irrelevant, for a camera center) position object.
///
/// Any failure from the platform call — not just a null result — also falls
/// back to [kDefaultCameraCenter]: this runs before the map's first frame,
/// and a screen that cannot even open because a location lookup threw would
/// be a strictly worse outcome than opening centered on Geneva.
///
/// [timeout] bounds how long that first frame is willing to wait — fix-round
/// finding: `MapScreen.build` gates its very first frame on this future, so
/// an indefinitely-hung platform channel (a wedged geolocator plugin, say)
/// used to mean a spinner forever rather than a screen that opens, late,
/// centered on Geneva.
///
/// [wait] is the delay primitive behind that timeout — defaults to
/// `Future.delayed`, injectable so a test can pin down which side of the
/// race wins deterministically. `Future.timeout()`'s own internal `Timer`
/// was tried first and dropped: importing `maplibre_gl` (for [LatLng])
/// pulls in Flutter's test-binding initialization, which puts `flutter
/// test` under `AutomatedTestWidgetsFlutterBinding`'s virtual clock — under
/// which a real `Timer(Duration(seconds: 2))` can fire before an
/// already-resolved-but-not-yet-microtask-flushed future does, turning a
/// "fast, successful lookup" test flaky rather than exercising the actual
/// timeout path. Racing explicitly via [Future.any] and letting tests
/// inject a [wait] that simply never resolves (see
/// `initial_camera_test.dart`) sidesteps that race instead of chasing it.
Future<LatLng> resolveInitialCameraCenter(
  Future<(double, double)?> Function() getLastKnownPosition, {
  Duration timeout = const Duration(seconds: 2),
  Future<void> Function(Duration duration)? wait,
}) async {
  try {
    final position = getLastKnownPosition()
        // Observed unconditionally: if the timeout wins the race below, a
        // position that arrives (or errors) afterwards must not surface as
        // an unhandled exception in the zone.
        .then<(double, double)?>((v) => v, onError: (_) => null);
    final timedOut = (wait ?? Future.delayed)(timeout).then((_) => null);
    final last = await Future.any([position, timedOut]);
    if (last != null) return LatLng(last.$1, last.$2);
  } catch (_) {
    // Fall through to the default below.
  }
  return kDefaultCameraCenter;
}
