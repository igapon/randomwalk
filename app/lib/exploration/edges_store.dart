import 'package:sqflite/sqflite.dart';

const _kTable = 'covered_edges';

/// SQLite-backed record of every OSM way id an on-device map-match
/// (`matcher.dart`) has ever attributed to a walked/ridden trip.
///
/// Uses the top-level `openDatabase` from `package:sqflite`, which is
/// governed by the process-wide `databaseFactory` variable: production code
/// never touches that variable (the default platform factory — real
/// Android/iOS sqflite — applies), while tests set it once, in `setUpAll`,
/// to `sqflite_common_ffi`'s desktop factory before calling [EdgesStore.open]
/// — the same "ambient factory" pattern the `sqflite_common_ffi` package
/// itself documents for desktop/CI unit tests.
class EdgesStore {
  final Database _db;

  EdgesStore._(this._db);

  /// Opens (creating if needed) the `covered_edges` table at [path].
  static Future<EdgesStore> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE $_kTable ('
        'way_id TEXT PRIMARY KEY, '
        'first_ts TEXT NOT NULL, '
        'count INTEGER NOT NULL'
        ')',
      ),
    );
    return EdgesStore._(db);
  }

  /// Records every id in [wayIds] as covered as of [ts]: a way id seen for
  /// the first time gets a new row (`first_ts: ts`, `count: 1`); a way id
  /// already present has its `count` incremented instead, keeping its
  /// original `first_ts`. Returns how many of [wayIds] were genuinely new
  /// (i.e. did not already have a row) — duplicates within [wayIds] itself
  /// (the same edge crossed more than once in one trip) count as new at most
  /// once, and only bump `count` on their repeat occurrences.
  ///
  /// A no-op — no transaction opened at all — for an empty [wayIds].
  Future<int> upsertAll(Iterable<String> wayIds, DateTime ts) async {
    final ids = wayIds.toSet();
    if (ids.isEmpty) return 0;

    final tsIso = ts.toUtc().toIso8601String();
    var newlyInserted = 0;
    await _db.transaction((txn) async {
      for (final id in ids) {
        final existing = await txn.query(
          _kTable,
          columns: const ['way_id'],
          where: 'way_id = ?',
          whereArgs: [id],
          limit: 1,
        );
        if (existing.isEmpty) {
          await txn.insert(_kTable, {
            'way_id': id,
            'first_ts': tsIso,
            'count': 1,
          });
          newlyInserted++;
        } else {
          await txn.rawUpdate(
            'UPDATE $_kTable SET count = count + 1 WHERE way_id = ?',
            [id],
          );
        }
      }
    });
    return newlyInserted;
  }

  /// Total number of distinct way ids ever covered.
  Future<int> get totalCount async {
    final rows = await _db.rawQuery('SELECT COUNT(*) AS c FROM $_kTable');
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Whether [wayId] has ever been covered.
  Future<bool> contains(String wayId) async {
    final rows = await _db.query(
      _kTable,
      columns: const ['way_id'],
      where: 'way_id = ?',
      whereArgs: [wayId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> close() => _db.close();
}
