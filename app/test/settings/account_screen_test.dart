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

import '../support/fake_sync_backend.dart';
import '../support/temp_dir.dart';

void main() {
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
  });
}

class _SignInThrowsBackend extends FakeSyncBackend {
  _SignInThrowsBackend(this.error);
  final Object error;

  @override
  Future<void> signInWithOtp(String email) async => throw error;
}
