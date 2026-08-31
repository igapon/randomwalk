/// Loop / A-to-B route planning: turns a target distance into a handful of
/// scored, routable candidates.
///
/// The planner is pure Dart and deliberately knows nothing about how routes
/// are actually computed: the routing call is injected as
/// [LoopRouter] (wired to the real engine's `routeMulti` by the caller), so
/// the whole search is unit-testable against a synthetic router.
///
/// Search shape (see the M3 brief — this is the binding algorithm):
///   * 3 intermediate waypoints per candidate, 3 candidates per request.
///   * Loop: waypoints sit on a circle centred on the start; the free
///     parameter is the circle radius, seeded at `targetM / (2*pi)` (the
///     radius whose circumference equals the target).
///   * A→B: waypoints sit on a half-sine bulge between start and end; the
///     free parameter is the bulge height ("detour"), seeded from the
///     surplus the user asked for beyond the direct distance.
///   * That parameter is then bisected against the distance the router
///     actually reports, with a hard budget of
///     [LoopPlanner.maxRouterCallsPerCandidate] router calls per candidate.
///   * Surviving candidates are scored, sorted, and near-duplicates are
///     collapsed — so a plan can come back with fewer than three offers.
///
/// "Not found" is never an exception: a request the router cannot satisfy
/// comes back as an empty candidate list (or as candidates with
/// `targetMet == false`), so the UI can show the real gap instead of an
/// error.
library;

import 'dart:math' as math;

import 'package:randomwalk/loop/geo_offsets.dart';
import 'package:randomwalk/loop/repeated_segments.dart';
import 'package:randomwalk/nav/polyline_math.dart';
import 'package:randomwalk/valhalla/models.dart';

/// Routes through an ordered list of (lat, lon) locations, or returns null
/// when no route exists (the planner treats null as "this geometry is not
/// routable", never as an error).
typedef LoopRouter = Future<RouteResult?> Function(
    List<(double, double)> locations);

enum PlanKind {
  /// Closed loop starting and ending at [LoopRequest.start].
  loop,

  /// Open route from [LoopRequest.start] to [LoopRequest.end], padded out to
  /// the target distance with a detour.
  toDestination,
}

class LoopRequest {
  final PlanKind kind;
  final (double, double) start;

  /// Destination — required for [PlanKind.toDestination], ignored (and
  /// normally null) for [PlanKind.loop].
  final (double, double)? end;
  final double targetKm;
  final RoutingProfile profile;

  /// Seed for candidate diversification. The same seed always yields the
  /// same candidates for the same request (see [LoopPlanner]'s `rng`).
  final int seed;

  LoopRequest({
    required this.kind,
    required this.start,
    this.end,
    required this.targetKm,
    required this.profile,
    required this.seed,
  }) {
    // ArgumentError rather than assert: both invariants must also hold in
    // release builds, where the whole search would otherwise divide by zero
    // (targetKm) or dereference null (end).
    if (targetKm <= 0) {
      throw ArgumentError.value(targetKm, 'targetKm', 'must be positive');
    }
    if (kind == PlanKind.toDestination && end == null) {
      throw ArgumentError.notNull('end');
    }
  }
}

class LoopCandidate {
  final RouteResult route;

  /// Signed relative distance error: `(measuredKm - targetKm) / targetKm`.
  /// Negative means the route is shorter than asked for.
  final double gapRatio;

  /// Fraction of the route that retraces itself, per
  /// [repeatedSegmentRatio] (0 = never repeats, 1 = pure out-and-back).
  final double repeatedRatio;

  /// Lower is better. See [LoopPlanner.scoreOf].
  final double score;

  const LoopCandidate({
    required this.route,
    required this.gapRatio,
    required this.repeatedRatio,
    required this.score,
  });
}

