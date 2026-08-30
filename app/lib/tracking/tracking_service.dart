import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';

import '../session/recorder.dart';
import '../session/session_controller.dart';
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
  /// Starts recording from [seed] — zeroed for a new trip, or carrying the
  /// distance/steps of an interrupted one being resumed.
  Future<bool> start(TripSnapshot seed);

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
const _kGpsErrorKey = 'gpsError';

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
  late final TripSnapshotStore _store = FileTripSnapshotStore(snapshotFile);
  final _updates = StreamController<TripSnapshot>.broadcast();
  final _errors = StreamController<String?>.broadcast();
  bool _callbackAttached = false;

  ForegroundServiceTripTracker(this.snapshotFile);

  /// Must run in `main()` before `runApp`: without it the service isolate
  /// has nowhere to send data.
  static void initCommunication() =>
      FlutterForegroundTask.initCommunicationPort();

  @override
  Stream<TripSnapshot> get updates => _updates.stream;

  @override
  Stream<String?> get errors => _errors.stream;

  @override
  Future<bool> isRunning() => FlutterForegroundTask.isRunningService;

  @override
  Future<TripSnapshot?> readSnapshot() => _store.read();

  @override
  Future<void> clearSnapshot() => _store.clear();

  @override
  Future<bool> start(TripSnapshot seed) async {
    _configure();
    _attachCallback();

    // Written before the service starts so the isolate never races the UI
    // for its own starting state, and so a service that dies before its
    // first snapshot still leaves a resumable trip behind.
    await _store.write(seed);
    await FlutterForegroundTask.saveData(
        key: _kSnapshotPathKey, value: snapshotFile.path);
    await FlutterForegroundTask.saveData(
        key: _kSeedKey, value: jsonEncode(seed.toJson()));

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

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final path = await FlutterForegroundTask.getData<String>(
        key: _kSnapshotPathKey);
    final rawSeed =
        await FlutterForegroundTask.getData<String>(key: _kSeedKey);
    if (path == null || rawSeed == null) return;

    final seed = TripSnapshot.fromJson(
        jsonDecode(rawSeed) as Map<String, dynamic>);
    _seed = seed;
    _steps = seed.steps;
    _writer = ThrottledSnapshotWriter(FileTripSnapshotStore(File(path)));

    final session = SessionController(
      store: _DiscardingDistanceStore(),
      checkPermissions: () async => true,
      onSessionError: (message) async => FlutterForegroundTask.sendDataToMain(
          jsonEncode({_kGpsErrorKey: message})),
      locationSettings: AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 3,
        intervalDuration: const Duration(seconds: 2),
      ),
    );
    _session = session;
    await session.start();
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    final snapshot = _snapshotAt(timestamp);
    if (snapshot == null) return;
    _writer?.submit(snapshot);
    FlutterForegroundTask.updateService(
        notificationText: tripNotificationText(snapshot, timestamp));
    FlutterForegroundTask.sendDataToMain(jsonEncode(snapshot.toJson()));
  }

  /// The UI hands us the step count it sampled from the hardware sensor;
  /// the service has no Activity and so no platform channel of its own.
  @override
  void onReceiveData(Object data) {
    if (data is Map && data['steps'] is int) _steps = data['steps'] as int;
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    final snapshot = _snapshotAt(timestamp);
    if (snapshot != null) await _writer?.submit(snapshot);
    await _writer?.flush();
    await _session?.dispose();
    _session = null;
  }

  TripSnapshot? _snapshotAt(DateTime now) {
    final seed = _seed;
    if (seed == null) return null;
    final recorded = _session?.recorder?.distanceKm ?? 0;
    return seed.copyWith(
      distanceKm: seed.distanceKm + recorded,
      steps: _steps,
      updatedAt: now,
    );
  }
}

/// [SessionController] insists on a [TotalDistanceStore]; inside the service
/// isolate there is nothing to bank into. The cumulative total and the
/// leaderboard submit happen once, in the UI, when the trip is finalised —
/// doing it here would double-count a resumed trip and would need
/// shared_preferences in an isolate that cannot reliably reach it.
class _DiscardingDistanceStore implements TotalDistanceStore {
  @override
  Future<double> totalKm() async => 0;

  @override
  Future<double> addAndGetTotalKm(double km) async => km;
}
