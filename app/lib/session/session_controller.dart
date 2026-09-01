import 'dart:async';
import 'package:geolocator/geolocator.dart';
import 'recorder.dart';

/// Manages the session lifecycle: start, stop, state, and distance tracking.
/// Handles re-entrancy protection, fresh recorder per session, and integrates
/// with Geolocator and TotalDistanceStore.
class SessionController {
  final TotalDistanceStore _store;
  final Stream<Position> Function(LocationSettings) _getPositionStream;
  final DateTime Function() _getClock;
  final Future<bool> Function() _checkPermissions;

  /// Injectable single-fix fetch, for [takeSafetyFix] (M5 Task 2d, low-power
  /// mode) — defaults to `Geolocator.getCurrentPosition()`.
  final Future<Position> Function() _getCurrentPosition;

  /// Injectable so the foreground-service isolate can ask for Android-
  /// specific background behaviour (an explicit update interval) without
  /// this class importing anything platform-specific.
  ///
  /// Mutable — not `final` — so [updateLocationSettings] can swap it for a
  /// tighter or coarser `distanceFilter` mid-session (adaptive GPS during
  /// turn-by-turn navigation, Task 7) without this class knowing anything
  /// about maneuvers or routes.
  LocationSettings _locationSettings;

  SessionRecorder? _recorder;
  DateTime? _lastFixAt;
  bool _isRecording = false;
  bool _isStarting = false;
  StreamSubscription<Position>? _positionStream;

  /// Low-power mode (M5 Task 2d, fix round 1 — C1): the *desired* stream
  /// state, as last requested by [pause]/[resume] — independent of whatever
  /// [_positionStream] happens to be doing at any given instant, which can
  /// lag behind while a cancel/resubscribe is still in flight. This is the
  /// single source of truth [_reconcile] converges the real stream towards.
  ///
  /// Previously [pause]/[resume] each guarded on `_positionStream`'s own
  /// nullability — a resume landing while `pause()`'s `await
  /// _positionStream.cancel()` was still suspended read a non-null stream
  /// (not yet nulled) and silently no-op'd, leaving the stream closed with
  /// nothing left to ever reopen it. Routing every request through
  /// [_desiredRunning] plus one serialized queue ([_enqueueReconcile])
  /// closes that: whichever of [pause]/[resume] is called *last* always
  /// gets the final say, however their awaits happen to land, because
  /// [_reconcile] always re-reads [_desiredRunning] fresh at the moment it
  /// actually runs rather than trusting whatever it was when enqueued.
  bool _desiredRunning = false;

  /// Serializes every [pause]/[resume]/[updateLocationSettings] request:
  /// each call enqueues its own [_reconcile] step *after* whatever is
  /// already queued, so two overlapping requests can never interleave their
  /// awaits into an inconsistent state — the second one's reconciliation
  /// simply runs once the first's has fully settled.
  Future<void> _transitionChain = Future<void>.value();

  /// Set by [updateLocationSettings] while paused (fix round 1 — I1):
  /// records that the stream needs to be reopened with the new settings
  /// once a [resume] actually happens, instead of reopening it immediately
  /// — low-power mode owns whether the stream is open at all, adaptive GPS
  /// only ever owns *which* `distanceFilter` it reopens with.
  bool _pendingResubscribe = false;

  /// Callback when a session ends (successful stop or error).
  /// Invoked with the total km accumulated in the session.
  Future<void> Function(double totalKm)? onSessionEnded;

  /// Callback when a session ends due to GPS stream error.
  /// Invoked with an optional error message.
  Future<void> Function(String? errorMessage)? onSessionError;

  /// Invoked for every fix accurate enough to be acted on (see
  /// [kMaxFixAccuracyM]), right after the recorder has consumed it.
  ///
  /// Exists so a second consumer — turn-by-turn navigation, running in the
  /// same isolate — can be driven by the same stream instead of opening a
  /// second GPS subscription, which on Android would double the fix rate and
  /// the battery cost of a screen-off trip. Fire-and-forget by design: the
  /// recording must not wait on anything the callback does.
  void Function(GpsSample sample)? onFix;

  SessionController({
    required this._store,
    Stream<Position> Function(LocationSettings)? getPositionStream,
    DateTime Function()? getClock,
    Future<bool> Function()? checkPermissions,
    Future<Position> Function()? getCurrentPosition,
    LocationSettings? locationSettings,
    this.onSessionEnded,
    this.onSessionError,
    this.onFix,
  }) : _locationSettings =
           locationSettings ??
           const LocationSettings(
             accuracy: LocationAccuracy.best,
             distanceFilter: 3,
           ),
       _getPositionStream =
           getPositionStream ??
           ((LocationSettings settings) =>
               Geolocator.getPositionStream(locationSettings: settings)),
       _getClock = getClock ?? DateTime.now,
       _checkPermissions = checkPermissions ?? _defaultCheckPermissions,
       _getCurrentPosition =
           getCurrentPosition ?? Geolocator.getCurrentPosition;

