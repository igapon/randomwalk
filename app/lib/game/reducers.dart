import 'dart:math' as math;

import 'events.dart';

/// Coin cooldown per (poiId, kind): a `landmark_visited` with `kind: 'coins'`
/// at the same place sooner than this since the last *rewarded* visit earns
/// nothing and does not advance the diminishing-yield counter.
const _coinsCooldown = Duration(hours: 24);

/// Energy cooldown per (poiId, kind): a `landmark_visited` with
/// `kind: 'energy'` at the same place sooner than this since the last
/// rewarded visit restores no energy.
const _energyCooldown = Duration(hours: 6);

/// Diminishing coin yield by number of *previous* rewarded visits to a
/// place (index 0 = first-ever reward there), floored at the last value.
const _coinYields = [100, 50, 25, 10];

/// Badge ids unlocked by the M4 game. These are the exact strings that
/// travel in `badge_unlocked.payload['badge']` — Tasks 2-5 must match them
/// verbatim (see the payload schema contract in the Task 1 report).
class GameBadges {
  GameBadges._();

  static const firstTrip = 'premier_trajet';
  static const firstLoop = 'premiere_boucle';
  static const km10 = 'km_10';
  static const km50 = 'km_50';
  static const km100 = 'km_100';
  static const landmarks10 = 'landmarks_10';
  static const streak7 = 'streak_7';

  /// "25% of a quartier (8x8 cell block) revealed." Reserved id only: this
  /// reducer has no notion of quartiers/8x8 blocks (that's Task 2's grid),
  /// so it is never auto-unlocked here. Task 2 must itself emit a
  /// `badge_unlocked` event with this id when its own logic detects a
  /// quartier crossing the 25% threshold; the generic `badge_unlocked`
  /// handling below then records it like any other badge.
  static const quartier25 = 'quartier_25';
}

/// Immutable game state: the sole output of replaying a journal of
/// [GameEvent]s through [reduceAll]. Every field here is derived — nothing
/// is ever mutated in place, and nothing reads a wall clock; time comes
/// entirely from [GameEvent.ts] (or from `streak_updated`'s bare-date `day`
/// payload). All exposed [Set]/[Map] fields are unmodifiable views:
/// mutating one from outside throws rather than silently desyncing state.
class GameState {
  final int coins;
  final double energy;
  final int xp;
  final int level;
  final Set<String> badges;
  final int streakDays;
  final DateTime? lastActivityDay;

  /// Every place id that has ever produced a `landmark_visited` event,
  /// regardless of kind or cooldown.
  final Set<String> visitedPoiIds;

  /// Timestamp of the last *rewarded* (cooldown-passing) visit, keyed by the
  /// composite `"<poiId>::<kind>"` — NOT by `poiId` alone, since a single
  /// OSM node can carry more than one game tag (e.g. historic+bank) and
  /// each kind's cooldown must be tracked independently. Only touched by
  /// kinds that carry an economy effect (`coins`, `energy`) — a `reveal`
  /// visit never sets it, and an `energy` visit whose subkind resolves to a
  /// zero amount (unknown subkind) never sets it either.
  final Map<String, DateTime> lastVisitByPoi;

  /// Number of rewarded coin visits, keyed by the same composite
  /// `"<poiId>::<kind>"` as [lastVisitByPoi]. Drives the diminishing yield
  /// in `_coinYieldFor`.
  final Map<String, int> visitCountByPoi;

  /// Count of distinct places visited (first `landmark_visited` per
  /// `poiId`, counted once regardless of kind).
  final int landmarksVisited;

  final double totalKm;
  final int cellsRevealed;
  final int loopsCompleted;

  /// Bare `'YYYY-MM-DD'` calendar-day strings seen via `streak_updated`,
  /// used to compute [streakDays] as a pure function of the *set* of active
  /// days rather than of event arrival order — see `_reduceStreakUpdated`.
  final Set<String> activeDays;

  /// Grid cell keys (Task 2's cell identity strings) revealed via
  /// `cell_revealed` events that carried an explicit `cells` payload. Used
  /// by Task 2's own logic to evaluate the `quartier_25` badge; this
  /// reducer only maintains the set, it never reads it itself.
  final Set<String> revealedCellKeys;

