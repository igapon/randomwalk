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
Future<LatLng> resolveInitialCameraCenter(
  Future<(double, double)?> Function() getLastKnownPosition,
) async {
  try {
    final last = await getLastKnownPosition();
    if (last != null) return LatLng(last.$1, last.$2);
  } catch (_) {
    // Fall through to the default below.
  }
  return kDefaultCameraCenter;
}
