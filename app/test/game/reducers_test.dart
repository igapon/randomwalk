import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/reducers.dart';

void main() {
  var seq = 0;
  GameEvent ev(String type, DateTime ts, Map<String, dynamic> payload) {
    seq++;
    return GameEvent(id: 'e$seq', ts: ts, type: type, payload: payload);
  }

  final t0 = DateTime.utc(2026, 1, 1, 12, 0, 0);

  setUp(() => seq = 0);

  group('default state', () {
    test('zero state has energy 100 and everything else at zero', () {
      final s = reduceAll(const []);
      expect(s.coins, 0);
      expect(s.energy, 100);
      expect(s.xp, 0);
      expect(s.level, 0);
      expect(s.badges, isEmpty);
      expect(s.streakDays, 0);
      expect(s.lastActivityDay, isNull);
      expect(s.visitedPoiIds, isEmpty);
      expect(s.landmarksVisited, 0);
      expect(s.totalKm, 0);
      expect(s.cellsRevealed, 0);
      expect(s.loopsCompleted, 0);
    });
  });

  group('coins_earned / coins_spent', () {
    test('coins_earned adds to the wallet', () {
      final s = reduceAll([ev(GameEventTypes.coinsEarned, t0, {'amount': 30})]);
      expect(s.coins, 30);
    });

    test('coins_spent subtracts from the wallet', () {
      final s = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 30}),
        ev(GameEventTypes.coinsSpent, t0, {'amount': 12}),
      ]);
      expect(s.coins, 18);
    });
  });

  group('energy_changed', () {
    test('applies a negative delta (e.g. -4/km on a trip)', () {
      final s = reduceAll([ev(GameEventTypes.energyChanged, t0, {'delta': -4})]);
      expect(s.energy, 96);
    });

    test('clamps at 0 on the low end', () {
      final s = reduceAll([ev(GameEventTypes.energyChanged, t0, {'delta': -500})]);
      expect(s.energy, 0);
    });

    test('clamps at 100 on the high end', () {
      final s = reduceAll([ev(GameEventTypes.energyChanged, t0, {'delta': 500})]);
      expect(s.energy, 100);
    });
  });

  group('landmark_visited: coins (bank/ATM) cooldown + diminishing yield', () {
    GameEvent visit(DateTime ts, {String poiId = 'bank-1'}) =>
        ev(GameEventTypes.landmarkVisited, ts, {'poiId': poiId, 'kind': 'coins'});

    test('first-ever visit yields 100 coins', () {
      final s = reduceAll([visit(t0)]);
      expect(s.coins, 100);
    });

    test('successive rewarded visits (24h apart) yield 100/50/25/10, floored at 10', () {
      final visits = [
        visit(t0),
        visit(t0.add(const Duration(hours: 24))),
        visit(t0.add(const Duration(hours: 48))),
        visit(t0.add(const Duration(hours: 72))),
        visit(t0.add(const Duration(hours: 96))), // 5th: stays floored at 10
      ];
      final s = reduceAll(visits);
      expect(s.coins, 100 + 50 + 25 + 10 + 10);
    });

    test('a visit inside the 24h cooldown earns nothing and does not advance the count', () {
      final s = reduceAll([
        visit(t0),
        visit(t0.add(const Duration(hours: 23, minutes: 59, seconds: 59))),
      ]);
      expect(s.coins, 100); // second visit blocked entirely
    });

    test('exactly 24h later is NOT in cooldown (inclusive boundary)', () {
      final s = reduceAll([
        visit(t0),
        visit(t0.add(const Duration(hours: 24))),
      ]);
      expect(s.coins, 150); // 100 + 50
    });

    test('one second short of 24h is still in cooldown', () {
      final s = reduceAll([
        visit(t0),
        visit(t0.add(const Duration(hours: 24) - const Duration(seconds: 1))),
      ]);
      expect(s.coins, 100);
    });

    test('a blocked visit does not reset the cooldown clock', () {
      // Reward at t0. Blocked attempt at t0+1h must NOT push the cooldown
      // window forward — a visit at t0+25h (25h after the ORIGINAL reward)
      // must still succeed.
      final s = reduceAll([
        visit(t0),
        visit(t0.add(const Duration(hours: 1))), // blocked
        visit(t0.add(const Duration(hours: 25))), // 25h after t0: rewarded
      ]);
      expect(s.coins, 150);
    });

    test('cooldown and yield are tracked independently per place', () {
      final s = reduceAll([
        visit(t0, poiId: 'bank-A'),
        visit(t0, poiId: 'bank-B'),
      ]);
      expect(s.coins, 200); // both are first-ever visits at their own place
    });
  });

  group('landmark_visited: energy (restaurant/cafe) cooldown', () {
    GameEvent visit(DateTime ts, String subkind, {String poiId = 'cafe-1'}) =>
        ev(GameEventTypes.landmarkVisited, ts,
            {'poiId': poiId, 'kind': 'energy', 'subkind': subkind});

    test('restaurant restores +40 energy', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -50}),
        visit(t0, 'restaurant'),
      ]);
      expect(s.energy, 90);
    });

    test('cafe restores +25 energy', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -50}),
        visit(t0, 'cafe'),
      ]);
      expect(s.energy, 75);
    });

    test('restoration clamps at 100', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -10}), // 90
        visit(t0, 'restaurant'), // +40 would be 130, clamps to 100
      ]);
      expect(s.energy, 100);
    });

    test('a second visit inside the 6h cooldown restores nothing', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -80}), // 20
        visit(t0, 'cafe'), // 20 + 25 = 45
        visit(t0.add(const Duration(hours: 5, minutes: 59, seconds: 59)), 'cafe'),
      ]);
      expect(s.energy, 45);
    });

    test('exactly 6h later is NOT in cooldown (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -80}), // 20
        visit(t0, 'cafe'), // 45
        visit(t0.add(const Duration(hours: 6)), 'cafe'), // 70
      ]);
      expect(s.energy, 70);
    });
  });

  group('landmark_visited: reveal kind and first-visit bookkeeping', () {
    test('reveal kind has no coin/energy effect', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {'poiId': 'church-1', 'kind': 'reveal'}),
      ]);
      expect(s.coins, 0);
      expect(s.energy, 100);
    });

    test('visiting a new place adds to visitedPoiIds and increments landmarksVisited once', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {'poiId': 'church-1', 'kind': 'reveal'}),
        ev(GameEventTypes.landmarkVisited, t0.add(const Duration(days: 1)),
            {'poiId': 'church-1', 'kind': 'reveal'}),
        ev(GameEventTypes.landmarkVisited, t0, {'poiId': 'bank-1', 'kind': 'coins'}),
      ]);
      expect(s.visitedPoiIds, {'church-1', 'bank-1'});
      expect(s.landmarksVisited, 2);
    });

    test('first-visit bookkeeping happens even for a cooldown-blocked coin visit', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {'poiId': 'bank-1', 'kind': 'coins'}),
        ev(GameEventTypes.landmarkVisited, t0.add(const Duration(minutes: 1)),
            {'poiId': 'bank-1', 'kind': 'coins'}),
      ]);
      expect(s.landmarksVisited, 1); // still just one distinct place
    });
  });

  group('xp_earned: energy multiplier', () {
    GameEvent xp(double amount, {bool? multiplied}) => ev(
          GameEventTypes.xpEarned,
          t0,
          {'amount': amount, if (multiplied != null) 'multiplied': multiplied},
        );

    test('energy >= 60 applies x1.5', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -30}), // 70
        xp(10),
      ]);
      expect(s.xp, 15);
    });

    test('energy exactly 60 still applies x1.5 (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -40}), // 60
        xp(10),
      ]);
      expect(s.xp, 15);
    });

    test('energy just below 60 applies x1.0', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -41}), // 59
        xp(10),
      ]);
      expect(s.xp, 10);
    });

    test('energy exactly 20 still applies x1.0 (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -80}), // 20
        xp(10),
      ]);
      expect(s.xp, 10);
    });

    test('energy just below 20 applies x0.5', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -81}), // 19
        xp(10),
      ]);
      expect(s.xp, 5);
    });

    test('result is rounded to the nearest integer (half away from zero)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -40}), // 60 -> x1.5
        xp(5), // 5 * 1.5 = 7.5 -> 8
      ]);
      expect(s.xp, 8);
    });

    test('multiplied:true bypasses the energy multiplier entirely', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -90}), // 10 -> would be x0.5
        xp(10, multiplied: true),
      ]);
      expect(s.xp, 10); // not halved
    });

    test('multiplier is evaluated at the energy level at the moment of the event', () {
      final s = reduceAll([
        xp(10), // energy 100 -> x1.5 -> +15
        ev(GameEventTypes.energyChanged, t0, {'delta': -90}), // energy now 10
        xp(10), // energy 10 -> x0.5 -> +5
      ]);
      expect(s.xp, 20);
    });
  });

  group('level thresholds (100 * n^1.5 cumulative XP)', () {
    GameEvent xpFlat(int amount) =>
        ev(GameEventTypes.xpEarned, t0, {'amount': amount, 'multiplied': true});

    test('0 xp is level 0', () {
      expect(reduceAll([xpFlat(0)]).level, 0);
    });

    test('99 xp is still level 0', () {
      expect(reduceAll([xpFlat(99)]).level, 0);
    });

    test('exactly 100 xp reaches level 1', () {
      expect(reduceAll([xpFlat(100)]).level, 1);
    });

    test('799 xp is level 3 (threshold for 4 is 800)', () {
      expect(reduceAll([xpFlat(799)]).level, 3);
    });

    test('exactly 800 xp reaches level 4', () {
      expect(reduceAll([xpFlat(800)]).level, 4);
    });

    test('2699 xp is level 8 (threshold for 9 is 2700)', () {
      expect(reduceAll([xpFlat(2699)]).level, 8);
    });

    test('exactly 2700 xp reaches level 9', () {
      expect(reduceAll([xpFlat(2700)]).level, 9);
    });
  });

  group('badge_unlocked', () {
    test('adds a badge', () {
      final s = reduceAll([ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_trip'})]);
      expect(s.badges, {'first_trip'});
    });

    test('unlocking the same badge twice keeps the set deduplicated', () {
      final s = reduceAll([
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_trip'}),
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_trip'}),
      ]);
      expect(s.badges, {'first_trip'});
    });

    test('accumulates distinct badges', () {
      final s = reduceAll([
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_trip'}),
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_loop'}),
      ]);
      expect(s.badges, {'first_trip', 'first_loop'});
    });
  });

  group('streak_updated: consecutive-day logic', () {
    GameEvent streak(String isoDay) =>
        ev(GameEventTypes.streakUpdated, t0, {'day': isoDay});

    test('first activity day starts a streak of 1', () {
      final s = reduceAll([streak('2026-01-01')]);
      expect(s.streakDays, 1);
      expect(s.lastActivityDay, DateTime.utc(2026, 1, 1));
    });

    test('the same day again is a no-op', () {
      final s = reduceAll([streak('2026-01-01'), streak('2026-01-01')]);
      expect(s.streakDays, 1);
    });

    test('the next day increments the streak', () {
      final s = reduceAll([streak('2026-01-01'), streak('2026-01-02')]);
      expect(s.streakDays, 2);
    });

    test('a multi-day chain keeps incrementing', () {
      final s = reduceAll([
        streak('2026-01-01'),
        streak('2026-01-02'),
        streak('2026-01-03'),
        streak('2026-01-04'),
      ]);
      expect(s.streakDays, 4);
    });

    test('a gap of one missed day resets the streak to 1', () {
      final s = reduceAll([
        streak('2026-01-01'),
        streak('2026-01-02'),
        streak('2026-01-04'), // skipped the 3rd
      ]);
      expect(s.streakDays, 1);
      expect(s.lastActivityDay, DateTime.utc(2026, 1, 4));
    });

    test('a large gap (multi-day) also resets to 1', () {
      final s = reduceAll([
        streak('2026-01-01'),
        streak('2026-02-15'),
      ]);
      expect(s.streakDays, 1);
    });

    test('survives interleaving with unrelated events (independent field)', () {
      final s = reduceAll([
        streak('2026-01-01'),
        ev(GameEventTypes.coinsEarned, t0, {'amount': 5}),
        streak('2026-01-02'),
      ]);
      expect(s.streakDays, 2);
      expect(s.coins, 5);
    });
  });

  group('cell_revealed', () {
    test('each event increments cellsRevealed by 1 by default', () {
      final s = reduceAll([
        ev(GameEventTypes.cellRevealed, t0, const {}),
        ev(GameEventTypes.cellRevealed, t0, const {}),
      ]);
      expect(s.cellsRevealed, 2);
    });

    test('an explicit count payload adds a batch at once', () {
      final s = reduceAll([ev(GameEventTypes.cellRevealed, t0, {'count': 7})]);
      expect(s.cellsRevealed, 7);
    });
  });

  group('edge_covered_batch', () {
    test('accumulates km travelled', () {
      final s = reduceAll([
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 2.5}),
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 1.5}),
      ]);
      expect(s.totalKm, 4.0);
    });
  });

  group('forward compat and resilience', () {
    test('an unknown event type is ignored entirely', () {
      final s = reduceAll([
        ev('some_future_event_type', t0, {'whatever': 'value'}),
      ]);
      expect(s.coins, 0);
      expect(s.xp, 0);
      expect(s.energy, 100);
    });

    test('a malformed payload on a known type is skipped, not thrown', () {
      expect(
        () => reduceAll([
          ev(GameEventTypes.coinsEarned, t0, const {}), // missing 'amount'
        ]),
        returnsNormally,
      );
    });

    test('a malformed event does not stop later valid events from applying', () {
      final s = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, const {}), // malformed: skipped
        ev(GameEventTypes.coinsEarned, t0, {'amount': 5}),
      ]);
      expect(s.coins, 5);
    });
  });

  group('ordering', () {
    test('reduceAll applies events in the order given, not sorted by ts', () {
      // Passing a later day before an earlier one is treated as the caller's
      // chosen order (a gap/reset from the reducer's point of view) — the
      // reducer never re-sorts by timestamp.
      final s = reduceAll([
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-05'}),
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01'}),
      ]);
      expect(s.lastActivityDay, DateTime.utc(2026, 1, 1));
      expect(s.streakDays, 1);
    });
  });
}
