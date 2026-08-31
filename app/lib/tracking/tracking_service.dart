import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';

import '../nav/alert_policy.dart';
import '../nav/nav_fields.dart';
import '../nav/navigation_runtime.dart';
import '../nav/route_follower.dart';
import '../nav/tts.dart';
import '../session/recorder.dart';
import '../session/session_controller.dart';
import '../settings/alert_settings.dart';
import '../valhalla/engine_channel.dart';
import '../valhalla/models.dart';
import 'adaptive_gps.dart';
import 'nav_seed.dart';
import 'trip_snapshot.dart';

/// The seam between the trip's state machine and whatever is actually
/// holding the GPS open.
///
/// The production implementation ([ForegroundServiceTripTracker]) runs the
/// recording in a separate isolate hosted by an Android foreground service,
/// which means `TripController` can never simply *ask* it for the current
/// distance — it reads a snapshot the tracker publishes. Modelling that
/// asymmetry in the interface (rather than pretending the recorder is a
/// local object) is what makes the controller's "the process died mid-trip"
/// path testable at all.
abstract class TripTracker {
  /// Begins receiving live snapshots from an already-running service.
  ///
  /// Separate from [start] because the UI process can die and come back
  /// while the service keeps recording: the reattaching process has a trip
  /// to display but nothing to start, and without this its live channel
  /// would never be opened.  Idempotent.
  Future<void> attach();

  /// Starts recording from [seed] — zeroed for a new trip, or carrying the
  /// distance/steps of an interrupted one being resumed.
  ///
  /// [nav] is present exactly for route-bound trips: it is what lets the
  /// service run turn-by-turn guidance (and recalculate the route) on its
  /// own, with the app dead and the screen off. A free trip passes none and
  /// records exactly as it did before navigation existed.
  Future<bool> start(TripSnapshot seed, {NavSeed? nav});

  /// Stops recording and returns the last snapshot the tracker produced.
  Future<TripSnapshot?> stop();

  /// Whether the tracker is recording *right now*. At cold start this is
  /// what distinguishes "a trip is running in the service" from "a trip was
  /// running when the process was killed".
  Future<bool> isRunning();

  /// The last snapshot persisted by the tracker, readable from a process
  /// that has never seen the trip.
  Future<TripSnapshot?> readSnapshot();

  /// Forgets the persisted snapshot — called once a trip has been finalised
  /// (distance banked, score submitted), so the next cold start sees idle.
  Future<void> clearSnapshot();

  /// Live snapshots, while the UI is attached to the tracker.
  Stream<TripSnapshot> get updates;

  /// GPS stream failures reported by the recorder. Surfaced rather than
  /// swallowed because the trip visibly stops advancing when one happens,
  /// and the user deserves to be told why.
  Stream<String?> get errors;

  /// Hands the tracker a step count sampled by the UI (the step sensor is
  /// read from the UI isolate — see [StepSensor]) so it lands in the
  /// persisted snapshot too.
  Future<void> publishSteps(int steps);

  /// Pushes a changed « Guidage vocal »/« Vibrations et alertes » setting
  /// into an already-running service, so flipping a toggle mid-trip takes
  /// effect on the very next maneuver alert instead of waiting for the trip
  /// to end. A no-op while nothing is recording — the next [start] reads the
  /// setting fresh from disk anyway (see `AlertSettingsStore`).
  Future<void> updateAlertSettings(
      {required bool ttsEnabled, required bool hapticsEnabled});

  Future<void> dispose();
}

/// Notification copy. Sober by design (brief): one line, no emoji, no call
/// to action — it is a status indicator, not an ad for the app.
String tripNotificationText(TripSnapshot snapshot, DateTime now) {
  final km = snapshot.distanceKm.toStringAsFixed(1).replaceAll('.', ',');
  final minutes = snapshot.elapsedAt(now).inMinutes;
  return '$km km · $minutes min';
}