class LoopPlanResult {
  /// Candidates sorted by ascending [LoopCandidate.score] (best first).
  ///
  /// May hold *fewer* than [LoopPlanner.candidateCount] entries: near
  /// duplicates are collapsed (see [LoopPlanner.plan]), and candidates the
  /// router refused are simply absent. Empty only when the router refused
  /// every geometry we tried.
  final List<LoopCandidate> candidates;

  /// True when the candidate the UI shows first — `candidates.first` — is
  /// within [LoopPlanner.targetTolerance] of the target.
  ///
  /// Deliberately *not* "some candidate is on target": the best-scoring
  /// candidate can be a slightly-off-distance route that avoids retracing
  /// itself, and claiming "target met" while showing that route would lie
  /// about the number the user actually sees. When this is false the UI
  /// shows the real gap, and [bestGapRatio] says how close any candidate
  /// got.
  final bool targetMet;

  /// Smallest |[LoopCandidate.gapRatio]| across [candidates] — a magnitude,
  /// so always >= 0 — or null when there are none. Display-only: lets the UI
  /// say "closest we found: 8.4 km" even when the top-scored candidate is not
  /// the closest one.
  final double? bestGapRatio;

  const LoopPlanResult({
    required this.candidates,
    required this.targetMet,
    required this.bestGapRatio,
  });
}

class LoopPlanner {
  /// Intermediate waypoints per candidate (excluding start/end).
  static const int waypointCount = 3;

  /// Candidates generated per request.
  static const int candidateCount = 3;

  /// Hard router budget per candidate, counting *every* call: bisections,
  /// expansions and post-failure retries alike.
  static const int maxRouterCallsPerCandidate = 4;

  /// Consecutive routing failures that abandon a candidate. At 2, a
  /// candidate gets exactly *one* shrink-and-retry: the first failure shrinks
  /// the geometry and retries, and a second failure in a row gives up.
  static const int maxConsecutiveFailures = 2;

  /// A routing failure means "too big to fit on the local network here", so
  /// the search parameter is shrunk by this factor before the single retry.
  static const double failureShrinkFactor = 0.7;

  /// Growth factor used while the bracket has no upper bound yet.
  static const double expansionFactor = 1.5;

  /// |gapRatio| at or below which a candidate counts as on-target.
  static const double targetTolerance = 0.10;

  /// Two candidates whose distances differ by less than this fraction *and*
  /// whose [LoopCandidate.repeatedRatio] differ by less than
  /// [dedupRepeatedTolerance] are the same offer as far as the user is
  /// concerned; only the better-scored one is returned.
  static const double dedupDistanceTolerance = 0.02;
  static const double dedupRepeatedTolerance = 0.05;

  /// `repeatedSegmentRatio`'s grid cell, in metres, is scaled to the target
  /// distance: a fixed 25 m cell makes every sub-kilometre loop look like an
  /// out-and-back, because consecutive polyline points land in the same
  /// cell. One fortieth of the target (≈ the spacing of a 40-point route),
  /// clamped to this range.
  static const double minRepeatedCellM = 5.0;
  static const double maxRepeatedCellM = 25.0;

  final LoopRouter router;
  final math.Random Function(int seed) _rng;

  /// [rng] exists so tests can pin the candidate diversification; the
  /// default is a *seeded* `Random`. The planner never draws from an
  /// unseeded generator, which is what makes [LoopRequest.seed] reproduce a
  /// plan exactly.
  LoopPlanner({required this.router, math.Random Function(int seed)? rng})
      : _rng = rng ?? math.Random.new;

  /// Candidate score, lower is better: distance accuracy dominates, with
  /// self-overlap as the tie-breaker. A→B leans harder on accuracy because
  /// an out-and-back tail is often unavoidable when padding a fixed
  /// origin/destination pair.
  static double scoreOf(PlanKind kind, double gapRatio, double repeatedRatio) =>
      kind == PlanKind.loop
          ? 0.6 * gapRatio.abs() + 0.4 * repeatedRatio
          : 0.7 * gapRatio.abs() + 0.3 * repeatedRatio;

