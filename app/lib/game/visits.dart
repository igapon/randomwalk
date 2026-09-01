import '../nav/polyline_math.dart';
import 'pois.dart';

/// Radius (meters) within which a GPS fix counts as "at" a landmark — the
/// M4 plan's "geofence 25 m" (Global Constraints / Task 5 brief). Inclusive:
/// a fix exactly 25.0 m away counts as in range.
const kVisitRadiusM = 25.0;

/// How long a walker must stay continuously within [kVisitRadiusM] of the
/// same landmark before it counts as visited (brief: "dwell 5 s").
/// Inclusive: a dwell of exactly 5.0 s completes the visit.
const kVisitDwell = Duration(seconds: 5);

/// One landmark visit, as detected by [VisitDetector.onFix].
class PoiVisit {
  final GamePoi poi;

  /// The fix time at which the dwell threshold was crossed — NOT the time
  /// the walker first entered the geofence.
  final DateTime ts;

  const PoiVisit(this.poi, this.ts);
}

/// Pure geofence + dwell detector for game landmarks.
///
/// Fed a pre-filtered list of *candidate* POIs — the caller
/// (`tracking/tracking_service.dart`'s `TripTaskHandler`) narrows the full
/// ~140k-entry dataset to a few-kilometer disc via `PoiStore.near` before
/// constructing this — so a per-fix linear scan over [pois] stays cheap even
/// though [PoiStore] itself is not queried again here.
///
/// A landmark counts as visited once a GPS fix stream stays within
/// [kVisitRadiusM] meters of it for at least [kVisitDwell] *continuously*:
/// leaving the radius — even briefly, even to move toward a different,
/// also-in-range landmark — resets the dwell clock. Each `poiId` fires
/// [PoiVisit] at most once for the lifetime of one detector instance (one
/// recording trip, in production); a later fix reaching the same place again
/// is simply ignored for that id.
///
/// When more than one candidate landmark is within range on the same fix,
/// only the *nearest* accumulates dwell time ("nearest POI wins" — brief).
/// If the nearest one changes between fixes (the walker is between two
/// landmarks and the closer one flips), the dwell clock restarts for the new
/// nearest one — the abandoned one keeps no credit for time already spent
/// near it.
class VisitDetector {
  final List<GamePoi> _pois;
  final Set<String> _detected = {};

  String? _trackingPoiId;
  DateTime? _enteredAt;

  VisitDetector(List<GamePoi> pois) : _pois = pois;

  /// Feeds one accepted GPS fix through the detector. Returns the
  /// [PoiVisit] that just crossed the dwell threshold, or `null` on a fix
  /// that does not complete one (including every fix after a landmark has
  /// already been detected once).
  PoiVisit? onFix(double lat, double lon, DateTime time) {
    final nearest = _nearestInRange(lat, lon);

    if (nearest == null) {
      _trackingPoiId = null;
      _enteredAt = null;
      return null;
    }

    if (_trackingPoiId != nearest.id) {
      _trackingPoiId = nearest.id;
      _enteredAt = time;
      return null;
    }

    final enteredAt = _enteredAt ?? time;
    if (time.difference(enteredAt) < kVisitDwell) {
      _enteredAt = enteredAt;
      return null;
    }

    _detected.add(nearest.id);
    _trackingPoiId = null;
    _enteredAt = null;
    return PoiVisit(nearest, time);
  }

  /// The nearest not-yet-detected candidate within [kVisitRadiusM] of
  /// ([lat], [lon]), or `null` if none qualifies.
  GamePoi? _nearestInRange(double lat, double lon) {
    GamePoi? nearest;
    var nearestDist = double.infinity;
    for (final poi in _pois) {
      if (_detected.contains(poi.id)) continue;
      final d = metersBetween(lat, lon, poi.lat, poi.lon);
      if (d <= kVisitRadiusM && d < nearestDist) {
        nearestDist = d;
        nearest = poi;
      }
    }
    return nearest;
  }
}