const _kChannelId = 'randomwalk_trip';
const _kServiceId = 4211;
const _kSnapshotPathKey = 'randomwalk_snapshot_path';
const _kSeedKey = 'randomwalk_seed_snapshot';
const _kNavSeedKey = 'randomwalk_nav_seed';
const _kGpsErrorKey = 'gpsError';
const _kTtsEnabledKey = 'randomwalk_tts_enabled';
const _kHapticsEnabledKey = 'randomwalk_haptics_enabled';

/// The maneuver-alert notification channel — distinct from [_kChannelId]'s
/// silent, sticky trip notification: this one is meant to be noticed with
/// the screen off, so it gets sound and vibration.
const _kAlertChannelId = 'guidance';

/// One id, reused for every alert: a fresh maneuver notice replaces the
/// previous one instead of piling up a history of turns the walker has
/// already taken.
const _kAlertNotificationId = 4212;

/// How long a recording trip may go without a single position before the UI
/// is told the GPS has gone quiet. Long enough not to fire on a cold fix in
/// a building, short enough that a walk does not finish before the user is
/// warned.
const kGpsSilenceThreshold = Duration(seconds: 60);

/// Whether a recording session has stopped hearing from the location
/// stream altogether.
///
/// Worth a warning of its own because it is the one failure mode with no
/// other symptom: geolocator not working inside the service isolate raises
/// nothing, logs nothing and simply never delivers a fix, leaving a trip
/// that looks like it is recording and measures nothing. [lastFixAt] is
/// null before the first position ever arrives, in which case the clock
/// runs from [recordingSince].
bool isGpsSilent({
  required DateTime now,
  required DateTime? lastFixAt,
  required DateTime recordingSince,
  Duration threshold = kGpsSilenceThreshold,
}) =>
    now.difference(lastFixAt ?? recordingSince) > threshold;

/// Android foreground service (`flutter_foreground_task` 11.x) hosting a
/// [SessionController] in its own isolate.
///
/// The division of labour:
///  - the *isolate* owns the GPS subscription and the distance maths, and
///    publishes a [TripSnapshot] to a file every couple of seconds;
///  - the *UI isolate* owns everything needing an Activity (permission
///    prompts, the step sensor's platform channel) and reads snapshots.
///
/// They talk over two channels, deliberately: the plugin's data port for
/// liveness while the app is attached, and the snapshot file for truth —
/// the file is the only one of the two that survives the UI process dying.
class ForegroundServiceTripTracker implements TripTracker {
  final File snapshotFile;
  final AlertSettingsStore _alertSettings;

  /// `.ui.tmp`, not the isolate's `.tmp`: both sides write this document.
  late final TripSnapshotStore _store =
      FileTripSnapshotStore(snapshotFile, tmpSuffix: '.ui.tmp');
  final _updates = StreamController<TripSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  bool _callbackAttached = false;

  ForegroundServiceTripTracker(this.snapshotFile, {AlertSettingsStore? alertSettings})
      : _alertSettings = alertSettings ?? AlertSettingsStore();

  /// Must run in `main()` before `runApp`: without it the service isolate
  /// has nowhere to send data.
  static void initCommunication() =>
      FlutterForegroundTask.initCommunicationPort();

  @override
  Stream<TripSnapshot> get updates => _updates.stream;

  @override
  Stream<String?> get errors => _errors.stream;

  @override
  Future<void> attach() async => _attachCallback();

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<TripSnapshot?> readSnapshot() => _store.read();

  @override
  Future<void> clearSnapshot() => _store.clear();

