import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/leaderboard/leaderboard_screen.dart';
import 'package:randomwalk/leaderboard/repository.dart';
import 'package:randomwalk/settings/identity.dart';
import 'package:randomwalk/theme/theme.dart';

class _FakeIdentityStore implements IdentityStore {
  @override
  Future<PlayerIdentity> get() async =>
      const PlayerIdentity(userId: 'u-test', pseudo: 'Testeur');

  @override
  Future<void> setPseudo(String pseudo) async {}
}

class _FakeRepo implements LeaderboardRepository {
  _FakeRepo(this._fetchImpl);
  final Future<LeaderboardData> Function() _fetchImpl;

  @override
  Future<SubmitResult> submit(PlayerIdentity id, double totalKm) async =>
      const SubmitResult(rank: 1, totalKm: 0);

  @override
  Future<LeaderboardData> fetch(String userId) => _fetchImpl();
}

Widget _app(LeaderboardRepository repo) => ProviderScope(
      overrides: [
        leaderboardRepositoryProvider.overrideWithValue(repo),
        identityStoreProvider.overrideWithValue(_FakeIdentityStore()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const LeaderboardScreen(),
      ),
    );

void main() {
  // TotalDistanceStore.totalKm() reads shared_preferences.
  SharedPreferences.setMockInitialValues({});

  testWidgets('shows a display-styled header and the loaded list',
      (tester) async {
    final repo = _FakeRepo(() async => const LeaderboardData(
          top: [LeaderboardEntry(pseudo: 'Ana', totalKm: 12, rank: 1)],
          me: null,
        ));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.text('Classement'), findsOneWidget);
    expect(find.text('Ana'), findsOneWidget);
  });

  testWidgets(
      'pull-to-refresh keeps the old list visible instead of a full-screen spinner',
      (tester) async {
    final pending = Completer<LeaderboardData>();
    var calls = 0;
    final repo = _FakeRepo(() {
      calls++;
      if (calls == 1) {
        return Future.value(const LeaderboardData(
          top: [LeaderboardEntry(pseudo: 'Ana', totalKm: 12, rank: 1)],
          me: null,
        ));
      }
      return pending.future; // Refresh: stays in-flight until we complete it.
    });

    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();
    expect(find.text('Ana'), findsOneWidget);

    await tester.fling(find.byType(ListView), const Offset(0, 300), 1000);
    await tester.pump();

    // While the refresh is still pending, the previously-loaded row must
    // still be on screen — this used to be replaced by a full-screen
    // spinner (hygiene fix, task 12).
    expect(find.text('Ana'), findsOneWidget);

    pending.complete(const LeaderboardData(
      top: [LeaderboardEntry(pseudo: 'Ana', totalKm: 12, rank: 1)],
      me: null,
    ));
    await tester.pumpAndSettle();
  });

  testWidgets('a non-200 backend response reads as "momentarily unavailable", not "offline"',
      (tester) async {
    final repo =
        _FakeRepo(() async => throw const LeaderboardException('fetch: HTTP 500'));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining('momentanément indisponible'), findsOneWidget);
    expect(find.textContaining('hors ligne'), findsNothing);
  });

  testWidgets('a network-level failure keeps the honest "offline" copy', (tester) async {
    final repo = _FakeRepo(() async => throw Exception('socket unreachable'));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    expect(find.textContaining('hors ligne'), findsOneWidget);
  });

  testWidgets(
      'RefreshIndicator spinner is legible (not the ~1.7:1 yellow-on-paper default)',
      (tester) async {
    final repo = _FakeRepo(() async => const LeaderboardData(
          top: [LeaderboardEntry(pseudo: 'Ana', totalKm: 12, rank: 1)],
          me: null,
        ));
    await tester.pumpWidget(_app(repo));
    await tester.pumpAndSettle();

    final indicator = tester.widget<RefreshIndicator>(find.byType(RefreshIndicator));
    expect(indicator.color, isNot(const Color(0xFFF5B800)));
    expect(indicator.color, AppTheme.light.colorScheme.onSurface);
  });
}
