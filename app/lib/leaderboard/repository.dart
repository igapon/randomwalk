import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import '../settings/identity.dart';

/// Raised when the leaderboard backend returns a non-200 response.
class LeaderboardException implements Exception {
  final String message;
  const LeaderboardException(this.message);

  @override
  String toString() => 'LeaderboardException: $message';
}

class LeaderboardEntry {
  final String pseudo;
  final double totalKm;
  final int rank;
  const LeaderboardEntry(
      {required this.pseudo, required this.totalKm, required this.rank});
  factory LeaderboardEntry.fromJson(Map<String, dynamic> j) => LeaderboardEntry(
      pseudo: j['pseudo'] as String,
      totalKm: (j['total_km'] as num).toDouble(),
      rank: j['rank'] as int);
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
    final resp = await client.post(Uri.parse('$base/v1/score'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(
            {'user_id': id.userId, 'pseudo': id.pseudo, 'total_km': totalKm}));
    if (resp.statusCode != 200) {
      throw LeaderboardException('submit: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return SubmitResult(
        rank: j['rank'] as int, totalKm: (j['total_km'] as num).toDouble());
  }

  @override
  Future<LeaderboardData> fetch(String userId) async {
    final resp =
        await client.get(Uri.parse('$base/v1/leaderboard?user_id=$userId'));
    if (resp.statusCode != 200) {
      throw LeaderboardException('fetch: HTTP ${resp.statusCode}');
    }
    final j = jsonDecode(resp.body) as Map<String, dynamic>;
    return LeaderboardData(
      top: [
        for (final e in j['top'] as List<dynamic>)
          LeaderboardEntry.fromJson(e as Map<String, dynamic>)
      ],
      me: j['me'] == null
          ? null
          : LeaderboardEntry.fromJson(j['me'] as Map<String, dynamic>),
    );
  }
}

final leaderboardRepositoryProvider = Provider<LeaderboardRepository>(
    (ref) => HttpLeaderboardRepository(http.Client()));