  @override
  Future<bool> start(TripSnapshot seed, {NavSeed? nav}) async {
    _configure();
    await attach();

    // Written before the service starts so the isolate never races the UI
    // for its own starting state, and so a service that dies before its
    // first snapshot still leaves a resumable trip behind.
    await _store.write(seed);
    await FlutterForegroundTask.saveData(
        key: _kSnapshotPathKey, value: snapshotFile.path);
    await FlutterForegroundTask.saveData(
        key: _kSeedKey, value: jsonEncode(seed.toJson()));
    // Overwritten (or blanked) on every start, never left over: a free trip
    // started after a route-bound one must not inherit its itinerary — this
    // store outlives both the service and the process.
    await FlutterForegroundTask.saveData(
        key: _kNavSeedKey, value: nav == null ? '' : jsonEncode(nav.toJson()));
    // Read fresh at every start (not just once, ever) so a setting flipped
    // between two trips is honoured by the second one even without
    // [updateAlertSettings] ever having been called on a running service.
    await FlutterForegroundTask.saveData(
        key: _kTtsEnabledKey, value: await _alertSettings.ttsEnabled());
    await FlutterForegroundTask.saveData(
        key: _kHapticsEnabledKey, value: await _alertSettings.hapticsEnabled());

    final result = await FlutterForegroundTask.startService(
      serviceId: _kServiceId,
      serviceTypes: [ForegroundServiceTypes.location],
      notificationTitle: 'RandomWalk',
      notificationText: tripNotificationText(seed, seed.startedAt),
      callback: startTrackingTask,
    );
    return result is ServiceRequestSuccess;
  }

  @override
  Future<TripSnapshot?> stop() async {
    await FlutterForegroundTask.stopService();
    // The itinerary dies with the trip. This store outlives the process, and
    // `start` blanking it is only enough for starts that go through this
    // class — a service Android brings back on its own does not.
    await FlutterForegroundTask.saveData(key: _kNavSeedKey, value: '');
    // `stopService` returns before the handler's `onDestroy` has necessarily
    // flushed, so the caller reconciles this with the last live snapshot it
    // saw (see TripController._finalise).
    return _store.read();
  }

  @override
  Future<void> publishSteps(int steps) async {
    if (!await isRunning()) return;
    FlutterForegroundTask.sendDataToTask({'steps': steps});
  }

  @override
  Future<void> updateAlertSettings(
      {required bool ttsEnabled, required bool hapticsEnabled}) async {
    // Persisted regardless of whether a service is running: an
    // Android-restarted service (allowAutoRestart) re-reads these at its own
    // `onStart`, same as the nav seed.
    await FlutterForegroundTask.saveData(
        key: _kTtsEnabledKey, value: ttsEnabled);
    await FlutterForegroundTask.saveData(
        key: _kHapticsEnabledKey, value: hapticsEnabled);
    if (!await isRunning()) return;
    FlutterForegroundTask.sendDataToTask(
        {'ttsEnabled': ttsEnabled, 'hapticsEnabled': hapticsEnabled});
  }

  @override
  Future<void> dispose() async {
    if (_callbackAttached) {
      FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
      _callbackAttached = false;
    }
    await _updates.close();
    await _errors.close();
  }

  void _attachCallback() {
    if (_callbackAttached) return;
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
    _callbackAttached = true;
  }

  void _onTaskData(Object data) {
    if (data is! String) return;
    try {
      final message = jsonDecode(data) as Map<String, dynamic>;
      if (message.containsKey(_kGpsErrorKey)) {
        if (!_errors.isClosed) {
          _errors.add(message[_kGpsErrorKey] as String?);
        }
        return;
      }
      final snapshot = TripSnapshot.fromJson(message);
      if (!_updates.isClosed) _updates.add(snapshot);
    } catch (_) {
      // A malformed message is not worth interrupting a trip for; the
      // snapshot file remains the source of truth.
    }
  }

  void _configure() => FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: _kChannelId,
          channelName: 'Trajet en cours',
          channelDescription: 'Suivi du trajet, même écran éteint.',
          // LOW keeps it silent and un-intrusive: a walk tracker has no
          // business buzzing every time it updates the distance.
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
          onlyAlertOnce: true,
          showWhen: false,
        ),
        iosNotificationOptions: const IOSNotificationOptions(
            showNotification: false, playSound: false),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.repeat(2000),
          // The point of the whole exercise: keep the CPU awake enough to
          // keep receiving GPS with the screen off, and keep the service
          // alive when the task is swiped out of the recents list.
          allowWakeLock: true,
          allowWifiLock: false,
          allowAutoRestart: true,
          stopWithTask: false,
        ),
      );
}

