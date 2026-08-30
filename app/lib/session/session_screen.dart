import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'recorder.dart';

enum ActivityMode { walk, bike }

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, this.onSessionEnded});
  final void Function(double totalKm)? onSessionEnded;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  final SessionRecorder _recorder = SessionRecorder();
  final TotalDistanceStore _store = TotalDistanceStore();

  bool _isRecording = false;
  ActivityMode _mode = ActivityMode.walk;
  Duration _elapsed = Duration.zero;
  StreamSubscription<Position>? _positionStream;
  Timer? _elapsedTimer;

  static const String _kLocationDeniedMessage =
      'Localisation refusée — activez-la dans les réglages.';
  static const String _kPositionUnavailableMessage =
      'Position indisponible — activez la localisation ou définissez un départ manuel.';

  /// Check if location services are available and permissions are granted.
  Future<bool> _checkAndRequestLocationPermissions() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(_kPositionUnavailableMessage)));
      }
      return false;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(_kLocationDeniedMessage)));
      }
      return false;
    }
    return true;
  }

  Future<void> _startSession() async {
    final canAccess = await _checkAndRequestLocationPermissions();
    if (!canAccess) return;

    if (!mounted) return;
    setState(() => _isRecording = true);

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _elapsed = _recorder.elapsed(DateTime.now());
        });
      }
    });

    try {
      _positionStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 3,
        ),
      ).listen(
        (Position position) {
          final sample = GpsSample(
            lat: position.latitude,
            lon: position.longitude,
            accuracyM: position.accuracy,
            speedMps: position.speed,
            time: position.timestamp,
          );
          _recorder.add(sample);
          if (mounted) {
            setState(() {});
          }
        },
        onError: (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text(_kPositionUnavailableMessage)));
            _stopSession();
          }
        },
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(_kPositionUnavailableMessage)));
        _stopSession();
      }
    }
  }

  Future<void> _stopSession() async {
    await _positionStream?.cancel();
    _positionStream = null;
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    if (!mounted) return;
    setState(() => _isRecording = false);

    final totalKm = await _store.addAndGetTotalKm(_recorder.distanceKm);
    widget.onSessionEnded?.call(totalKm);
  }

  String _formatDuration(Duration d) {
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else {
      return '${minutes}m ${seconds}s';
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _elapsedTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: SegmentedButton<ActivityMode>(
                segments: const [
                  ButtonSegment(
                    value: ActivityMode.walk,
                    label: Text('Marche'),
                    icon: Icon(Icons.directions_walk),
                  ),
                  ButtonSegment(
                    value: ActivityMode.bike,
                    label: Text('Vélo'),
                    icon: Icon(Icons.directions_bike),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (s) {
                  if (!_isRecording) {
                    setState(() => _mode = s.first);
                  }
                },
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Distance display
                  Text(
                    '${_recorder.distanceKm.toStringAsFixed(2)} km',
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  const SizedBox(height: 8),
                  // Duration display
                  Text(
                    _formatDuration(_elapsed),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 32),
                  // Start/Stop button
                  ElevatedButton(
                    onPressed: _isRecording ? _stopSession : _startSession,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 48,
                        vertical: 24,
                      ),
                    ),
                    child: Text(
                      _isRecording ? 'Terminer' : 'Démarrer',
                      style: const TextStyle(fontSize: 20),
                    ),
                  ),
                ],
              ),
            ),
            // UI note about keeping app open
            Padding(
              padding: const EdgeInsets.all(16),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.withAlpha(25),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'Gardez l\'app ouverte pendant la session (v1)',
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
