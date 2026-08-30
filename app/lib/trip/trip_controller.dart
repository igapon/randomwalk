import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../session/recorder.dart';
import '../tracking/permissions.dart';
import '../tracking/steps.dart';
import '../tracking/tracking_service.dart';
import '../tracking/trip_snapshot.dart';
import '../valhalla/models.dart';
import 'active_route_store.dart';

enum TripState {
  idle,
  recording,

  /// A trip was recording when the app's process was killed and the
  /// foreground service went with it. Nothing is being recorded now, but
  /// the distance and steps up to that point are intact and the user has
  /// not been asked what to do with them yet.
  interrupted,
}

const _kTripProfileKey = 'trip_profile';

/// All of a trip's application state: the planned route, whether a trip is
/// recording, and how far it has got.
///
/// The important structural change over the version that composed
/// `SessionController` directly (task 13): the recording no longer lives in
/// this object, or even in this isolate. It runs in a foreground service,
/// and this controller is a *view* of it — it starts and stops the tracker,
/// reads the snapshots the tracker publishes, and owns everything that
/// needs an Activity (permission prompts, the step sensor). That is what
/// lets a trip survive the app being backgrounded, the screen going off,
/// and the app being swiped out of the recents list.
///
/// Everything it owns is either persisted by the tracker (trip progress) or
/// by [ActiveRouteStore] (the planned route), so a cold start can rebuild
/// the whole screen — including a « Trajet interrompu » offer — from disk.
class TripController extends ChangeNotifier {
  final TripTracker tracker;
  final ActiveRouteStore routeStore;
  final TotalDistanceStore _totals;
  final Future<TripPermissions> Function() ensurePermissions;
  final SessionStepCounter Function(int seed) _createStepCounter;
  final Future<TrackingMode> Function()? readTrackingMode;
  final DateTime Function() _clock;
  final Future<void> Function(RoutingProfile profile) _persistProfile;
  final Future<RoutingProfile?> Function() _loadProfile;

  /// Notified when the map should turn its "follow me" camera mode on
  /// (route-bound trip start) or off (trip stop / manual pan elsewhere).
  /// Mutable so the map screen — the only widget holding the actual
  /// `MapLibreMapController` — can wire/unwire it from `initState`/
  /// `dispose` regardless of which screen started the trip.
  void Function(bool follow)? onCameraFollowChanged;

  /// Invoked with the *cumulative* total km once a trip has been banked, so
  /// the shell can submit it to the leaderboard. Same contract the old
  /// `SessionController.onSessionEnded` had, moved here because banking a
  /// session is now the UI's job, not the recorder's.
  Future<void> Function(double totalKm)? onSessionEnded;

  /// Invoked when the recorder loses the GPS stream mid-trip.
  Future<void> Function(String? message)? onSessionError;

  TripState _state = TripState.idle;
  TripSnapshot? _snapshot;
  ActiveRoute? _activeRoute;
  RoutingProfile _profile = RoutingProfile.walk;
  TrackingMode _trackingMode = TrackingMode.background;
  TripPermissionOutcome? _lastOutcome;
  bool _starting = false;
  SessionStepCounter? _steps;
  StreamSubscription<TripSnapshot>? _updates;
  StreamSubscription<String?>? _errors;

  TripController({
    required this.tracker,
    required this.routeStore,
    required TotalDistanceStore totalStore,
    required this.ensurePermissions,
    SessionStepCounter Function(int seed)? createStepCounter,
    this.readTrackingMode,
    DateTime Function()? clock,
    Future<void> Function(RoutingProfile profile)? persistProfile,
    Future<RoutingProfile?> Function()? loadProfile,
    this.onCameraFollowChanged,
  })  : _totals = totalStore,
        _createStepCounter = createStepCounter ??
            ((seed) => SessionStepCounter(ChannelStepSensor(), seed: seed)),
        _clock = clock ?? DateTime.now,
        _persistProfile = persistProfile ?? _defaultPersistProfile,
        _loadProfile = loadProfile ?? _defaultLoadProfile {
    _updates = tracker.updates.listen(_onTrackerSnapshot);
    _errors = tracker.errors.listen((message) => onSessionError?.call(message));
  }

  TripState get state => _state;
  bool get isRecording => _state == TripState.recording;
  bool get isInterrupted => _state == TripState.interrupted;

