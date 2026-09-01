import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../map/boot_preload.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import '../trip/trip_controller.dart';
import 'onboarding_store.dart';

/// Gate shown once, at first launch, before the map — task 2b brief item 2:
/// the owner's device-QA report was that permissions were only ever asked at
/// the first trip start, deep into the app, rather than up front.
///
/// Decisions pinned by the brief (item 2b), not re-litigated here:
///  * a refusal is never blocking — the flow below runs to completion and
///    [child] is shown regardless of its outcome, including
///    `TripPermissionOutcome.openedSettings` (no loop back to onboarding on
///    return from Android settings);
///  * the permission flow itself is [TripController.ensurePermissions] —
///    `TripPermissionCoordinator.ensureForTrip` — reused as-is, not
///    forked, so its ordering and ask-once memory (`PermissionMemory`) are
///    exactly what a trip start would use later;
///  * one sober screen, no carousel.
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({
    super.key,
    required this.onboarded,
    required this.child,
  });

  /// Read once, before `runApp` (see main.dart) — whether
  /// [kOnboardedPrefKey] was already set on a previous run.
  final bool onboarded;
  final Widget child;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate> {
  late bool _onboarded = widget.onboarded;
  bool _continuing = false;
  bool _preloadTriggered = false;

  @override
  void initState() {
    super.initState();
    // Already onboarded on a previous run: this boot's map preload (brief
    // item 3) starts immediately, since there is no flow left to wait for.
    if (_onboarded) _triggerPreloadOnce();
  }

  void _triggerPreloadOnce() {
    if (_preloadTriggered) return;
    _preloadTriggered = true;
    // Fire-and-forget on purpose — see `triggerBootCoveragePreload`'s own
    // doc comment for why it can never throw out of this call.
    unawaited(triggerBootCoveragePreload(ref));
  }

  Future<void> _continueFromOnboarding() async {
    if (_continuing) return;
    _continuing = true;
    try {
      await ref.read(tripControllerProvider).ensurePermissions();
    } catch (_) {
      // Non-blocking (brief item 2b): a refusal, or any failure in the
      // permission flow itself, must never strand the user here.
    }
    // Set only after the flow has run — not at build/mount time — so a kill
    // mid-onboarding shows onboarding again on the next launch (brief 2c).
    await markOnboarded();
    if (!mounted) return;
    setState(() => _onboarded = true);
    _triggerPreloadOnce();
  }

  @override
  Widget build(BuildContext context) => _onboarded
      ? widget.child
      : OnboardingScreen(onContinue: _continueFromOnboarding);
}

/// The one-screen, no-carousel onboarding content itself (brief item 2a/2b).
class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key, required this.onContinue});

  final Future<void> Function() onContinue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Center(
                child: WaymarkDiamond(
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'RandomWalk',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'RandomWalk mesure vos marches et dévoile la carte au fil de '
                'vos trajets, même écran éteint.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Pour ça, l\'app demande la localisation « tout le temps », '
                'le capteur de pas et les notifications — uniquement pour '
                'suivre vos trajets, rien n\'est partagé.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Vous pouvez refuser : l\'app reste utilisable, juste avec '
                'moins de suivi automatique.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => onContinue(),
                child: const Text('C\'est parti'),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }
}
