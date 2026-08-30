import 'dart:async';
import 'package:flutter/material.dart';
import 'recorder.dart';
import 'session_controller.dart';

enum ActivityMode { walk, bike }

class SessionScreen extends StatefulWidget {
  const SessionScreen({super.key, this.onSessionEnded});
  final void Function(double totalKm)? onSessionEnded;

  @override
  State<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends State<SessionScreen> {
  late final SessionController _controller;
  ActivityMode _mode = ActivityMode.walk;
  Duration _elapsed = Duration.zero;
  Timer? _elapsedTimer;

  static const String _kPositionUnavailableMessage =
      'Position indisponible — activez la localisation ou définissez un départ manuel.';

  @override
  void initState() {
    super.initState();
    _controller = SessionController(store: TotalDistanceStore());
  }

  Future<void> _startSession() async {
    final started = await _controller.start();
    if (!started) {
      // Permission denied or already starting.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text(_kPositionUnavailableMessage)));
      }
      return;
    }

    if (!mounted) return;
    setState(() {});

    _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _elapsed = _controller.elapsed;
        });
      }
    });
  }

  Future<void> _stopSession() async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    final totalKm = await _controller.stop();

    if (!mounted) return;
    setState(() => _elapsed = Duration.zero);

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
    _elapsedTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final distance = _controller.recorder?.distanceKm ?? 0.0;
    final isRecording = _controller.isRecording;

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
                  if (!isRecording) {
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
                    '${distance.toStringAsFixed(2)} km',
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
                    onPressed: isRecording ? _stopSession : _startSession,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 48,
                        vertical: 24,
                      ),
                    ),
                    child: Text(
                      isRecording ? 'Terminer' : 'Démarrer',
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