  const GameState({
    this.coins = 0,
    this.energy = 100,
    this.xp = 0,
    this.level = 0,
    this.badges = const {},
    this.streakDays = 0,
    this.lastActivityDay,
    this.visitedPoiIds = const {},
    this.lastVisitByPoi = const {},
    this.visitCountByPoi = const {},
    this.landmarksVisited = 0,
    this.totalKm = 0,
    this.cellsRevealed = 0,
    this.loopsCompleted = 0,
    this.activeDays = const {},
    this.revealedCellKeys = const {},
  });

  GameState copyWith({
    int? coins,
    double? energy,
    int? xp,
    int? level,
    Set<String>? badges,
    int? streakDays,
    DateTime? lastActivityDay,
    Set<String>? visitedPoiIds,
    Map<String, DateTime>? lastVisitByPoi,
    Map<String, int>? visitCountByPoi,
    int? landmarksVisited,
    double? totalKm,
    int? cellsRevealed,
    int? loopsCompleted,
    Set<String>? activeDays,
    Set<String>? revealedCellKeys,
  }) {
    return GameState(
      coins: coins ?? this.coins,
      energy: energy ?? this.energy,
      xp: xp ?? this.xp,
      level: level ?? this.level,
      badges: badges != null ? Set.unmodifiable(badges) : this.badges,
      streakDays: streakDays ?? this.streakDays,
      lastActivityDay: lastActivityDay ?? this.lastActivityDay,
      visitedPoiIds: visitedPoiIds != null
          ? Set.unmodifiable(visitedPoiIds)
          : this.visitedPoiIds,
      lastVisitByPoi: lastVisitByPoi != null
          ? Map.unmodifiable(lastVisitByPoi)
          : this.lastVisitByPoi,
      visitCountByPoi: visitCountByPoi != null
          ? Map.unmodifiable(visitCountByPoi)
          : this.visitCountByPoi,
      landmarksVisited: landmarksVisited ?? this.landmarksVisited,
      totalKm: totalKm ?? this.totalKm,
      cellsRevealed: cellsRevealed ?? this.cellsRevealed,
      loopsCompleted: loopsCompleted ?? this.loopsCompleted,
      activeDays: activeDays != null
          ? Set.unmodifiable(activeDays)
          : this.activeDays,
      revealedCellKeys: revealedCellKeys != null
          ? Set.unmodifiable(revealedCellKeys)
          : this.revealedCellKeys,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GameState &&
        other.coins == coins &&
        other.energy == energy &&
        other.xp == xp &&
        other.level == level &&
        _setEquals(other.badges, badges) &&
        other.streakDays == streakDays &&
        other.lastActivityDay == lastActivityDay &&
        _setEquals(other.visitedPoiIds, visitedPoiIds) &&
        _mapEquals(other.lastVisitByPoi, lastVisitByPoi) &&
        _mapEquals(other.visitCountByPoi, visitCountByPoi) &&
        other.landmarksVisited == landmarksVisited &&
        other.totalKm == totalKm &&
        other.cellsRevealed == cellsRevealed &&
        other.loopsCompleted == loopsCompleted &&
        _setEquals(other.activeDays, activeDays) &&
        _setEquals(other.revealedCellKeys, revealedCellKeys);
  }

  @override
  int get hashCode => Object.hash(
    coins,
    energy,
    xp,
    level,
    streakDays,
    lastActivityDay,
    landmarksVisited,
    totalKm,
    cellsRevealed,
    loopsCompleted,
    Object.hashAllUnordered(badges),
    Object.hashAllUnordered(visitedPoiIds),
    Object.hashAllUnordered(activeDays),
    Object.hashAllUnordered(revealedCellKeys),
    Object.hashAllUnordered(
      lastVisitByPoi.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      visitCountByPoi.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );
}

bool _setEquals<T>(Set<T> a, Set<T> b) =>
    a.length == b.length && a.every(b.contains);

bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (!b.containsKey(entry.key) || b[entry.key] != entry.value) return false;
  }
  return true;
}

