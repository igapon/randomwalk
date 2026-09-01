import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../nav/guidance_text.dart';
import '../theme/tokens.dart';
import '../tracking/permissions.dart';
import '../trip/gated_ticker.dart';
import '../trip/trip_controller.dart';
import '../trip/trip_messages.dart';
import '../valhalla/models.dart';

/// Shows the trip currently recording (started here or from the map's
/// one-tap "Démarrer" pill — both drive the same shared [TripController],
/// see trip_controller.dart) large, or a minimal start affordance when
/// idle. Kept deliberately thin: all trip lifecycle logic lives in
/// [TripController] and, while recording, in the foreground service.
class SessionScreen extends ConsumerStatefulWidget {
  const SessionScreen({super.key});

  @override
  ConsumerState<SessionScreen> createState() => _SessionScreenState();
}

class _SessionScreenState extends ConsumerState<SessionScreen> {
  /// Local UI tick, gated to only run while recording (see [GatedTicker]).
  /// The service publishes a snapshot every couple of seconds, but the
  /// duration has to advance every second — and the tick is also where the
  /// hardware step counter is sampled (see [TripController.tick]).
  late final _ticker = GatedTicker(
    onTick: () {
      if (!mounted) return;
      ref.read(tripControllerProvider).tick();
      setState(() {});
    },
  );

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final trip = ref.read(tripControllerProvider);
    if (!await trip.startTrip(profile: trip.profile) && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(startFailureMessage(trip.lastStartFailure))),
      );
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
    _ticker.sync(trip.isRecording);
    final isRecording = trip.isRecording;
    final textTheme = Theme.of(context).textTheme;
    final snapshot = trip.snapshot;
    final navigating = isRecording && trip.isRouteBound;
    final arrived = navigating && (snapshot?.navArrived ?? false);
    final offRoute = navigating && !arrived && (snapshot?.navOffRoute ?? false);
    final remainingKm = navigating ? snapshot?.navRemainingKm : null;
    final etaSeconds = snapshot?.navEtaSeconds;
    final remainingLabel = remainingKm == null
        ? null
        : formatRemaining(
            remainingKm,
            etaSeconds == null ? null : Duration(seconds: etaSeconds),
          );

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
                selected: {trip.profile},
                onSelectionChanged: isRecording
                    ? null
                    : (s) => trip.setProfile(s.first),
              ),
            ),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (navigating) ...[
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Trajet lié à l\'itinéraire',
                        style: textTheme.labelMedium,
                      ),
                    ),
                    // Review ruling: arrived wins over off-route.
                    if (arrived)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          kNavArrivedLabel,
                          style: textTheme.headlineSmall,
                        ),
                      )
                    else if (offRoute)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          kNavRecalculatingLabel,
                          style: textTheme.titleMedium?.copyWith(
                            color: AppColors.recalcOrange,
                          ),
                        ),
                      )
                    else if (snapshot?.navInstruction != null &&
                        snapshot!.navInstruction!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          snapshot.navInstruction!,
                          textAlign: TextAlign.center,
                          style: textTheme.titleMedium,
                        ),
                      ),
                    if (remainingLabel != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          remainingLabel,
                          style: textTheme.titleMedium,
                        ),
                      ),
                  ],
                  // Distance display — Bricolage Grotesque, "gros chiffres".
                  Text(
                    '${trip.distanceKm.toStringAsFixed(2)} km',
                    style: textTheme.displayMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _formatDuration(trip.elapsed),
                    style: textTheme.headlineSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  // Hidden rather than shown as a permanent zero when the
                  // step sensor is unavailable (permission refused, or no
                  // hardware counter).
                  if (trip.stepsAvailable)
                    Text('${trip.steps} pas', style: textTheme.titleMedium),
                  if (trip.needsReview)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.xs),
                      child: Text(
                        'À vérifier — distance sans pas détectés',
                        style: textTheme.labelSmall,
                      ),
                    ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    onPressed: isRecording ? _stop : _start,
                    // Arrived puts Terminer forward as the theme's default
                    // primary (yellow) button instead of recording's plain
                    // ink/paper one — brief: "bouton Terminer mis en avant".
                    style: isRecording && !arrived
                        ? ElevatedButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.onSurface,
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.surface,
                          )
                        : null,
                    child: Text(isRecording ? 'Terminer' : 'Démarrer'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    trip.isRecording &&
                            trip.trackingMode == TrackingMode.foregroundOnly
                        ? 'Le suivi s\'arrêtera si l\'écran s\'éteint.'
                        : 'Le trajet continue écran éteint, même si vous '
                              'quittez l\'application.',
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
