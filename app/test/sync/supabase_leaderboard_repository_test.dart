import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/settings/identity.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/supabase_leaderboard_repository.dart';

import '../support/fake_sync_backend.dart';

void main() {
  group('submit', () {
    test('falls back to rows.length + 1 when the pseudo is not found in '
        'topProfiles (fix round 1, Task 4 review I4: this was previously '
        "mis-named as covering the real `mine.first.rank` branch, which it "
        "doesn't — see the test below for that one)", () async {
      final backend = FakeSyncBackend();
      final repo = SupabaseLeaderboardRepository(backend, limit: 10);

      // The fake backend doesn't wire upsertProfile into topProfiles
      // (SyncBackend keeps those as independent calls), so this test
      // drives the exact contract SupabaseLeaderboardRepository uses:
      // it calls upsertProfile, then re-reads topProfiles.
      final result = await repo.submit(
        const PlayerIdentity(userId: 'anon-1', pseudo: 'iaro'),
        12.5,
      );

      expect(result.totalKm, 12.5);
      // No rows seeded on topProfiles, so 'iaro' isn't found: falls back
      // to rows.length + 1 == 1.
      expect(result.rank, 1);
    });

    test('returns the REAL rank found in topProfiles when the submitted '
        'pseudo is present in the page (fix round 1, Task 4 review I4 — the '
        "method's actual purpose, previously uncovered)", () async {
      final backend = _CapturingBackend(
        rows: const [
          LeaderboardRow(pseudo: 'a', totalKm: 30, rank: 1),
          LeaderboardRow(pseudo: 'iaro', totalKm: 20, rank: 2),
          LeaderboardRow(pseudo: 'b', totalKm: 10, rank: 3),
        ],
      );
      final repo = SupabaseLeaderboardRepository(backend, limit: 10);

      final result = await repo.submit(
        const PlayerIdentity(userId: 'anon-1', pseudo: 'iaro'),
        20.0,
      );

      expect(result.rank, 2); // NOT rows.length + 1 (4) — the real rank
      expect(result.totalKm, 20.0);
    });

    test(
      'the anonymous drive.lmqc.fr userId is never sent to upsertProfile',
      () async {
        final backend = _CapturingBackend();
        final repo = SupabaseLeaderboardRepository(backend);
        await repo.submit(
          const PlayerIdentity(userId: 'anon-should-not-leak', pseudo: 'iaro'),
          5.0,
        );
        expect(backend.upsertedPseudo, 'iaro');
        expect(backend.upsertedTotalKm, 5.0);
      },
    );
  });

  group('fetch', () {
    test(
      'maps topProfiles rows to LeaderboardEntry, always with me: null',
      () async {
        final backend = _CapturingBackend();
        final repo = SupabaseLeaderboardRepository(backend);

        final data = await repo.fetch('anon-1');

        expect(data.top, hasLength(2));
        expect(data.top.first.pseudo, 'a');
        expect(data.top.first.rank, 1);
        expect(data.me, isNull);
      },
    );
  });
}

/// A [FakeSyncBackend] whose `topProfiles` returns a fixed, configurable
/// page of [rows] and which records what `upsertProfile` was called with.
class _CapturingBackend extends FakeSyncBackend {
  _CapturingBackend({
    this.rows = const [
      LeaderboardRow(pseudo: 'a', totalKm: 20, rank: 1),
      LeaderboardRow(pseudo: 'b', totalKm: 10, rank: 2),
    ],
  });

  final List<LeaderboardRow> rows;
  String? upsertedPseudo;
  double? upsertedTotalKm;

  @override
  Future<void> upsertProfile({
    required String pseudo,
    required double totalKm,
  }) async {
    upsertedPseudo = pseudo;
    upsertedTotalKm = totalKm;
  }

  @override
  Future<List<LeaderboardRow>> topProfiles({required int limit}) async => rows;
}
