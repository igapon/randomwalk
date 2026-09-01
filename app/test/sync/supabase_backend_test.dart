import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/sync/backend.dart';
import 'package:randomwalk/sync/supabase_backend.dart';

// Most of these tests exercise only the pure mapping/encoding helpers
// (GameEvent<->row json, cursor encode/decode, error mapping) — no
// network I/O, no `Supabase.initialize`, per the M5 global constraint that
// nothing in this task's test suite attempts real network I/O.
//
// The `buildPullRequest` group is the one exception: it constructs a plain
// `SupabaseClient` directly (bypassing `Supabase.initialize`/the global
// singleton — this package's `SupabaseClient`, not `supabase_flutter`'s
// lazily-initialized one `SupabaseBackend` normally uses) with a recording
// `httpClient` that never leaves the process, so the real query-builder
// code path can be asserted against without any live network call — see
// that group's own comment for why this is the request-capture test the
// review asked for.
//
// The RPC/PostgREST call sites inside `SupabaseBackend`'s own instance
// methods are still verified later against a live project by the owner
// (see the plan and supabase/README.md).
void main() {
  group('eventToRow', () {
    test('matches GameEvent.toJson shape with ts forced to UTC', () {
      final localTs = DateTime(2026, 1, 2, 3, 4, 5); // not UTC
      final event = GameEvent(
        id: 'e1',
        ts: localTs,
        type: GameEventTypes.loopCompleted,
        payload: const {'k': 'v'},
      );

      final row = SupabaseBackend.eventToRow(event);

      expect(row['id'], 'e1');
      expect(row['type'], GameEventTypes.loopCompleted);
      expect(row['payload'], const {'k': 'v'});
      expect(row['ts'], localTs.toUtc().toIso8601String());
      // Explicit UTC/offset marker present — see supabase/notes.md's note
      // that an offset-less string is ambiguous to push_events' ::timestamptz
      // cast.
      expect(row['ts'], endsWith('Z'));
    });

    test('an already-UTC ts round-trips unchanged (still ends in Z)', () {
      final event = GameEvent(
        id: 'e2',
        ts: DateTime.utc(2026, 6, 1, 12),
        type: GameEventTypes.coinsEarned,
      );

      final row = SupabaseBackend.eventToRow(event);

      expect(row['ts'], '2026-06-01T12:00:00.000Z');
    });

    test('default empty payload is preserved', () {
      final event = GameEvent(
        id: 'e3',
        ts: DateTime.utc(2026, 1, 1),
        type: GameEventTypes.streakUpdated,
      );

      expect(SupabaseBackend.eventToRow(event)['payload'], const {});
    });
  });

  group('rowToEvent', () {
    test('maps a game_events select row back to a GameEvent', () {
      final row = {
        'id': 'e1',
        'ts': '2026-01-02T03:04:05.000Z',
        'type': GameEventTypes.badgeUnlocked,
        'payload': {'badge': 'premiere_boucle'},
        // Extra column present on the real row, not part of GameEvent —
        // must be silently ignored.
        'inserted_at': '2026-01-02T03:04:06.000Z',
      };

      final event = SupabaseBackend.rowToEvent(row);

      expect(event.id, 'e1');
      expect(event.ts, DateTime.parse('2026-01-02T03:04:05.000Z'));
      expect(event.type, GameEventTypes.badgeUnlocked);
      expect(event.payload, {'badge': 'premiere_boucle'});
    });

    test('null payload column maps to the empty map', () {
      final row = {
        'id': 'e2',
        'ts': '2026-01-01T00:00:00.000Z',
        'type': GameEventTypes.loopCompleted,
        'payload': null,
        'inserted_at': '2026-01-01T00:00:01.000Z',
      };

      expect(SupabaseBackend.rowToEvent(row).payload, const {});
    });

    test(
      'push then pull round-trips id/type/payload and preserves the UTC instant',
      () {
        final original = GameEvent(
          id: 'round-trip',
          ts: DateTime(2026, 3, 4, 5, 6, 7), // local
          type: GameEventTypes.xpEarned,
          payload: const {'amount': 10},
        );

        final pushed = SupabaseBackend.eventToRow(original);
        // Simulate the row coming back from a select (server adds inserted_at).
        final pulledRow = {...pushed, 'inserted_at': pushed['ts']};
        final pulled = SupabaseBackend.rowToEvent(pulledRow);

        expect(pulled.id, original.id);
        expect(pulled.type, original.type);
        expect(pulled.payload, original.payload);
        expect(pulled.ts.toUtc(), original.ts.toUtc());
      },
    );
  });

  group('rowToLeaderboardRow', () {
    test('maps pseudo/total_km/rank, tolerating integral JSON numbers', () {
      final row = SupabaseBackend.rowToLeaderboardRow({
        'pseudo': 'Marcheur',
        'total_km': 12, // integral value, arrives as int over JSON
        'rank': 1,
      });

      expect(row.pseudo, 'Marcheur');
      expect(row.totalKm, 12.0);
      expect(row.rank, 1);
    });

    test('maps a fractional total_km and a tied rank', () {
      final row = SupabaseBackend.rowToLeaderboardRow({
        'pseudo': 'Randonneuse',
        'total_km': 42.5,
        'rank': 2,
      });

      expect(row.totalKm, 42.5);
      expect(row.rank, 2);
    });
  });

  group('cursor encode/decode', () {
    test('round-trips inserted_at and id', () {
      const insertedAt = '2026-09-01T10:00:00.123456+00:00';
      const id = 'a1b2c3d4-0000-0000-0000-000000000001';

      final cursor = SupabaseBackend.encodeCursor(
        insertedAt: insertedAt,
        id: id,
      );
      final decoded = SupabaseBackend.decodeCursor(cursor);

      expect(decoded.insertedAt, insertedAt);
      expect(decoded.id, id);
    });

    test('encoded cursor is inserted_at and id joined by a single |', () {
      final cursor = SupabaseBackend.encodeCursor(
        insertedAt: '2026-01-01T00:00:00Z',
        id: 'uuid-1',
      );
      expect(cursor, '2026-01-01T00:00:00Z|uuid-1');
    });

    test('decodeCursor throws FormatException on a malformed cursor', () {
      expect(
        () => SupabaseBackend.decodeCursor('not-a-valid-cursor'),
        throwsFormatException,
      );
    });

    test('decodeCursor throws FormatException on an empty field', () {
      expect(
        () => SupabaseBackend.decodeCursor('|uuid-1'),
        throwsFormatException,
      );
      expect(
        () => SupabaseBackend.decodeCursor('2026-01-01T00:00:00Z|'),
        throwsFormatException,
      );
    });

    test('decodeCursor throws FormatException on extra separators', () {
      expect(
        () => SupabaseBackend.decodeCursor('a|b|c'),
        throwsFormatException,
      );
    });
  });

  group('userToAuthUser', () {
    test('null user maps to null (no signed-in user is not an error)', () {
      expect(SupabaseBackend.userToAuthUser(null), isNull);
    });
  });

  group('mapError', () {
    test('AuthRetryableFetchException maps to SyncNetworkError', () {
      final mapped = SupabaseBackend.mapError(
        AuthRetryableFetchException(message: 'fetch failed'),
      );
      expect(mapped, isA<SyncNetworkError>());
      expect((mapped as SyncNetworkError).message, 'fetch failed');
    });

    test('a rejected-OTP AuthApiException maps to SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const AuthApiException('Token has expired or is invalid'),
      );
      expect(mapped, isA<SyncAuthError>());
      expect(
        (mapped as SyncAuthError).message,
        'Token has expired or is invalid',
      );
    });

    test('AuthSessionMissingException maps to SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(AuthSessionMissingException());
      expect(mapped, isA<SyncAuthError>());
    });

    test('a PostgrestException carrying push_events\' "authentication '
        'required" message maps to SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(
          message: 'push_events: authentication required',
          code: 'P0001',
        ),
      );
      expect(mapped, isA<SyncAuthError>());
      expect(
        (mapped as SyncAuthError).message,
        'push_events: authentication required',
      );
    });

    test('delete_account\'s "authentication required" message also maps to '
        'SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(
          message: 'delete_account: authentication required',
        ),
      );
      expect(mapped, isA<SyncAuthError>());
    });

    test('a PostgrestException with code 42501 (insufficient_privilege — '
        'e.g. an RLS rejection, or an anon-role caller with no EXECUTE '
        'grant on push_events/delete_account) maps to SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(
          message: 'new row violates row-level security policy',
          code: '42501',
        ),
      );
      expect(mapped, isA<SyncAuthError>());
      expect(
        (mapped as SyncAuthError).message,
        'new row violates row-level security policy',
      );
    });

    test('a PostgrestException with an HTTP-403-shaped code maps to '
        'SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(message: 'Forbidden', code: '403'),
      );
      expect(mapped, isA<SyncAuthError>());
    });

    test('a PostgrestException with an HTTP-401-shaped code maps to '
        'SyncAuthError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(message: 'Unauthorized', code: '401'),
      );
      expect(mapped, isA<SyncAuthError>());
    });

    test('a PostgrestException with an unrelated code (e.g. a malformed 2xx '
        'body) maps to SyncNetworkError', () {
      final mapped = SupabaseBackend.mapError(
        const PostgrestException(message: 'invalid json', code: '200'),
      );
      expect(mapped, isA<SyncNetworkError>());
      expect((mapped as SyncNetworkError).message, 'invalid json');
    });

    test(
      'a PostgrestException with no code at all maps to SyncNetworkError',
      () {
        final mapped = SupabaseBackend.mapError(
          const PostgrestException(message: 'something went wrong'),
        );
        expect(mapped, isA<SyncNetworkError>());
      },
    );

    test(
      'an unrecognized error (e.g. no connectivity) maps to SyncNetworkError',
      () {
        final mapped = SupabaseBackend.mapError(const FormatException('boom'));
        expect(mapped, isA<SyncNetworkError>());
      },
    );
  });

  group('buildPullRequest (request-capture, no live network)', () {
    // These construct a plain SupabaseClient directly — bypassing
    // Supabase.initialize/the global singleton entirely — with a
    // recording httpClient, so the real query-builder code path
    // (.select/.or/.order/.limit) runs and the generated request URL can
    // be asserted against, without any real network I/O. This is what
    // would have caught the ascending/descending ordering bug: the
    // request-capture approach the review asked for.
    late List<Uri> requests;
    late SupabaseClient client;

    setUp(() {
      requests = [];
      client = SupabaseClient(
        'https://example.supabase.co',
        'test-anon-key',
        httpClient: MockClient((request) async {
          requests.add(request.url);
          // postgrest-dart's response parsing reads response.request! (not
          // nullable there), so the mock response must carry it back —
          // omitting it throws a null-check error inside the package, not
          // a useful assertion failure.
          return http.Response(
            '[]',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
    });

    test(
      'no cursor: orders ascending by inserted_at then id, no filter',
      () async {
        await SupabaseBackend.buildPullRequest(client, null);

        expect(requests, hasLength(1));
        final query = requests.single.queryParameters;
        expect(query['order'], 'inserted_at.asc.nullslast,id.asc.nullslast');
        expect(query.containsKey('or'), isFalse);
        // postgrest-dart strips whitespace from the columns string, so the
        // `select` param has no spaces even though buildPullRequest's own
        // literal does — asserted here so an unrelated future edit to that
        // literal doesn't quietly change what's actually requested.
        expect(query['select'], 'id,ts,type,payload,inserted_at');
      },
    );

    test('with a cursor: still orders ascending, and adds the exclusive '
        '(inserted_at, id) OR-filter', () async {
      final cursor = SupabaseBackend.encodeCursor(
        insertedAt: '2026-09-01T10:00:00+00:00',
        id: 'a1b2c3d4-0000-0000-0000-000000000001',
      );

      await SupabaseBackend.buildPullRequest(client, cursor);

      expect(requests, hasLength(1));
      final query = requests.single.queryParameters;
      expect(query['order'], 'inserted_at.asc.nullslast,id.asc.nullslast');
      expect(
        query['or'],
        '(inserted_at.gt.2026-09-01T10:00:00+00:00,'
        'and(inserted_at.eq.2026-09-01T10:00:00+00:00,'
        'id.gt.a1b2c3d4-0000-0000-0000-000000000001))',
      );
    });

    test('a cursor with a tied inserted_at still produces the same '
        'AND-tiebreaker shape (the batched-push tie case)', () async {
      // supabase/notes.md section 1: a batched push shares one
      // inserted_at across every event in the batch, so the tiebreaker
      // branch of the OR-filter is the normal case, not an edge case.
      final cursor = SupabaseBackend.encodeCursor(
        insertedAt: '2026-09-01T10:00:00.000000+00:00',
        id: 'tied-row-id',
      );

      await SupabaseBackend.buildPullRequest(client, cursor);

      final query = requests.single.queryParameters;
      expect(
        query['or'],
        '(inserted_at.gt.2026-09-01T10:00:00.000000+00:00,'
        'and(inserted_at.eq.2026-09-01T10:00:00.000000+00:00,'
        'id.gt.tied-row-id))',
      );
    });
  });
}
