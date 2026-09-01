import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../map/boot_preload.dart';
import '../theme/tokens.dart';
import '../theme/waymark_glyph.dart';
import '../tracking/permissions.dart';
import '../trip/trip_controller.dart';
import 'onboarding_store.dart';

/// The two screens [OnboardingGate] can show before handing off to
/// [OnboardingGate.child] — see [_OnboardingGateState.build].
enum _OnboardingStage {
  /// The one sober "C'est parti" screen (brief 2b item 2a/2b).
  intro,

  /// Task 2c: shown when the permission flow finished without "Autoriser
  /// tout le temps" — see [_OnboardingGateState._continueFromOnboarding].
  insistence,
}

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
///
/// Task 2c (direct owner request: "assure toi bien de la permission de
/// location tout le temps") adds a second, still-non-blocking screen: after
/// the flow above, [TripController.readTrackingMode] —
/// `TripPermissionCoordinator.currentTrackingMode`, the same re-check the
/// shell's own degraded-mode banner uses on resume (see main.dart's
/// `didChangeAppLifecycleState`) — is re-read fresh rather than trusting the
/// `TripPermissions.mode` the flow returned (that field is only meaningful
/// for `TripPermissionOutcome.ready`; every other outcome, notably
/// `openedSettings`, leaves it at its default). Anything short of
/// [TrackingMode.background] shows the insistence step instead of finishing
/// onboarding immediately.
class OnboardingGate extends ConsumerStatefulWidget {
  const OnboardingGate({
    super.key,
    required this.onboarded,
    required this.child,
    this.openSettings,
  });

  /// Read once, before `runApp` (see main.dart) — whether
  /// [kOnboardedPrefKey] was already set on a previous run.
  final bool onboarded;
  final Widget child;

  /// Task 2c: opens the Android app-settings screen from the insistence
  /// step's "Ouvrir les réglages" button. Defaults to
  /// [PluginPermissionService.openSettings] — the same call the existing
  /// degraded-mode banners use (main.dart) — injectable so tests can assert
  /// the tap without a real platform channel.
  final Future<void> Function()? openSettings;

  @override
  ConsumerState<OnboardingGate> createState() => _OnboardingGateState();
}

