import 'dart:math' as math;

import 'events.dart';

/// Coin cooldown per place: a `landmark_visited` with `kind: 'coins'` at the
/// same `poiId` sooner than this since the last *rewarded* visit earns
/// nothing and does not advance the diminishing-yield counter.
const _coinsCooldown = Duration(hours: 24);

/// Energy cooldown per place: a `landmark_visited` with `kind: 'energy'` at
/// the same `poiId` sooner than this since the last rewarded visit restores
/// no energy.
const _energyCooldown = Duration(hours: 6);

/// Diminishing coin yield by number of *previous* rewarded visits to a
/// place (index 0 = first-ever reward there), floored at the last value.
const _coinYields = [100, 50, 25, 10];

/// Immutable game state: the sole output of replaying a journal of
/// [GameEvent]s through [reduceAll]. Every field here is derived — nothing
/// is ever mutated in place, and nothing reads a wall clock; time comes
/// entirely from [GameEvent.ts] (or from `streak_updated`'s `day` payload).
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

  /// Timestamp of the last *rewarded* (cooldown-passing) visit to a place,
  /// keyed by `poiId`. Only touched by kinds that carry an economy effect
  /// (`coins`, `energy`) — a `reveal` visit never sets it.
  final Map<String, DateTime> lastVisitByPoi;

  /// Number of rewarded coin visits to a place, keyed by `poiId`. Drives the
  /// diminishing yield in [_coinYieldFor].
  final Map<String, int> visitCountByPoi;

  /// Count of distinct places visited (first `landmark_visited` per
  /// `poiId`, counted once regardless of kind).
  final int landmarksVisited;

  final double totalKm;
  final int cellsRevealed;
  final int loopsCompleted;

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
  });

  GameState copyWith({
    int? coins,
    double? energy,
    int? xp,
    int? level,
    Set<String>? badges,
    int? streakDays,
    DateTime? lastActivityDay,
    bool clearLastActivityDay = false,
    Set<String>? visitedPoiIds,
    Map<String, DateTime>? lastVisitByPoi,
    Map<String, int>? visitCountByPoi,
    int? landmarksVisited,
    double? totalKm,
    int? cellsRevealed,
    int? loopsCompleted,
  }) {
    return GameState(
      coins: coins ?? this.coins,
      energy: energy ?? this.energy,
      xp: xp ?? this.xp,
      level: level ?? this.level,
      badges: badges ?? this.badges,
      streakDays: streakDays ?? this.streakDays,
      lastActivityDay: clearLastActivityDay
          ? null
          : (lastActivityDay ?? this.lastActivityDay),
      visitedPoiIds: visitedPoiIds ?? this.visitedPoiIds,
      lastVisitByPoi: lastVisitByPoi ?? this.lastVisitByPoi,
      visitCountByPoi: visitCountByPoi ?? this.visitCountByPoi,
      landmarksVisited: landmarksVisited ?? this.landmarksVisited,
      totalKm: totalKm ?? this.totalKm,
      cellsRevealed: cellsRevealed ?? this.cellsRevealed,
      loopsCompleted: loopsCompleted ?? this.loopsCompleted,
    );
  }
}

