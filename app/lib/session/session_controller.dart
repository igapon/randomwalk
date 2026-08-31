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

  /// Injectable so the foreground-service isolate can ask for Android-
  /// specific background behaviour (an explicit update interval) without
  /// this class importing anything platform-specific.
  final LocationSettings _locationSettings;

  SessionRecorder? _recorder;
  DateTime? _lastFixAt;
  bool _isRecording = false;
  bool _isStarting = false;
  StreamSubscription<Position>? _positionStream;

  /// Callback when a session ends (successful stop or error).
  /// Invoked with the total km accumulated in the session.
  Future<void> Function(double totalKm)? onSessionEnded;

  /// Callback when a session ends due to GPS stream error.
  /// Invoked with an optional error message.
  Future<void> Function(String? errorMessage)? onSessionError;

  SessionController({
    required this._store,
    Stream<Position> Function(LocationSettings)? getPositionStream,
    DateTime Function()? getClock,
    Future<bool> Function()? checkPermissions,
    LocationSettings? locationSettings,
    this.onSessionEnded,
    this.onSessionError,
  })  : _locationSettings = locationSettings ??
            const LocationSettings(
                accuracy: LocationAccuracy.best, distanceFilter: 3),
        _getPositionStream = getPositionStream ??
            ((LocationSettings settings) => Geolocator.getPositionStream(locationSettings: settings)),
        _getClock = getClock ?? DateTime.now,
        _checkPermissions = checkPermissions ?? _defaultCheckPermissions;

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

      // Subscribe to position stream.
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
        },
        onError: (e) {
          // Finish session on stream error, persisting partial distance.
          _finishSession(isError: true, errorMessage: e?.toString());
        },
      );

      _isRecording = true;
      return true;
    } finally {
      _isStarting = false;
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
