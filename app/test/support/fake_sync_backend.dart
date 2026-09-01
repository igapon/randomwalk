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

  /// Which account's event set [pushEvents]/[pullEventsSince]/[seedServer]
  /// operate against — stands in for a real backend's RLS scoping by the
  /// signed-in `auth.uid()`. Defaults to one shared account (`'default'`),
  /// so single-account tests (most of them) never need to touch this;
  /// account-switch tests (Task 4 review C2) change it between `sync()`
  /// rounds to simulate "this device signed out and into a different
  /// account" while sharing one backend instance the way a real device
  /// would share one `supabase_flutter` client across accounts.
  String currentAccountKey = 'default';

  final Map<String, List<GameEvent>> _serverEventsByAccount = {};
  final Map<String, Set<String>> _idsByAccount = {};

  List<GameEvent> get _serverEvents =>
      _serverEventsByAccount.putIfAbsent(currentAccountKey, () => []);
  Set<String> get _ids =>
      _idsByAccount.putIfAbsent(currentAccountKey, () => {});

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

  /// Invoked once per [pullEventsSince] call, right before it returns a
  /// page — lets a test simulate a local journal write landing WHILE the
  /// pull "network call" is in flight, exactly the race Task 4 review
  /// finding C1 documents (`ExplorationRecorder`/`GameVisitConsumer`
  /// appending fire-and-forget, concurrently with a sync). `null` (the
  /// default) does nothing.
  Future<void> Function()? beforePullReturns;

  List<GameEvent> get serverEvents => List.unmodifiable(_serverEvents);

  /// [serverEvents] for a specific [accountKey], regardless of
  /// [currentAccountKey] — lets an account-switch test inspect what each
  /// account's server-side state looks like without having to flip
  /// [currentAccountKey] back and forth just to read it.
  List<GameEvent> serverEventsFor(String accountKey) =>
      List.unmodifiable(_serverEventsByAccount[accountKey] ?? const []);

  /// Queue of successive [currentUser] answers — each call pops the next
  /// entry, and the last entry repeats once the queue is drained. Lets a
  /// test simulate the cold-start "transiently null, then resolved" race
  /// `sync/auto_sync.dart`'s `restoreAccountAndAutoSync` tolerates (see
  /// `task-3-report.md` concern #2), by queuing `[null, someUser]`.
  /// Defaults to always answering `null` (nobody signed in).
  List<AuthUser?> currentUserAnswers = const [null];
  int _currentUserCallIndex = 0;
  int currentUserCallCount = 0;

  /// Seeds [currentAccountKey]'s server-side events directly, bypassing
  /// [pushEvents] — stands in for "another device already pushed these
  /// before this test's engine ever ran".
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
    final events = _serverEvents;
    final start = cursor == null ? 0 : int.parse(cursor);
    final hook = beforePullReturns;
    if (hook != null) await hook();
    if (start >= events.length) return const PullPage(events: []);
    final end = (start + pageSize).clamp(0, events.length);
    final page = events.sublist(start, end);
    return PullPage(
      events: page,
      nextCursor: page.isEmpty ? null : end.toString(),
    );
  }

  @override
  Future<AuthUser?> currentUser() async {
    final i = _currentUserCallIndex;
    currentUserCallCount++;
    if (i < currentUserAnswers.length - 1) _currentUserCallIndex++;
    return currentUserAnswers[i];
  }

  @override
  Future<void> signInWithOtp(String email) async {}

  /// What [verifyOtp] returns — `null` (an invalid/unrecognized code, the
  /// default) unless a test sets this to simulate a correct code.
  AuthUser? verifyOtpResult;

  @override
  Future<AuthUser?> verifyOtp({
    required String email,
    required String code,
  }) async => verifyOtpResult;

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
