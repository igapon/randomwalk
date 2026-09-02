import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/game/game_state_provider.dart';
import 'package:randomwalk/settings/account_screen.dart';
import 'package:randomwalk/sync/account_state.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/providers.dart';
import 'package:randomwalk/sync/sync_state_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../support/fake_sync_backend.dart';
import '../support/temp_dir.dart';

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

  Future<void> pump(
    WidgetTester tester, {
    required FakeSyncBackend backend,
    required AccountState account,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncBackendProvider.overrideWithValue(backend),
          accountStateProvider.overrideWith((ref) => account),
          gameJournalProvider.overrideWith(
            (ref) async => GameJournal(Directory('${tempDir.path}/journal')),
          ),
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
  Future<void> tapAndWait(WidgetTester tester, String text) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(text));
      await Future<void>.delayed(const Duration(milliseconds: 100));
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
        'sync-state prefs keys',
        (tester) async {
          final backend = FakeSyncBackend();
          await PrefsSyncStateStore(
            'u1',
          ).write(const SyncCursorState(pushedIndex: 3, pullCursor: 'c1'));
          await pump(
            tester,
            backend: backend,
            account: const AccountState.signedOut().signedIn('u1', 'a@b.ch'),
          );

          await tapAndWait(tester, 'Supprimer mon compte');
          await tapAndWait(tester, 'Continuer');
          await tapAndWait(tester, 'Supprimer définitivement');
          await tapAndWait(tester, 'Supprimer aussi mes données');

          expect(
            find.text('Compte et données locales supprimés.'),
            findsOneWidget,
          );
          final state = await PrefsSyncStateStore('u1').read();
          expect(state.pushedIndex, 0);
          expect(state.pullCursor, isNull);
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
