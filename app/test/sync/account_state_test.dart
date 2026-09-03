import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/sync/account_state.dart';

void main() {
  group('AccountState.configure', () {
    test('unconfigured -> signedOut', () {
      final result = const AccountState.unconfigured().configure();
      expect(result.phase, AccountPhase.signedOut);
      expect(result.email, isNull);
      expect(result.uid, isNull);
    });

    test('throws StateError from every other phase', () {
      expect(
        () => const AccountState.signedOut().configure(),
        throwsStateError,
      );
      expect(
        () => const AccountState.signedOut().otpRequested('a@b.ch').configure(),
        throwsStateError,
      );
      expect(
        () => const AccountState.signedOut()
            .otpRequested('a@b.ch')
            .signedIn('uid-1', 'a@b.ch')
            .configure(),
        throwsStateError,
      );
    });
  });

  group('AccountState.otpRequested', () {
    test('signedOut -> otpSent(email)', () {
      final result = const AccountState.signedOut().otpRequested('a@b.ch');
      expect(result.phase, AccountPhase.otpSent);
      expect(result.email, 'a@b.ch');
      expect(result.uid, isNull);
    });

    test('otpSent -> otpSent(newEmail) (resend / restart)', () {
      final first = const AccountState.signedOut().otpRequested('a@b.ch');
      final second = first.otpRequested('c@d.ch');
      expect(second.phase, AccountPhase.otpSent);
      expect(second.email, 'c@d.ch');
    });

    test('throws StateError from unconfigured', () {
      expect(
        () => const AccountState.unconfigured().otpRequested('a@b.ch'),
        throwsStateError,
      );
    });

    test('throws StateError from signedIn', () {
      final signedIn = const AccountState.signedOut()
          .otpRequested('a@b.ch')
          .signedIn('uid-1', 'a@b.ch');
      expect(() => signedIn.otpRequested('a@b.ch'), throwsStateError);
    });
  });

  group('AccountState.signedIn', () {
    test('otpSent -> signedIn(uid, email)', () {
      final result = const AccountState.signedOut()
          .otpRequested('a@b.ch')
          .signedIn('uid-1', 'a@b.ch');
      expect(result.phase, AccountPhase.signedIn);
      expect(result.uid, 'uid-1');
      expect(result.email, 'a@b.ch');
    });

    test('signedOut -> signedIn(uid, email) (restored session, no OTP)', () {
      final result = const AccountState.signedOut().signedIn('uid-1', 'a@b.ch');
      expect(result.phase, AccountPhase.signedIn);
      expect(result.uid, 'uid-1');
    });

    test('keeps the pending email when signedIn is called with null', () {
      final result = const AccountState.signedOut()
          .otpRequested('a@b.ch')
          .signedIn('uid-1', null);
      expect(result.email, 'a@b.ch');
    });

    test('throws StateError from unconfigured', () {
      expect(
        () => const AccountState.unconfigured().signedIn('uid-1', 'a@b.ch'),
        throwsStateError,
      );
    });

    test('throws StateError from signedIn (already signed in)', () {
      final signedIn = const AccountState.signedOut().signedIn(
        'uid-1',
        'a@b.ch',
      );
      expect(() => signedIn.signedIn('uid-2', 'c@d.ch'), throwsStateError);
    });
  });

  group('AccountState.signOut', () {
    test('signedIn -> signedOut', () {
      final signedIn = const AccountState.signedOut().signedIn(
        'uid-1',
        'a@b.ch',
      );
      final result = signedIn.signOut();
      expect(result.phase, AccountPhase.signedOut);
      expect(result.email, isNull);
      expect(result.uid, isNull);
    });

    test('throws StateError from every other phase', () {
      expect(
        () => const AccountState.unconfigured().signOut(),
        throwsStateError,
      );
      expect(() => const AccountState.signedOut().signOut(), throwsStateError);
      expect(
        () => const AccountState.signedOut().otpRequested('a@b.ch').signOut(),
        throwsStateError,
      );
    });
  });

  group('AccountState.reset', () {
    test('otpSent -> signedOut (cancels the pending OTP)', () {
      final otpSent = const AccountState.signedOut().otpRequested('a@b.ch');
      final result = otpSent.reset();
      expect(result.phase, AccountPhase.signedOut);
      expect(result.email, isNull);
    });

    test('throws StateError from every other phase', () {
      expect(() => const AccountState.unconfigured().reset(), throwsStateError);
      expect(() => const AccountState.signedOut().reset(), throwsStateError);
      final signedIn = const AccountState.signedOut().signedIn(
        'uid-1',
        'a@b.ch',
      );
      expect(() => signedIn.reset(), throwsStateError);
    });
  });
}
