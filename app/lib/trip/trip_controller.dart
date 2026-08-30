import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../session/recorder.dart';
import '../session/session_controller.dart';
import '../valhalla/models.dart';

enum TripState { idle, recording }

const _kTripProfileKey = 'trip_profile';

/// One-tap trip start/stop. Composes [SessionController] rather than
/// duplicating its lifecycle: `stopTrip()` calls `sessionController.stop()`
/// directly, so whatever `onSessionEnded`/`onSessionError` callbacks the
/// caller already wired on that controller (leaderboard submit, etc.) keep
/// firing unchanged.
///
/// Two flavours of trip:
/// - route-bound: a [RouteResult] from the planner (T9) is supplied, camera
///   follow is switched on for the duration of the trip.
/// - free: no route: the last-used routing profile (Marche/Vélo) is
///   remembered across trips via shared_preferences.
///
/// A [ChangeNotifier] so [MapScreen]/[SessionScreen] can share one instance
/// (see [tripControllerProvider]) and both rebuild on start/stop, without
/// either screen owning the trip's lifecycle.
class TripController extends ChangeNotifier {
  final SessionController sessionController;
  final Future<void> Function(RoutingProfile profile) _persistProfile;
  final Future<RoutingProfile?> Function() _loadProfile;

  /// Notified when the map should turn its "follow me" camera mode on
  /// (route-bound trip start) or off (trip stop / manual pan elsewhere).
  /// Mutable (not constructor-only) so the map screen — the only widget
  /// holding the actual `MapLibreMapController` — can wire/unwire it from
  /// `initState`/`dispose` regardless of which screen started the trip.
  void Function(bool follow)? onCameraFollowChanged;

  TripState _state = TripState.idle;
  bool _routeBound = false;
  RouteResult? _route;
  RoutingProfile _profile = RoutingProfile.walk;

  TripController(
    this.sessionController, {
    Future<void> Function(RoutingProfile profile)? persistProfile,
    Future<RoutingProfile?> Function()? loadProfile,
    this.onCameraFollowChanged,
  })  : _persistProfile = persistProfile ?? _defaultPersistProfile,
        _loadProfile = loadProfile ?? _defaultLoadProfile;

  TripState get state => _state;
  bool get isRecording => _state == TripState.recording;
  bool get isRouteBound => _routeBound;
  RouteResult? get route => _route;
  RoutingProfile get profile => _profile;

  static Future<void> _defaultPersistProfile(RoutingProfile profile) async {
    await (await SharedPreferences.getInstance())
        .setString(_kTripProfileKey, profile.name);
  }

  static Future<RoutingProfile?> _defaultLoadProfile() async {
    final stored =
        (await SharedPreferences.getInstance()).getString(_kTripProfileKey);
    return RoutingProfile.values
        .where((p) => p.name == stored)
        .cast<RoutingProfile?>()
        .firstWhere((_) => true, orElse: () => null);
  }

  /// Starts a trip. If [route] is supplied the trip is route-bound (camera
  /// follow turns on); otherwise it's a free trip using [profile] (falling
  /// back to the last remembered profile, defaulting to walk). Ignored
  /// (returns false) if a trip is already recording.
  Future<bool> startTrip({RouteResult? route, RoutingProfile? profile}) async {
    if (_state == TripState.recording) return false;

    if (profile != null) {
      _profile = profile;
      await _persistProfile(profile);
    } else {
      _profile = await _loadProfile() ?? _profile;
    }

    final started = await sessionController.start();
    if (!started) return false;

    _routeBound = route != null;
    _route = route;
    _state = TripState.recording;
    if (_routeBound) onCameraFollowChanged?.call(true);
    notifyListeners();
    return true;
  }

  /// Stops the current trip via [SessionController.stop] (same path used by
  /// the leaderboard submit callback) and releases camera follow. No-op
  /// (returns 0) if idle.
  Future<double> stopTrip() async {
    if (_state != TripState.recording) return 0;
    final distanceKm = await sessionController.stop();
    _state = TripState.idle;
    _routeBound = false;
    _route = null;
    // Always released on stop: harmless no-op if camera follow was never
    // switched on (free trip, or already released by a manual pan).
    onCameraFollowChanged?.call(false);
    notifyListeners();
    return distanceKm;
  }
}

/// Single shared [SessionController] for the whole app: the map's "Démarrer"
/// pill and the Session tab's own start/stop both drive the same recording,
/// so either one starting or stopping it is reflected in both places.
final sessionControllerProvider = Provider<SessionController>((ref) {
  final controller = SessionController(store: TotalDistanceStore());
  ref.onDispose(controller.dispose);
  return controller;
});

final tripControllerProvider = ChangeNotifierProvider<TripController>((ref) {
  return TripController(ref.watch(sessionControllerProvider));
});
