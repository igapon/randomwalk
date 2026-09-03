import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/sync/sync_state_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('read() with nothing persisted yields the zero state', () async {
    final store = PrefsSyncStateStore('uid-a');
    final state = await store.read();
    expect(state.pushedIndex, 0);
    expect(state.pushedCatchupIds, isEmpty);
    expect(state.pullCursor, isNull);
  });

  test('write() then read() round-trips every field', () async {
    final store = PrefsSyncStateStore('uid-a');
    await store.write(
      const SyncCursorState(
        pushedIndex: 7,
        pushedCatchupIds: {'a', 'b'},
        pullCursor: '2026-09-01T10:00:00.000000+00:00|some-uuid',
      ),
    );
    final state = await store.read();
    expect(state.pushedIndex, 7);
    expect(state.pushedCatchupIds, {'a', 'b'});
    expect(state.pullCursor, '2026-09-01T10:00:00.000000+00:00|some-uuid');
  });

  test('a new store instance for the same uid, pointed at the same backing '
      'prefs, sees the same state — simulates a process restart reading the '
      'last checkpoint', () async {
    await PrefsSyncStateStore(
      'uid-a',
    ).write(const SyncCursorState(pushedIndex: 3, pushedCatchupIds: {'x'}));
    final restarted = PrefsSyncStateStore('uid-a');
    final state = await restarted.read();
    expect(state.pushedIndex, 3);
    expect(state.pushedCatchupIds, {'x'});
  });

  test('writing a state with a null pullCursor clears a previously '
      'persisted one', () async {
    final store = PrefsSyncStateStore('uid-a');
    await store.write(const SyncCursorState(pullCursor: 'a|b'));
    expect((await store.read()).pullCursor, 'a|b');

    await store.write(const SyncCursorState());
    expect((await store.read()).pullCursor, isNull);
  });

  test('knownSkippedLines round-trips (fix round 2, Task 4 review NEW-1) and '
      'defaults to 0 when nothing was ever written', () async {
    final store = PrefsSyncStateStore('uid-a');
    expect((await store.read()).knownSkippedLines, 0);

    await store.write(const SyncCursorState(knownSkippedLines: 2));
    expect((await store.read()).knownSkippedLines, 2);
  });

  group('per-uid scoping (fix round 1, Task 4 review C2)', () {
    test(
      'two different uids never see each other\'s checkpoint, even though '
      'they share the same underlying shared_preferences backing store',
      () async {
        await PrefsSyncStateStore('uid-a').write(
          const SyncCursorState(
            pushedIndex: 5,
            pushedCatchupIds: {'a-1'},
            pullCursor: 'a-cursor',
          ),
        );
        await PrefsSyncStateStore('uid-b').write(
          const SyncCursorState(
            pushedIndex: 9,
            pushedCatchupIds: {'b-1'},
            pullCursor: 'b-cursor',
          ),
        );

        final a = await PrefsSyncStateStore('uid-a').read();
        expect(a.pushedIndex, 5);
        expect(a.pushedCatchupIds, {'a-1'});
        expect(a.pullCursor, 'a-cursor');

        final b = await PrefsSyncStateStore('uid-b').read();
        expect(b.pushedIndex, 9);
        expect(b.pushedCatchupIds, {'b-1'});
        expect(b.pullCursor, 'b-cursor');
      },
    );

    test('signing into an account that has never synced on this device before '
        '(a brand-new uid) reads back the zero state — full pull from the '
        'beginning, full push of local history, regardless of what a '
        'previously signed-in account had persisted', () async {
      await PrefsSyncStateStore('uid-a').write(
        const SyncCursorState(
          pushedIndex: 42,
          pullCursor: '2026-09-01T10:00:00Z|some-id',
        ),
      );

      final freshAccount = await PrefsSyncStateStore('uid-c').read();
      expect(freshAccount.pushedIndex, 0);
      expect(freshAccount.pushedCatchupIds, isEmpty);
      expect(freshAccount.pullCursor, isNull);
    });

    test('a returning account (same uid signs out and back in) resumes '
        'exactly where it left off — no cleanup needed on sign-out for this '
        'to be correct', () async {
      await PrefsSyncStateStore(
        'uid-a',
      ).write(const SyncCursorState(pushedIndex: 12, pullCursor: 'c1'));

      // Simulates: sign out (nothing touches the store — see
      // AccountScreen._signOut), then sign back in as the same uid.
      final resumed = await PrefsSyncStateStore('uid-a').read();
      expect(resumed.pushedIndex, 12);
      expect(resumed.pullCursor, 'c1');
    });
  });

  group('deleteFor (Task 6 local purge / account deletion)', () {
    test('removes every persisted key for that uid — read() falls back to '
        'the zero state afterward', () async {
      await PrefsSyncStateStore('uid-a').write(
        const SyncCursorState(
          pushedIndex: 5,
          pushedCatchupIds: {'a-1'},
          pullCursor: 'a-cursor',
          knownSkippedLines: 2,
        ),
      );

      await PrefsSyncStateStore.deleteFor('uid-a');

      final state = await PrefsSyncStateStore('uid-a').read();
      expect(state.pushedIndex, 0);
      expect(state.pushedCatchupIds, isEmpty);
      expect(state.pullCursor, isNull);
      expect(state.knownSkippedLines, 0);
    });

    test('never touches a different uid\'s checkpoint', () async {
      await PrefsSyncStateStore(
        'uid-a',
      ).write(const SyncCursorState(pushedIndex: 5, pullCursor: 'a-cursor'));
      await PrefsSyncStateStore(
        'uid-b',
      ).write(const SyncCursorState(pushedIndex: 9, pullCursor: 'b-cursor'));

      await PrefsSyncStateStore.deleteFor('uid-a');

      final b = await PrefsSyncStateStore('uid-b').read();
      expect(b.pushedIndex, 9);
      expect(b.pullCursor, 'b-cursor');
    });

    test(
      'is safe to call for a uid that never had anything persisted',
      () async {
        await PrefsSyncStateStore.deleteFor('never-signed-in');
        final state = await PrefsSyncStateStore('never-signed-in').read();
        expect(state.pushedIndex, 0);
      },
    );
  });

  group('SyncCursorState.copyWith', () {
    test('omitted fields are preserved', () {
      const state = SyncCursorState(
        pushedIndex: 5,
        pushedCatchupIds: {'a'},
        pullCursor: 'c1',
        knownSkippedLines: 1,
      );
      final copy = state.copyWith(pushedIndex: 9);
      expect(copy.pushedIndex, 9);
      expect(copy.pushedCatchupIds, {'a'});
      expect(copy.pullCursor, 'c1');
      expect(copy.knownSkippedLines, 1);
    });

    test('clearPullCursor explicitly nulls the cursor even though a plain '
        'null argument would otherwise mean "unchanged"', () {
      const state = SyncCursorState(pullCursor: 'c1');
      final cleared = state.copyWith(clearPullCursor: true);
      expect(cleared.pullCursor, isNull);
    });
  });
}