  Future<LoopPlanResult> plan(LoopRequest request) async {
    final routes = <RouteResult>[];

    if (request.kind == PlanKind.toDestination && _surplusM(request) <= 0) {
      // The destination is already at (or beyond) the target distance:
      // padding it out would be absurd, so the only sensible candidate is
      // the direct route. Its gap is reported as-is and targetMet follows.
      final direct = await router([request.start, request.end!]);
      if (direct != null) routes.add(direct);
    } else {
      for (var index = 0; index < candidateCount; index++) {
        final best = await _searchCandidate(request, index);
        if (best != null) routes.add(best);
      }
    }

    final candidates =
        _dedup(_scoreAndSort(request.kind, request.targetKm, routes));
    final targetMet = candidates.isNotEmpty &&
        candidates.first.gapRatio.abs() <= targetTolerance + _epsilon;
    final bestGapRatio = candidates.isEmpty
        ? null
        : candidates
            .map((c) => c.gapRatio.abs())
            .reduce((a, b) => a < b ? a : b);
    return LoopPlanResult(
      candidates: candidates,
      targetMet: targetMet,
      bestGapRatio: bestGapRatio,
    );
  }

  /// Guards against a candidate that lands exactly on the tolerance being
  /// rejected by floating-point noise.
  static const double _epsilon = 1e-9;

  double _surplusM(LoopRequest request) {
    final (startLat, startLon) = request.start;
    final (endLat, endLon) = request.end!;
    final directM = metersBetween(startLat, startLon, endLat, endLon);
    return request.targetKm * 1000 - directM;
  }

  /// Bisects the geometry parameter (circle radius / detour height) for one
  /// candidate and returns the closest-to-target route it saw, or null if
  /// the router never produced one.
  ///
  /// The best route is kept explicitly rather than "whatever the last call
  /// returned": bisection's last probe is not necessarily its best one, and
  /// a candidate can end on a routing failure.
  Future<RouteResult?> _searchCandidate(LoopRequest request, int index) async {
    final targetM = request.targetKm * 1000;
    // One draw per candidate, from a generator seeded by the request seed
    // and the candidate index — so candidates differ from each other and the
    // whole plan is reproducible.
    //
    // The sub-seeds are spaced by [candidateCount] rather than being
    // `seed + index`: that keeps consecutive request seeds' candidate sets
    // disjoint, so a UI that offers "other options" by incrementing the seed
    // by 1 gets three genuinely new candidates instead of two of the old ones.
    final draw = _rng(request.seed * candidateCount + index).nextDouble();

    var param = _initialParam(request, draw);
    var low = 0.0;
    var high = double.infinity;

    RouteResult? best;
    var bestGapAbs = double.infinity;
    var consecutiveFailures = 0;

    for (var call = 0; call < maxRouterCallsPerCandidate; call++) {
      final route = await router(_locationsFor(request, index, draw, param));

      if (route == null) {
        consecutiveFailures++;
        if (consecutiveFailures >= maxConsecutiveFailures) break;
        // A failure carries no distance, so it cannot tighten the bracket —
        // just try a smaller geometry.
        param *= failureShrinkFactor;
        continue;
      }
      consecutiveFailures = 0;

      final gapRatio = (route.distanceKm * 1000 - targetM) / targetM;
      if (gapRatio.abs() < bestGapAbs) {
        bestGapAbs = gapRatio.abs();
        best = route;
      }
      if (bestGapAbs <= targetTolerance + _epsilon) break;

      if (gapRatio < 0) {
        // Too short: raise the floor, then bisect — or grow, while the
        // bracket still has no ceiling.
        low = param;
        if (high <= low) high = double.infinity; // stale ceiling
        param = high.isFinite ? (low + high) / 2 : param * expansionFactor;
      } else {
        high = param;
        if (low >= high) low = 0.0; // stale floor (e.g. after a shrink)
        param = (low + high) / 2;
      }
    }
    return best;
  }

