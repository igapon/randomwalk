import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../valhalla/models.dart';

enum TripStatus { idle, recording }

/// Below this a trip is too short to say anything about cadence: the
/// hardware step counter (TYPE_STEP_COUNTER) only reports after a burst of
/// steps, so the first ~100 m of any walk legitimately shows zero.
const _kPlausibilityMinKm = 0.4;

/// A walker does roughly 1300–1600 steps per kilometre. Anything under this
/// is not "a slow walk", it is a trip that was not walked — the point of the
/// check (brief §5) is catching a phone in a car, not policing stride length.
const _kMinStepsPerKm = 250;

/// Whether a recorded trip's step count is too low for the distance to have
/// been walked. Only meaningful for [RoutingProfile.walk]; a bike trip
/// legitimately produces no steps at all.
bool isImplausibleWalk({
  required RoutingProfile profile,
  required double distanceKm,
  required int steps,
}) {
  if (profile != RoutingProfile.walk) return false;
  if (distanceKm < _kPlausibilityMinKm) return false;
  return steps < distanceKm * _kMinStepsPerKm;
}

/// The whole of a trip's live progress, as a value.
///
/// This is the contract between the tracking isolate (which owns the GPS and
/// step streams and writes snapshots) and the UI isolate (which renders
/// them, and may not even exist while a trip records). Everything the UI
/// needs to draw the recording state — and everything needed to *resume* a
/// trip whose process was killed — is in here, so restoring is a matter of
/// reading one document rather than replaying a session.
class TripSnapshot {
  final TripStatus status;
  final double distanceKm;
  final int steps;
  final DateTime startedAt;

  /// When the tracker last refreshed this snapshot. Used to tell a fresh
  /// snapshot from a stale one left by a killed process.
  final DateTime updatedAt;
  final RoutingProfile profile;

  /// Whether the trip was started from a planned route (see [ActiveRoute]):
  /// restored trips need it to put the camera back into follow mode.
  final bool routeBound;

  const TripSnapshot({
    required this.status,
    required this.distanceKm,
    required this.steps,
    required this.startedAt,
    required this.updatedAt,
    required this.profile,
    required this.routeBound,
  });

  /// A trip that is about to start: zeroed, or — when resuming an
  /// interrupted trip — seeded with what was already accumulated.
  factory TripSnapshot.starting({
    required DateTime startedAt,
    required RoutingProfile profile,
    required bool routeBound,
    double distanceKm = 0,
    int steps = 0,
  }) =>
      TripSnapshot(
        status: TripStatus.recording,
        distanceKm: distanceKm,
        steps: steps,
        startedAt: startedAt,
        updatedAt: startedAt,
        profile: profile,
        routeBound: routeBound,
      );

  Duration elapsedAt(DateTime now) {
    final d = now.difference(startedAt);
    return d.isNegative ? Duration.zero : d;
  }

  bool get isRecording => status == TripStatus.recording;

  /// Locally-computed "à vérifier" flag (brief §5). Server-side use is M5;
  /// for now it exists so the session UI can say so and the value is
  /// carried in the persisted snapshot.
  bool get needsReview => isImplausibleWalk(
        profile: profile,
        distanceKm: distanceKm,
        steps: steps,
      );

  TripSnapshot copyWith({
    TripStatus? status,
    double? distanceKm,
    int? steps,
    DateTime? updatedAt,
  }) =>
      TripSnapshot(
        status: status ?? this.status,
        distanceKm: distanceKm ?? this.distanceKm,
        steps: steps ?? this.steps,
        startedAt: startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        profile: profile,
        routeBound: routeBound,
      );

  Map<String, dynamic> toJson() => {
        'status': status.name,
        'distanceKm': distanceKm,
        'steps': steps,
        'startedAt': startedAt.toUtc().toIso8601String(),
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'profile': profile.name,
        'routeBound': routeBound,
      };