/// Replays [events] through the pure reducer, folding them into a single
/// [GameState] starting from the zero state.
///
/// **M5 sync ordering (binding since Task 4, amended in Task 4's fix
/// round 1 — see [_typePrecedence]):** [events] is first sorted by
/// `(ts, type-precedence, id)` — timestamp ascending, then a small fixed
/// per-type precedence, then id ascending as a final tiebreaker for two
/// events that still tie on both. This is no longer the journal's raw
/// append order: M5's [SyncEngine] merges remote events onto the tail of
/// the local journal (see `sync/sync_engine.dart`), so the same device can
/// end up with an out-of-chronological-order append sequence (e.g. a
/// landmark visit recorded offline, then a same-day-earlier event pulled
/// from another device after reconnecting). Cooldowns (`_cooldownPassed`)
/// and the streak (`_reduceStreakUpdated`) only produce device-independent,
/// replay-order-independent results when every replay — on every device —
/// processes events in the same, deterministic order.
///
/// **Why type-precedence, not just `(ts, id)`:** every trip-ending emitter
/// (`ExplorationRecorder._run`, `GameVisitConsumer._process`) stamps every
/// event of one trip/visit with the exact same `ts`, and one hard
/// requirement — the `xp_earned`-before-`energy_changed` ordering
/// contract below — depends on which of two same-`ts` events applies
/// first. [GameEvent.id]s are random uuids, so tie-breaking on `id` alone
/// would decide that order at random (fix round 1 finding: roughly half of
/// all trips would have silently applied the drain before the XP,
/// collapsing the ×1.5 multiplier to ×0.5). [_typePrecedence] removes the
/// randomness for exactly the one pair that needs it, without having to
/// touch every emitter's timestamps.
///
/// `(ts, type-precedence, id)` is still a total order (no unresolved ties):
/// `id` is unique per event, so even two same-`ts`-same-precedence events
/// are fully ordered by it. Any correct sort (Dart's `List.sort` included,
/// which does not itself guarantee stability) therefore yields the one
/// well-defined result — "stable" describes the comparator, not a
/// requirement on the sort algorithm's implementation.
///
/// **Ordering contract for emitters (Tasks 3/5), now enforced by the sort
/// itself:** within one trip, `xp_earned` MUST be applied before that same
/// trip's `energy_changed` drain (the −4/km energy cost) — the XP
/// energy-multiplier is evaluated against `state.energy` *at the moment
/// each `xp_earned` event is applied*, i.e. "the multiplier reflects the
/// energy you walked with", not what's left after paying for the trip.
/// [_typePrecedence] gives `energy_changed` a strictly later tier than
/// every other type, so this now holds regardless of `ts`-tie append order
/// or `id` — emitters no longer need to coordinate ids to get this right,
/// only to keep stamping one trip's events with one shared `ts` (already
/// true of every emitter in this codebase). See
/// reducers_test.dart's "ordering contract" group, which pins this for
/// both append orders, plus a shuffled-replay and an M4-identity test.
///
/// Every event id is deduplicated: an event whose `id` has already been
/// seen earlier in the sorted sequence is skipped entirely (not even passed
/// to the per-type reducer) — essential once M5 sync can redeliver the same
/// event more than once.
///
/// Any event whose `type` isn't one of [GameEventTypes]'s constants is
/// ignored (forward compat with journals written by a newer app version). A
/// recognized type with a malformed payload (wrong shape/missing required
/// key) is also skipped rather than thrown — a single bad event must never
/// stop the rest of the journal from applying.
///
/// After every event (including ones that end up being no-ops), the set of
/// derived badges is re-evaluated — see [_autoUnlockBadges] — so badges
/// unlock the instant their underlying condition is met, not only when a
/// `badge_unlocked` event happens to be replayed.
GameState reduceAll(Iterable<GameEvent> events) {
  final sorted = events.toList()..sort(_byTsPrecedenceThenId);
  var state = const GameState();
  final seenIds = <String>{};
  for (final event in sorted) {
    if (!seenIds.add(event.id)) {
      continue; // Duplicate delivery of an already-applied event id: skip.
    }
    state = reduceOne(state, event);
  }
  return state;
}

int _byTsPrecedenceThenId(GameEvent a, GameEvent b) {
  final byTs = a.ts.compareTo(b.ts);
  if (byTs != 0) return byTs;
  final byPrecedence = _typePrecedence(
    a.type,
  ).compareTo(_typePrecedence(b.type));
  if (byPrecedence != 0) return byPrecedence;
  return a.id.compareTo(b.id);
}

