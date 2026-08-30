import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../trip/trip_controller.dart';
import '../valhalla/models.dart';

/// Shows the trip currently recording (started here or from the map's
/// one-tap "Démarrer" pill — both drive the same shared [TripController],
/// see trip_controller.dart) large, or a minimal start affordance when
/// idle. Kept deliberately thin: all trip lifecycle logic lives in
/// [TripController]/[SessionController].
class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key});

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  RoutingProfile _profile = RoutingProfile.walk;

  /// Local UI tick: TripController only notifies on start/stop, not per
  /// GPS fix (see trip_controller.dart), so the live distance/duration
  /// numbers are refreshed the same lightweight way map_screen.dart does.
  Timer? _ticker;

  static const String _kPositionUnavailableMessage =
      'Position indisponible — activez la localisation ou définissez un départ manuel.';

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    final trip = ref.read(tripControllerProvider);
    final started = await trip.startTrip(profile: _profile);
    if (!started && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text(_kPositionUnavailableMessage)));
    }
  }

  Future<void> _stop() async {
    await ref.read(tripControllerProvider).stopTrip();
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
  Widget build(BuildContext context) {
    final trip = ref.watch(tripControllerProvider);
    final session = trip.sessionController;
    final distance = session.recorder?.distanceKm ?? 0.0;
    final isRecording = trip.isRecording;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
              child: SegmentedButton<RoutingProfile>(
                segments: const [
                  ButtonSegment(
                    value: RoutingProfile.walk,
                    label: Text('Marche'),
                    icon: Icon(Icons.directions_walk),
                  ),
                  ButtonSegment(
                    value: RoutingProfile.bike,
                    label: Text('Vélo'),
                    icon: Icon(Icons.directions_bike),
                  ),
                ],
                selected: {_profile},
                onSelectionChanged: (s) {
                  if (!isRecording) {
                    setState(() => _profile = s.first);
                  }
                },
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isRecording && trip.isRouteBound)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('Trajet lié à l\'itinéraire',
                          style: textTheme.labelMedium),
                    ),
                  // Distance display — Bricolage Grotesque, "gros chiffres".
                  Text(
                    '${distance.toStringAsFixed(2)} km',
                    style: textTheme.displayMedium,
                  ),
                  const SizedBox(height: 8),
                  // Duration display.
                  Text(
                    _formatDuration(session.elapsed),
                    style: textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 32),
                  // Start/Stop button.
                  ElevatedButton(
                    onPressed: isRecording ? _stop : _start,
                    style: isRecording
                        ? ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(context).colorScheme.onSurface,
                            foregroundColor: Theme.of(context).colorScheme.surface,
                          )
                        : null,
                    child: Text(isRecording ? 'Terminer' : 'Démarrer'),
                  ),
                ],
              ),
            ),
            // UI note about keeping app open.
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'Gardez l\'app ouverte pendant la session (v1)',
                    style: textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
