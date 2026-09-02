import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../exploration/exploration_recorder.dart';
import '../game/events.dart' show GameEvent, GameEventTypes;
import '../loop/speed_history.dart';
import '../nav/nav_fields.dart';
import '../session/recorder.dart';
import '../settings/alert_settings.dart';
import '../tracking/nav_seed.dart';
import '../tracking/permissions.dart';
import '../tracking/steps.dart';
import '../tracking/tracking_service.dart';
import '../tracking/trip_snapshot.dart';
import '../valhalla/models.dart';
import 'active_route_store.dart';
import 'finalised_trip_memory.dart';

enum TripState {
  idle,
  recording,

  /// A trip was recording when the app's process was killed and the
  /// foreground service went with it. Nothing is being recorded now, but
  /// the distance and steps up to that point are intact and the user has
  /// not been asked what to do with them yet.
  interrupted,
}

/// Why a [TripController.startTrip] refused, phrased for the user by
/// `trip_messages.dart`.
///
/// Not [TripPermissionOutcome] itself: not every refusal is a permission
/// problem, and conflating them made a trip refused because another one is
/// waiting to be resumed tell the user their GPS was unavailable.
enum TripStartFailure {
  locationServiceOff,
  locationDenied,
  openedSettings,

  /// A trip is already recording. Reachable when both screens are mounted
  /// (see the shell's IndexedStack) and one is tapped while the other has
  /// not rebuilt yet.
  alreadyRecording,

  /// A trip is sitting in [TripState.interrupted]. The « Trajet interrompu »
  /// banner is the only way out of that state, so the user is pointed at it.
  interruptedTripPending,

  /// The permission flow passed but the service refused to start.
  serviceUnavailable,
}

/// Task 2g (owner brief): the synchronously-known facts about a just-
/// finalised, arrived guided trip — everything `TripController._finalise`
/// itself already has in hand at the moment it finishes, handed to
/// [TripController.onTripCelebration] so a screen can render distance/
/// duration/speed immediately rather than waiting on the asynchronous
/// history write.
///
/// [startedAt] is this trip's identity (same convention `FinalisedTripMemory`
/// uses) — the celebration screen matches it against `TripHistoryStore`'s
/// freshly-written row to read the authoritative, combined XP figure (see
/// `history/trip_history_recorder.dart`'s "Task 2g update" doc comment for
/// why that number is not known synchronously: it depends on
/// `processTripExploration` actually finishing, which is fire-and-forget by
/// design and must stay that way — see `_finalise`'s own doc comment on why
/// that hook is never awaited).
class FinishedTripCelebration {
  final DateTime startedAt;
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;
  final RoutingProfile profile;

  /// Whether this trip followed a planned loop — purely to phrase the
  /// screen's headline ("boucle terminée" vs. "vous êtes arrivé(e)"); the XP
  /// consequence of a loop (`loop_completed`, +50 XP) is already folded into
  /// the combined total the screen reads from history.
  final bool isLoop;

  const FinishedTripCelebration({
    required this.startedAt,
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    required this.profile,
    required this.isLoop,
  });
}

const _kTripProfileKey = 'trip_profile';