/// Replays [events] in the order given (the journal's append order — this
/// function never reorders by timestamp) through the pure reducer, folding
/// them into a single [GameState] starting from the zero state.
///
/// Any event whose `type` isn't one of [GameEventTypes]'s constants is
/// ignored (forward compat with journals written by a newer app version). A
/// recognized type with a malformed payload (wrong shape/missing required
/// key) is also skipped rather than thrown — a single bad event must never
/// stop the rest of the journal from applying.
GameState reduceAll(Iterable<GameEvent> events) {
  var state = const GameState();
  for (final event in events) {
    try {
      state = _reduceOne(state, event);
    } catch (_) {
      // Malformed payload for an otherwise-known type: skip, keep replaying.
    }
  }
  return state;
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
      return state.copyWith(
        coins: state.coins - (event.payload['amount'] as num).round(),
      );
    case GameEventTypes.energyChanged:
      final delta = (event.payload['delta'] as num).toDouble();
      return state.copyWith(
        energy: (state.energy + delta).clamp(0.0, 100.0),
      );
    case GameEventTypes.xpEarned:
      return _reduceXpEarned(state, event);
    case GameEventTypes.badgeUnlocked:
      final badge = event.payload['badge'] as String;
      return state.copyWith(badges: {...state.badges, badge});
    case GameEventTypes.streakUpdated:
      return _reduceStreakUpdated(state, event);
    case GameEventTypes.cellRevealed:
      final count = (event.payload['count'] as num?)?.round() ?? 1;
      return state.copyWith(cellsRevealed: state.cellsRevealed + count);
    case GameEventTypes.edgeCoveredBatch:
      final km = (event.payload['km'] as num?)?.toDouble() ?? 0;
      return state.copyWith(totalKm: state.totalKm + km);
    default:
      // Unknown type: forward-compat no-op.
      return state;
  }
}

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
    landmarksVisited:
        firstVisit ? state.landmarksVisited + 1 : state.landmarksVisited,
  );

  switch (kind) {
    case 'coins':
      return _applyCoinsVisit(state, poiId, event.ts);
    case 'energy':
      final subkind = event.payload['subkind'] as String;
      return _applyEnergyVisit(state, poiId, event.ts, subkind);
    case 'reveal':
    default:
      // Reveal landmarks (and any unrecognized kind) have no economy
      // effect here; revelation itself is handled by grid.dart/reveal.dart.
      return state;
  }
}

bool _cooldownPassed(
  Map<String, DateTime> lastVisitByPoi,
  String poiId,
  DateTime ts,
  Duration cooldown,
) {
  final last = lastVisitByPoi[poiId];
  if (last == null) return true;
  return ts.difference(last) >= cooldown;
}

int _coinYieldFor(int previousRewardedVisits) {
  final index = previousRewardedVisits.clamp(0, _coinYields.length - 1);
  return _coinYields[index];
}

GameState _applyCoinsVisit(GameState state, String poiId, DateTime ts) {
  if (!_cooldownPassed(state.lastVisitByPoi, poiId, ts, _coinsCooldown)) {
    return state; // Within cooldown: no coins, no count increment.
  }
  final previousVisits = state.visitCountByPoi[poiId] ?? 0;
  final yield_ = _coinYieldFor(previousVisits);
  return state.copyWith(
    coins: state.coins + yield_,
    lastVisitByPoi: {...state.lastVisitByPoi, poiId: ts},
    visitCountByPoi: {...state.visitCountByPoi, poiId: previousVisits + 1},
  );
}

GameState _applyEnergyVisit(
  GameState state,
  String poiId,
  DateTime ts,
  String subkind,
) {
  if (!_cooldownPassed(state.lastVisitByPoi, poiId, ts, _energyCooldown)) {
    return state; // Within cooldown: no energy restored.
  }
  final amount = switch (subkind) {
    'restaurant' => 40,
    'cafe' => 25,
    _ => 0,
  };
  return state.copyWith(
    energy: (state.energy + amount).clamp(0.0, 100.0),
    lastVisitByPoi: {...state.lastVisitByPoi, poiId: ts},
  );
}

double _energyMultiplier(double energy) {
  if (energy >= 60) return 1.5;
  if (energy >= 20) return 1.0;
  return 0.5;
}

GameState _reduceXpEarned(GameState state, GameEvent event) {
  final amount = (event.payload['amount'] as num).toDouble();
  final multiplied = event.payload['multiplied'] == true;
  final gained =
      (multiplied ? amount : amount * _energyMultiplier(state.energy)).round();
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

GameState _reduceStreakUpdated(GameState state, GameEvent event) {
  final day = _dateOnly(DateTime.parse(event.payload['day'] as String));
  final last = state.lastActivityDay;

  if (last == null) {
    return state.copyWith(streakDays: 1, lastActivityDay: day);
  }
  if (day.isAtSameMomentAs(last)) {
    return state; // Same day: no-op.
  }
  if (day.difference(last).inDays == 1) {
    return state.copyWith(streakDays: state.streakDays + 1, lastActivityDay: day);
  }
  // A gap (or a day not strictly the next one, including out-of-order
  // dates) resets the streak to 1 starting at this day.
  return state.copyWith(streakDays: 1, lastActivityDay: day);
}

DateTime _dateOnly(DateTime dt) => DateTime.utc(dt.year, dt.month, dt.day);
