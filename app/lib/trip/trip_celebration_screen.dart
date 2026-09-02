import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../history/history_format.dart';
import '../history/trip_history_detail_screen.dart' show TripHistoryStats;
import '../history/trip_history_store.dart';
import '../theme/tokens.dart';
import 'trip_controller.dart';

/// Task 2g (owner brief, « il faut finir automatiquement et arrêter, avec un
/// écran encourageant de félicitations et des xp! »): the post-trip
/// congratulations screen — shown the instant a guided (route-bound) trip
/// finalises having latched arrival, whether that happened via the
/// auto-finish (`TripTaskHandler._autoFinishOnArrival`) or a manual
/// « Terminer » tapped after quietly arriving (`TripController._finalise`
/// fires the same `onTripCelebration`/pending-celebration-marker pair
/// either way — see their own doc comments). Also reachable at the NEXT app
/// open when the trip finalised while nothing was watching live
/// (backgrounded, or the whole app process killed — the foreground service
/// survives both, `tracking_service.dart`'s `stopWithTask: false`).
///
/// [startedAt] is the trip's identity (see `FinalisedTripMemory`'s own doc
/// comment on why that is the natural identity in this codebase);
/// [celebration] carries whatever `TripController` already knew — distance/
/// duration/speed, see `FinishedTripCelebration`'s own doc comment — so the
/// screen has something to show immediately. Fix round 1 (Important 5): the
/// deferred (next-open) path supplies this too now, not just the live one —
/// `TripController.takePendingCelebration()` rebuilds it from the stats
/// `FinalisedTripMemory` now persists alongside the pending-celebration
/// marker. `celebration` stays nullable purely as a defensive fallback (a
/// caller with truly nothing synchronous can still pass `null`); in
/// practice every production caller supplies one, so only the combined XP
/// figure below is ever left for [_resolve] to fill in.
///
/// The combined XP figure (exploration + landmark-visit — see
/// `history/trip_history_recorder.dart`'s "Task 2g update" doc comment) is
/// never known synchronously: it depends on `processTripExploration`
/// actually finishing, which is fire-and-forget by design and must stay
/// that way (`TripController._finalise`'s own doc comment on why that hook
/// is never awaited). This screen polls `TripHistoryStore` for the matching
/// row instead of blocking on it — bounded (see [resolveCelebrationEntry]),
/// never an indefinite spinner — since the on-device pipeline it is waiting
/// on is documented (task-2f-report.md) as consistently sub-second.
///
/// **Not widget-tested itself** — same "cannot be widget-tested" situation
/// `TripHistoryDetailScreen`/`AdventureScreen`/`MapScreen` already document,
/// for a different underlying cause: combining this class's real
/// `TripHistoryStore` (sqflite) I/O with `flutter_test`'s fake-async pump
/// zone reliably hung the test runner on this environment rather than
/// merely running slowly. [resolveCelebrationEntry] (the actual polling
/// logic, with the store call and the delay both injected) and
/// [CelebrationStats] (the pure stats card) are extracted specifically so
/// each is fully unit/widget-testable on its own — see
/// `trip_celebration_screen_test.dart`.
class TripCelebrationScreen extends ConsumerStatefulWidget {
  const TripCelebrationScreen({
    super.key,
    required this.startedAt,
    this.celebration,
  });

  final DateTime startedAt;
  final FinishedTripCelebration? celebration;

  @override
  ConsumerState<TripCelebrationScreen> createState() =>
      _TripCelebrationScreenState();
}

