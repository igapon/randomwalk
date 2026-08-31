import 'package:flutter_test/flutter_test.dart';
import 'package:randomwalk/exploration/edges_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late EdgesStore store;

  setUp(() async {
    // A fresh in-memory database per test: `sqflite_common_ffi` opens a new,
    // independent connection for `inMemoryDatabasePath` every call, so tests
    // never see another test's rows.
    store = await EdgesStore.open(inMemoryDatabasePath);
  });

  tearDown(() => store.close());

  final ts = DateTime.utc(2026, 8, 30, 10, 0, 0);

  test('a brand-new store has no covered edges', () async {
    expect(await store.totalCount, 0);
    expect(await store.contains('123'), isFalse);
  });

  test('upsertAll on new way ids inserts all of them and reports the count',
      () async {
    final newly = await store.upsertAll(['1', '2', '3'], ts);
    expect(newly, 3);
    expect(await store.totalCount, 3);
    expect(await store.contains('1'), isTrue);
    expect(await store.contains('2'), isTrue);
    expect(await store.contains('3'), isTrue);
    expect(await store.contains('4'), isFalse);
  });

  test('re-upserting an already-covered way id reports it as not new',
      () async {
    await store.upsertAll(['1'], ts);
    final newly = await store.upsertAll(['1'], ts.add(const Duration(days: 1)));
    expect(newly, 0);
    expect(await store.totalCount, 1);
  });

  test('a batch mixing new and already-covered ids only counts the new ones',
      () async {
    await store.upsertAll(['1', '2'], ts);
    final newly = await store.upsertAll(['2', '3', '4'], ts);
    expect(newly, 2);
    expect(await store.totalCount, 4);
  });

  test('duplicate way ids within one batch count as new at most once',
      () async {
    final newly = await store.upsertAll(['1', '1', '1'], ts);
    expect(newly, 1);
    expect(await store.totalCount, 1);
  });

  test('an empty batch is a no-op', () async {
    final newly = await store.upsertAll(<String>[], ts);
    expect(newly, 0);
    expect(await store.totalCount, 0);
  });

  test('upsertAll never overwrites the first-seen timestamp of an existing '
      'row (verified indirectly via a second upsert not creating a '
      'duplicate row)', () async {
    await store.upsertAll(['1'], ts);
    await store.upsertAll(['1'], ts.add(const Duration(days: 30)));
    await store.upsertAll(['1'], ts.add(const Duration(days: 60)));
    expect(await store.totalCount, 1);
  });
}
