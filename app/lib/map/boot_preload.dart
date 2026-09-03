import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart' as geo;
import 'package:shared_preferences/shared_preferences.dart';

import '../trip/trip_controller.dart';
import 'route_controller.dart' show coverageRepositoryProvider;

/// Pure trigger logic for task 2b brief item 3 — "download the map tiles
/// right away" at boot, instead of waiting for the first route plan (the
/// owner's device-QA complaint: coverage used to be fetched only from
/// `RoutePlanner`/`LoopPlanOrchestrator`, both reached only once a walker
/// tapped a planning action).
///
/// Deliberately free of Riverpod, Geolocator and SharedPreferences — like
/// [RoutePlanner]/`TripPermissionCoordinator`, the orchestration is a plain
/// class taking interfaces as closures, so it is unit-testable with fakes
/// (see `boot_preload_test.dart`). The real platform-backed wiring is
/// [triggerBootCoveragePreload] below, called once from `main()`, and is not
/// itself unit-tested — same "thin glue, trust the pure core" split as
/// `PluginPermissionService`/`ChannelRoutingEngine`.
class BootCoveragePreloader {
  /// A cheap, no-permission-prompt read (`Geolocator.getLastKnownPosition`).
  final Future<(double, double)?> Function() getLastKnownPosition;

  /// Falls back to a live fix when there is no last-known position. Must
  /// itself apply a reasonable timeout and never throw — brief item 3a
  /// ("~10 s, sinon abandonner silencieusement"); see the real
  /// implementation's own doc comment below for why the timeout lives there
  /// rather than being layered on here.
  final Future<(double, double)?> Function() getCurrentPosition;

  final Future<void> Function(
    double lat,
    double lon, {
    void Function(int done, int total)? onProgress,
  })
  ensureCoverage;

  /// True while a restored trip (recording *or* interrupted — either one is
  /// "active" from the walker's point of view) is on screen. Brief item 3d:
  /// this boot must skip preloading entirely rather than compete for
  /// bandwidth/CPU with a restored navigation.
  final bool Function() isTripActive;

  final Future<DateTime?> Function() lastRunAt;
  final Future<void> Function(DateTime now) markRanAt;
  final DateTime Function() clock;

  /// Brief item 3a's own escape hatch: `CoverageRepository.ensureCoverage`
  /// re-fetches the manifest over the network on *every* call (see its own
  /// doc comment) even when every tile the walker needs is already on disk,
  /// so an unconditional once-per-boot call would still cost one network
  /// round trip on every single app open. Capped at once per [guardInterval]
  /// instead — documented decision (brief leaves this to the implementer):
  /// tile downloads themselves stay idempotent/free regardless of this guard
  /// (an existsSync check per wanted tile), so the guard only bounds the
  /// manifest fetch's own traffic, not correctness.
  final Duration guardInterval;

  BootCoveragePreloader({
    required this.getLastKnownPosition,
    required this.getCurrentPosition,
    required this.ensureCoverage,
    required this.isTripActive,
    required this.lastRunAt,
    required this.markRanAt,
    DateTime Function()? clock,
    this.guardInterval = const Duration(hours: 24),
  }) : clock = clock ?? DateTime.now;

  Future<void> maybeRun({
    void Function(int done, int total)? onProgress,
  }) async {
    if (isTripActive()) return;
    final last = await lastRunAt();
    if (last != null && clock().difference(last) < guardInterval) return;
    final position = await _resolvePosition();
    if (position == null) return;
    try {
      await ensureCoverage(position.$1, position.$2, onProgress: onProgress);
    } catch (_) {
      // Brief item 3c: offline/server failures are silent here — planning
      // retries coverage itself the moment the walker actually asks for a
      // route, exactly as it does today.
      return;
    }
    await markRanAt(clock());
  }

  Future<(double, double)?> _resolvePosition() async {
    try {
      final last = await getLastKnownPosition();
      if (last != null) return last;
    } catch (_) {
      // Fall through to a live fix.
    }
    try {
      return await getCurrentPosition();
    } catch (_) {
      return null;
    }
  }
}

