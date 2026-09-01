import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../settings/identity.dart';
import '../sync/account_state.dart';
import '../sync/providers.dart';
import '../sync/supabase_leaderboard_repository.dart';

/// Raised when the leaderboard backend returns a non-200 response.
class LeaderboardException implements Exception {
  final String message;
  const LeaderboardException(this.message);

  @override
  String toString() => 'LeaderboardException: $message';
}

class LeaderboardEntry {
  /// Nullable for backward compat with a server response that predates the
  /// server including it (or a `me` entry that still omits it) — callers
  /// matching "me" should treat a `null` userId as "can't tell", not "not
  /// me".
  final String? userId;
  final String pseudo;
  final double totalKm;
  final int rank;
  const LeaderboardEntry({
    this.userId,
    required this.pseudo,
    required this.totalKm,
    required this.rank,
  });
  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
    userId: j['user_id'] as String?,
    pseudo: j['pseudo'] as String,
    totalKm: (j['total_km'] as num).toDouble(),
    rank: j['rank'] as int,
  );
}

class LeaderboardData {
  final List<LeaderboardEntry> top;
  final LeaderboardEntry? me;
  const LeaderboardData({required this.top, required this.me});
}

class SubmitResult {
  final int rank;
  final double totalKm;
  const SubmitResult({required this.rank, required this.totalKm});
}

abstract class LeaderboardRepository {
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm);
  Future<LeaderboardData> fetch(String userId);
}

/// HTTP client for the `drive.lmqc.fr` leaderboard backend (Task 2 contract).
class HttpLeaderboardRepository implements LeaderboardRepository {
  final http.Client client;
  final String base;
  HttpLeaderboardRepository(this.client, {this.base = 'https://drive.lmqc.fr'});

  @override
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm) async {
    final resp = await client.post(
      Uri.parse('$base/v1/score'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({
        'user_id': id.userId,
        'pseudo': id.pseudo,
        'total_km': totalKm,
      }),
    );
    if (resp.statusCode != 200) {
      throw LeaderboardException('submit: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return SubmitResult(
      rank: j['rank'] as int,
      totalKm: (j['total_km'] as num).toDouble(),
    );
  }

  @override
  Future<LeaderboardData> fetch(String userId) async {
    final resp = await client.get(
      Uri.parse('$base/v1/leaderboard?user_id=$userId'),
    );
    if (resp.statusCode != 200) {
      throw LeaderboardException('fetch: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return LeaderboardData(
      top: [
        for (final e in j['top'] as List<dynamic>)
          LeaderboardEntry.fromJson(e as Map<String, dynamic>),
      ],
      me: j['me'] == null
          ? null
          : LeaderboardEntry.fromJson(j['me'] as Map<String, dynamic>),
    );
  }
}

/// The app's single [LeaderboardRepository] — `drive.lmqc.fr` (anonymous)
/// by default, exactly as in M4. M5's decision (`task-4-brief.md`): once
/// signed in on a configured backend, the SAME interface switches to
/// [SupabaseLeaderboardRepository] instead — every existing caller
/// (`leaderboard/leaderboard_screen.dart`, `main.dart`'s `_onSessionEnded`)
/// needs no changes, they just start talking to a different backend. See
/// [SupabaseLeaderboardRepository]'s own dartdoc for what does (and
/// deliberately doesn't) carry over from the anonymous identity.
final leaderboardRepositoryProvider = Provider<LeaderboardRepository>((ref) {
  final account = ref.watch(accountStateProvider);
  if (account.phase == AccountPhase.signedIn) {
    return SupabaseLeaderboardRepository(ref.watch(syncBackendProvider));
  }
  final client = http.Client();
  ref.onDispose(client.close);
  return HttpLeaderboardRepository(client);
});