/// [reduceAll]'s sort-tiebreak table for two events sharing the exact same
/// [GameEvent.ts] — LOWER sorts first. Deliberately tiny: [
/// GameEventTypes.energyChanged] is the only type singled out (tier 1,
/// applied last among same-`ts` events); every other type — including
/// [GameEventTypes.xpEarned] and [GameEventTypes.landmarkVisited], the
/// "gain" events the ordering contract exists to protect — shares one
/// neutral tier (0). That is exactly what the contract needs: at equal
/// `ts`, every gain-type event for a trip applies against that trip's
/// *pre-drain* energy, and the relative order among tier-0 events
/// themselves never matters (`edge_covered_batch`/`cell_revealed`/
/// `streak_updated`/`loop_completed`/`badge_unlocked` are all
/// order-independent set/counter updates; multiple `xp_earned`s for one
/// trip all read the same pre-drain energy no matter their relative
/// order — see the reducers for each type). No other reducer depends on
/// same-`ts` ordering, which is why this table stays this small rather
/// than growing a tier per type.
int _typePrecedence(String type) =>
    type == GameEventTypes.energyChanged ? 1 : 0;

/// Applies a single [event] to [state] — exactly what one step of
/// [reduceAll]'s left fold does (same per-type reducer via [_reduceOne],
/// same malformed-payload tolerance, same after-every-event derived-badge
/// re-evaluation via [_autoUnlockBadges]) — but without [reduceAll]'s own
/// event-id dedup bookkeeping, which only matters across a whole journal
/// replay and has no meaning for a single event.
///
/// Fix round 1 (Task 5 review): exposed for callers that build a short run
/// of fresh events in memory (e.g. `GameVisitConsumer`, one visit's
/// `landmark_visited`/`cell_revealed`/`xp_earned`) and want to fold them
/// onto an already-known state to get the resulting state, without
/// re-reading and fully re-replaying the whole journal just to see the
/// effect of a handful of new events.
GameState reduceOne(GameState state, GameEvent event) {
  try {
    state = _reduceOne(state, event);
  } catch (_) {
    // Malformed payload for an otherwise-known type: skip, keep replaying.
  }
  return _autoUnlockBadges(state);
}

/// Derived-badge evaluation, run after every event application. Each badge
/// is granted the first time its condition holds and never revoked
/// afterwards (e.g. `streak_7` stays unlocked even after a later gap resets
/// `streakDays` back to 1).
GameState _autoUnlockBadges(GameState state) {
  final toAdd = <String>{};
  void maybe(String badge, bool condition) {
    if (condition && !state.badges.contains(badge)) toAdd.add(badge);
  }

  // "First trip": at least one edge_covered_batch with km > 0 has ever been
  // applied. totalKm is monotonically non-decreasing and only edge_covered_
  // batch feeds it, so totalKm > 0 is exactly that condition.
  maybe(GameBadges.firstTrip, state.totalKm > 0);
  maybe(GameBadges.firstLoop, state.loopsCompleted >= 1);
  maybe(GameBadges.km10, state.totalKm >= 10);
  maybe(GameBadges.km50, state.totalKm >= 50);
  maybe(GameBadges.km100, state.totalKm >= 100);
  maybe(GameBadges.landmarks10, state.landmarksVisited >= 10);
  maybe(GameBadges.streak7, state.streakDays >= 7);
  // quartier_25 is intentionally NOT evaluated here — see GameBadges.quartier25.

  if (toAdd.isEmpty) return state;
  return state.copyWith(badges: {...state.badges, ...toAdd});
}

GameState _reduceOne(GameState state, GameEvent event) {
  switch (event.type) {
    case GameEventTypes.landmarkVisited:
      return _reduceLandmarkVisited(state, event);
    case GameEventTypes.coinsEarned:
      return state.copyWith(
        coins: state.coins + (event.payload['amount'] as num).round(),
      );
    case GameEventTypes.coinsSpent:
      final amount = (event.payload['amount'] as num).round();
      // Last line of defence against overdraw (e.g. a spend authorized
      // against stale/racing state): coins never go negative.
      return state.copyWith(coins: math.max(0, state.coins - amount));
    case GameEventTypes.energyChanged:
      final delta = (event.payload['delta'] as num).toDouble();
      return state.copyWith(energy: (state.energy + delta).clamp(0.0, 100.0));
    case GameEventTypes.xpEarned:
      return _reduceXpEarned(state, event);
    case GameEventTypes.badgeUnlocked:
      final badge = event.payload['badge'] as String;
      return state.copyWith(badges: {...state.badges, badge});
    case GameEventTypes.streakUpdated:
      return _reduceStreakUpdated(state, event);
    case GameEventTypes.cellRevealed:
      return _reduceCellRevealed(state, event);
    case GameEventTypes.edgeCoveredBatch:
      // `km` is the TOTAL distance of the trip this batch represents (not
      // an incremental delta) — the reducer adds it once to the running
      // cumulative totalKm.
      final km = (event.payload['km'] as num?)?.toDouble() ?? 0;
      return state.copyWith(totalKm: state.totalKm + km);
    case GameEventTypes.loopCompleted:
      return state.copyWith(loopsCompleted: state.loopsCompleted + 1);
    default:
      // Unknown type: forward-compat no-op.
      return state;
  }
}

