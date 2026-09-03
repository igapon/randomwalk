import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/sync/backend.dart';

void main() {
  group('UnconfiguredBackend', () {
    final backend = const UnconfiguredBackend();

    test('currentUser throws SyncUnconfigured', () {
      expect(backend.currentUser(), throwsA(isA<SyncUnconfigured>()));
    });

    test('signInWithOtp throws SyncUnconfigured', () {
      expect(backend.signInWithOtp('a@b.ch'), throwsA(isA<SyncUnconfigured>()));
    });

    test('verifyOtp throws SyncUnconfigured', () {
      expect(
        backend.verifyOtp(email: 'a@b.ch', code: '123456'),
        throwsA(isA<SyncUnconfigured>()),
      );
    });

    test('signOut throws SyncUnconfigured', () {
      expect(backend.signOut(), throwsA(isA<SyncUnconfigured>()));
    });

    test('deleteAccount throws SyncUnconfigured', () {
      expect(backend.deleteAccount(), throwsA(isA<SyncUnconfigured>()));
    });

    test('pushEvents throws SyncUnconfigured', () {
      final event = GameEvent(
        id: 'e1',
        ts: DateTime.utc(2026, 1, 1),
        type: GameEventTypes.loopCompleted,
      );
      expect(backend.pushEvents([event]), throwsA(isA<SyncUnconfigured>()));
    });

    test('upsertProfile throws SyncUnconfigured', () {
      expect(
        backend.upsertProfile(pseudo: 'Marcheur', totalKm: 12.5),
        throwsA(isA<SyncUnconfigured>()),
      );
    });

    test('pullEventsSince returns an empty page, no cursor', () async {
      final page = await backend.pullEventsSince(null);
      expect(page.events, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test('pullEventsSince with a cursor still returns an empty page', () async {
      final page = await backend.pullEventsSince('some-cursor');
      expect(page.events, isEmpty);
      expect(page.nextCursor, isNull);
    });

    test('topProfiles returns an empty list', () async {
      final rows = await backend.topProfiles(limit: 10);
      expect(rows, isEmpty);
    });
  });

  group('typed exceptions', () {
    test('SyncUnconfigured has a readable toString', () {
      expect(const SyncUnconfigured().toString(), contains('SyncUnconfigured'));
    });

    test('SyncNetworkError carries its message', () {
      final e = const SyncNetworkError('timeout');
      expect(e.message, 'timeout');
      expect(e.toString(), contains('timeout'));
    });

    test('SyncAuthError carries its message', () {
      final e = const SyncAuthError('invalid code');
      expect(e.message, 'invalid code');
      expect(e.toString(), contains('invalid code'));
    });
  });
}