  /// Starting value for the bisected parameter.
  double _initialParam(LoopRequest request, double draw) {
    final targetM = request.targetKm * 1000;
    if (request.kind == PlanKind.loop) {
      // Radius whose circumference is the target distance.
      return targetM / (2 * math.pi);
    }
    // A half-sine bulge of height h over a straight axis lengthens the path
    // by roughly 0.7*h..1.4*h across the detour sizes we care about, so
    // 0.7 * surplus is a serviceable first guess; bisection does the rest.
    // The per-candidate jitter keeps the three A→B candidates from
    // collapsing onto the same shape, since the bulge geometry has no
    // bearing to vary (only its side, alternated in [_locationsFor]).
    final jitter = 0.85 + 0.3 * draw;
    return _surplusM(request) * 0.7 * jitter;
  }

  /// The router argument list for one probe: start, the generated
  /// waypoints, and the terminus — the start again for a loop (so the
  /// polyline closes), the destination for A→B.
  List<(double, double)> _locationsFor(
    LoopRequest request,
    int index,
    double draw,
    double param,
  ) {
    final (startLat, startLon) = request.start;
    if (request.kind == PlanKind.loop) {
      final waypoints = circleWaypoints(
        lat: startLat,
        lon: startLon,
        radiusM: param,
        count: waypointCount,
        startBearingDeg: draw * 360,
      );
      return [request.start, ...waypoints, request.start];
    }
    final waypoints = ellipseWaypoints(
      a: request.start,
      b: request.end!,
      detourM: param,
      count: waypointCount,
      mirrored: index.isOdd, // alternate sides across candidates
    );
    return [request.start, ...waypoints, request.end!];
  }

  List<LoopCandidate> _scoreAndSort(
    PlanKind kind,
    double targetKm,
    List<RouteResult> routes,
  ) {
    final cellM = (targetKm * 1000 / 40)
        .clamp(minRepeatedCellM, maxRepeatedCellM)
        .toDouble();
    final scored = <LoopCandidate>[];
    for (final route in routes) {
      final gapRatio = (route.distanceKm - targetKm) / targetKm;
      final repeatedRatio = repeatedSegmentRatio(route.shape, cellM: cellM);
      scored.add(LoopCandidate(
        route: route,
        gapRatio: gapRatio,
        repeatedRatio: repeatedRatio,
        score: scoreOf(kind, gapRatio, repeatedRatio),
      ));
    }
    // Index tie-break: List.sort is not stable, and equal-scoring
    // candidates must still come back in a reproducible order.
    final order = List<int>.generate(scored.length, (i) => i);
    order.sort((a, b) {
      final byScore = scored[a].score.compareTo(scored[b].score);
      return byScore != 0 ? byScore : a.compareTo(b);
    });
    return [for (final i in order) scored[i]];
  }

  /// Drops candidates that are, for a user picking between offers, the same
  /// route as one already kept: same length to within
  /// [dedupDistanceTolerance] and the same amount of retracing to within
  /// [dedupRepeatedTolerance]. Expects [sorted] in score order, so the
  /// survivor of a duplicate pair is always the better-scored one.
  List<LoopCandidate> _dedup(List<LoopCandidate> sorted) {
    final kept = <LoopCandidate>[];
    for (final candidate in sorted) {
      final duplicate = kept.any((k) {
        final distanceDelta =
            (candidate.route.distanceKm - k.route.distanceKm).abs();
        final relative =
            k.route.distanceKm == 0 ? 0.0 : distanceDelta / k.route.distanceKm;
        return relative < dedupDistanceTolerance &&
            (candidate.repeatedRatio - k.repeatedRatio).abs() <
                dedupRepeatedTolerance;
      });
      if (!duplicate) kept.add(candidate);
    }
    return kept;
  }
}