  bool get isRecording => _isRecording;

  /// When a position last arrived from the stream, by this controller's own
  /// clock — not the fix's timestamp, which comes from the device and says
  /// nothing about whether the stream is still alive.
  ///
  /// Null until the first fix. Only a liveness signal: it is set for every
  /// position received, including ones the recorder then discards as too
  /// inaccurate, because "arriving but imprecise" and "not arriving at all"
  /// are different failures and only the second one is worth warning about.
  DateTime? get lastFixAt => _lastFixAt;
  bool get isStarting => _isStarting;
  SessionRecorder? get recorder => _recorder;
  Duration get elapsed => _recorder?.elapsed(_getClock()) ?? Duration.zero;

  /// Default permission checker: verifies location service is enabled and
  /// permission is granted.
  static Future<bool> _defaultCheckPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return false;
    }
    return true;
  }

  /// Initiates a new session. Returns true if started, false if already
  /// recording or starting. Handles re-entrancy.
  Future<bool> start() async {
    if (_isRecording || _isStarting) return false;

    _isStarting = true;
    try {
      // Permission and service checks.
      final canStart = await _checkPermissions();
      if (!canStart) return false;

      // Create a fresh recorder for this session.
      _recorder = SessionRecorder();
      _lastFixAt = null;

      _subscribe();
      _desiredRunning = true;

      _isRecording = true;
      return true;
    } finally {
      _isStarting = false;
    }
  }

  /// (Re)opens the position stream against [_locationSettings]. Factored out
  /// of [start] so [updateLocationSettings] can resubscribe with a changed
  /// `distanceFilter` through the exact same listener — a second copy of it
  /// would be one more place for the recorder/onFix/onError wiring to drift.
  void _subscribe() {
    _positionStream = _getPositionStream(_locationSettings).listen(
      (Position position) {
        _lastFixAt = _getClock();
        final sample = GpsSample(
          lat: position.latitude,
          lon: position.longitude,
          accuracyM: position.accuracy,
          speedMps: position.speed,
          time: position.timestamp,
        );
        _recorder?.add(sample);
        if (sample.accuracyM <= kMaxFixAccuracyM) onFix?.call(sample);
      },
      onError: (e) {
        // Finish session on stream error, persisting partial distance.
        _finishSession(isError: true, errorMessage: e?.toString());
      },
    );
  }

  /// Swaps the location stream for a new subscription opened with
  /// [settings] — used by adaptive GPS (Task 7) to tighten or loosen
  /// `distanceFilter` as a route-bound trip nears or leaves a maneuver.
  ///
  /// A no-op while nothing is recording. Callers are expected to have
  /// already decided, via `AdaptiveGpsRateLimiter`, that this is worth the
  /// churn of tearing down and reopening the platform's location provider —
  /// this method does not itself rate-limit anything.
  ///
  /// Fix round 1 — I1: while [pause] has [_desiredRunning] false, this
  /// records [settings] and marks [_pendingResubscribe] rather than
  /// reopening the stream immediately — low-power mode owns *whether* the
  /// stream is open at all; adaptive GPS only ever owns *which*
  /// `distanceFilter` it reopens with once [resume] actually happens
  /// (which already re-subscribes against [_locationSettings], so recording
  /// the new value here is enough — the change simply takes effect on the
  /// next resume instead of fighting the pause for the stream right now).
  Future<void> updateLocationSettings(LocationSettings settings) {
    if (!_isRecording) return Future<void>.value();
    _locationSettings = settings;
    _pendingResubscribe = true;
    if (!_desiredRunning) return Future<void>.value();
    return _enqueueReconcile();
  }

  /// Low-power mode (M5 Task 2d, owner brief): shuts off the continuous
  /// position stream without ending the session — [_isRecording], the
  /// [_recorder] and everything it has accumulated survive untouched, so
  /// [resume] simply reopens the stream where this left off. A no-op while
  /// nothing is recording.
  ///
  /// Deliberately distinct from [stop]: [_finishSession] banks the distance,
  /// nulls [_recorder] and fires [onSessionEnded] — appropriate for a trip
  /// actually ending, wrong for a walker who is simply standing still for a
  /// few minutes (the trip must read as still recording throughout, per the
  /// task brief: "l'enregistrement du trajet n'est pas terminé/altéré par la
  /// pause").
  ///
  /// Fix round 1 — C1: routes through [_enqueueReconcile] rather than
  /// cancelling the stream directly — see [_desiredRunning]'s doc comment
  /// for why a direct cancel here could race a concurrent [resume] into a
  /// permanently-closed stream.
  Future<void> pause() {
    if (!_isRecording) return Future<void>.value();
    _desiredRunning = false;
    return _enqueueReconcile();
  }

  /// Reopens the position stream [pause] shut off, at the [LocationSettings]
  /// currently in effect (including any [updateLocationSettings] change
  /// that arrived while paused — see [_pendingResubscribe]). A no-op while
  /// nothing is recording.
  ///
  /// Fix round 1 — C1: same serialized-reconciliation path as [pause] — a
  /// resume requested while a pause is still in flight always wins, because
  /// this request's own [_reconcile] step is enqueued *after* the pause's
  /// and re-reads [_desiredRunning] fresh when it runs.
  Future<void> resume() {
    if (!_isRecording) return Future<void>.value();
    _desiredRunning = true;
    return _enqueueReconcile();
  }

  /// Chains one more [_reconcile] step onto [_transitionChain] and returns
  /// it. A failed reconcile is swallowed here (not left to propagate) so a
  /// single broken step can never wedge every later `pause()`/`resume()`
  /// call behind a permanently-rejected chain link.
  Future<void> _enqueueReconcile() {
    final next = _transitionChain.then((_) => _reconcile());
    _transitionChain = next.catchError((_) {});
    return next;
  }

  /// Brings [_positionStream] in line with [_desiredRunning] (and
  /// [_pendingResubscribe]), as of *this* moment — not as of whenever the
  /// request that queued this step was made. That distinction is the whole
  /// fix: by the time this actually runs, [_desiredRunning] may already
  /// reflect a later request than the one that enqueued it, and reading it
  /// fresh here is what makes the *last* request always win.
  Future<void> _reconcile() async {
    if (!_isRecording) return;
    if (_desiredRunning) {
      if (_positionStream == null) {
        _subscribe();
      } else if (_pendingResubscribe) {
        _pendingResubscribe = false;
        final sub = _positionStream;
        _positionStream = null;
        await sub?.cancel();
        if (_isRecording && _desiredRunning) _subscribe();
      }
      return;
    }
    final sub = _positionStream;
    if (sub == null) return;
    // Nulled *before* awaiting the cancel, not after (fix round 1 — C1):
    // a resume() landing in this exact window must see a stream it can act
    // on (subscribe fresh) rather than one that still looks "already open"
    // and silently no-ops.
    _positionStream = null;
    await sub.cancel();
  }

  /// One isolated position request while [pause] has the stream shut off —
  /// the "fix de sécurité" the task brief has low-power mode take every few
  /// minutes as a guard against a missed resume signal. Feeds [_recorder]
  /// and [onFix] exactly like a fix from the continuous stream (so track
  /// sampling, landmark detection and turn-by-turn guidance all see it),
  /// but does not itself reopen the stream — a caller that decides this fix
  /// shows genuine movement calls [resume] on top of it.
  ///
  /// Returns null (touching nothing) while not recording, or on any
  /// failure — a single missed safety fix is never worth ending the trip
  /// over, same rationale as every other best-effort path in this class.
  Future<GpsSample?> takeSafetyFix() async {
    if (!_isRecording) return null;
    try {
      final position = await _getCurrentPosition();
      _lastFixAt = _getClock();
      final sample = GpsSample(
        lat: position.latitude,
        lon: position.longitude,
        accuracyM: position.accuracy,
        speedMps: position.speed,
        time: position.timestamp,
      );
      _recorder?.add(sample);
      if (sample.accuracyM <= kMaxFixAccuracyM) onFix?.call(sample);
      return sample;
    } catch (_) {
      return null;
    }
  }

  /// Stops the current session and persists distance to TotalDistanceStore.
  /// Returns the total distance accumulated in this session, or 0 if not
  /// recording.
  Future<double> stop() async {
    return (await _finishSession(isError: false)) ?? 0;
  }

  /// Internal: finishes a session (manual stop or stream error), persists
  /// distance, and invokes appropriate callbacks.
  Future<double?> _finishSession({
    required bool isError,
    String? errorMessage,
  }) async {
    if (!_isRecording) return null;

    _isRecording = false;
    _desiredRunning = false;
    _pendingResubscribe = false;
    await _positionStream?.cancel();
    _positionStream = null;

    final distanceKm = _recorder?.distanceKm ?? 0;
    final totalKm = await _store.addAndGetTotalKm(distanceKm);

    _recorder = null;

    // Invoke appropriate callbacks.
    if (isError) {
      await onSessionError?.call(errorMessage);
    }
    await onSessionEnded?.call(totalKm);

    return totalKm;
  }

  /// Clean up resources (subscriptions, timers).
  Future<void> dispose() async {
    if (_isRecording) {
      await stop();
    }
    await _positionStream?.cancel();
    _positionStream = null;
  }
}