/// How often the UI re-reads the persisted snapshot as a fallback to the
/// service's live channel. Slower than the tick, faster than a user would
/// notice a stale number.
const _kSnapshotPollInterval = Duration(seconds: 3);

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
  final FinalisedTripMemory _finalisedTrips;
  final SpeedHistoryStore _speedHistory;
  final Future<TrackingMode> Function()? readTrackingMode;
  final DateTime Function() _clock;
  final Future<void> Function(RoutingProfile profile) _persistProfile;
  final Future<RoutingProfile?> Function() _loadProfile;
  final AlertSettingsStore _alertSettings;

  /// Where the offline tiles already on disk live, so the tracking service
  /// can recalculate a route without this process (or any network) being
  /// around. Null — or absent — simply means a trip whose route cannot be
  /// recalculated; it never stops one from starting.
  final Future<String?> Function()? resolveTileDir;

  /// M4 exploration: best-effort, fire-and-forget post-trip processing —
  /// map-matching, covered-edge storage, fog reveal, and the resulting
  /// journal events (see `ExplorationRecorder`). Null in every test that
  /// does not care about the game layer (the default), and in any build
  /// where the game is disabled entirely: absent, exploration processing is
  /// simply skipped, same as every other "game never blocks the tool"
  /// degradation in this app. Never awaited by [_finalise] — a slow or
  /// throwing implementation must not delay « Terminer » finishing, and
  /// [ExplorationRecorder.process] itself is already documented to never
  /// throw, so this is a second, independent guard rather than the only one.
  final Future<void> Function(FinishedTrip trip)? processTripExploration;

  /// M4 exploration Task 5: resolves the current `pois.json.gz` path (if
  /// any) for [tracker.start] to hand the service — mirrors
  /// [resolveTileDir]'s "read only what's already on disk" contract. Null,
  /// or a resolver that throws or returns null, simply means this trip
  /// detects no landmark visits; never a reason to refuse starting one (see
  /// [_resolvePoisFilePath]).
  final Future<String?> Function()? resolvePoisFile;

  /// M4 exploration Task 5: best-effort, fire-and-forget landmark-visit
  /// processing (see `GameVisitConsumer`) — journal events plus a discreet
  /// alert for whatever `TripSnapshot.pendingVisits` a newly-adopted
  /// snapshot carries. Null in every test that does not care about the
  /// game layer, and wherever the game is disabled entirely. Never awaited
  /// (see [_maybeProcessGameVisits]) — same "never blocks the tool"
  /// relationship [processTripExploration] has to `_finalise`, just fired
  /// from [_adopt] instead of trip end, since visits arrive mid-trip.
  ///
  /// Task 2g: returns exactly the events THIS call appended (mirroring
  /// `ExplorationRecorder.process`'s own contract — see
  /// `GameVisitConsumer.consume`'s doc comment) so [_maybeProcessGameVisits]
  /// can accumulate this trip's own landmark-visit XP into [_tripVisitXp].
  final Future<List<GameEvent>> Function(List<PendingVisit> visits)?
  processGameVisits;

  /// Task 2g (owner brief): fired once, synchronously from inside
  /// `_finalise`, for a guided (route-bound) trip that had latched arrival —
  /// whether it ended via the Task 2g auto-finish or a manual « Terminer »
  /// on an already-arrived trip. Null whenever nothing is watching live: in
  /// particular during `restore()`'s own cold-start reconciliation, which
  /// runs before `runApp`/the widget tree exist — that is fine by design,
  /// since [FinalisedTripMemory.setPendingCelebration] (also set from
  /// `_finalise`, unconditionally for the same trips) is exactly the
  /// deferred path for that case (see its own doc comment).
  void Function(FinishedTripCelebration celebration)? onTripCelebration;

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
  TripStartFailure? _lastStartFailure;
  bool _stepsAvailable = true;
  bool _starting = false;
  DateTime? _lastPollAt;
  SessionStepCounter? _steps;
  StreamSubscription<TripSnapshot>? _updates;
  StreamSubscription<String?>? _errors;

  /// Task 2g: this trip's own accumulated landmark-visit XP — the running
  /// sum of `xp_earned` amounts among the events every [processGameVisits]
  /// call made FOR THIS TRIP itself returned (see [_maybeProcessGameVisits]),
  /// never a `GameState` read (see [FinishedTrip.visitXpEarned]'s doc
  /// comment for why). Reset to 0 in [_launch] — i.e. at every genuinely new
  /// `startTrip()` and at every `resumeInterrupted()` — so it can never leak
  /// into a later trip; handed to `_finalise`'s `FinishedTrip` at trip end.
  ///
  /// Known, accepted limitation: this is in-memory, per-`TripController`-
  /// instance state. A trip interrupted (the whole app process killed) after
  /// already earning some visit XP, then resumed by a FRESH `TripController`
  /// in a new process, loses that pre-interruption contribution — the new
  /// instance's accumulator starts at 0 regardless of what the dead one saw.
  /// The visit XP itself is not lost (already durably journaled by the
  /// `GameVisitConsumer` call that earned it) — only its contribution to
  /// THIS trip's own history-row total. Accepted rather than solved by
  /// persisting a running counter in `TripSnapshot` itself: interruption is
  /// already the uncommon case this codebase treats as such elsewhere (see
  /// e.g. `_finalise`'s own "moving time" approximation), and the
  /// alternative is plumbing yet another field through every service
  /// incarnation for a residual this narrow.
  double _tripVisitXp = 0;

  TripController({
    required this.tracker,
    required this.routeStore,
    required TotalDistanceStore totalStore,
    required this.ensurePermissions,
    FinalisedTripMemory? finalisedTrips,
    SpeedHistoryStore? speedHistory,
    SessionStepCounter Function(int seed)? createStepCounter,
    this.readTrackingMode,
    DateTime Function()? clock,
    Future<void> Function(RoutingProfile profile)? persistProfile,
    Future<RoutingProfile?> Function()? loadProfile,
    this.resolveTileDir,
    this.onCameraFollowChanged,
    this.processTripExploration,
    this.resolvePoisFile,
    this.processGameVisits,
    AlertSettingsStore? alertSettings,
  }) : _totals = totalStore,
       _finalisedTrips = finalisedTrips ?? PrefsFinalisedTripMemory(),
       _speedHistory = speedHistory ?? SpeedHistoryStore(),
       _createStepCounter =
           createStepCounter ??
           ((seed) => SessionStepCounter(ChannelStepSensor(), seed: seed)),
       _clock = clock ?? DateTime.now,
       _persistProfile = persistProfile ?? _defaultPersistProfile,
       _loadProfile = loadProfile ?? _defaultLoadProfile,
       _alertSettings = alertSettings ?? AlertSettingsStore() {
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
  Duration get elapsed => _state == TripState.idle
      ? Duration.zero
      : _snapshot?.elapsedAt(_clock()) ?? Duration.zero;

  ActiveRoute? get activeRoute => _activeRoute;
  RouteResult? get route => _activeRoute?.route;
  bool get isRouteBound => isRecording && (_snapshot?.routeBound ?? false);
  RoutingProfile get profile => _profile;

  /// Whether Android will keep feeding us positions with the screen off.
  /// [TrackingMode.foregroundOnly] is what the degraded-mode banner reads.
  TrackingMode get trackingMode => _trackingMode;

  /// Why the last [startTrip] refused, for the screen to phrase a message.
  TripStartFailure? get lastStartFailure => _lastStartFailure;

  /// Whether the step counter is usable at all (ACTIVITY_RECOGNITION granted
  /// and a sensor present). False hides the step read-out rather than
  /// showing a permanent, unexplained zero.
  bool get stepsAvailable => _stepsAvailable;

  /// The recorder has stopped hearing from the location stream — see
  /// [isGpsSilent]. Drives a discreet banner, because this is the one
  /// tracking failure with no other visible symptom.
  ///
  /// Read straight off the snapshot: the service is the only party that can
  /// tell a quiet stream from a stationary walker, and taking it from the
  /// snapshot means a UI that adopts an already-silent service shows the
  /// warning immediately instead of waiting for a transition that has
  /// already happened.
  bool get gpsSilent => isRecording && (_snapshot?.gpsSilent ?? false);

  static Future<void> _defaultPersistProfile(RoutingProfile profile) async {
    await (await SharedPreferences.getInstance()).setString(
      _kTripProfileKey,
      profile.name,
    );
  }

  static Future<RoutingProfile?> _defaultLoadProfile() async {
    final stored = (await SharedPreferences.getInstance()).getString(
      _kTripProfileKey,
    );
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

    // Task 2g: a guided trip (A→B or loop) that latched arrival while this
    // process was away — backgrounded, or the whole app task swiped away
    // (the foreground service survives both: `tracking_service.dart`'s
    // `_configure` sets `stopWithTask: false`) — publishes its FINAL
    // snapshot with `status: idle` instead of simply vanishing (see
    // `TripTaskHandler._autoFinishOnArrival`). Finalise it through the
    // exact same pipeline a live auto-finish or a manual "Terminer" uses —
    // banking, history, game XP, the celebration marker — rather than
    // falling into the generic "debris, discard" handling just below, which
    // would silently drop all of that. Checked before the generic branch,
    // not folded into it, so the ordinary case (an idle leftover from a
    // trip that already finalised normally) is completely unaffected.
    if (snapshot != null &&
        !snapshot.isRecording &&
        snapshot.routeBound &&
        snapshot.navArrived &&
        !await _finalisedTrips.wasFinalised(snapshot.startedAt)) {
      await _finalise(snapshot);
      return;
    }

    // A non-recording snapshot is debris from a finalised trip. So is a
    // recording one whose trip has already been banked: the service's last
    // flush can land after the stop cleared the file (see
    // [FinalisedTripMemory]), and offering « Trajet interrompu » for it
    // would let « Terminer » submit the same kilometres twice.
    if (snapshot == null ||
        !snapshot.isRecording ||
        await _finalisedTrips.wasFinalised(snapshot.startedAt)) {
      if (snapshot != null) await tracker.clearSnapshot();
      _state = TripState.idle;
      notifyListeners();
      return;
    }

    _snapshot = snapshot;
    _profile = snapshot.profile;
    if (await tracker.isRunning()) {
      // The service outlived the UI: adopt it rather than restarting it —
      // and open the live channel, which only [TripTracker.start] would
      // otherwise have done.
      await tracker.attach();
      _lastPollAt = null;
      _state = TripState.recording;
      await _startStepCounter(snapshot.steps);
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
    if (_starting) return false;
    if (_state != TripState.idle) {
      _lastStartFailure = _state == TripState.interrupted
          ? TripStartFailure.interruptedTripPending
          : TripStartFailure.alreadyRecording;
      notifyListeners();
      return false;
    }

    if (profile != null) {
      _profile = profile;
      await _persistProfile(profile);
    } else {
      _profile = await _loadProfile() ?? _profile;
    }

    return _launch(
      TripSnapshot.starting(
        startedAt: _clock(),
        profile: _profile,
        routeBound: route != null,
      ),
      nav: await _navSeedFor(route),
    );
  }

  /// The navigation handover for a route-bound trip: the route itself, where
  /// it is going, and the tiles a service-side replan may need. Null for a
  /// free trip, and for a route too degenerate to follow.
  ///
  /// Built here, in the UI isolate, because this is the only side that knows
  /// what the user planned and where the tiles were downloaded — the service
  /// has neither the route store nor `path_provider`.
  Future<NavSeed?> _navSeedFor(RouteResult? route) async {
    if (route == null || route.shape.length < 2) return null;
    final destination = _activeRoute?.destination ?? route.shape.last;
    return NavSeed(
      route: route,
      destLat: destination.$1,
      destLon: destination.$2,
      profile: _profile,
      tileDirPath: await _tileDirPath(),
      // Final review item 1: without this the `shape.last` fallback above
      // silently names a closed loop's own *start* as the replan target, and
      // the first wrong turn reroutes the walker home. A loop is flagged
      // instead, and the service skips replanning entirely.
      isLoop: _activeRoute?.isLoop ?? false,
    );
  }

  Future<String?> _tileDirPath() async {
    final resolve = resolveTileDir;
    if (resolve == null) return null;
    try {
      return await resolve();
      // Losing the ability to recalculate is worth a trip without guidance
      // updates, never a trip that refuses to start.
    } catch (_) {
      return null;
    }
  }

  /// M4 exploration Task 5: best-effort — a failure resolving the POI asset
  /// path must never stop a trip from starting, same as [_tileDirPath].
  Future<String?> _resolvePoisFilePath() async {
    final resolve = resolvePoisFile;
    if (resolve == null) return null;
    try {
      return await resolve();
    } catch (_) {
      return null;
    }
  }

  /// « Reprendre » on the interrupted-trip banner: restarts the service
  /// seeded with the distance and steps already banked, and with the
  /// original start time so the elapsed clock does not reset.
  Future<bool> resumeInterrupted() async {
    final snapshot = _snapshot;
    if (_state != TripState.interrupted || snapshot == null) return false;
    // gpsSilent deliberately cleared: it describes the *previous* session's
    // stream, and the service re-derives it from the new one's first repeat
    // event. Carrying it would flash the warning for the couple of seconds
    // before that arrives. nav is blanked the same way: the interrupted
    // session's guidance — including any replanned route shape — belongs to
    // a follower that is gone, not to whatever this resumed service builds
    // fresh from the planned route below. Without this, the map would draw
    // the dead session's replanned line (keyed on `navRouteShapeEnc`, see
    // `map_screen.dart`'s `_maybeSyncReplannedRoute`) until the new service
    // happens to replan again — which might be never.
    return _launch(
      snapshot.copyWith(
        status: TripStatus.recording,
        updatedAt: _clock(),
        gpsSilent: false,
        nav: const NavFields(),
      ),
      // A resumed route-bound trip is re-seeded from the planned route
      // (which outlives the trip, see [ActiveRouteStore]); without this,
      // « Reprendre » would silently come back without guidance.
      nav: snapshot.routeBound ? await _navSeedFor(_activeRoute?.route) : null,
    );
  }

  /// « Terminer » on the interrupted-trip banner: banks what was recorded
  /// through exactly the same path a normal stop takes, so the leaderboard
  /// submit happens once and identically.
  ///
  /// Shares [_stopping] with [stopTrip] — same double-bank window (the
  /// `_state != interrupted` guard alone lets two close-together taps both
  /// through before the first call's first `await` ever suspends it), same
  /// fix, and the shared flag means the two banners can never race each
  /// other into a double bank either (unlikely in the UI, since only one of
  /// « Terminer »/the interrupted banner is ever shown at once, but the
  /// guard is free either way once it is shared).
  Future<double> finishInterrupted() async {
    final snapshot = _snapshot;
    if (_state != TripState.interrupted || snapshot == null || _stopping) {
      return 0;
    }
    _stopping = true;
    try {
      // The service is *probably* dead — that is what put us in this state —
      // but `allowAutoRestart` means Android may have brought it back before
      // the user answered the banner. Banking without stopping would leave
      // it recording, notification and all, over a trip that has been
      // finished. Tolerant of failure: when the service really is gone
      // there is nothing to stop, and that must not block « Terminer ».
      TripSnapshot? persisted;
      try {
        persisted = await tracker.stop();
      } catch (_) {
        persisted = null;
      }
      return await _finalise(_freshest(persisted, snapshot));
    } finally {
      _stopping = false;
    }
  }

  Future<bool> _launch(TripSnapshot seed, {NavSeed? nav}) async {
    _starting = true;
    // Task 2g: a fresh accumulator for whichever trip this launch is about
    // to start or resume — see [_tripVisitXp]'s own doc comment for why this
    // must happen here rather than only once, in the constructor.
    _tripVisitXp = 0;
    try {
      final permissions = await ensurePermissions();
      _trackingMode = permissions.mode;
      _stepsAvailable = permissions.stepsAvailable;
      if (!permissions.canStart) {
        _lastStartFailure = _failureFor(permissions.outcome);
        notifyListeners();
        return false;
      }

      final poisFilePath = await _resolvePoisFilePath();
      if (!await tracker.start(seed, nav: nav, poisFilePath: poisFilePath)) {
        _lastStartFailure = TripStartFailure.serviceUnavailable;
        notifyListeners();
        return false;
      }

      _lastStartFailure = null;
      _lastPollAt = null;
      _snapshot = seed;
      _state = TripState.recording;
      await _startStepCounter(seed.steps);
      if (seed.routeBound) onCameraFollowChanged?.call(true);
      notifyListeners();
      return true;
    } finally {
      _starting = false;
    }
  }

  static TripStartFailure _failureFor(TripPermissionOutcome outcome) =>
      switch (outcome) {
        TripPermissionOutcome.locationServiceOff =>
          TripStartFailure.locationServiceOff,
        TripPermissionOutcome.openedSettings => TripStartFailure.openedSettings,
        _ => TripStartFailure.locationDenied,
      };

  Future<void> _startStepCounter(int seed) async {
    if (!_stepsAvailable) return;
    final counter = _createStepCounter(seed);
    _steps = counter;
    _stepsAvailable = await counter.start();
  }

  /// True from the moment [stopTrip] or [finishInterrupted] commits to
  /// stopping until it (or the call it raced — either of itself, or the
  /// other of the pair) has finished banking. Shared between the two: both
  /// bank through [_finalise] and both have the identical double-tap
  /// window (their own `_state` guard alone is not enough — see either
  /// method's doc comment).
  bool _stopping = false;

  /// Stops the trip and banks it. Returns the distance recorded by this
  /// trip (not the cumulative total, which reaches [onSessionEnded]).
  ///
  /// [_state] does not become [TripState.idle] until deep inside
  /// [_finalise], after several `await`s (`tracker.stop()`,
  /// `markFinalised`, `addAndGetTotalKm`...) — a double-tap on « Terminer »
  /// fires two calls before the first of those awaits ever suspends the
  /// first call, so the `_state != recording` guard alone lets both through
  /// and banks the same trip twice. [_stopping] is set synchronously,
  /// before the first `await`, closing that window: the second call sees it
  /// already true and returns immediately rather than racing the first.
  Future<double> stopTrip() async {
    if (_state != TripState.recording || _stopping) return 0;
    _stopping = true;
    try {
      final persisted = await tracker.stop();
      return await _finalise(_freshest(persisted, _snapshot));
    } finally {
      _stopping = false;
    }
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
    // Recorded *before* the total is banked, so a crash between the two
    // leaves a trip that is skipped rather than one that is counted twice.
    if (snapshot != null) {
      await _finalisedTrips.markFinalised(snapshot.startedAt);
    }
    final totalKm = await _totals.addAndGetTotalKm(distanceKm);
    // The session's own distance and duration, not the cumulative total
    // above — the speed history is per-trip pace, not a running sum. Elapsed
    // is measured from the snapshot's *original* `startedAt`: a resumed
    // interrupted trip (see [resumeInterrupted]) keeps that timestamp across
    // the gap it was interrupted for, so this counts wall-clock time
    // including the pause rather than only time spent actively recording.
    // That is a deliberate approximation — accepted here rather than
    // plumbing "moving time" through the snapshot — because a resumed trip
    // is the uncommon case and the EMA already damps any one session's
    // effect on the estimate.
    if (snapshot != null) {
      // Best-effort only, and deliberately scoped to just this call: banking
      // (`addAndGetTotalKm`, above) and marking-finalised have already run by
      // the time we get here, and `tracker.clearSnapshot()` /
      // `_state = TripState.idle` below still must run regardless of what
      // happens to the speed average. `recordSession`'s own doc comment
      // promises the caller it never breaks a trip; this is what actually
      // enforces that promise against a real failure (e.g. SharedPreferences
      // throwing on a platform channel hiccup) rather than merely asserting
      // it never throws. Log-and-continue: losing one session's contribution
      // to the learned pace is a rounding error next to leaving the trip
      // stuck mid-finalise.
      try {
        await _speedHistory.recordSession(
          snapshot.profile,
          distanceKm,
          _clock().difference(snapshot.startedAt),
        );
      } catch (e) {
        debugPrint('TripController: recordSession failed, continuing: $e');
      }
    }

    // M4 exploration: fire-and-forget, never awaited — see
    // [processTripExploration]'s doc comment. `unawaited` plus its own
    // `catchError` means neither a slow map-match nor a thrown error from a
    // broken hook can delay or interrupt anything below this line, or the
    // `stopTrip()`/`finishInterrupted()` call that got us here.
    final exploration = processTripExploration;
    if (exploration != null && snapshot != null) {
      unawaited(
        exploration(
          FinishedTrip(
            km: distanceKm,
            isLoop: _activeRoute?.isLoop ?? false,
            navArrived: snapshot.navArrived,
            // Task 2f (local trip history): carried purely for whatever
            // decorator main.dart wraps around this hook — see
            // FinishedTrip's own doc comment.
            startedAt: snapshot.startedAt,
            endedAt: _clock(),
            profile: snapshot.profile,
            // Task 2g: this trip's own accumulated landmark-visit XP — see
            // [_tripVisitXp]'s doc comment. Read here, not after
            // `tracker.clearSnapshot()` below: nothing resets it before the
            // NEXT trip's own `_launch`, but reading it as close to "this
            // trip's own data" as possible keeps the two together.
            visitXpEarned: _tripVisitXp,
          ),
        ).catchError((e) {
          debugPrint(
            'TripController: exploration processing failed, continuing: $e',
          );
        }),
      );
    }

    // Task 2g (owner brief): a guided trip that had latched arrival gets a
    // congratulations screen — whether it got here via the Task 2g
    // auto-finish or a manual "Terminer" tapped after quietly arriving. Free
    // trips (never `routeBound`) and a guided trip stopped before arriving
    // never do. The marker is persisted unconditionally, not just when
    // [onTripCelebration] is wired: it is what makes the *deferred* case
    // (nothing watching live right now — see that field's own doc comment)
    // work at all, including from `restore()`'s own call into this same
    // method. The callback itself, though, fires further down — after the
    // trip has actually reached [TripState.idle] — so anything reacting to
    // it (pushing a screen) sees a fully settled, idle `TripController`
    // underneath rather than one still reading as recording.
    FinishedTripCelebration? celebration;
    if (snapshot != null && snapshot.routeBound && snapshot.navArrived) {
      await _finalisedTrips.setPendingCelebration(snapshot.startedAt);
      final rawDuration = _clock().difference(snapshot.startedAt);
      final duration = rawDuration.isNegative ? Duration.zero : rawDuration;
      final hours = duration.inMilliseconds / Duration.millisecondsPerHour;
      celebration = FinishedTripCelebration(
        startedAt: snapshot.startedAt,
        distanceKm: distanceKm,
        duration: duration,
        avgSpeedKmh: hours > 0 ? distanceKm / hours : 0,
        profile: snapshot.profile,
        isLoop: _activeRoute?.isLoop ?? false,
      );
    }

    await tracker.clearSnapshot();

    _state = TripState.idle;
    _snapshot = null;
    // The planned route deliberately survives the trip: finishing a walk is
    // not a request to erase the itinerary from the map. The ✕ on the route
    // card is what clears it.
    onCameraFollowChanged?.call(false);
    notifyListeners();
    if (celebration != null) onTripCelebration?.call(celebration);

    await onSessionEnded?.call(totalKm);
    return distanceKm;
  }

  /// Called from the screens' once-a-second ticker while recording: samples
  /// the hardware step counter (only readable from this isolate) and hands
  /// the result to the tracker so it lands in the persisted snapshot.
  Future<void> tick() async {
    if (!isRecording) return;
    await _pollSnapshot();

    final steps = _steps;
    if (steps == null) return;
    await steps.sample();
    if (steps.steps == (_snapshot?.steps ?? 0)) return;
    // `updatedAt` deliberately untouched: it is the service's stamp, and
    // _pollSnapshot compares against it. Bumping it here — once a second,
    // from a clock the service does not share — would make every persisted
    // snapshot look stale and shut the polling fallback off entirely.
    _snapshot = _snapshot?.copyWith(steps: steps.steps);
    await tracker.publishSteps(steps.steps);
    notifyListeners();
  }

  /// Belt to the live channel's braces: re-reads the snapshot the service
  /// persists, so progress still shows even if the plugin's data port is
  /// not delivering. Never rewinds — whichever of the two channels wrote
  /// last wins.
  Future<void> _pollSnapshot() async {
    // Both screens tick once a second (IndexedStack keeps them mounted), so
    // an unthrottled poll would be two file reads a second for a document
    // the service only rewrites every two.
    final now = _clock();
    final last = _lastPollAt;
    if (last != null && now.difference(last) < _kSnapshotPollInterval) return;
    _lastPollAt = now;

    final persisted = await tracker.readSnapshot();
    if (persisted == null) return;
    if (!persisted.isRecording) {
      // Task 2g: the live data-port message this same event usually reaches
      // us on can be dropped (e.g. right as the service isolate tears
      // itself down) — this poll, up to `_kSnapshotPollInterval` later, is
      // the belt-and-braces catch for exactly that.
      if (isRecording && _isAutoFinishSignal(persisted)) {
        // Adopted first (distance/steps/etc.), same as the live-channel
        // path below — see `_onTrackerSnapshot`'s own doc comment for why:
        // it is what makes `stopTrip()`'s own `_freshest` pick this exact,
        // known-final snapshot rather than depending on `tracker.stop()`'s
        // own (potentially staler) read racing it correctly.
        _adopt(persisted);
        unawaited(stopTrip());
      }
      return;
    }
    if (!isRecording) return;
    final current = _snapshot;
    if (current != null && !persisted.updatedAt.isAfter(current.updatedAt)) {
      return;
    }
    _adopt(persisted);
  }

  /// Task 2g: whether [snapshot] is the service's own signal that a guided
  /// trip auto-finished at arrival (`TripTaskHandler._autoFinishOnArrival`)
  /// — its final published/persisted snapshot, marked `status: idle` while
  /// still carrying `routeBound`/`navArrived` from the trip it just ended.
  /// Never true for a free trip (never `routeBound`) or an ordinary
  /// mid-trip idle blip (the service has no other way to publish
  /// `status: idle` while a trip is recording — see that method's own doc
  /// comment).
  bool _isAutoFinishSignal(TripSnapshot snapshot) =>
      !snapshot.isRecording && snapshot.routeBound && snapshot.navArrived;

  void _onTrackerSnapshot(TripSnapshot snapshot) {
    if (_state != TripState.recording) return;
    // Task 2g: the service's own signal that a guided trip auto-finished at
    // arrival — react exactly as a manual "Terminer" tap would (same
    // pipeline, same events, same history write). `_adopt` still runs
    // first — it is what makes `_snapshot` (hence `stopTrip()`'s own
    // `_freshest` comparison against `tracker.stop()`'s independent read)
    // reflect this exact, known-final distance/steps rather than depending
    // on whichever of the two happens to carry the later `updatedAt`; the
    // extra `notifyListeners()`/`_maybeProcessGameVisits` calls this costs
    // are harmless; only `stopTrip()` right after actually matters.
    if (_isAutoFinishSignal(snapshot)) {
      _adopt(snapshot);
      unawaited(stopTrip());
      return;
    }
    _adopt(snapshot);
  }

  void _adopt(TripSnapshot snapshot) {
    // The service does not know about steps sampled since its last event;
    // keep the higher of the two rather than letting the count flicker
    // backwards between the two channels.
    final steps = _steps?.steps ?? snapshot.steps;
    _snapshot = snapshot.copyWith(
      steps: steps > snapshot.steps ? steps : snapshot.steps,
    );
    notifyListeners();
    // M4 exploration Task 5: fed the just-adopted snapshot's OWN
    // pendingVisits (not `_snapshot`'s field again) since that is exactly
    // what the service published this time, from either channel (live or
    // polled) that reached [_adopt].
    _maybeProcessGameVisits(snapshot.pendingVisits);
  }

  /// M4 exploration Task 5: fire-and-forget, exactly like
  /// [processTripExploration] — a slow or throwing `GameVisitConsumer` must
  /// never delay adopting a snapshot or block the trip in any way.
  ///
  /// Task 2g: chains [_accumulateVisitXp] onto the call's own returned
  /// events before the existing `catchError` — a failure there is caught by
  /// the same handler as a failure in [process] itself, so this still never
  /// escapes into the fire-and-forget caller.
  void _maybeProcessGameVisits(List<PendingVisit> visits) {
    final process = processGameVisits;
    if (process == null || visits.isEmpty) return;
    unawaited(
      process(visits).then(_accumulateVisitXp).catchError((e) {
        debugPrint(
          'TripController: game visit processing failed, continuing: $e',
        );
      }),
    );
  }

  /// Task 2g: adds this one `processGameVisits` call's own `xp_earned`
  /// amounts to [_tripVisitXp] — see that field's doc comment for why this
  /// is the only source ever consulted (never a `GameState` read). A no-op
  /// for a batch that earned no XP at all (e.g. every visit in it was a
  /// cooldown-blocked revisit, which appends `landmark_visited` alone).
  void _accumulateVisitXp(List<GameEvent> events) {
    for (final event in events) {
      if (event.type != GameEventTypes.xpEarned) continue;
      _tripVisitXp += (event.payload['amount'] as num?)?.toDouble() ?? 0;
    }
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
      // The computed route belonged to the old profile: a cyclist's line
      // through a park is not a walker's. Dropping it (the endpoints stay)
      // means no screen can show a route that does not match the selected
      // profile — the map replans immediately, and the session tab, which
      // has no planner, simply stops showing a stale one.
      _activeRoute = route.copyWith(profile: profile, clearRoute: true);
      notifyListeners();
      await routeStore.save(_activeRoute!);
      return;
    }
    notifyListeners();
    await _persistProfile(profile);
  }

  /// Persists « Guidage vocal » and pushes it into a running trip's service
  /// immediately — see [TripTracker.updateAlertSettings] — so toggling it
  /// mid-trip takes effect on the very next alert instead of waiting for the
  /// trip to end.
  Future<void> setTtsEnabled(bool value) async {
    await _alertSettings.setTtsEnabled(value);
    await tracker.updateAlertSettings(
      ttsEnabled: value,
      hapticsEnabled: await _alertSettings.hapticsEnabled(),
    );
  }

  /// Persists « Vibrations et alertes » and pushes it into a running trip's
  /// service immediately — see [setTtsEnabled].
  Future<void> setHapticsEnabled(bool value) async {
    await _alertSettings.setHapticsEnabled(value);
    await tracker.updateAlertSettings(
      ttsEnabled: await _alertSettings.ttsEnabled(),
      hapticsEnabled: value,
    );
  }

  /// Task 2g: the pending celebration's trip identity, if any — a thin
  /// passthrough to [FinalisedTripMemory.pendingCelebration] (private on
  /// this class) so whatever widget hosts the congratulations screen (see
  /// `trip/trip_celebration_screen.dart`) can check for one at startup,
  /// after [restore] — for a trip that finalised while nothing was watching
  /// live. Does not clear it: call [clearPendingCelebration] once the
  /// screen has actually been shown.
  Future<DateTime?> takePendingCelebration() =>
      _finalisedTrips.pendingCelebration();

  /// Marks the pending celebration (if any) as shown, so it is not offered
  /// again on the next cold start — see [takePendingCelebration].
  Future<void> clearPendingCelebration() =>
      _finalisedTrips.clearPendingCelebration();

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
    'tripControllerProvider must be overridden — see main().',
  );
});