/// Where a (re)starting service isolate picks the trip up from.
///
/// [persisted] is the last snapshot written to disk; [seed] is what the UI
/// handed over when the user pressed Démarrer. The persisted one wins:
/// `allowAutoRestart` means Android can kill and relaunch the service
/// mid-trip and run `onStart` again, and restarting from the seed would
/// silently reset the distance to whatever it was at the start of the trip.
/// Restarting from the snapshot loses at most one write interval.
TripSnapshot? resumePoint(TripSnapshot? persisted, TripSnapshot? seed) =>
    persisted != null && persisted.isRecording ? persisted : seed;

/// [snapshot] with its navigation state forgotten — what a (re)starting
/// service incarnation must record on top of.
///
/// The distance and steps of a killed incarnation are worth resuming; its
/// *guidance* is not. A new incarnation rebuilds its follower from the
/// planned route (or, with no nav seed to read, has no follower at all), so
/// carrying the dead one's fields over would republish a frozen instruction
/// and a stale route shape — for the rest of the trip in the no-follower
/// case, since nothing would ever overwrite them. Resetting `navReplanCount`
/// with them is the honest reading: the count belongs to a route this
/// incarnation is not following.
TripSnapshot withoutNavigation(TripSnapshot snapshot) =>
    snapshot.copyWith(nav: const NavFields());

/// The service isolate's entry point. Must be a top-level function marked
/// `vm:entry-point` — the AOT compiler cannot see it otherwise.
@pragma('vm:entry-point')
void startTrackingTask() {
  FlutterForegroundTask.setTaskHandler(TripTaskHandler());
}

/// Runs the recording inside the foreground service.
///
/// Reuses [SessionController] unchanged as the recording brain — the same
/// GPS filtering and distance maths the app has always used, and the same
/// unit tests — with two substitutions appropriate to an isolate: the
/// permission check is a no-op (the UI ran the real flow before starting
/// the service, and requesting a permission here would need an Activity),
/// and the distance store is a sink, because banking a session's kilometres
/// and submitting the score belong to the UI's finalisation path.
class TripTaskHandler extends TaskHandler {
  SessionController? _session;
  ThrottledSnapshotWriter? _writer;
  TripSnapshot? _seed;
  int _steps = 0;
  DateTime? _recordingSince;

  /// Turn-by-turn state, for route-bound trips only. Null for a free trip,
  /// which then behaves exactly as it did before navigation existed.
  NavSeed? _navSeed;
  NavigationRuntime? _nav;
  NavFields? _navFields;

  /// Decides which fixes are worth a maneuver alert for. Built alongside
  /// [_nav] — null for a free trip, so [_maybeAlert] never has anything to
  /// evaluate for one (brief: "Free sessions: no alerts").
  AlertPolicy? _alertPolicy;

  /// Adaptive GPS (Task 7 + owner brief): tightens the location stream's
  /// `distanceFilter` as the walker nears a maneuver and loosens it again on
  /// a long straight leg. `_currentDistanceFilter` starts at the tight value
  /// because that is what [SessionController]'s own `AndroidSettings` below
  /// is constructed with — the two must never disagree about what is
  /// currently subscribed, or the rate limiter's "nothing to change" check
  /// would be comparing against a filter the stream isn't actually using.
  int _currentDistanceFilter = kNavCloseDistanceFilterM;
  final _gpsRateLimiter = AdaptiveGpsRateLimiter();

  /// The [NavFields.replanCount] [_alertPolicy] was last reset for. A
  /// replan builds a fresh `RouteFollower` (see `NavigationRuntime`'s own
  /// doc comment) whose maneuver numbering restarts at 0 — without
  /// noticing the count changed and calling [AlertPolicy.reset], the new
  /// route's early maneuvers could read as "already alerted" purely by
  /// index coincidence with the old one.
  int _lastAlertPolicyReplanCount = 0;

  /// « Vibrations et alertes » / « Guidage vocal », read from the seed and
  /// refreshed live via [onReceiveData] — see `TripTracker.updateAlertSettings`.
  bool _hapticsEnabled = true;
  bool _ttsEnabled = true;

