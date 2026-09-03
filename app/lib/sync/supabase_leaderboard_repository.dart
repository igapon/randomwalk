import '../leaderboard/repository.dart';
import '../settings/identity.dart';
import 'backend.dart';

/// [LeaderboardRepository] backed by [SyncBackend] (`upsertProfile` +
/// `topProfiles`) instead of the anonymous `drive.lmqc.fr` HTTP API —
/// the M5 decision that a signed-in, configured account switches the
/// leaderboard to the Supabase-backed profiles table while keeping the
/// SAME [LeaderboardRepository] interface, so `leaderboard/leaderboard_
/// screen.dart` needs no changes at all.
///
/// **Identity is deliberately NOT migrated.** [PlayerIdentity.userId] (the
/// device-generated anonymous id `settings/identity.dart` persists, used
/// against `drive.lmqc.fr`) is kept locally exactly as-is and is never sent
/// here or reconciled with the backend account's own uid — per
/// `task-4-brief.md`'s explicit decision ("L'ancien user_id anonyme est
/// conservé localement (pas de migration serveur drive→supabase,
/// documenté)"). Only [PlayerIdentity.pseudo] crosses over, as the
/// display name on the Supabase-backed profile.
///
/// **`fetch`'s `userId` parameter is ignored.** [LeaderboardRepository.
/// fetch] takes the anonymous `drive.lmqc.fr` id so that backend can find
/// "me" among the rows it returns; [SyncBackend.topProfiles] has no
/// equivalent (a [LeaderboardRow] carries only `pseudo`/`totalKm`/`rank`,
/// no stable id — see that class's dartdoc), so there is no way to
/// reliably tell "me" apart from a same-pseudo stranger. [fetch] always
/// returns `me: null` rather than guessing by pseudo match, which could
/// silently show a different account's row as the caller's own — an open
/// concern, documented here and in `task-4-report.md`, rather than solved
/// by a heuristic that can be wrong.
class SupabaseLeaderboardRepository implements LeaderboardRepository {
  final SyncBackend backend;

  /// How many rows [topProfiles] is asked for — also what [submit] scans
  /// to find the caller's own new rank (see that method's doc comment).
  final int limit;

  const SupabaseLeaderboardRepository(this.backend, {this.limit = 100});

  /// Upserts [id.pseudo]/[totalKm] to the signed-in user's profile, then
  /// re-fetches the top [limit] rows to find the resulting rank by
  /// matching [id.pseudo] — [SyncBackend.upsertProfile] doesn't itself
  /// return a rank (Task 3's contract only has it on [LeaderboardRow], via
  /// [SyncBackend.topProfiles]'s server-computed ranking). A pseudo not
  /// found in that page (outside the top [limit]) falls back to
  /// `rows.length + 1` — an approximation, not the true rank, but strictly
  /// worse than every returned row, which is the only thing callers
  /// currently do with [SubmitResult.rank] (display it).
  @override
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm) async {
    await backend.upsertProfile(pseudo: id.pseudo, totalKm: totalKm);
    final rows = await backend.topProfiles(limit: limit);
    final mine = rows.where((r) => r.pseudo == id.pseudo);
    final rank = mine.isEmpty ? rows.length + 1 : mine.first.rank;
    return SubmitResult(rank: rank, totalKm: totalKm);
  }

  @override
  Future<LeaderboardData> fetch(String userId) async {
    final rows = await backend.topProfiles(limit: limit);
    return LeaderboardData(
      top: [
        for (final r in rows)
          LeaderboardEntry(pseudo: r.pseudo, totalKm: r.totalKm, rank: r.rank),
      ],
      me: null, // See class dartdoc: no reliable "me" without a stable id.
    );
  }
}
