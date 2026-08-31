/// Adaptive GPS for turn-by-turn navigation (Task 7 + owner brief): a
/// walker approaching a maneuver needs a tight `distanceFilter` so the last
/// few metres before a turn are not missed between fixes; the same
/// precision, kept up for the whole of a long straight leg, only spends
/// battery. Free (non-route-bound) sessions never call any of this — they
/// keep the constant 3 m filter [SessionController] has always used.
library;

/// Below this distance to the next maneuver, the tight filter applies.
const kNavCloseThresholdM = 500.0;

/// `distanceFilter`, in metres, while within [kNavCloseThresholdM] of the
/// next maneuver.
const kNavCloseDistanceFilterM = 3;

/// `distanceFilter`, in metres, while further from the next maneuver than
/// that — or before the first maneuver distance is known at all.
const kNavFarDistanceFilterM = 12;

/// The `LocationSettings.distanceFilter` navigation should be asking for
/// right now, given how far the walker is from the next maneuver.
///
/// A pure decision function — no clock, no stream, no platform channel — so
/// the 500 m threshold is a fact this file states once and everything else
/// (the rate limiter below, the handler that drives the actual
/// resubscription) can be tested against without a real GPS.
///
/// [distanceToManeuverM] is null before the first navigated fix has been
/// processed; that reads as "not yet known to be close", the same tight
/// filter [SessionController]'s default already uses, so a trip's very
/// first fixes are never coarser than they were before adaptive GPS
/// existed.
int adaptiveDistanceFilter(double? distanceToManeuverM) {
  if (distanceToManeuverM == null) return kNavCloseDistanceFilterM;
  return distanceToManeuverM < kNavCloseThresholdM
      ? kNavCloseDistanceFilterM
      : kNavFarDistanceFilterM;
}

/// Rate-limits how often adaptive GPS may resubscribe the location stream
/// with a new `distanceFilter`.
///
/// Swapping `LocationSettings` mid-trip means tearing down and reopening the
/// platform's location provider — not free, and not something a walker
/// pacing back and forth across the 500 m boundary should be allowed to
/// trigger every fix. Clock-driven (like `ThrottledSnapshotWriter`) rather
/// than `Timer`-driven, so it is testable without fake-async and behaves
/// identically inside the tracking isolate.
class AdaptiveGpsRateLimiter {
  final Duration minInterval;
  final DateTime Function() _clock;
  DateTime? _lastChangeAt;

  AdaptiveGpsRateLimiter({
    this.minInterval = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Whether a resubscribe from [currentFilter] to [desiredFilter] may
  /// happen now. False when there is nothing to change, or when a previous
  /// change (see [recordChange]) happened less than [minInterval] ago.
  ///
  /// Does not itself record anything: a caller that gets `true` back but
  /// then fails to actually resubscribe (or decides not to) must not have
  /// spent the budget on nothing.
  bool shouldResubscribe({
    required int currentFilter,
    required int desiredFilter,
  }) {
    if (currentFilter == desiredFilter) return false;
    final last = _lastChangeAt;
    if (last != null && _clock().difference(last) < minInterval) return false;
    return true;
  }

  /// Marks now as the moment a resubscribe actually happened, starting the
  /// next [minInterval] cooldown.
  void recordChange() => _lastChangeAt = _clock();
}