String _cooldownKey(String poiId, String kind) => '$poiId::$kind';

GameState _reduceLandmarkVisited(GameState state, GameEvent event) {
  final poiId = event.payload['poiId'] as String;
  final kind = event.payload['kind'] as String;

  // First-visit bookkeeping applies to every kind, including `reveal`,
  // and regardless of any cooldown below.
  final firstVisit = !state.visitedPoiIds.contains(poiId);
  state = state.copyWith(
    visitedPoiIds: firstVisit
        ? {...state.visitedPoiIds, poiId}
        : state.visitedPoiIds,
    landmarksVisited: firstVisit
        ? state.landmarksVisited + 1
        : state.landmarksVisited,
  );

  switch (kind) {
    case 'coins':
      return _applyCoinsVisit(state, poiId, kind, event.ts);
    case 'energy':
      // Fix round 1 (Task 5 review): tolerate a missing/non-string subkind
      // rather than throwing. A malformed dataset entry (`GamePoi.subkind`
      // is nullable by design) could otherwise carry an energy-kind visit
      // with no subkind at all; an unconditional cast here would throw,
      // `reduceAll`'s catch would discard the WHOLE event — including the
      // `visitedPoiIds` bookkeeping just above — and every future visit to
      // that same broken landmark (any trip, forever) would keep evaluating
      // `firstVisit` as true and minting another `xp_earned`. Falling back
      // to `''` instead routes through the ordinary
      // "unrecognized subkind = no reward, no cooldown write" path
      // ([_energyAmountFor]/[_applyEnergyVisit]), so the event still applies
      // successfully and `visitedPoiIds` gets recorded on the first real
      // visit, exactly as it should.
      final subkind = event.payload['subkind'] as String? ?? '';
      return _applyEnergyVisit(state, poiId, kind, event.ts, subkind);
    case 'reveal':
    default:
      // Reveal landmarks (and any unrecognized kind) have no economy
      // effect here; revelation itself is handled by grid.dart/reveal.dart.
      return state;
  }
}

bool _cooldownPassed(
  Map<String, DateTime> lastVisitByPoi,
  String key,
  DateTime ts,
  Duration cooldown,
) {
  final last = lastVisitByPoi[key];
  if (last == null) return true;
  return ts.difference(last) >= cooldown;
}

int _coinYieldFor(int previousRewardedVisits) {
  final index = previousRewardedVisits.clamp(0, _coinYields.length - 1);
  return _coinYields[index];
}

GameState _applyCoinsVisit(
  GameState state,
  String poiId,
  String kind,
  DateTime ts,
) {
  final key = _cooldownKey(poiId, kind);
  if (!_cooldownPassed(state.lastVisitByPoi, key, ts, _coinsCooldown)) {
    return state; // Within cooldown: no coins, no count increment.
  }
  final previousVisits = state.visitCountByPoi[key] ?? 0;
  final yield_ = _coinYieldFor(previousVisits);
  return state.copyWith(
    coins: state.coins + yield_,
    lastVisitByPoi: {...state.lastVisitByPoi, key: ts},
    visitCountByPoi: {...state.visitCountByPoi, key: previousVisits + 1},
  );
}

/// Energy restored by an `energy`-kind landmark visit, by `subkind`. An
/// unrecognized subkind resolves to 0 — deliberately, so the caller
/// ([_applyEnergyVisit]) can treat it as "no reward" and, per the schema
/// contract, leave the cooldown untouched.
int _energyAmountFor(String subkind) => switch (subkind) {
  'restaurant' => 40,
  'cafe' => 25,
  'fast_food' => 25,
  _ => 0,
};

GameState _applyEnergyVisit(
  GameState state,
  String poiId,
  String kind,
  DateTime ts,
  String subkind,
) {
  final amount = _energyAmountFor(subkind);
  if (amount == 0) {
    // Unknown subkind: no reward AND no cooldown write, so a later visit
    // with a recognized subkind at the same place isn't blocked by this one.
    return state;
  }
  final key = _cooldownKey(poiId, kind);
  if (!_cooldownPassed(state.lastVisitByPoi, key, ts, _energyCooldown)) {
    return state; // Within cooldown: no energy restored.
  }
  return state.copyWith(
    energy: (state.energy + amount).clamp(0.0, 100.0),
    lastVisitByPoi: {...state.lastVisitByPoi, key: ts},
  );
}

