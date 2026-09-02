import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/history/trip_history_store.dart';
import 'package:randomwalk/settings/account_screen.dart';
import 'package:randomwalk/settings/local_purge.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/providers.dart';
import 'package:randomwalk/sync/sync_state_store.dart';
import 'package:randomwalk/tracking/permissions.dart';
import 'package:randomwalk/tracking/steps.dart';
import 'package:randomwalk/tracking/trip_snapshot.dart';
import 'package:randomwalk/trip/trip_controller.dart';
import 'package:randomwalk/valhalla/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_sync_backend.dart';
import '../support/temp_dir.dart';
import '../support/trip_fakes.dart';

void main() {
  // Task 6: the "Supprimer mon compte" flow's local-purge step opens an
  // EdgesStore (`covered_edges.db`) — same ambient-factory pattern as
  // `edges_store_test.dart`, needed here because these are otherwise
  // widget, not sqflite, tests.
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Directory tempDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('account_screen_test');
  });

  tearDown(() async {
    // gameStateProvider replays via loadStateFast (Task 5), which fires an
    // unawaited background checkpoint write on every read — tolerate that
    // write still being in flight (see deleteTempDirRetrying's dartdoc).
    await deleteTempDirRetrying(tempDir);
  });

  /// A minimal [TripController] for `_deleteAccount`'s `runLocalPurge` call
  /// (Task 6 review round 1, I1; widened round 2 to also cover
  /// `TripState.interrupted`) to read trip state off — same fakes
  /// `settings_screen_test.dart`'s own `buildTrip()` uses. Idle by default;
  /// [recording] starts a real trip, [interrupted] seeds a persisted
  /// still-recording snapshot with the tracker's service NOT running
  /// (`FakeTripTracker.running = false`) and calls `restore()` — the same
  /// path `TripController.restore` takes for a trip whose process died
  /// mid-recording (see that method's own dartdoc).
  Future<TripController> buildTrip({
    bool recording = false,
    bool interrupted = false,
  }) async {
    final tracker = FakeTripTracker();
    final trip = TripController(
      tracker: tracker,
      routeStore: MemoryRouteStore(),
      totalStore: FakeTotalDistanceStore(),
      finalisedTrips: MemoryFinalisedTripMemory(),
      ensurePermissions: () async => const TripPermissions(
        outcome: TripPermissionOutcome.ready,
        mode: TrackingMode.background,
      ),
      createStepCounter: (seed) =>
          SessionStepCounter(FakeStepSensor(), seed: seed),
      persistProfile: (_) async {},
      loadProfile: () async => null,
    );
    if (recording) {
      await trip.startTrip();
    } else if (interrupted) {
      tracker.persisted = TripSnapshot.starting(
        startedAt: DateTime.utc(2026, 8, 30, 9),
        profile: RoutingProfile.walk,
        routeBound: false,
      );
      tracker.running = false;
      await trip.restore();
    }
    return trip;
  }

  Future<void> pump(
    WidgetTester tester, {
    required FakeSyncBackend backend,
    required AccountState account,
    TripController? trip,
  }) async {
    final resolvedTrip = trip ?? await buildTrip();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncBackendProvider.overrideWithValue(backend),
          accountStateProvider.overrideWith((ref) => account),
          gameJournalProvider.overrideWith(
            (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
          ),
          tripControllerProvider.overrideWith((ref) => resolvedTrip),
        ],
        child: const MaterialApp(home: AccountScreen()),
      ),
    );
  }

  /// Taps [text] then lets any real async work it kicks off (backend
  /// calls, and — for signedIn/otp-verify actions — real `dart:io` journal
  /// reads/writes via `SyncEngine`) actually complete before returning: a
  /// button's `onPressed` fires an unawaited async method, so
  /// `testWidgets`' fake-clock `pump`/`pumpAndSettle` alone can't be relied
  /// on to observe its result (same issue `auto_sync_test.dart` hit) —
  /// `runAsync` runs in the real zone, where a short real wait is enough
  /// for this test's in-memory/local-file work.
  Future<void> tapAndWait(
    WidgetTester tester,
    String text, {
    Duration wait = const Duration(milliseconds: 100),
  }) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(text));
      await Future<void>.delayed(wait);
    });
    await tester.pumpAndSettle();
  }

  group('signedOut', () {
    testWidgets('shows the email field and requests an OTP on submit', (
      tester,
    ) async {
      final backend = FakeSyncBackend();
      await pump(
        tester,
        backend: backend,
        account: const AccountState.signedOut(),
      );

      await tester.enterText(find.byType(TextField), 'a@b.ch');
      await tapAndWait(tester, 'Recevoir un code');

      expect(find.textContaining('a@b.ch'), findsOneWidget);
      expect(find.text('Valider'), findsOneWidget); // now on otpSent
    });

    testWidgets('shows a French error message when signInWithOtp rejects', (
      tester,
    ) async {
      final backend = _SignInThrowsBackend(const SyncNetworkError('offline'));
      await pump(
        tester,
        backend: backend,
        account: const AccountState.signedOut(),
      );

      await tester.enterText(find.byType(TextField), 'a@b.ch');
      await tapAndWait(tester, 'Recevoir un code');

      expect(
        find.text('Connexion impossible. Réessayez plus tard.'),
        findsOneWidget,
      );
      expect(find.text('Valider'), findsNothing); // still signedOut
    });
  });

  group('otpSent', () {
    testWidgets(
      'a correct 6-digit code transitions to signedIn and shows the email',
      (tester) async {
        final backend = FakeSyncBackend()
          ..verifyOtpResult = const AuthUser(uid: 'u1', email: 'a@b.ch');
        await pump(
          tester,
          backend: backend,
          account: const AccountState.signedOut().otpRequested('a@b.ch'),
        );

        await tester.enterText(find.byType(TextField), '123456');
        await tapAndWait(tester, 'Valider');

        expect(find.text('Connecté'), findsOneWidget);
        expect(find.textContaining('a@b.ch'), findsOneWidget);
        expect(find.text('Se déconnecter'), findsOneWidget);
      },
    );

    testWidgets('an invalid code shows a French error and stays on otpSent', (
      tester,
    ) async {
      final backend = FakeSyncBackend();
      await pump(
        tester,
        backend: backend,
        account: const AccountState.signedOut().otpRequested('a@b.ch'),
      );

      await tester.enterText(find.byType(TextField), '000000');
      await tapAndWait(tester, 'Valider');

      // FakeSyncBackend.verifyOtp defaults to returning null (no user).
      expect(find.text('Code invalide.'), findsOneWidget);
      expect(find.text('Se déconnecter'), findsNothing);
    });

    testWidgets('Annuler returns to signedOut without calling the backend', (
      tester,
    ) async {
      final backend = FakeSyncBackend();
      await pump(
        tester,
        backend: backend,
        account: const AccountState.signedOut().otpRequested('a@b.ch'),
      );

      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      expect(find.text('Recevoir un code'), findsOneWidget);
    });
  });

  group('signedIn', () {
    testWidgets('the manual sync button records a last sync result', (
      tester,
    ) async {
      final backend = FakeSyncBackend();
      await pump(
        tester,
        backend: backend,
        account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
      );

      expect(
        find.text('Aucune synchronisation effectuée pour le moment.'),
        findsOneWidget,
      );

      await tapAndWait(tester, 'Synchroniser maintenant');

      expect(find.textContaining('Dernière synchronisation'), findsOneWidget);
    });

    testWidgets(
      'a sync failure surfaces the French error on the account screen',
      (tester) async {
        final backend = FakeSyncBackend()
          ..pullError = const SyncNetworkError('offline');
        await pump(
          tester,
          backend: backend,
          account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
        );

        await tapAndWait(tester, 'Synchroniser maintenant');

        expect(
          find.textContaining('Dernière synchronisation échouée'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'Se déconnecter calls backend.signOut() and returns to signedOut',
      (tester) async {
        final backend = FakeSyncBackend();
        await pump(
          tester,
          backend: backend,
          account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
        );

        await tapAndWait(tester, 'Se déconnecter');

        expect(find.text('Recevoir un code'), findsOneWidget);
      },
    );

    group('Supprimer mon compte (Task 6)', () {
      testWidgets(
        'cancelling the first confirmation dialog calls nothing and leaves '
        'the session untouched',
        (tester) async {
          final backend = FakeSyncBackend();
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          expect(find.text('Supprimer le compte ?'), findsOneWidget);
          await tapAndWait(tester, 'Annuler');

          expect(backend.deleteAccountCallCount, 0);
          expect(find.text('Connecté'), findsOneWidget);
        },
      );

      testWidgets(
        'cancelling the second (final) confirmation dialog also calls '
        'nothing',
        (tester) async {
          final backend = FakeSyncBackend();
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          expect(find.text('Confirmation finale'), findsOneWidget);
          await tapAndWait(tester, 'Annuler');

          expect(backend.deleteAccountCallCount, 0);
          expect(find.text('Connecté'), findsOneWidget);
        },
      );

      testWidgets(
        'confirming both dialogs calls deleteAccount() exactly once, then '
        'signs out locally, then offers a local purge — declining it keeps '
        'the local sync-state prefs untouched',
        (tester) async {
          final backend = FakeSyncBackend();
          await PrefsSyncStateStore(
            'u1',
          ).write(const SyncCursorState(pushedIndex: 3));
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');

          expect(backend.deleteAccountCallCount, 1);
          // Local session cleared: back to the signedOut form.
          expect(find.text('Recevoir un code'), findsOneWidget);
          expect(
            find.text('Supprimer aussi les données locales ?'),
            findsOneWidget,
          );

          await tapAndWait(tester, 'Conserver mes données');

          expect(
            find.text(
              'Compte supprimé. Vos données de jeu restent sur cet appareil.',
            ),
            findsOneWidget,
          );
          // Declining the purge leaves this uid's sync-state prefs alone.
          expect((await PrefsSyncStateStore('u1').read()).pushedIndex, 3);
        },
      );

      testWidgets(
        'accepting the local-purge offer clears the deleted account\'s own '
        'sync-state prefs keys and deletes trip history (Task 6 review '
        'round 1 Critical: the dialog promises "parcours" are removed)',
        (tester) async {
          final backend = FakeSyncBackend();
          await PrefsSyncStateStore(
            'u1',
          ).write(const SyncCursorState(pushedIndex: 3, pullCursor: 'c1'));
          // A trip in history — the exact gap Task 6 review round 1 flagged
          // Critical: the confirmation dialog says "parcours" are removed,
          // but nothing ever purged this store. Real `dart:io`/sqlite work,
          // so it has to run inside `runAsync` — a bare await here is the
          // exact "never completes" trap the CI-fix commit's report writeup
          // documents (see export_data_tile_test.dart's own note).
          // `LocalDataPurge`'s appSupportDir is `journal.dir.parent` (=
          // tempDir here, since gameJournalProvider is overridden to
          // `Directory('${tempDir.path}/journal')` below) — trip_history.db
          // is a SIBLING of the `game/` journal dir, matching main.dart's
          // real wiring (`${dir.path}/trip_history.db`), not inside it.
          final tripHistoryPath = '${tempDir.path}/trip_history.db';
          await tester.runAsync(() async {
            final tripHistoryStore = await TripHistoryStore.open(
              tripHistoryPath,
            );
            await tripHistoryStore.record(
              TripHistoryEntry(
                startedAt: DateTime.utc(2026, 8, 30, 9),
                endedAt: DateTime.utc(2026, 8, 30, 9, 30),
                profile: RoutingProfile.walk,
                distanceKm: 2.5,
                duration: const Duration(minutes: 30),
                avgSpeedKmh: 5,
              ),
            );
            await tripHistoryStore.close();
          });

          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');
          // Longer wait than the default: this tap's async chain runs the
          // full local purge (journal/checkpoint file deletes, an EdgesStore
          // open+clear+close round trip, trip history's own open+deleteAll+
          // close+file-delete, trip-snapshot delete, sync-state prefs
          // deletion) before the snackbar appears — under load (observed on
          // a CI runner) the default 100 ms budget isn't reliably enough for
          // all of that real I/O to land before pumpAndSettle checks below.
          await tapAndWait(
            tester,
            'Supprimer aussi mes données',
            wait: const Duration(milliseconds: 1000),
          );

          expect(
            find.text('Compte et données locales supprimés.'),
            findsOneWidget,
          );
          final state = await PrefsSyncStateStore('u1').read();
          expect(state.pushedIndex, 0);
          expect(state.pullCursor, isNull);

          // Real dart:io/sqlite again — see the matching note above.
          await tester.runAsync(() async {
            expect(await File(tripHistoryPath).exists(), isFalse);
            final reopened = await TripHistoryStore.open(tripHistoryPath);
            expect(await reopened.list(), isEmpty);
            await reopened.close();
          });
        },
      );

      testWidgets(
        'refuses to purge while a trip is recording (Task 6 review round 1 '
        'I1) — deleting live trip state under a running service would '
        'corrupt it',
        (tester) async {
          final backend = FakeSyncBackend();
          final trip = await buildTrip(recording: true);
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
            trip: trip,
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');
          await tapAndWait(tester, 'Supprimer aussi mes données');

          expect(find.text(kPurgeRefusedTripActiveMessage), findsOneWidget);
          // The account itself is still deleted server-side (that part
          // never depends on trip state) — only the local purge is refused.
          expect(backend.deleteAccountCallCount, 1);
        },
      );

      testWidgets(
        'refuses to purge while a trip is merely interrupted too (Task 6 '
        'review round 2) — finishing it afterward would write the '
        'pre-purge trip straight back into the just-emptied stores',
        (tester) async {
          final backend = FakeSyncBackend();
          final trip = await buildTrip(interrupted: true);
          expect(trip.isInterrupted, isTrue);
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
            trip: trip,
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');
          await tapAndWait(tester, 'Supprimer aussi mes données');

          expect(find.text(kPurgeRefusedTripActiveMessage), findsOneWidget);
          expect(backend.deleteAccountCallCount, 1);
        },
      );

      testWidgets(
        'a deleteAccount() failure surfaces a French error and leaves the '
        'session signed in — nothing local is touched',
        (tester) async {
          final backend = FakeSyncBackend()
            ..deleteAccountError = const SyncNetworkError('offline');
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');

          expect(backend.deleteAccountCallCount, 1);
          expect(find.text('Connecté'), findsOneWidget);
          expect(find.text('Se déconnecter'), findsOneWidget);
          expect(
            find.textContaining("le compte n'a pas été supprimé"),
            findsOneWidget,
          );
        },
      );
    });
  });
}

class _SignInThrowsBackend extends FakeSyncBackend {
  _SignInThrowsBackend(this.error);
  final Object error;

  @override
  Future<void> signInWithOtp(String email) async => throw error;
}