  factory TripSnapshot.fromJson(Map<String, dynamic> j) => TripSnapshot(
        status: TripStatus.values.firstWhere((s) => s.name == j['status'],
            orElse: () => TripStatus.idle),
        distanceKm: (j['distanceKm'] as num).toDouble(),
        steps: (j['steps'] as num).toInt(),
        startedAt: DateTime.parse(j['startedAt'] as String),
        updatedAt: DateTime.parse(j['updatedAt'] as String),
        profile: RoutingProfile.values.firstWhere((p) => p.name == j['profile'],
            orElse: () => RoutingProfile.walk),
        routeBound: j['routeBound'] as bool? ?? false,
      );
}

/// Persistence seam for [TripSnapshot], written by the tracker and read by
/// the UI (including at cold start, in a process that never saw the trip).
abstract class TripSnapshotStore {
  Future<TripSnapshot?> read();
  Future<void> write(TripSnapshot snapshot);
  Future<void> clear();
}

/// A JSON document on disk, `.tmp` + rename like [FileActiveRouteStore].
///
/// Deliberately a plain [File] and not `shared_preferences`: the writer runs
/// in the foreground-service isolate and the reader in the UI isolate, and
/// `SharedPreferences` caches its whole backing map per isolate — the UI
/// would keep serving the values it read at startup. The filesystem has no
/// such cache. The path is handed to the isolate at start-up (see
/// `TrackingService`) so the isolate never has to call `path_provider`.
class FileTripSnapshotStore implements TripSnapshotStore {
  final File file;

  /// Two isolates write this document — the UI writes the seed at trip
  /// start, the service writes progress — so they must not share a scratch
  /// path, or one rename can consume the other's half-written file.
  final String tmpSuffix;

  Future<void> _pending = Future.value();

  FileTripSnapshotStore(this.file, {this.tmpSuffix = '.tmp'});

  @override
  Future<TripSnapshot?> read() async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return TripSnapshot.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(TripSnapshot snapshot) => _serialize(() async {
        await file.parent.create(recursive: true);
        final tmp = File('${file.path}$tmpSuffix');
        await tmp.writeAsString(jsonEncode(snapshot.toJson()), flush: true);
        await tmp.rename(file.path);
      });

  @override
  Future<void> clear() => _serialize(() async {
        if (await file.exists()) await file.delete();
      });

  Future<void> _serialize(Future<void> Function() op) {
    final next = _pending.then((_) => op());
    _pending = next.catchError((_) {});
    return next;
  }
}

/// Rate-limits snapshot writes to one per [interval], keeping the most
/// recent value so nothing is lost — a GPS fix arrives every few metres and
/// the step counter fires continuously, and writing the document on each of
/// them would be a flash write every few hundred milliseconds for a value
/// nobody reads until the process dies.
///
/// Clock-driven rather than `Timer`-driven so it can be tested without
/// fake-async, and so it behaves identically in the tracking isolate where
/// events, not timers, drive progress.
class ThrottledSnapshotWriter {
  final TripSnapshotStore store;
  final Duration interval;
  final DateTime Function() _clock;

  DateTime? _lastWriteAt;
  TripSnapshot? _pendingSnapshot;

  ThrottledSnapshotWriter(
    this.store, {
    this.interval = const Duration(seconds: 2),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Records [snapshot] as the current value and writes it if the interval
  /// has elapsed since the last successful write. Never throws: a failed
  /// write leaves the value pending so the next submit retries it.
  Future<void> submit(TripSnapshot snapshot) async {
    _pendingSnapshot = snapshot;
    final last = _lastWriteAt;
    if (last != null && _clock().difference(last) < interval) return;
    await _write();
  }

  /// Writes the pending value regardless of the interval. Called when the
  /// trip stops or the service is torn down — the moments where losing the
  /// last few hundred metres would actually be visible.
  Future<void> flush() async {
    if (_pendingSnapshot == null) return;
    await _write();
  }

  Future<void> _write() async {
    final snapshot = _pendingSnapshot;
    if (snapshot == null) return;
    try {
      await store.write(snapshot);
      _pendingSnapshot = null;
      _lastWriteAt = _clock();
      // Storage failures are never worth killing a recording trip over: the
      // value stays pending and the next submit/flush writes it.
    } catch (_) {}
  }
}
