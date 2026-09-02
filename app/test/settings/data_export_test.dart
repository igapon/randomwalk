import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/settings/data_export.dart';
import 'package:randomwalk/settings/identity.dart';

void main() {
  final identity = const PlayerIdentity(userId: 'device-1', pseudo: 'Marcheur');
  final events = [
    GameEvent(
      id: 'e1',
      ts: DateTime.utc(2026, 8, 30, 10),
      type: GameEventTypes.landmarkVisited,
      payload: const {'poiId': 'p1'},
    ),
  ];
  final exportedAt = DateTime.utc(2026, 9, 1, 12);

  test('includes the app version and export date', () {
    final payload = buildExportPayload(
      identity: identity,
      totalKm: 12.5,
      journalEvents: const [],
      edgesCoveredCount: 0,
      exportedAt: exportedAt,
    );

    expect(payload['appVersion'], kAppVersion);
    expect(payload['exportedAt'], exportedAt.toIso8601String());
  });

  test('includes the profile: pseudo, userId and total distance', () {
    final payload = buildExportPayload(
      identity: identity,
      totalKm: 42.0,
      journalEvents: const [],
      edgesCoveredCount: 0,
      exportedAt: exportedAt,
    );

    expect(payload['profile'], {
      'userId': 'device-1',
      'pseudo': 'Marcheur',
      'totalKm': 42.0,
    });
  });

  test('includes the full journal, serialized the same way GameEvent.toJson '
      'does', () {
    final payload = buildExportPayload(
      identity: identity,
      totalKm: 0,
      journalEvents: events,
      edgesCoveredCount: 0,
      exportedAt: exportedAt,
    );

    expect(payload['journal'], [events.first.toJson()]);
  });

  test('includes the covered-edges count', () {
    final payload = buildExportPayload(
      identity: identity,
      totalKm: 0,
      journalEvents: const [],
      edgesCoveredCount: 137,
      exportedAt: exportedAt,
    );

    expect(payload['edgesCoveredCount'], 137);
  });

  group('account section', () {
    test('is null when no account uid is given (unconfigured, signed out, '
        'or otpSent — none of these have an account to report)', () {
      final payload = buildExportPayload(
        identity: identity,
        totalKm: 0,
        journalEvents: const [],
        edgesCoveredCount: 0,
        exportedAt: exportedAt,
      );

      expect(payload['account'], isNull);
    });

    test('carries uid and email when signed in', () {
      final payload = buildExportPayload(
        identity: identity,
        totalKm: 0,
        journalEvents: const [],
        edgesCoveredCount: 0,
        accountUid: 'u1',
        accountEmail: 'a@b.ch',
        exportedAt: exportedAt,
      );

      expect(payload['account'], {'uid': 'u1', 'email': 'a@b.ch'});
    });
  });

  test('works with nothing local at all — a brand-new install\'s payload is '
      'still well-formed, never throws', () {
    final payload = buildExportPayload(
      identity: identity,
      totalKm: 0,
      journalEvents: const [],
      edgesCoveredCount: 0,
      exportedAt: exportedAt,
    );

    expect(payload['journal'], isEmpty);
    expect(payload['account'], isNull);
    expect(payload['profile'], isNotNull);
  });
}
