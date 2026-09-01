import 'package:randomwalk/game/events.dart';
import 'package:randomwalk/sync/backend.dart';

/// In-memory [SyncBackend] double for M5 sync tests — plays the role of one
/// shared cloud account across simulated devices (each with its own
/// [GameJournal]/`SyncEngine`/state store pointed at the *same* instance of
/// this class).
///
/// Event storage mirrors the real contract's shape: [pushEvents] is
/// idempotent by id (`ON CONFLICT DO NOTHING`, matching `SyncBackend`'s
/// dartdoc), and [pullEventsSince] pages through events in the order they
/// were accepted server-side (this class's own insertion order stands in
/// for the real backend's `inserted_at`), with an opaque integer-offset
/// string as the cursor — never parsed by the engine under test, exactly
/// per the real [PullPage] contract.
class FakeSyncBackend implements SyncBackend {
  FakeSyncBackend({this.pageSize = 200});

  /// Page size [pullEventsSince] returns at most — small values let tests
  /// exercise pagination without seeding hundreds of events.
  final int pageSize;

  final List<GameEvent> _serverEvents = [];
  final Set<String> _ids = {};

  int pushCallCount = 0;
  int pullCallCount = 0;

  /// When set, the next [pushEvents] call throws this instead of
  /// succeeding. If [pushErrorPersistsEvents] is also true, the events are
  /// recorded server-side anyway before throwing — simulating a real
  /// backend that committed the write but whose success response never
  /// reached the caller (a dropped/timed-out HTTP response).
  Object? pushError;
  bool pushErrorPersistsEvents = false;

  /// When set, every [pullEventsSince] call throws this.
  Object? pullError;

  List<GameEvent> get serverEvents => List.unmodifiable(_serverEvents);

  /// Seeds server-side events directly, bypassing [pushEvents] — stands in
  /// for "another device already pushed these before this test's engine
  /// ever ran".
  void seedServer(List<GameEvent> events) {
    for (final e in events) {
      if (_ids.add(e.id)) _serverEvents.add(e);
    }
  }

  @override
  Future<void> pushEvents(List<GameEvent> events) async {
    pushCallCount++;
    if (pushError != null) {
      final err = pushError!;
      if (pushErrorPersistsEvents) _accept(events);
      throw err;
    }
    _accept(events);
  }

  void _accept(List<GameEvent> events) {
    for (final e in events) {
      if (_ids.add(e.id)) _serverEvents.add(e); // ON CONFLICT DO NOTHING
    }
  }

  @override
  Future<PullPage> pullEventsSince(String? cursor) async {
    pullCallCount++;
    if (pullError != null) throw pullError!;
    final start = cursor == null ? 0 : int.parse(cursor);
    if (start >= _serverEvents.length) return const PullPage(events: []);
    final end = (start + pageSize).clamp(0, _serverEvents.length);
    final page = _serverEvents.sublist(start, end);
    return PullPage(
      events: page,
      nextCursor: page.isEmpty ? null : end.toString(),
    );
  }

  @override
  Future<AuthUser?> currentUser() async => null;

  @override
  Future<void> signInWithOtp(String email) async {}

  @override
  Future<AuthUser?> verifyOtp({
    required String email,
    required String code,
  }) async => null;

  @override
  Future<void> signOut() async {}

  @override
  Future<void> upsertProfile({
    required String pseudo,
    required double totalKm,
  }) async {}

  @override
  Future<List<LeaderboardRow>> topProfiles({required int limit}) async =>
      const [];

  @override
  Future<void> deleteAccount() async {}
}