class _OnboardingGateState extends ConsumerState<OnboardingGate>
    with WidgetsBindingObserver {
  late bool _onboarded = widget.onboarded;
  _OnboardingStage _stage = _OnboardingStage.intro;
  bool _continuing = false;
  bool _preloadTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Already onboarded on a previous run: this boot's map preload (brief
    // item 3) starts immediately, since there is no flow left to wait for.
    if (_onboarded) _triggerPreloadOnce();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Task 2c: coming back from the Android settings screen the insistence
    // step sent the user to is the one moment "Autoriser tout le temps" can
    // have changed under us — same trigger, same reasoning as the shell's
    // own degraded-mode banner re-check (main.dart).
    if (state == AppLifecycleState.resumed &&
        _stage == _OnboardingStage.insistence) {
      unawaited(_recheckTrackingMode());
    }
  }

  void _triggerPreloadOnce() {
    if (_preloadTriggered) return;
    _preloadTriggered = true;
    // Fire-and-forget on purpose — see `triggerBootCoveragePreload`'s own
    // doc comment for why it can never throw out of this call.
    unawaited(triggerBootCoveragePreload(ref));
  }

  /// Fresh, non-prompting read of the background-location state — never the
  /// stale/default `TripPermissions.mode` (see the class doc comment).
  /// Fails open to [TrackingMode.background] on any error or when no reader
  /// is wired: task 2c's insistence step is an add-on, never a new way for
  /// onboarding to get stuck (brief item 2b's "never blocking" still holds).
  Future<TrackingMode> _readCurrentTrackingMode() async {
    final read = ref.read(tripControllerProvider).readTrackingMode;
    if (read == null) return TrackingMode.background;
    try {
      return await read();
    } catch (_) {
      return TrackingMode.background;
    }
  }

  Future<void> _recheckTrackingMode() async {
    // Guards against racing the initial flow's own re-check below.
    if (_continuing) return;
    final mode = await _readCurrentTrackingMode();
    if (!mounted || _stage != _OnboardingStage.insistence) return;
    if (mode == TrackingMode.background) await _finishOnboarding();
    // Otherwise: stay on the insistence step. The user can tap "Ouvrir les
    // réglages" again or "Continuer sans" — never a loop back to the intro
    // screen, never re-prompted automatically (brief item 2, Play-compliant).
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
    _continuing = false;
    if (!mounted) return;

    final mode = await _readCurrentTrackingMode();
    if (!mounted) return;
    if (mode == TrackingMode.background) {
      await _finishOnboarding();
    } else {
      // Task 2c: background location was not granted — insist once, gently,
      // before letting the map through.
      setState(() => _stage = _OnboardingStage.insistence);
    }
  }

  Future<void> _openSettingsFromInsistence() async {
    final open = widget.openSettings ?? PluginPermissionService().openSettings;
    try {
      await open();
    } catch (_) {
      // Best-effort — the insistence step itself is the fallback if this
      // never opens anything.
    }
  }

  /// Sets [kOnboardedPrefKey] and shows [widget.child] — the only path that
  /// does either, reached from the intro screen when background location is
  /// already granted, from the insistence step's "Continuer sans", and from
  /// the lifecycle re-check once the user grants it in settings.
  ///
  /// Set only after the flow has run — not at build/mount time — so a kill
  /// mid-onboarding shows onboarding again on the next launch (brief 2c).
  Future<void> _finishOnboarding() async {
    if (_onboarded) return;
    await markOnboarded();
    if (!mounted) return;
    setState(() => _onboarded = true);
    _triggerPreloadOnce();
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarded) return widget.child;
    return switch (_stage) {
      _OnboardingStage.intro => OnboardingScreen(
        onContinue: _continueFromOnboarding,
      ),
      _OnboardingStage.insistence => BackgroundLocationInsistenceScreen(
        onOpenSettings: _openSettingsFromInsistence,
        onContinueWithout: _finishOnboarding,
      ),
    };
  }
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

/// Task 2c: shown when the onboarding permission flow finished without
/// "Autoriser tout le temps" (refused outright, or `openedSettings` came
/// back without it — see [OnboardingGate]'s class doc comment). Never
/// blocking (brief item 2): "Continuer sans" is always reachable, and the
/// screen never re-appears once onboarding has finished (a later trip start
/// falls back to today's in-trip banner/rationale flow, unchanged by this
/// task).
class BackgroundLocationInsistenceScreen extends StatefulWidget {
  const BackgroundLocationInsistenceScreen({
    super.key,
    required this.onOpenSettings,
    required this.onContinueWithout,
  });

  final Future<void> Function() onOpenSettings;
  final Future<void> Function() onContinueWithout;

  @override
  State<BackgroundLocationInsistenceScreen> createState() =>
      _BackgroundLocationInsistenceScreenState();
}

class _BackgroundLocationInsistenceScreenState
    extends State<BackgroundLocationInsistenceScreen> {
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
                child: Icon(
                  Icons.my_location,
                  size: 64,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text(
                'Un dernier réglage pour un suivi fiable',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpacing.md),
              Text(
                'Sans « Autoriser tout le temps », Android coupe le suivi '
                'dès que l\'écran s\'éteint ou que l\'app est fermée — le '
                'trajet peut s\'arrêter en plein milieu.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Ouvrez les réglages et choisissez « Autoriser tout le '
                'temps » pour que l\'itinéraire continue écran éteint.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : () => _run(widget.onOpenSettings),
                child: const Text('Ouvrir les réglages'),
              ),
              const SizedBox(height: AppSpacing.sm),
              TextButton(
                onPressed: _busy ? null : () => _run(widget.onContinueWithout),
                child: const Text('Continuer sans'),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }
}