  TripSnapshot? get snapshot => _snapshot;
  double get distanceKm => _snapshot?.distanceKm ?? 0;
  int get steps => _snapshot?.steps ?? 0;
  bool get needsReview => _snapshot?.needsReview ?? false;
  Duration get elapsed =>
      _state == TripState.idle ? Duration.zero : _snapshot?.elapsedAt(_clock()) ?? Duration.zero;

  ActiveRoute? get activeRoute => _activeRoute;
  RouteResult? get route => _activeRoute?.route;
  bool get isRouteBound => isRecording && (_snapshot?.routeBound ?? false);
  RoutingProfile get profile => _profile;

  /// Whether Android will keep feeding us positions with the screen off.
  /// [TrackingMode.foregroundOnly] is what the degraded-mode banner reads.
  TrackingMode get trackingMode => _trackingMode;

  /// Why the last [startTrip] refused, for the screen to phrase a message.
  TripPermissionOutcome? get lastOutcome => _lastOutcome;

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

  /// Rebuilds the whole trip state from disk. Called once at startup,
  /// before the first frame that could show a trip.
  Future<void> restore() async {
    _activeRoute = await routeStore.load();
    if (_activeRoute != null) _profile = _activeRoute!.profile;

    final snapshot = await tracker.readSnapshot();
    if (snapshot == null || !snapshot.isRecording) {
      // A non-recording snapshot is debris from a finalised trip; drop it
      // so the next cold start does not have to reason about it again.
      if (snapshot != null) await tracker.clearSnapshot();
      _state = TripState.idle;
      notifyListeners();
      return;
    }

    _snapshot = snapshot;
    _profile = snapshot.profile;
    if (await tracker.isRunning()) {
      // The service outlived the UI: adopt it rather than restarting it.
      _state = TripState.recording;
      _steps = _createStepCounter(snapshot.steps);
      await _steps!.start();
      if (snapshot.routeBound) onCameraFollowChanged?.call(true);
    } else {
      _state = TripState.interrupted;
    }
    notifyListeners();
  }

  /// Starts a trip. Runs the permission flow first (brief §4: asked at the
  /// moment the user actually wants to record, never in a burst at first
  /// launch). Returns false — with [lastOutcome] set — when the trip could
  /// not start.
  Future<bool> startTrip({RouteResult? route, RoutingProfile? profile}) async {
    // Refused while a trip is interrupted, not just while one is recording:
    // a fresh zeroed seed would overwrite the snapshot the « Trajet
    // interrompu » banner is offering to resume, silently binning the
    // distance it is showing. The banner is the only way out of that state.
    if (_state != TripState.idle || _starting) return false;

    if (profile != null) {
      _profile = profile;
      await _persistProfile(profile);
    } else {
      _profile = await _loadProfile() ?? _profile;
    }

    return _launch(TripSnapshot.starting(
      startedAt: _clock(),
      profile: _profile,
      routeBound: route != null,
    ));
  }

  /// « Reprendre » on the interrupted-trip banner: restarts the service
  /// seeded with the distance and steps already banked, and with the
  /// original start time so the elapsed clock does not reset.
  Future<bool> resumeInterrupted() async {
    final snapshot = _snapshot;
    if (_state != TripState.interrupted || snapshot == null) return false;
    return _launch(snapshot.copyWith(
        status: TripStatus.recording, updatedAt: _clock()));
  }

  /// « Terminer » on the interrupted-trip banner: banks what was recorded
  /// through exactly the same path a normal stop takes, so the leaderboard
  /// submit happens once and identically.
  Future<double> finishInterrupted() async {
    final snapshot = _snapshot;
    if (_state != TripState.interrupted || snapshot == null) return 0;
    return _finalise(snapshot);
  }

  Future<bool> _launch(TripSnapshot seed) async {
    _starting = true;
    try {
      final permissions = await ensurePermissions();
      _lastOutcome = permissions.outcome;
      _trackingMode = permissions.mode;
      if (!permissions.canStart) {
        notifyListeners();
        return false;
      }

      if (!await tracker.start(seed)) {
        notifyListeners();
        return false;
      }

      _snapshot = seed;
      _state = TripState.recording;
      _steps = _createStepCounter(seed.steps);
      await _steps!.start();
      if (seed.routeBound) onCameraFollowChanged?.call(true);
      notifyListeners();
      return true;
    } finally {
      _starting = false;
    }
  }