double _energyMultiplier(double energy) {
  if (energy >= 60) return 1.5;
  if (energy >= 20) return 1.0;
  return 0.5;
}

GameState _reduceXpEarned(GameState state, GameEvent event) {
  final amount = (event.payload['amount'] as num).toDouble();
  final preMultiplied = event.payload['preMultiplied'] == true;
  final gained =
      (preMultiplied ? amount : amount * _energyMultiplier(state.energy))
          .round();
  final newXp = state.xp + gained;
  return state.copyWith(xp: newXp, level: _levelForXp(newXp));
}

/// The largest level `n` (>= 0) whose cumulative XP requirement
/// `100 * n^1.5` is met or exceeded by [xp].
int _levelForXp(int xp) {
  var n = 0;
  while (100 * math.pow(n + 1, 1.5) <= xp) {
    n++;
  }
  return n;
}

/// `streak_updated` payloads carry a bare calendar date, e.g. `'2026-08-30'`
/// — no time-of-day, no timezone marker. A payload containing `'T'` or
/// `'Z'` (the tell-tale markers of a full ISO-8601 datetime, which is what
/// [GameEvent.ts] itself is serialized as) is rejected outright: mixing
/// datetime-with-offset semantics into a pure calendar-day streak would
/// reintroduce timezone/DST edge cases this design deliberately avoids by
/// working only with plain date strings.
GameState _reduceStreakUpdated(GameState state, GameEvent event) {
  final raw = event.payload['day'] as String;
  if (raw.contains('T') || raw.contains('Z')) {
    return state;
  }
  if (state.activeDays.contains(raw)) {
    return state; // Already recorded: no-op, regardless of arrival order.
  }
  final activeDays = {...state.activeDays, raw};
  final maxDay = activeDays.reduce((a, b) => a.compareTo(b) >= 0 ? a : b);
  return state.copyWith(
    activeDays: activeDays,
    streakDays: _consecutiveRunLength(activeDays, maxDay),
    lastActivityDay: _parseBareDate(maxDay),
  );
}

/// Length of the run of consecutive calendar days in [activeDays] ending at
/// (and including) [endDay]. Computed purely from the *set* of days, so the
/// result is identical no matter what order those days were recorded in —
/// this is what makes the streak reorder-invariant and idempotent under
/// re-delivery of the same day.
int _consecutiveRunLength(Set<String> activeDays, String endDay) {
  var count = 0;
  var cursor = _parseBareDate(endDay);
  while (activeDays.contains(_formatBareDate(cursor))) {
    count++;
    cursor = cursor.subtract(const Duration(days: 1));
  }
  return count;
}

DateTime _parseBareDate(String s) {
  final parts = s.split('-');
  return DateTime.utc(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

String _formatBareDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// `cell_revealed` supports two payload shapes:
///  - `{'cells': ['x:12,y:34', ...]}` — the preferred, cell-identity-aware
///    shape. New (not-already-seen) keys are added to [GameState.
///    revealedCellKeys], and [GameState.cellsRevealed] is kept as that set's
///    size — i.e. a genuine distinct-cell count, safe against duplicates.
///  - `{'count': n}` (or no payload at all, defaulting to 1) — the legacy/
///    compat shape for a caller that doesn't have cell identities yet. This
///    only bumps the raw [GameState.cellsRevealed] counter; it cannot
///    contribute to [GameState.revealedCellKeys] since the cells' identities
///    aren't known, so Task 2's quartier-completion math must use the
///    identity-aware shape.
GameState _reduceCellRevealed(GameState state, GameEvent event) {
  final cells = event.payload['cells'] as List?;
  if (cells != null) {
    final keys = cells.cast<String>();
    final newKeys = keys.where((k) => !state.revealedCellKeys.contains(k));
    if (newKeys.isEmpty) return state;
    final revealed = {...state.revealedCellKeys, ...newKeys};
    return state.copyWith(
      revealedCellKeys: revealed,
      cellsRevealed: revealed.length,
    );
  }
  final count = (event.payload['count'] as num?)?.round() ?? 1;
  return state.copyWith(cellsRevealed: state.cellsRevealed + count);
}