class _TripCelebrationScreenState extends ConsumerState<TripCelebrationScreen> {
  TripHistoryEntry? _entry;
  bool _gaveUp = false;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  /// Fix round 1 (Important 1): the WHOLE body is wrapped in try/catch —
  /// `ref.read(tripHistoryStoreProvider.future)` can throw (`main.dart`
  /// itself documents `TripHistoryStore.open` failing as a real
  /// possibility), and that call sits OUTSIDE `resolveCelebrationEntry`'s
  /// own try/catch (it only guards `fetchLatest`, called once the store
  /// already exists). Before this fix, that throw escaped the `unawaited(
  /// _resolve())` in [initState] as an unhandled async error and `setState`
  /// never ran — `_gaveUp` stayed `false` forever, so the deferred path
  /// spun on [CircularProgressIndicator] indefinitely and the live path
  /// showed XP as `···` indefinitely. Moving the store resolution INSIDE
  /// the `fetchLatest` closure handed to [resolveCelebrationEntry] means a
  /// transient store failure is retried like any other "not yet written"
  /// case; this outer try/catch is the backstop for a PERSISTENT one (or
  /// any other unexpected throw), so this method can never leave [_gaveUp]
  /// stuck at `false`.
  Future<void> _resolve() async {
    try {
      final entry = await resolveCelebrationEntry(
        fetchLatest: () async {
          final store = await ref.read(tripHistoryStoreProvider.future);
          return store.latest();
        },
        startedAt: widget.startedAt,
      );
      if (!mounted) return;
      setState(() {
        if (entry != null) {
          _entry = entry;
        } else {
          _gaveUp = true;
        }
      });
    } catch (_) {
      if (mounted) setState(() => _gaveUp = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final celebration = widget.celebration;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: Column(
            children: [
              const Spacer(),
              _Badge(theme: theme),
              const SizedBox(height: AppSpacing.lg),
              Text(
                _headline(celebration),
                style: theme.textTheme.headlineMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Encore une belle sortie balisée.',
                style: theme.textTheme.bodyLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              CelebrationStats(
                entry: _entry,
                celebration: celebration,
                gaveUp: _gaveUp,
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  // A single button back to the map at rest (brief: "bouton
                  // unique « Continuer » → carte") — this screen is always
                  // reached by a push (live: right after finalisation;
                  // deferred: at the next app open), so popping it is
                  // exactly that.
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Continuer'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _headline(FinishedTripCelebration? c) => c != null && c.isLoop
      ? 'Bravo, boucle terminée !'
      : 'Bravo, vous êtes arrivé(e) !';
}

/// The polling logic behind [TripCelebrationScreen]'s wait for the matching
/// `TripHistoryEntry` — extracted as a pure function, [fetchLatest] and
/// [delay] both injected, so it is unit-testable with a fake store and no
/// real wall-clock wait at all (see this file's own doc comment on why the
/// screen itself is not tested this way).
///
/// Polls [fetchLatest] up to [maxPolls] times, [pollInterval] apart, and
/// returns the first result whose `startedAt` matches [startedAt] — or
/// `null` once [maxPolls] is exhausted with nothing matching. A throwing
/// [fetchLatest] is treated exactly like "not yet written": retried on the
/// next attempt, never surfaced to the caller.
///
/// The trip this screen is celebrating is, by construction, the only one
/// that can possibly be recording at a time (`TripController` refuses a
/// second `startTrip()` while one is already under way), so "the latest
/// row" and "this trip's row" coincide unless the walker starts and
/// finishes an entirely new trip before this ever resolves — an edge case
/// accepted the same way `task-2f-report.md` already documents
/// `TripHistoryStore.latest()`'s own timing tradeoff.
///
/// [maxPolls] × [pollInterval] defaults to 10 × 200 ms = 2 s — comfortably
/// above the "consistently sub-second" figure `task-2f-report.md` documents
/// for the on-device exploration pipeline this is waiting on, without ever
/// spinning indefinitely if something upstream is genuinely broken (the
/// game layer disabled, a wedged store, ...).
Future<TripHistoryEntry?> resolveCelebrationEntry({
  required Future<TripHistoryEntry?> Function() fetchLatest,
  required DateTime startedAt,
  int maxPolls = 10,
  Duration pollInterval = const Duration(milliseconds: 200),
  Future<void> Function(Duration duration)? delay,
}) async {
  final sleep = delay ?? Future<void>.delayed;
  for (var i = 0; i < maxPolls; i++) {
    try {
      final latest = await fetchLatest();
      if (latest != null && latest.startedAt.toUtc() == startedAt.toUtc()) {
        return latest;
      }
      // Best-effort like every other local-store read in this app: a
      // store failure here just means another attempt, exactly like "not
      // yet written" — never a thrown error out of this function.
    } catch (_) {
      // See the doc comment above.
    }
    await sleep(pollInterval);
  }
  return null;
}

/// The trophy/waymark accent — a pale yellow disc (never a saturated one
/// with anything drawn on top of it in white, per the balisage brief's
/// "jamais de blanc sur jaune") behind an ink/paper icon, both colors
/// already guaranteed to contrast by `AppTheme` (`onPrimaryContainer`).
class _Badge extends StatelessWidget {
  const _Badge({required this.theme});
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => Container(
    width: 96,
    height: 96,
    decoration: BoxDecoration(
      color: theme.colorScheme.primaryContainer,
      shape: BoxShape.circle,
    ),
    child: Icon(
      Icons.emoji_events,
      size: 48,
      color: theme.colorScheme.onPrimaryContainer,
    ),
  );
}

/// The stats card: [TripHistoryStats] once the matching history row has
/// resolved (distance/durée/vitesse moy./XP — the combined total, see this
/// file's own doc comment), a lighter card built straight from
/// [celebration] while still waiting (XP shown as pending, never guessed),
/// and a graceful, data-free fallback if [gaveUp] with nothing synchronous
/// to fall back on either (the game layer disabled entirely, so no history
/// row will ever be written for this trip).
///
/// Public (unlike [_Badge]/[_Card]/[_Stat]) specifically so it is directly
/// widget-testable, pure and synchronous, without going through
/// [TripCelebrationScreen]'s own real-store polling — see this file's own
/// doc comment on why that container is not tested that way.
class CelebrationStats extends StatelessWidget {
  const CelebrationStats({
    super.key,
    required this.entry,
    required this.celebration,
    required this.gaveUp,
  });

  final TripHistoryEntry? entry;
  final FinishedTripCelebration? celebration;
  final bool gaveUp;

  @override
  Widget build(BuildContext context) {
    final resolved = entry;
    if (resolved != null) return TripHistoryStats(entry: resolved);

    final known = celebration;
    if (known == null) {
      return _Card(
        child: gaveUp
            ? Text(
                'Trajet enregistré.',
                style: Theme.of(context).textTheme.bodyMedium,
              )
            : const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
      );
    }

    final theme = Theme.of(context);
    return _Card(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _Stat(label: 'Distance', value: formatTripDistance(known.distanceKm)),
          _Stat(label: 'Durée', value: formatTripDuration(known.duration)),
          _Stat(
            label: 'Vitesse moy.',
            value: formatTripSpeed(known.avgSpeedKmh),
          ),
          _Stat(
            label: 'XP',
            value: gaveUp ? '—' : '···',
            valueStyle: gaveUp
                ? null
                : theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      elevation: 2,
      borderRadius: BorderRadius.circular(AppRadii.card),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: child,
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value, this.valueStyle});
  final String label;
  final String value;
  final TextStyle? valueStyle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        Text(value, style: valueStyle ?? theme.textTheme.labelLarge),
      ],
    );
  }
}