  /// [NoopTtsSpeaker] until [_initSpeaker] (called from [onStart], and again
  /// from [onReceiveData] if "Guidage vocal" is turned on mid-trip) swaps in
  /// a [NativeTtsSpeaker] that actually answered `init()` with usable French
  /// TTS. Stays [NoopTtsSpeaker] on a device with none.
  TtsSpeaker _speaker = const NoopTtsSpeaker();

  FlutterLocalNotificationsPlugin? _notifications;
  bool _notificationsReady = false;

  /// Built on the first replan, not at start-up: a trip that never leaves
  /// its route never pays for loading a routing engine into this isolate.
  ChannelRoutingEngine? _engine;

  /// One fix at a time through the runtime. A replan is a round trip to
  /// Valhalla over a method channel and can easily outlast the ~2 s between
  /// fixes; fixes arriving meanwhile still count for distance, they just do
  /// not queue up behind guidance.
  bool _navBusy = false;

  /// The service is being torn down. A replan can outlive `onDestroy` — it
  /// is awaiting a platform channel, which the teardown does not cancel —
  /// and must not then submit a snapshot after the final flush or update a
  /// notification that is on its way out.
  bool _stopped = false;

  /// The notification line last published, so a fix that does not change
  /// what the guidance *says* costs nothing (see [_publish]).
  String? _lastNotificationText;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final path = await FlutterForegroundTask.getData<String>(
        key: _kSnapshotPathKey);
    if (path == null) return;

    final store = FileTripSnapshotStore(File(path));
    final resumed = await _resumePoint(store);
    if (resumed == null) return;
    // Distance and steps carry over from a killed incarnation; guidance does
    // not (see [withoutNavigation]).
    final seed = withoutNavigation(resumed);
    _seed = seed;
    _steps = seed.steps;
    _writer = ThrottledSnapshotWriter(store);

    // Note that an Android-restarted service (allowAutoRestart) rebuilds the
    // follower from the *planned* route, not from a route a previous
    // incarnation had replanned onto — that one exists nowhere but in the
    // dead isolate. Self-correcting rather than lost: the first fixes after
    // the restart read as off-route and trigger a fresh replan.
    final navSeed = seed.routeBound ? await _readNavSeed() : null;
    _navSeed = navSeed;
    if (navSeed != null && navSeed.route.shape.length >= 2) {
      _nav = NavigationRuntime(
        follower: RouteFollower(navSeed.route),
        replan: _replanFrom,
      );
      _alertPolicy = AlertPolicy(profile: navSeed.profile);
    }

    _hapticsEnabled =
        await FlutterForegroundTask.getData<bool>(key: _kHapticsEnabledKey) ??
            true;
    _ttsEnabled =
        await FlutterForegroundTask.getData<bool>(key: _kTtsEnabledKey) ?? true;
    if (_ttsEnabled) await _initSpeaker();

