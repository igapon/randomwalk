import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:randomwalk/sync/sync_state_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('read() with nothing persisted yields the zero state', () async {
    final store = PrefsSyncStateStore();
    final state = await store.read();
    expect(state.pushedIndex, 0);
    expect(state.pushedCatchupIds, isEmpty);
    expect(state.pullCursor, isNull);
  });

  test('write() then read() round-trips every field', () async {
    final store = PrefsSyncStateStore();
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

  test(
    'a new store instance pointed at the same backing prefs sees the same '
    'state — simulates a process restart reading the last checkpoint',
    () async {
      await PrefsSyncStateStore().write(
        const SyncCursorState(pushedIndex: 3, pushedCatchupIds: {'x'}),
      );
      final restarted = PrefsSyncStateStore();
      final state = await restarted.read();
      expect(state.pushedIndex, 3);
      expect(state.pushedCatchupIds, {'x'});
    },
  );

  test('writing a state with a null pullCursor clears a previously '
      'persisted one', () async {
    final store = PrefsSyncStateStore();
    await store.write(const SyncCursorState(pullCursor: 'a|b'));
    expect((await store.read()).pullCursor, 'a|b');

    await store.write(const SyncCursorState());
    expect((await store.read()).pullCursor, isNull);
  });

  group('SyncCursorState.copyWith', () {
    test('omitted fields are preserved', () {
      const state = SyncCursorState(
        pushedIndex: 5,
        pushedCatchupIds: {'a'},
        pullCursor: 'c1',
      );
      final copy = state.copyWith(pushedIndex: 9);
      expect(copy.pushedIndex, 9);
      expect(copy.pushedCatchupIds, {'a'});
      expect(copy.pullCursor, 'c1');
    });

    test('clearPullCursor explicitly nulls the cursor even though a plain '
        'null argument would otherwise mean "unchanged"', () {
      const state = SyncCursorState(pullCursor: 'c1');
      final cleared = state.copyWith(clearPullCursor: true);
      expect(cleared.pullCursor, isNull);
    });
  });
}