/// Progress of the boot-time preload while it is actually downloading, or
/// `null` the rest of the time — read by `BootPreloadBanner` (main.dart) for
/// the discreet "téléchargement des cartes" banner (brief item 3b).
///
/// Deliberately its own provider, not `route_controller.dart`'s
/// `ProgressSink`: that slot is scoped to one in-flight *planning* request
/// (`_planRoute`/`_proposeCandidates` in map_screen.dart both clear it in
/// their own `finally`), which is not this call's lifetime and would race it
/// for the same slot.
final bootPreloadProgressProvider = StateProvider<({int done, int total})?>(
  (ref) => null,
);

const _kLastRunPrefKey = 'boot_preload_last_run_ms';

/// Real wiring for [BootCoveragePreloader]: Geolocator for position,
/// [coverageRepositoryProvider] for the download, SharedPreferences for the
/// 24h guard.
///
/// Called once, from [OnboardingGate] (`onboarding/onboarding_screen.dart`)
/// the moment it first shows the map — whether that is immediately (already
/// onboarded) or right after the onboarding flow completes — which is what
/// gives "at every boot, after onboarding if there is one" (brief item 3a)
/// without racing the onboarding permission prompts.
///
/// Wrapped entirely in try/catch: this is fire-and-forget best-effort
/// background work and must never surface as an unhandled zone error, in
/// production or in a widget test that happens to pump this path with none
/// of Geolocator/SharedPreferences/path_provider mocked.
Future<void> triggerBootCoveragePreload(WidgetRef ref) async {
  try {
    final trip = ref.read(tripControllerProvider);
    final coverage = await ref.read(coverageRepositoryProvider.future);
    final prefs = await SharedPreferences.getInstance();
    final preloader = BootCoveragePreloader(
      getLastKnownPosition: () async {
        final pos = await geo.Geolocator.getLastKnownPosition();
        return pos == null ? null : (pos.latitude, pos.longitude);
      },
      getCurrentPosition: _currentPositionWithTimeout,
      ensureCoverage: (lat, lon, {onProgress}) =>
          coverage.ensureCoverage(lat, lon, onProgress: onProgress),
      isTripActive: () => trip.state != TripState.idle,
      lastRunAt: () async {
        final ms = prefs.getInt(_kLastRunPrefKey);
        return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
      },
      markRanAt: (now) =>
          prefs.setInt(_kLastRunPrefKey, now.millisecondsSinceEpoch),
    );
    await preloader.maybeRun(
      onProgress: (done, total) {
        ref.read(bootPreloadProgressProvider.notifier).state = (
          done: done,
          total: total,
        );
      },
    );
  } catch (_) {
    // Silent — brief item 3c applies just as much to a resolution failure
    // (no position, coverage provider unavailable, prefs unreachable) as to
    // a download failure.
  } finally {
    ref.read(bootPreloadProgressProvider.notifier).state = null;
  }
}

/// No permission *request* here on purpose: task 2b's onboarding screen
/// (item 2) is now the one place that asks, at first launch; a silent
/// background preload prompting the user out of nowhere on some later boot
/// would undercut that. A permission already refused (or not yet granted)
/// simply yields `null` here, same as no position at all — brief item 3a's
/// "abandonner silencieusement".
///
/// Races a live fix against [timeout] via `Future.any` with an injectable
/// [wait], the same pattern `initial_camera.dart`'s
/// `resolveInitialCameraCenter` uses and documents: a raw `Future.timeout()`
/// races flutter_test's virtual clock once anything pulling in the
/// automated test binding is in play, which main.dart (via map_screen.dart's
/// `maplibre_gl` import) is.
Future<(double, double)?> _currentPositionWithTimeout({
  Duration timeout = const Duration(seconds: 10),
  Future<void> Function(Duration duration)? wait,
}) async {
  try {
    if (!await geo.Geolocator.isLocationServiceEnabled()) return null;
    final permission = await geo.Geolocator.checkPermission();
    if (permission != geo.LocationPermission.always &&
        permission != geo.LocationPermission.whileInUse) {
      return null;
    }
    final position = geo.Geolocator.getCurrentPosition()
        .then<(double, double)?>(
          (p) => (p.latitude, p.longitude),
          onError: (_) => null,
        );
    final timedOut = (wait ?? Future.delayed)(timeout).then((_) => null);
    return await Future.any([position, timedOut]);
  } catch (_) {
    return null;
  }
}