    final session = SessionController(
      store: _PassThroughDistanceStore(),
      checkPermissions: () async => true,
      // Banks what the recorder measured into the running total *before* it
      // is discarded. Without this, a GPS stream error mid-trip would drop
      // the trip's distance back to whatever it was at the last (re)start:
      // SessionController nulls its recorder when a session finishes, and
      // [_snapshotAt] reads the distance from that recorder.
      onSessionEnded: _bank,
      onSessionError: (message) async => FlutterForegroundTask.sendDataToMain(
          jsonEncode({_kGpsErrorKey: message})),
      // Guidance rides the recording's own GPS subscription: a second one
      // would double the fix rate the OS bills a screen-off trip for.
      onFix: _nav == null ? null : _onNavFix,
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
      ),
    );
    _session = session;
    _recordingSince = timestamp;
    await session.start();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    // A GPS stream error ends the underlying session (see
    // SessionController._finishSession). In the foreground that meant the
    // trip was over; for a background recorder it usually means a transient
    // provider hiccup, so retry rather than silently stopping a walk the
    // user thinks is still being measured. Already-measured distance is
    // safe in [_seed] by now, so a restart resumes on top of it.
    final session = _session;
    if (session != null && !session.isRecording && !session.isStarting) {
      session.start();
      // Restart the watchdog's clock with the session. Left at the original
      // trip start it would measure a gap the new session was never given a
      // chance to fill, and raise the warning on the very next event.
      _recordingSince = timestamp;
    }

    _publish(timestamp, periodic: true);
  }

  /// Writes the current state everywhere it is read from: the persisted
  /// snapshot (throttled), the notification, and the UI's live channel.
  ///
  /// Called on every repeat event ([periodic]) *and* on every navigated fix
  /// — a walker approaching a turn should not have to wait out the tick for
  /// the notification to say so. A fix that does not change what the
  /// guidance *says*, though, publishes nothing at all: the metre-by-metre
  /// progress behind it reaches the UI on the next repeat event anyway, and
  /// the alternative is a snapshot (route polyline included) crossing the
  /// isolate boundary for every fix of the walk.
  void _publish(DateTime now, {required bool periodic}) {
    if (_stopped) return;
    final snapshot = _snapshotAt(now);
    if (snapshot == null) return;
    final text = _notificationText(snapshot, now);
    if (!periodic && text == _lastNotificationText) return;
    _lastNotificationText = text;
    _writer?.submit(snapshot);
    FlutterForegroundTask.updateService(notificationText: text);
    FlutterForegroundTask.sendDataToMain(jsonEncode(snapshot.toJson()));
  }

  String _notificationText(TripSnapshot snapshot, DateTime now) {
    final fields = _navFields;
    return fields == null
        ? tripNotificationText(snapshot, now)
        : navNotificationText(fields);
  }

  /// One accepted GPS fix, run through turn-by-turn navigation.
  ///
  /// Deliberately swallows everything: guidance is an addition to a
  /// recording trip, never a way to end one.
  Future<void> _onNavFix(GpsSample sample) async {
    final nav = _nav;
    if (nav == null || _navBusy || _stopped) return;
    _navBusy = true;
    try {
      _navFields = await nav.onFix(
          sample.lat, sample.lon, sample.speedMps, sample.time);
      await _maybeAlert(nav.lastUpdate);
      await _maybeAdaptGps();
      // Publishing is inside the try for the same reason [_stopped] exists:
      // a fix whose replan outlived the teardown must not raise from a
      // callback nothing is left to await.
      _publish(DateTime.now(), periodic: false);
    } catch (_) {
      return;
    } finally {
      _navBusy = false;
    }
  }

  /// Runs [update] through [AlertPolicy] and, if it is worth interrupting
  /// the walker for, fires whichever of the notification/TTS are enabled.
  ///
  /// Both are best-effort: a notification-plugin hiccup or a wedged TTS
  /// engine must cost this fix nothing beyond the alert it was trying to
  /// deliver — the trip keeps recording either way.
  Future<void> _maybeAlert(NavUpdate? update) async {
    final policy = _alertPolicy;
    if (policy == null || update == null || _stopped) return;

    // A replan since the last fix means a fresh RouteFollower — reset before
    // asking the policy about this update, so its very first tick on the new
    // route is judged fresh rather than against the old route's bookkeeping
    // (see AlertPolicy.reset's doc comment for why this matters).
    final replanCount = _navFields?.replanCount ?? _lastAlertPolicyReplanCount;
    if (replanCount != _lastAlertPolicyReplanCount) {
      policy.reset();
      _lastAlertPolicyReplanCount = replanCount;
    }

    if (!policy.shouldAlert(update)) return;

    final text = alertText(update);
    final tasks = <Future<void>>[];
    if (_hapticsEnabled) tasks.add(_postAlertNotification(text));
    if (_ttsEnabled) tasks.add(_speaker.speak(text).catchError((_) {}));
    await Future.wait(tasks);
  }

  /// Adaptive GPS (Task 7): tightens or loosens the recording's own
  /// `distanceFilter` based on how far the walker now is from the next
  /// maneuver — see `adaptiveDistanceFilter`. Rides the recording's existing
  /// subscription (via [SessionController.updateLocationSettings]) rather
  /// than opening a second one, same as guidance itself does (see
  /// [SessionController.onFix]'s doc comment). Rate-limited to at most one
  /// resubscribe a minute so a walker pacing the 500 m boundary cannot churn
  /// the platform's location provider.
  Future<void> _maybeAdaptGps() async {
    final session = _session;
    if (session == null || _stopped) return;
    final desired = adaptiveDistanceFilter(_navFields?.distanceToManeuverM);
    if (!_gpsRateLimiter.shouldResubscribe(
        currentFilter: _currentDistanceFilter, desiredFilter: desired)) {
      return;
    }
    await session.updateLocationSettings(AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: desired,
      intervalDuration: const Duration(seconds: 2),
    ));
    _currentDistanceFilter = desired;
    _gpsRateLimiter.recordChange();
  }

  /// Builds a [NativeTtsSpeaker], asks it to `init()`, and swaps it in as
  /// [_speaker] if — and only if — it answered with usable French TTS.
  /// Leaves [_speaker] as [NoopTtsSpeaker] otherwise (no voice data for
  /// fr-FR, or no TTS engine on the device at all): [init]'s whole point is
  /// answering that question honestly rather than throwing.
  Future<void> _initSpeaker() async {
    final speaker = NativeTtsSpeaker();
    final available = await speaker.init();
    _speaker = available ? speaker : const NoopTtsSpeaker();
  }

  /// Posts (or replaces) the single guidance-alert notification — high
  /// importance, system sound + vibration, on the « guidage » channel — so
  /// it is noticed with the screen off, unlike [_kChannelId]'s silent,
  /// sticky trip notification.
  Future<void> _postAlertNotification(String text) async {
    try {
      final notifications = _notifications ??= FlutterLocalNotificationsPlugin();
      if (!_notificationsReady) {
        // Each engine — this service's included — needs its own
        // `initialize()` call; the plugin keeps no state across isolates.
        await notifications.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        _notificationsReady = true;
      }
      await notifications.show(
        id: _kAlertNotificationId,
        title: 'RandomWalk',
        body: text,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _kAlertChannelId,
            'Guidage',
            channelDescription:
                "Alerte sonore et vibration à l'approche d'une manœuvre.",
            importance: Importance.high,
            priority: Priority.high,
            playSound: true,
            enableVibration: true,
            // The next alert replaces this one under the same id; a walker
            // who never gets a next maneuver (trip ends first) still sees
            // this clear itself rather than linger indefinitely.
            timeoutAfter: 8000,
          ),
        ),
      );
      // A failed alert must never take the recording down with it — see
      // [_onNavFix]'s own swallow-everything philosophy.
    } catch (_) {
      return;
    }
  }

  /// The recalculation [NavigationRuntime] calls when the walker has left
  /// the route. Throwing is a legitimate outcome here — the runtime reads it
  /// as "no route available" and keeps following the old one.
  ///
  /// Never downloads tiles: the service has no UI to show progress in, and
  /// the walker who most needs a replan is the one least likely to have
  /// connectivity. It routes against whatever was on disk when the trip
  /// started, and reports failure outside that.
  Future<RouteResult?> _replanFrom(double lat, double lon) async {
    final seed = _navSeed;
    final tileDirPath = seed?.tileDirPath;
    if (seed == null || tileDirPath == null) return null;
    var engine = _engine;
    if (engine == null) {
      engine = ChannelRoutingEngine();
      // Assigned only once init succeeds, so a failed init is retried on the
      // next replan rather than cached as a working engine.
      await engine.init(tileDirPath);
      _engine = engine;
    }
    return engine.route(RouteRequest(
      fromLat: lat,
      fromLon: lon,
      toLat: seed.destLat,
      toLon: seed.destLon,
      profile: seed.profile,
    ));
  }

  /// The UI hands us the step count it sampled from the hardware sensor;
  /// the service has no Activity and so no platform channel of its own.
  @override
  void onReceiveData(Object data) {
    if (data is! Map) return;
    if (data['steps'] is int) _steps = data['steps'] as int;
    if (data['hapticsEnabled'] is bool) {
      _hapticsEnabled = data['hapticsEnabled'] as bool;
    }
    if (data['ttsEnabled'] is bool) {
      final enabled = data['ttsEnabled'] as bool;
      _ttsEnabled = enabled;
      // Fire-and-forget: onReceiveData is synchronous, and until init()
      // resolves _speaker simply stays whatever it already was (Noop, most
      // likely) — harmless, since _maybeAlert only ever calls it while
      // _ttsEnabled is true and it is always safe to call.
      if (enabled && _speaker is NoopTtsSpeaker) unawaited(_initSpeaker());
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    // Before the final flush, so an in-flight replan completing during the
    // teardown cannot submit a snapshot after it.
    _stopped = true;
    final snapshot = _snapshotAt(timestamp);
    if (snapshot != null) await _writer?.submit(snapshot);
    await _writer?.flush();
    await _session?.dispose();
    _session = null;
    await _cancelAlertNotification();
  }

  /// Clears a lingering guidance alert when the trip ends — a walker who
  /// stops mid-instruction should not keep seeing (and hearing, on the next
  /// unlock) a notification about a maneuver from a trip that is now over.
  /// A no-op if no alert ever fired: nothing here should construct the
  /// notifications plugin for the first time just to immediately cancel
  /// something that was never shown.
  Future<void> _cancelAlertNotification() async {
    final notifications = _notifications;
    if (notifications == null || !_notificationsReady) return;
    try {
      await notifications.cancel(id: _kAlertNotificationId);
    } catch (_) {
      // Symmetric with _postAlertNotification: teardown must never hang or
      // throw over a notification plugin that is misbehaving.
    }
  }

  bool _isGpsSilentAt(DateTime now) {
    final since = _recordingSince;
    if (since == null) return false;
    return isGpsSilent(
      now: now,
      lastFixAt: _session?.lastFixAt,
      recordingSince: since,
    );
  }

  /// Folds a finished session's distance into the running total.
  Future<void> _bank(double sessionKm) async {
    final seed = _seed;
    if (seed == null) return;
    _seed = seed.copyWith(distanceKm: seed.distanceKm + sessionKm);
  }

  /// The navigation handover written by the UI at trip start. Absent, empty
  /// or unreadable all mean the same thing: record the trip, guide nothing.
  Future<NavSeed?> _readNavSeed() async {
    final raw = await FlutterForegroundTask.getData<String>(key: _kNavSeedKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return NavSeed.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<TripSnapshot?> _resumePoint(TripSnapshotStore store) async {
    final raw = await FlutterForegroundTask.getData<String>(key: _kSeedKey);
    return resumePoint(
      await store.read(),
      raw == null
          ? null
          : TripSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>),
    );
  }

  TripSnapshot? _snapshotAt(DateTime now) {
    final seed = _seed;
    if (seed == null) return null;
    final recorded = _session?.recorder?.distanceKm ?? 0;
    return seed.copyWith(
      distanceKm: seed.distanceKm + recorded,
      steps: _steps,
      updatedAt: now,
      gpsSilent: _isGpsSilentAt(now),
      nav: _navFields,
    );
  }
}

/// [SessionController] insists on a [TotalDistanceStore]; inside the service
/// isolate there is nothing to bank into. The cumulative *lifetime* total and
/// the leaderboard submit happen once, in the UI, when the trip is finalised
/// — doing it here would double-count a resumed trip and would need
/// shared_preferences in an isolate that cannot reliably reach it.
///
/// Returning the session's own distance unchanged (rather than 0) is what
/// makes `onSessionEnded` hand [TripTaskHandler._bank] the kilometres this
/// session measured.
class _PassThroughDistanceStore implements TotalDistanceStore {
  @override
  Future<double> totalKm() async => 0;

  @override
  Future<double> addAndGetTotalKm(double km) async => km;
}
