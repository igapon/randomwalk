import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:randomwalk/leaderboard/repository.dart';
import 'package:randomwalk/settings/identity.dart';

void main() {
  test('submit posts identity and km, parses rank', () async {
    late http.Request captured;
    final client = MockClient((req) async {
      captured = req;
      return http.Response(jsonEncode({'rank': 3, 'total_km': 42.0}), 200);
    });
    final repo = HttpLeaderboardRepository(client, base: 'https://x.test');
    final res = await repo.submit(
        const PlayerIdentity(userId: 'u-12345678', pseudo: 'iaro'), 42.0);
    expect(captured.url.toString(), 'https://x.test/v1/score');
    expect(jsonDecode(captured.body)['pseudo'], 'iaro');
    expect(res.rank, 3);
  });

  test('fetch parses top and me', () async {
    final client = MockClient((req) async => http.Response(
        jsonEncode({
          'top': [
            {'pseudo': 'a', 'total_km': 10.0, 'rank': 1}
          ],
          'me': {'pseudo': 'iaro', 'total_km': 5.0, 'rank': 2}
        }),
        200));
    final repo = HttpLeaderboardRepository(client, base: 'https://x.test');
    final data = await repo.fetch('u-12345678');
    expect(data.top.single.pseudo, 'a');
    expect(data.me!.rank, 2);
  });

  test('fetch surfaces http errors as LeaderboardException', () async {
    final repo = HttpLeaderboardRepository(
        MockClient((_) async => http.Response('boom', 500)),
        base: 'https://x.test');
    expect(() => repo.fetch('u-12345678'),
        throwsA(isA<LeaderboardException>()));
  });
}