  /// Stops the trip and banks it. Returns the distance recorded by this
  /// trip (not the cumulative total, which reaches [onSessionEnded]).
  Future<double> stopTrip() async {
    if (_state != TripState.recording) return 0;
    final persisted = await tracker.stop();
    return _finalise(_freshest(persisted, _snapshot));
  }

  /// The service may be killed between its last published snapshot and its
  /// last persisted one, in either order; take whichever was written last
  /// rather than trusting one channel over the other.
  TripSnapshot? _freshest(TripSnapshot? a, TripSnapshot? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.updatedAt.isAfter(b.updatedAt) ? a : b;
  }

  Future<double> _finalise(TripSnapshot? snapshot) async {
    await _steps?.stop();
    _steps = null;

    final distanceKm = snapshot?.distanceKm ?? 0;
    final totalKm = await _totals.addAndGetTotalKm(distanceKm);
    await tracker.clearSnapshot();

    _state = TripState.idle;
    _snapshot = null;
    // The planned route deliberately survives the trip: finishing a walk is
    // not a request to erase the itinerary from the map. The ✕ on the route
    // card is what clears it.
    onCameraFollowChanged?.call(false);
    notifyListeners();

    await onSessionEnded?.call(totalKm);
    return distanceKm;
  }

  /// Called from the screens' once-a-second ticker while recording: samples
  /// the hardware step counter (only readable from this isolate) and hands
  /// the result to the tracker so it lands in the persisted snapshot.
  Future<void> tick() async {
    final steps = _steps;
    if (!isRecording || steps == null) return;
    await steps.sample();
    if (steps.steps == (_snapshot?.steps ?? 0)) return;
    _snapshot = _snapshot?.copyWith(steps: steps.steps, updatedAt: _clock());
    await tracker.publishSteps(steps.steps);
    notifyListeners();
  }

  void _onTrackerSnapshot(TripSnapshot snapshot) {
    if (_state != TripState.recording) return;
    // The service does not know about steps sampled since its last event;
    // keep the higher of the two rather than letting the count flicker
    // backwards between the two channels.
    final steps = _steps?.steps ?? snapshot.steps;
    _snapshot = snapshot.copyWith(
        steps: steps > snapshot.steps ? steps : snapshot.steps);
    notifyListeners();
  }

  /// Persists the planned route. Called by the map screen on every planning
  /// change, which is what makes the itinerary survive a tab switch, a
  /// theme flip (which remounts the whole map) and a cold start.
  Future<void> saveActiveRoute(ActiveRoute route) async {
    _activeRoute = route;
    _profile = route.profile;
    notifyListeners();
    await routeStore.save(route);
  }

  Future<void> clearActiveRoute() async {
    _activeRoute = null;
    notifyListeners();
    await routeStore.clear();
  }

  /// Changes the routing profile, keeping it on the planned route when
  /// there is one and in the "last used" preference when there is not.
  Future<void> setProfile(RoutingProfile profile) async {
    if (_profile == profile) return;
    _profile = profile;
    final route = _activeRoute;
    if (route != null) {
      _activeRoute = route.copyWith(profile: profile);
      notifyListeners();
      await routeStore.save(_activeRoute!);
      return;
    }
    notifyListeners();
    await _persistProfile(profile);
  }

  /// Re-reads whether "Autoriser tout le temps" has since been granted —
  /// called when the app comes back to the foreground, so the degraded-mode
  /// banner disappears once the user has changed it in Android settings.
  Future<void> refreshTrackingMode() async {
    final read = readTrackingMode;
    if (read == null) return;
    final mode = await read();
    if (_trackingMode == mode) return;
    _trackingMode = mode;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel() ?? Future.value());
    unawaited(_errors?.cancel() ?? Future.value());
    unawaited(_steps?.stop() ?? Future.value());
    super.dispose();
  }
}

/// Overridden in `main()` with an instance built on the resolved app
/// support directory and already [TripController.restore]d, so the first
/// frame can render an in-progress or interrupted trip rather than
/// flickering through "idle". Widget tests override it with fakes.
final tripControllerProvider = ChangeNotifierProvider<TripController>((ref) {
  throw UnimplementedError(
      'tripControllerProvider must be overridden — see main().');
});
