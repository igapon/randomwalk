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
      final s = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 30}),
      ]);
      expect(s.coins, 30);
    });

    test('coins_spent subtracts from the wallet', () {
      final s = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 30}),
        ev(GameEventTypes.coinsSpent, t0, {'amount': 12}),
      ]);
      expect(s.coins, 18);
    });

    test(
      'coins_spent clamps at 0 on overdraw (reducer as last line of defence)',
      () {
        final s = reduceAll([
          ev(GameEventTypes.coinsEarned, t0, {'amount': 10}),
          ev(GameEventTypes.coinsSpent, t0, {'amount': 999}),
        ]);
        expect(s.coins, 0);
      },
    );
  });

  group('energy_changed', () {
    test('applies a negative delta (e.g. -4/km on a trip)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -4}),
      ]);
      expect(s.energy, 96);
    });

    test('clamps at 0 on the low end', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': -500}),
      ]);
      expect(s.energy, 0);
    });

    test('clamps at 100 on the high end', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, t0, {'delta': 500}),
      ]);
      expect(s.energy, 100);
    });
  });

  group('landmark_visited: coins (bank/ATM) cooldown + diminishing yield', () {
    GameEvent visit(DateTime ts, {String poiId = 'bank-1'}) => ev(
      GameEventTypes.landmarkVisited,
      ts,
      {'poiId': poiId, 'kind': 'coins'},
    );

    test('first-ever visit yields 100 coins', () {
      final s = reduceAll([visit(t0)]);
      expect(s.coins, 100);
    });

    test(
      'successive rewarded visits (24h apart) yield 100/50/25/10, floored at 10',
      () {
        final visits = [
          visit(t0),
          visit(t0.add(const Duration(hours: 24))),
          visit(t0.add(const Duration(hours: 48))),
          visit(t0.add(const Duration(hours: 72))),
          visit(t0.add(const Duration(hours: 96))), // 5th: stays floored at 10
        ];
        final s = reduceAll(visits);
        expect(s.coins, 100 + 50 + 25 + 10 + 10);
      },
    );

    test(
      'a visit inside the 24h cooldown earns nothing and does not advance the count',
      () {
        final s = reduceAll([
          visit(t0),
          visit(t0.add(const Duration(hours: 23, minutes: 59, seconds: 59))),
        ]);
        expect(s.coins, 100); // second visit blocked entirely
      },
    );

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

  group('landmark_visited: energy (restaurant/cafe/fast_food) cooldown', () {
    GameEvent visit(DateTime ts, String subkind, {String poiId = 'cafe-1'}) =>
        ev(GameEventTypes.landmarkVisited, ts, {
          'poiId': poiId,
          'kind': 'energy',
          'subkind': subkind,
        });

    // These tests set up a specific energy level via an energy_changed
    // BEFORE the landmark_visited under test — fix round 1 (Task 4 review,
    // C3) moved this drain from the SAME `ts` as the visit to a strictly
    // EARLIER one: _typePrecedence now always applies energy_changed AFTER
    // every other same-`ts` event (see reducers.dart), so same-`ts` could
    // no longer express "drain, then visit" — a distinct, earlier `ts` is
    // the correct way to express that instead (and matches how a real
    // drain and a real visit are never literally simultaneous anyway).
    final drained = t0.subtract(const Duration(minutes: 30));

    test('restaurant restores +40 energy', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -50}),
        visit(t0, 'restaurant'),
      ]);
      expect(s.energy, 90);
    });

    test('cafe restores +25 energy', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -50}),
        visit(t0, 'cafe'),
      ]);
      expect(s.energy, 75);
    });

    test('fast_food restores +25 energy, same as cafe', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -50}),
        visit(t0, 'fast_food'),
      ]);
      expect(s.energy, 75);
    });

    test('restoration clamps at 100', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -10}), // 90
        visit(t0, 'restaurant'), // +40 would be 130, clamps to 100
      ]);
      expect(s.energy, 100);
    });

    test('a second visit inside the 6h cooldown restores nothing', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -80}), // 20
        visit(t0, 'cafe'), // 20 + 25 = 45
        visit(
          t0.add(const Duration(hours: 5, minutes: 59, seconds: 59)),
          'cafe',
        ),
      ]);
      expect(s.energy, 45);
    });

    test('exactly 6h later is NOT in cooldown (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -80}), // 20
        visit(t0, 'cafe'), // 45
        visit(t0.add(const Duration(hours: 6)), 'cafe'), // 70
      ]);
      expect(s.energy, 70);
    });

    test(
      'an unknown subkind restores nothing AND does not write the cooldown',
      () {
        final s = reduceAll([
          ev(GameEventTypes.energyChanged, drained, {'delta': -80}), // 20
          visit(t0, 'kiosk'), // unknown subkind: no-op
          // Immediately after, at the SAME instant, a real cafe visit must
          // still be rewarded — proving the unknown-subkind visit above never
          // touched the cooldown map.
          visit(t0, 'cafe'),
        ]);
        expect(s.energy, 45); // 20 + 25, not blocked
      },
    );

    test('a missing subkind key on an energy visit is tolerated (fix round 1, '
        'Task 5 review): no reward, but the event still applies and records '
        'visitedPoiIds — a throw here would silently drop the WHOLE event, '
        'leaving firstVisit permanently true for every future visit to this '
        'poiId', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'broken-poi',
          'kind': 'energy',
        }), // no 'subkind' at all
      ]);
      expect(s.energy, 100); // no reward.
      expect(s.visitedPoiIds, contains('broken-poi'));
      expect(s.landmarksVisited, 1);
    });

    test('a null subkind value (not just a missing key) is tolerated the same '
        'way', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'broken-poi',
          'kind': 'energy',
          'subkind': null,
        }),
      ]);
      expect(s.energy, 100);
      expect(s.visitedPoiIds, contains('broken-poi'));
    });

    test('once the missing-subkind event has applied, a later real visit to '
        'the SAME poiId sees firstVisit == false — the exploit this closes: '
        'a bad dataset entry used to let every future visit mint another '
        'xp_earned forever', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'broken-poi',
          'kind': 'energy',
        }),
        ev(GameEventTypes.xpEarned, t0, {'amount': 25, 'preMultiplied': false}),
        // A second "visit" to the same broken landmark on a later trip.
        ev(GameEventTypes.landmarkVisited, t0.add(const Duration(days: 1)), {
          'poiId': 'broken-poi',
          'kind': 'energy',
        }),
        ev(GameEventTypes.xpEarned, t0.add(const Duration(days: 1)), {
          'amount': 25,
          'preMultiplied': false,
        }),
      ]);
      // Only the first visit's xp_earned should have counted for real —
      // the second landmark_visited must not have reset visitedPoiIds, so
      // a real emitter (GameVisitConsumer) checking `visitedPoiIds` before
      // emitting the second xp_earned would never have appended it. This
      // reducer-level test can only prove the *first* half of that (the
      // event applies and bookkeeping sticks); GameVisitConsumer's own
      // tests prove the emitter side never appends the second xp_earned.
      expect(s.landmarksVisited, 1); // not 2: still the same poiId.
    });

    test(
      'cooldown is tracked independently for coins vs energy on the same poiId',
      () {
        // A single OSM node can carry more than one game tag (e.g.
        // historic+bank). Two landmark_visited events sharing a poiId but
        // differing in kind must not share a cooldown/yield bucket: the cafe
        // reward below must land in full even though a coins visit at the
        // exact same instant, on the exact same poiId, just happened.
        const sharedId = 'node-42';
        final s = reduceAll([
          ev(GameEventTypes.energyChanged, drained, {
            'delta': -50,
          }), // energy 50
          ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': sharedId,
            'kind': 'coins',
          }),
          ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': sharedId,
            'kind': 'energy',
            'subkind': 'cafe',
          }),
        ]);
        expect(s.coins, 100); // coins reward, unaffected by the energy visit
        expect(
          s.energy,
          75,
        ); // 50 + 25 cafe reward, unaffected by the coins visit
      },
    );
  });

  group('landmark_visited: reveal kind and first-visit bookkeeping', () {
    test('reveal kind has no coin/energy effect', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'church-1',
          'kind': 'reveal',
        }),
      ]);
      expect(s.coins, 0);
      expect(s.energy, 100);
    });

    test(
      'visiting a new place adds to visitedPoiIds and increments landmarksVisited once',
      () {
        final s = reduceAll([
          ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': 'church-1',
            'kind': 'reveal',
          }),
          ev(GameEventTypes.landmarkVisited, t0.add(const Duration(days: 1)), {
            'poiId': 'church-1',
            'kind': 'reveal',
          }),
          ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': 'bank-1',
            'kind': 'coins',
          }),
        ]);
        expect(s.visitedPoiIds, {'church-1', 'bank-1'});
        expect(s.landmarksVisited, 2);
      },
    );

    test(
      'first-visit bookkeeping happens even for a cooldown-blocked coin visit',
      () {
        final s = reduceAll([
          ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': 'bank-1',
            'kind': 'coins',
          }),
          ev(
            GameEventTypes.landmarkVisited,
            t0.add(const Duration(minutes: 1)),
            {'poiId': 'bank-1', 'kind': 'coins'},
          ),
        ]);
        expect(s.landmarksVisited, 1); // still just one distinct place
      },
    );
  });

  group('xp_earned: energy multiplier', () {
    GameEvent xp(double amount, {bool? preMultiplied, DateTime? ts}) =>
        ev(GameEventTypes.xpEarned, ts ?? t0, {
          'amount': amount,
          if (preMultiplied != null) 'preMultiplied': preMultiplied,
        });

    // These tests set up a specific energy level via an energy_changed
    // BEFORE minting the xp_earned under test — a fix-round-1 (Task 4
    // review, C3) change from same-`ts` ordering to a strictly-earlier `ts`
    // for the drain: since _typePrecedence now always applies energy_changed
    // AFTER every other same-`ts` event (see reducers.dart), same-`ts`
    // could no longer express "drain, then measure" — a distinct, earlier
    // `ts` is the correct way to do that instead, and is also what every
    // real emitter does across two different trips/visits.
    final drained = t0.subtract(const Duration(seconds: 1));

    test('energy >= 60 applies x1.5', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -30}), // 70
        xp(10),
      ]);
      expect(s.xp, 15);
    });

    test('energy exactly 60 still applies x1.5 (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -40}), // 60
        xp(10),
      ]);
      expect(s.xp, 15);
    });

    test('energy just below 60 applies x1.0', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -41}), // 59
        xp(10),
      ]);
      expect(s.xp, 10);
    });

    test('energy exactly 20 still applies x1.0 (inclusive boundary)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -80}), // 20
        xp(10),
      ]);
      expect(s.xp, 10);
    });

    test('energy just below 20 applies x0.5', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -81}), // 19
        xp(10),
      ]);
      expect(s.xp, 5);
    });

    test('result is rounded to the nearest integer (half away from zero)', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {'delta': -40}), // 60 -> x1.5
        xp(5), // 5 * 1.5 = 7.5 -> 8
      ]);
      expect(s.xp, 8);
    });

    test('preMultiplied:true bypasses the energy multiplier entirely', () {
      final s = reduceAll([
        ev(GameEventTypes.energyChanged, drained, {
          'delta': -90,
        }), // 10 -> would be x0.5
        xp(10, preMultiplied: true),
      ]);
      expect(s.xp, 10); // not halved
    });

    test(
      'multiplier is evaluated at the energy level at the moment of the event',
      () {
        final t1 = t0.add(const Duration(seconds: 1));
        final t2 = t0.add(const Duration(seconds: 2));
        final s = reduceAll([
          xp(10, ts: t0), // energy 100 -> x1.5 -> +15
          ev(GameEventTypes.energyChanged, t1, {'delta': -90}), // energy now 10
          xp(10, ts: t2), // energy 10 -> x0.5 -> +5
        ]);
        expect(s.xp, 20);
      },
    );

    group(
      "ordering contract: xp_earned and a same-trip (same-`ts`) energy "
      'drain always apply xp first, regardless of journal/append order '
      '(fix round 1, Task 4 review C3 — _typePrecedence in reducers.dart)',
      () {
        test('xp appended before drain (the real emitters\' own order): '
            'multiplier reflects the energy walked in with (x1.5)', () {
          final s = reduceAll([
            xp(10), // ts == t0
            ev(GameEventTypes.energyChanged, t0, {'delta': -90}),
          ]);
          expect(s.xp, 15);
          expect(s.energy, 10);
        });

        test('drain appended before xp, same ts (a hypothetical bad emitter, '
            'or a merge landing them in reverse order): the sort still '
            'applies xp first — same (x1.5) result as the order above', () {
          final s = reduceAll([
            ev(GameEventTypes.energyChanged, t0, {'delta': -90}),
            xp(10), // ts == t0, same exact timestamp as the drain
          ]);
          expect(s.xp, 15);
          expect(s.energy, 10);
        });
      },
    );
  });

  group('level thresholds (100 * n^1.5 cumulative XP)', () {
    GameEvent xpFlat(int amount) => ev(GameEventTypes.xpEarned, t0, {
      'amount': amount,
      'preMultiplied': true,
    });

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

  group('badge_unlocked (explicit event)', () {
    test('adds a badge', () {
      final s = reduceAll([
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'first_trip'}),
      ]);
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

    test(
      'Task 2 can still unlock quartier_25 explicitly (reducer never derives it itself)',
      () {
        final s = reduceAll([
          ev(GameEventTypes.badgeUnlocked, t0, {
            'badge': GameBadges.quartier25,
          }),
        ]);
        expect(s.badges, {GameBadges.quartier25});
      },
    );
  });

  group(
    'derived badges (auto-unlocked from state, not from badge_unlocked events)',
    () {
      test(
        'premier_trajet unlocks on the first edge_covered_batch with km > 0',
        () {
          final before = reduceAll(const []);
          expect(before.badges.contains(GameBadges.firstTrip), isFalse);
          final after = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 1.2}),
          ]);
          expect(after.badges.contains(GameBadges.firstTrip), isTrue);
        },
      );

      test('premier_trajet does not unlock on a zero-km batch', () {
        final s = reduceAll([
          ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 0}),
        ]);
        expect(s.badges.contains(GameBadges.firstTrip), isFalse);
      });

      test('premiere_boucle unlocks on the first loop_completed', () {
        final s = reduceAll([ev(GameEventTypes.loopCompleted, t0, const {})]);
        expect(s.badges.contains(GameBadges.firstLoop), isTrue);
        expect(s.loopsCompleted, 1);
      });

      test('premiere_boucle unlocks exactly once even after several loops', () {
        final s = reduceAll(
          List.generate(
            3,
            (_) => ev(GameEventTypes.loopCompleted, t0, const {}),
          ),
        );
        expect(s.loopsCompleted, 3);
        // A Set cannot hold a duplicate, but the intent here is that the
        // badge transitions from absent to present exactly once across the
        // fold — confirmed indirectly by it simply being present post-fold.
        expect(s.badges.where((b) => b == GameBadges.firstLoop).length, 1);
      });

      test(
        'km_10 / km_50 / km_100 unlock at their respective totalKm thresholds',
        () {
          final at9 = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 9}),
          ]);
          expect(at9.badges.contains(GameBadges.km10), isFalse);

          final at10 = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 10}),
          ]);
          expect(at10.badges.contains(GameBadges.km10), isTrue);
          expect(at10.badges.contains(GameBadges.km50), isFalse);

          final at50 = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 50}),
          ]);
          expect(at50.badges.contains(GameBadges.km10), isTrue);
          expect(at50.badges.contains(GameBadges.km50), isTrue);
          expect(at50.badges.contains(GameBadges.km100), isFalse);

          final at100 = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 100}),
          ]);
          expect(
            at100.badges,
            containsAll([GameBadges.km10, GameBadges.km50, GameBadges.km100]),
          );
        },
      );

      test(
        'a single large batch crossing all three km thresholds unlocks all three at once',
        () {
          final s = reduceAll([
            ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 120}),
          ]);
          expect(
            s.badges,
            containsAll([GameBadges.km10, GameBadges.km50, GameBadges.km100]),
          );
        },
      );

      test('landmarks_10 unlocks on the 10th distinct place visited', () {
        final events = List.generate(
          9,
          (i) => ev(GameEventTypes.landmarkVisited, t0, {
            'poiId': 'poi-$i',
            'kind': 'reveal',
          }),
        );
        final at9 = reduceAll(events);
        expect(at9.badges.contains(GameBadges.landmarks10), isFalse);

        final tenth = ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'poi-9',
          'kind': 'reveal',
        });
        final at10 = reduceAll([...events, tenth]);
        expect(at10.badges.contains(GameBadges.landmarks10), isTrue);
      });

      test('streak_7 unlocks on the 7th consecutive day', () {
        final days = List.generate(6, (i) => '2026-01-0${i + 1}');
        final before = reduceAll(
          days.map((d) => ev(GameEventTypes.streakUpdated, t0, {'day': d})),
        );
        expect(before.badges.contains(GameBadges.streak7), isFalse);

        final withSeventh = reduceAll(
          [
            ...days,
            '2026-01-07',
          ].map((d) => ev(GameEventTypes.streakUpdated, t0, {'day': d})),
        );
        expect(withSeventh.badges.contains(GameBadges.streak7), isTrue);
      });

      test('streak_7, once unlocked, is never revoked by a later gap', () {
        final events = [
          ...List.generate(7, (i) => '2026-01-0${i + 1}'),
          '2026-02-01', // big gap: streakDays resets to 1
        ].map((d) => ev(GameEventTypes.streakUpdated, t0, {'day': d}));
        final s = reduceAll(events);
        expect(s.streakDays, 1);
        expect(s.badges.contains(GameBadges.streak7), isTrue);
      });

      test('quartier_25 is never auto-derived by this reducer', () {
        // Even with huge cell-reveal activity, this reducer has no notion of
        // quartiers, so it must never invent the badge on its own.
        final s = reduceAll([
          ev(GameEventTypes.cellRevealed, t0, {
            'cells': List.generate(1000, (i) => 'cell-$i'),
          }),
        ]);
        expect(s.badges.contains(GameBadges.quartier25), isFalse);
      });
    },
  );

  group('streak_updated: reorder-invariant, set-based consecutive-day logic', () {
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
      final s = reduceAll([streak('2026-01-01'), streak('2026-02-15')]);
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

    test(
      'out-of-order delivery yields the same result as in-order delivery',
      () {
        final inOrder = reduceAll(
          ['2026-01-01', '2026-01-02', '2026-01-03', '2026-01-04'].map(streak),
        );
        final scrambled = reduceAll(
          ['2026-01-03', '2026-01-01', '2026-01-04', '2026-01-02'].map(streak),
        );
        expect(scrambled.streakDays, inOrder.streakDays);
        expect(scrambled.streakDays, 4);
        expect(scrambled.lastActivityDay, inOrder.lastActivityDay);
      },
    );

    test('duplicate deliveries in any order do not inflate the streak', () {
      final s = reduceAll([
        streak('2026-01-01'),
        streak('2026-01-02'),
        streak('2026-01-01'), // re-delivered
        streak('2026-01-02'), // re-delivered
      ]);
      expect(s.streakDays, 2);
    });

    test(
      'out-of-order delivery with a gap still reflects the run ending at the max day',
      () {
        // Days 1,2 then 4,5 (gap at 3): the run ending at the max day (5) is
        // just {4,5} -> length 2, regardless of the order events arrive in.
        final s = reduceAll(
          ['2026-01-05', '2026-01-01', '2026-01-04', '2026-01-02'].map(streak),
        );
        expect(s.streakDays, 2);
        expect(s.lastActivityDay, DateTime.utc(2026, 1, 5));
      },
    );

    test(
      'a bare date payload is pure-string/DST-safe: no local-timezone shift applied',
      () {
        // Regardless of what timezone concept might apply elsewhere, a bare
        // 'YYYY-MM-DD' always parses to that exact UTC calendar date.
        final s = reduceAll([streak('2026-03-29'), streak('2026-03-30')]);
        expect(s.lastActivityDay, DateTime.utc(2026, 3, 30));
        expect(s.streakDays, 2);
      },
    );

    test('a payload containing a full ISO datetime (T marker) is rejected', () {
      final s = reduceAll([
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01T00:00:00'}),
      ]);
      expect(s.streakDays, 0);
      expect(s.lastActivityDay, isNull);
    });

    test('a payload containing a Z (UTC) marker is rejected', () {
      final s = reduceAll([
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01Z'}),
      ]);
      expect(s.streakDays, 0);
    });

    test(
      'a rejected malformed day does not disturb an already-valid streak',
      () {
        final s = reduceAll([
          streak('2026-01-01'),
          ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-02T00:00:00Z'}),
        ]);
        expect(s.streakDays, 1);
      },
    );
  });

  group('cell_revealed', () {
    test(
      'with no payload at all, defaults to bumping the legacy counter by 1',
      () {
        final s = reduceAll([
          ev(GameEventTypes.cellRevealed, t0, const {}),
          ev(GameEventTypes.cellRevealed, t0, const {}),
        ]);
        expect(s.cellsRevealed, 2);
        expect(s.revealedCellKeys, isEmpty);
      },
    );

    test('a legacy count payload adds a batch to the counter at once', () {
      final s = reduceAll([
        ev(GameEventTypes.cellRevealed, t0, {'count': 7}),
      ]);
      expect(s.cellsRevealed, 7);
      expect(s.revealedCellKeys, isEmpty);
    });

    test(
      'a cells payload adds distinct cell keys and cellsRevealed tracks the set size',
      () {
        final s = reduceAll([
          ev(GameEventTypes.cellRevealed, t0, {
            'cells': ['1:1', '1:2', '1:3'],
          }),
        ]);
        expect(s.revealedCellKeys, {'1:1', '1:2', '1:3'});
        expect(s.cellsRevealed, 3);
      },
    );

    test('re-reporting an already-revealed cell key does not double count', () {
      final s = reduceAll([
        ev(GameEventTypes.cellRevealed, t0, {
          'cells': ['1:1', '1:2'],
        }),
        ev(GameEventTypes.cellRevealed, t0, {
          'cells': ['1:2', '1:3'],
        }),
      ]);
      expect(s.revealedCellKeys, {'1:1', '1:2', '1:3'});
      expect(s.cellsRevealed, 3);
    });
  });

  group('edge_covered_batch', () {
    test('accumulates the total km of each trip batch', () {
      final s = reduceAll([
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 2.5}),
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 1.5}),
      ]);
      expect(s.totalKm, 4.0);
    });
  });

  group('loop_completed', () {
    test('increments loopsCompleted', () {
      final s = reduceAll([
        ev(GameEventTypes.loopCompleted, t0, const {}),
        ev(GameEventTypes.loopCompleted, t0, const {}),
      ]);
      expect(s.loopsCompleted, 2);
    });
  });

  group('event id dedup (essential for M5 sync re-delivery)', () {
    test('the exact same event id delivered twice is only applied once', () {
      final e = GameEvent(
        id: 'dup-1',
        ts: t0,
        type: GameEventTypes.landmarkVisited,
        payload: const {'poiId': 'bank-1', 'kind': 'coins'},
      );
      final s = reduceAll([e, e]); // literally the same event object twice
      expect(s.coins, 100); // not 100+100
      expect(s.landmarksVisited, 1);
    });

    test(
      'two distinct events with the same id (re-sent payload) also count once',
      () {
        final first = GameEvent(
          id: 'same-id',
          ts: t0,
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 30},
        );
        final resend = GameEvent(
          id: 'same-id',
          ts: t0,
          type: GameEventTypes.coinsEarned,
          payload: const {'amount': 30},
        );
        final s = reduceAll([first, resend]);
        expect(s.coins, 30);
      },
    );
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

    test(
      'a malformed event does not stop later valid events from applying',
      () {
        final s = reduceAll([
          ev(GameEventTypes.coinsEarned, t0, const {}), // malformed: skipped
          ev(GameEventTypes.coinsEarned, t0, {'amount': 5}),
        ]);
        expect(s.coins, 5);
      },
    );
  });

  group('ordering (reduceAll sorts by (ts, id), M5 Task 4)', () {
    test('two rewarded coin visits fed in reverse-append order still cooldown '
        'correctly by ts, not by list/append position', () {
      final early = ev(GameEventTypes.landmarkVisited, t0, {
        'poiId': 'bank-1',
        'kind': 'coins',
      });
      final late = ev(
        GameEventTypes.landmarkVisited,
        t0.add(const Duration(hours: 25)),
        {'poiId': 'bank-1', 'kind': 'coins'},
      );
      // Appended out of chronological order — exactly what an M5
      // SyncEngine merge can leave in the local journal (see
      // sync/sync_engine.dart): `late` first, `early` second.
      final outOfOrder = reduceAll([late, early]);
      final inOrder = reduceAll([early, late]);
      expect(outOfOrder, inOrder);
      expect(outOfOrder.coins, 100 + 50); // both rewarded, 25h apart
    });

    test(
      'a visit appended out of order but within 24h of the '
      'chronologically-earlier one still earns nothing for the later visit',
      () {
        final early = ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'bank-1',
          'kind': 'coins',
        });
        final late = ev(
          GameEventTypes.landmarkVisited,
          t0.add(const Duration(hours: 1)),
          {'poiId': 'bank-1', 'kind': 'coins'},
        );
        final s = reduceAll([late, early]); // append order reversed
        expect(s.coins, 100); // only the ts-earlier visit was rewarded
        expect(s.visitCountByPoi['bank-1::coins'], 1);
      },
    );

    test('an energy visit appended out of order still respects the 6h '
        'cooldown by ts, not by append position', () {
      // Three distinct ts (no ties, so this isolates the ts-sort itself
      // from the id tiebreak covered by the test below).
      final drain = ev(GameEventTypes.energyChanged, t0, {'delta': -50});
      final early = ev(
        GameEventTypes.landmarkVisited,
        t0.add(const Duration(minutes: 1)),
        {'poiId': 'cafe-1', 'kind': 'energy', 'subkind': 'cafe'},
      );
      final late = ev(
        GameEventTypes.landmarkVisited,
        t0.add(const Duration(hours: 1)),
        {'poiId': 'cafe-1', 'kind': 'energy', 'subkind': 'cafe'},
      );
      final s = reduceAll([late, drain, early]); // fully scrambled append
      // ts order is drain, early, late: 100 - 50 (drain) + 25 (cafe,
      // `early`) = 75; `late` is only 59min after `early`, inside the 6h
      // cooldown, so it restores nothing.
      expect(s.energy, 75);
    });

    test('(ts, id) is a total order: two events sharing the same ts break '
        'ties by id, deterministically, regardless of append order', () {
      final a = GameEvent(
        id: 'aaa',
        ts: t0,
        type: GameEventTypes.coinsEarned,
        payload: const {'amount': 1},
      );
      final b = GameEvent(
        id: 'bbb',
        ts: t0,
        type: GameEventTypes.coinsEarned,
        payload: const {'amount': 2},
      );
      // coins_earned is itself order-insensitive (pure addition), so this
      // only pins that same-ts events never get lost or double-applied
      // regardless of append order — the id tiebreak matters for reducers
      // like the coins cooldown above, covered by the tests above.
      expect(reduceAll([a, b]).coins, 3);
      expect(reduceAll([b, a]).coins, 3);
    });
  });

  group('type-precedence determinism (fix round 1, Task 4 review C3)', () {
    test('a realistic trip (2 xp_earned + 1 energy_changed, all same ts) '
        'converges on the identical GameState across every permutation — '
        'ids are chosen so the OLD (ts, id)-only tiebreak would have put the '
        'drain first every time (it sorts lowest), yet the multiplier is '
        'still x1.5, proving the type-precedence tier — not id luck — is '
        'what decides it now', () {
      final tripTs = t0;
      final xpKm = GameEvent(
        id: 'a-xp-km', // would have sorted 2nd under old (ts, id) alone
        ts: tripTs,
        type: GameEventTypes.xpEarned,
        payload: const {'amount': 30.0, 'preMultiplied': false},
      );
      final xpCells = GameEvent(
        id: 'b-xp-cells', // would have sorted 3rd (last) under old rules
        ts: tripTs,
        type: GameEventTypes.xpEarned,
        payload: const {'amount': 10.0, 'preMultiplied': false},
      );
      final drain = GameEvent(
        id: '0-drain', // would have sorted 1st (first!) under old rules
        ts: tripTs,
        type: GameEventTypes.energyChanged,
        payload: const {'delta': -20.0},
      );
      final permutations = [
        [xpKm, xpCells, drain],
        [xpKm, drain, xpCells],
        [xpCells, xpKm, drain],
        [xpCells, drain, xpKm],
        [drain, xpKm, xpCells],
        [drain, xpCells, xpKm],
      ];
      GameState? expected;
      for (final perm in permutations) {
        final s = reduceAll(perm);
        expected ??= s;
        expect(s, expected);
      }
      // Energy is 100 going into both xp_earned events (drain always
      // applies last, regardless of append order): 30*1.5 + 10*1.5 = 60.
      expect(expected!.xp, 60);
      expect(expected.energy, 80); // 100 - 20, order-independent
    });

    test('M4 identity: a realistic ExplorationRecorder-shaped trip batch, '
        'with non-sequential ids (not construction-order-sortable, unlike '
        "this file's `ev` helper — exactly what a real Uuid().v4() gives no "
        'guarantee about), replays to the outcome production emitters have '
        'always produced: xp_earned before the energy drain', () {
      final tripTs = DateTime.utc(2026, 3, 15, 8, 0);
      final events = [
        GameEvent(
          id: 'f47ac10b',
          ts: tripTs,
          type: GameEventTypes.edgeCoveredBatch,
          payload: const {'km': 5.0},
        ),
        GameEvent(
          id: '3d813cea',
          ts: tripTs,
          type: GameEventTypes.streakUpdated,
          payload: const {'day': '2026-03-15'},
        ),
        GameEvent(
          id: '2ba1dc7e',
          ts: tripTs,
          type: GameEventTypes.xpEarned,
          payload: const {'amount': 50.0, 'preMultiplied': false},
        ),
        GameEvent(
          id: '11e73f1d',
          ts: tripTs,
          type: GameEventTypes.energyChanged,
          payload: const {'delta': -20.0},
        ),
      ];
      final s = reduceAll(events);
      expect(s.totalKm, 5.0);
      expect(s.xp, 75); // 50 * x1.5 (energy still 100 going in)
      expect(s.energy, 80);
    });
  });

  group('GameVisitConsumer-shaped ordering (fix round 2, Task 4 review C3 '
      'remainder)', () {
    test('landmark_visited (energy kind) + xp_earned, same ts, in either '
        "journal order: the visit's refill is always visible to the "
        "multiplier — matches GameVisitConsumer's own live fold order "
        '(landmark_visited appended, then xp_earned)', () {
      final earlierTs = t0.subtract(const Duration(minutes: 1));
      final drainToFortyFive = ev(GameEventTypes.energyChanged, earlierTs, {
        'delta': -55,
      }); // 100 -> 45
      final visited = ev(GameEventTypes.landmarkVisited, t0, {
        'poiId': 'cafe-1',
        'kind': 'energy',
        'subkind': 'cafe',
      });
      final xpEarned = ev(GameEventTypes.xpEarned, t0, {
        'amount': 25,
        'preMultiplied': false,
      });

      final visitedFirst = reduceAll([drainToFortyFive, visited, xpEarned]);
      final xpFirst = reduceAll([drainToFortyFive, xpEarned, visited]);

      expect(visitedFirst, xpFirst);
      // Refill always applies first: 45 + 25 (cafe) = 70 -> x1.5 ->
      // round(25 * 1.5) = 38. If xp_earned had applied first instead
      // (the fix-round-1 bug this pins), it would have read energy 45
      // (x1.0 tier) and yielded 25, not 38.
      expect(visitedFirst.xp, 38);
      expect(visitedFirst.energy, 70);
    });

    test('M4/live identity: reduceAll (replay, from a journal-order list) '
        "produces the SAME state as GameVisitConsumer's own live fold "
        '(reduceOne applied in emitted order) for a realistic visit batch '
        'with non-sequential, deliberately-backwards ids', () {
      final visitTs = DateTime.utc(2026, 3, 20, 14, 30);
      final earlierTs = visitTs.subtract(const Duration(hours: 2));
      final priorDrain = GameEvent(
        id: '5f2c8e91',
        ts: earlierTs,
        type: GameEventTypes.energyChanged,
        payload: const {'delta': -60.0},
      ); // 100 -> 40
      // Ids deliberately backwards alphabetically relative to emit
      // order, so a stray reliance on id-as-tiebreak (rather than the
      // landmark_visited tier) would sort `xpEarned` BEFORE `visited`.
      final visited = GameEvent(
        id: 'zzz-visit',
        ts: visitTs,
        type: GameEventTypes.landmarkVisited,
        payload: const {
          'poiId': 'chapel-1',
          'kind': 'energy',
          'subkind': 'restaurant',
        },
      );
      final xpEarned = GameEvent(
        id: 'aaa-xp',
        ts: visitTs,
        type: GameEventTypes.xpEarned,
        payload: const {'amount': 25.0, 'preMultiplied': false},
      );

      // "Live": exactly what GameVisitConsumer._process itself does —
      // fold events one at a time via reduceOne, in emitted order.
      var live = const GameState();
      for (final e in [priorDrain, visited, xpEarned]) {
        live = reduceOne(live, e);
      }

      // "Replay": reduceAll from a DIFFERENT (journal/merge) order —
      // a real journal can hold these in any order once M5 sync has
      // merged events from elsewhere.
      final replay = reduceAll([xpEarned, priorDrain, visited]);

      expect(replay, live);
      // 100 - 60 = 40; +40 (restaurant refill) = 80; xp: 80 -> x1.5 ->
      // round(25 * 1.5) = 38.
      expect(replay.xp, 38);
      expect(replay.energy, 80);
    });

    test('a same-ts trio (landmark_visited energy-kind + xp_earned + '
        'energy_changed) converges on the identical GameState across '
        'every permutation, with the tier order — visited, then xp, then '
        'drain — holding regardless of list position', () {
      final earlierTs = t0.subtract(const Duration(hours: 1));
      final priorDrain = ev(GameEventTypes.energyChanged, earlierTs, {
        'delta': -55,
      }); // 100 -> 45, outside the permuted trio

      final visited = GameEvent(
        id: 'zzz-visit',
        ts: t0,
        type: GameEventTypes.landmarkVisited,
        payload: const {'poiId': 'cafe-1', 'kind': 'energy', 'subkind': 'cafe'},
      );
      final xpEarned = GameEvent(
        id: 'aaa-xp',
        ts: t0,
        type: GameEventTypes.xpEarned,
        payload: const {'amount': 20.0, 'preMultiplied': false},
      );
      final drain = GameEvent(
        id: 'mmm-drain',
        ts: t0,
        type: GameEventTypes.energyChanged,
        payload: const {'delta': -10.0},
      );

      final trioPermutations = [
        [visited, xpEarned, drain],
        [visited, drain, xpEarned],
        [xpEarned, visited, drain],
        [xpEarned, drain, visited],
        [drain, visited, xpEarned],
        [drain, xpEarned, visited],
      ];

      GameState? expected;
      for (final perm in trioPermutations) {
        final s = reduceAll([priorDrain, ...perm]);
        expected ??= s;
        expect(s, expected);
      }

      // 45 (after priorDrain) -> visited (+25 cafe) -> 70 -> xp
      // (round(20 * 1.5) = 30) -> drain (-10) -> 60.
      expect(expected!.xp, 30);
      expect(expected.energy, 60);
    });
  });

  group('GameState equality and replay idempotence', () {
    test('two states with identical field values compare equal', () {
      final events = [
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}),
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'p1',
          'kind': 'reveal',
        }),
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01'}),
      ];
      expect(reduceAll(events), reduceAll(events));
      expect(reduceAll(events).hashCode, reduceAll(events).hashCode);
    });

    test('reduceAll(events) == reduceAll(events): replay is idempotent', () {
      final events = [
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 12}),
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'bank-1',
          'kind': 'coins',
        }),
        ev(GameEventTypes.xpEarned, t0, {'amount': 10}),
        ev(GameEventTypes.loopCompleted, t0, const {}),
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01'}),
        ev(GameEventTypes.cellRevealed, t0, {
          'cells': ['1:1', '1:2'],
        }),
      ];
      final a = reduceAll(events);
      final b = reduceAll(events);
      expect(a, b);
    });

    test('states that differ in even one field compare unequal', () {
      final a = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 10}),
      ]);
      final b = reduceAll([
        ev(GameEventTypes.coinsEarned, t0, {'amount': 11}),
      ]);
      expect(a == b, isFalse);
    });
  });

  group('exposed collections are unmodifiable', () {
    test('mutating badges from outside throws', () {
      final s = reduceAll([
        ev(GameEventTypes.badgeUnlocked, t0, {'badge': 'x'}),
      ]);
      expect(() => s.badges.add('y'), throwsUnsupportedError);
    });

    test('mutating visitedPoiIds from outside throws', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'p1',
          'kind': 'reveal',
        }),
      ]);
      expect(() => s.visitedPoiIds.add('p2'), throwsUnsupportedError);
    });

    test('mutating lastVisitByPoi from outside throws', () {
      final s = reduceAll([
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'bank-1',
          'kind': 'coins',
        }),
      ]);
      expect(() => s.lastVisitByPoi['x'] = t0, throwsUnsupportedError);
    });

    test('mutating activeDays from outside throws', () {
      final s = reduceAll([
        ev(GameEventTypes.streakUpdated, t0, {'day': '2026-01-01'}),
      ]);
      expect(() => s.activeDays.add('2099-01-01'), throwsUnsupportedError);
    });

    test('mutating revealedCellKeys from outside throws', () {
      final s = reduceAll([
        ev(GameEventTypes.cellRevealed, t0, {
          'cells': ['1:1'],
        }),
      ]);
      expect(() => s.revealedCellKeys.add('9:9'), throwsUnsupportedError);
    });
  });

  group('reduceOne (fix round 1, Task 5 review: single-step fold seam)', () {
    test('folding events one at a time via reduceOne matches reduceAll', () {
      final events = [
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'bank-1',
          'kind': 'coins',
        }),
        ev(GameEventTypes.xpEarned, t0, {'amount': 25, 'preMultiplied': false}),
        ev(GameEventTypes.energyChanged, t0, {'delta': -4}),
      ];
      var folded = const GameState();
      for (final e in events) {
        folded = reduceOne(folded, e);
      }
      expect(folded, reduceAll(events));
    });

    test('reduceOne also tolerates a malformed payload, same as reduceAll', () {
      final state = reduceOne(
        const GameState(),
        ev(GameEventTypes.landmarkVisited, t0, {
          'poiId': 'x',
          'kind': 'energy',
        }),
      ); // no subkind
      expect(state.visitedPoiIds, contains('x'));
      expect(state.energy, 100);
    });

    test('reduceOne re-evaluates derived badges after the single event, '
        'same as reduceAll does after each of its own', () {
      final state = reduceOne(
        const GameState(),
        ev(GameEventTypes.edgeCoveredBatch, t0, {'km': 5.0}),
      );
      expect(state.badges, contains(GameBadges.firstTrip));
    });
  });
}
