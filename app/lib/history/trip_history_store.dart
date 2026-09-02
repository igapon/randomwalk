import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../valhalla/models.dart';

const _kTable = 'trip_history';

/// Every column except `track` — what [TripHistoryStore.list] (and, through
/// it, [TripHistoryStore.latest]) actually selects. Review fix round 1
/// (Critical 2): with retention unbounded (brief), a `SELECT *` for the
/// list screen would decode and hold every trip's full track (up to
/// `kTrackMaxPoints` points each) in memory just to render date/distance/
/// duration/icon rows. [TripHistoryStore.fetchById] is the only method that
/// still selects `track`, and only for the one trip actually being opened.
const _kSummaryColumns = [
  'id',
  'started_at',
  'ended_at',
  'profile',
  'distance_km',
  'duration_s',
  'avg_speed_kmh',
  'xp_earned',
];

/// One finalised trip's compact summary (Task 2f, owner-requested: « ce
/// serait bien d'ajouter les anciens trajets comme historique »).
///
/// **Local only in M5.** The game journal (`game/events.dart`) stays the
/// only sync unit — this store is a *candidate* for M6 sync, not part of
/// it; nothing here is read or written by `sync/`. Retention is unbounded
/// in v1 (brief: a few KB per trip, unlimited).
class TripHistoryEntry {
  /// `null` until the row this entry came from has actually been inserted
  /// (see [TripHistoryStore.record]'s return value).
  final int? id;

  final DateTime startedAt;
  final DateTime endedAt;
  final RoutingProfile profile;
  final double distanceKm;
  final Duration duration;
  final double avgSpeedKmh;

  /// XP this trip earned, or `null` when it could not be determined (brief:
  /// "XP gagné si dispo") — see `TripHistoryRecorder`'s doc comment for
  /// exactly when that happens. Deliberately `null`, never `0`, so a screen
  /// can tell "no XP source available" from "this trip earned zero XP".
  final double? xpEarned;

  /// The trip's compacted GPS track, `(lat, lon)` pairs in recording order.
  /// Bounded the same way the live tracker's own `TrackSampler` already is
  /// (`kTrackMaxPoints`, `exploration/track_sampler.dart`) — reused rather
  /// than re-implemented (brief: "borne de taille par trajet"). Empty for a
  /// trip whose track could not be read (still a valid summary — distance/
  /// duration/profile came straight from the trip snapshot, not the track).
  final List<(double, double)> track;

  const TripHistoryEntry({
    this.id,
    required this.startedAt,
    required this.endedAt,
    required this.profile,
    required this.distanceKm,
    required this.duration,
    required this.avgSpeedKmh,
    this.xpEarned,
    this.track = const [],
  });

  TripHistoryEntry copyWith({int? id}) => TripHistoryEntry(
    id: id ?? this.id,
    startedAt: startedAt,
    endedAt: endedAt,
    profile: profile,
    distanceKm: distanceKm,
    duration: duration,
    avgSpeedKmh: avgSpeedKmh,
    xpEarned: xpEarned,
    track: track,
  );

  Map<String, Object?> toRow() => {
    'started_at': startedAt.toUtc().toIso8601String(),
    'ended_at': endedAt.toUtc().toIso8601String(),
    'profile': profile.name,
    'distance_km': distanceKm,
    'duration_s': duration.inSeconds,
    'avg_speed_kmh': avgSpeedKmh,
    'xp_earned': xpEarned,
    'track': jsonEncode([
      for (final (lat, lon) in track) [lat, lon],
    ]),
  };

  /// Parses one row back, or throws for anything corrupt. Callers (see
  /// [TripHistoryStore.list]) treat a throw here as "skip this row" — the
  /// same per-row tolerance `GameJournal.readAll` gives a corrupt journal
  /// line: one bad row must never take the rest of the history down.
  ///
  /// [row] may omit the `track` column entirely (see [TripHistoryStore
  /// .list]'s column projection) — that reads back as an empty [track],
  /// exactly like a trip whose track genuinely couldn't be captured.
  static TripHistoryEntry fromRow(Map<String, Object?> row) {
    final trackRaw = row['track'];
    final trackJson = trackRaw is String
        ? jsonDecode(trackRaw) as List
        : const [];
    final track = <(double, double)>[
      for (final point in trackJson)
        (((point as List)[0] as num).toDouble(), (point[1] as num).toDouble()),
    ];
    return TripHistoryEntry(
      id: row['id'] as int?,
      startedAt: DateTime.parse(row['started_at'] as String),
      endedAt: DateTime.parse(row['ended_at'] as String),
      profile: RoutingProfile.values.firstWhere(
        (p) => p.name == row['profile'],
        orElse: () => RoutingProfile.walk,
      ),
      distanceKm: (row['distance_km'] as num).toDouble(),
      duration: Duration(seconds: (row['duration_s'] as num).toInt()),
      avgSpeedKmh: (row['avg_speed_kmh'] as num).toDouble(),
      xpEarned: (row['xp_earned'] as num?)?.toDouble(),
      track: track,
    );
  }
}

/// SQLite-backed local store of finalised trip summaries.
///
/// Uses the top-level `openDatabase` from `package:sqflite`, exactly like
/// `exploration/edges_store.dart` — the ambient `databaseFactory` variable
/// is the real platform plugin in production and `sqflite_common_ffi`'s
/// desktop factory in tests (set once in `setUpAll`).
class TripHistoryStore {
  final Database _db;

  TripHistoryStore._(this._db);

  /// Opens (creating if needed) the `trip_history` table at [path].
  static Future<TripHistoryStore> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE $_kTable ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'started_at TEXT NOT NULL, '
        'ended_at TEXT NOT NULL, '
        'profile TEXT NOT NULL, '
        'distance_km REAL NOT NULL, '
        'duration_s INTEGER NOT NULL, '
        'avg_speed_kmh REAL NOT NULL, '
        'xp_earned REAL, '
        'track TEXT NOT NULL'
        ')',
      ),
    );
    return TripHistoryStore._(db);
  }

  /// Inserts [entry] as a new row and returns its id.
  Future<int> record(TripHistoryEntry entry) =>
      _db.insert(_kTable, entry.toRow());

  /// Every recorded trip, newest first (brief: "liste antichronologique") —
  /// **summary only**: [TripHistoryEntry.track] always reads back empty
  /// (see [_kSummaryColumns]'s doc comment for why). Use [fetchById] to load
  /// one trip's full track for the detail screen. Rows that fail to parse
  /// (see [TripHistoryEntry.fromRow]) are skipped rather than failing the
  /// whole read.
  Future<List<TripHistoryEntry>> list({int? limit}) async {
    final rows = await _db.query(
      _kTable,
      columns: _kSummaryColumns,
      orderBy: 'started_at DESC',
      limit: limit,
    );
    final entries = <TripHistoryEntry>[];
    for (final row in rows) {
      try {
        entries.add(TripHistoryEntry.fromRow(row));
      } catch (_) {
        // One corrupt row costs one entry, never the whole history.
      }
    }
    return entries;
  }

  /// The most recently *started* trip, or `null` when history is empty (or
  /// its newest row happens to be corrupt). **Summary only** — see [list].
  ///
  /// This is the read Task 2g's congratulations screen is expected to use
  /// right after a trip is banked — see `task-2f-report.md` for the timing
  /// this is actually available on. 2g shows stats, not the trace, so
  /// summary-only is exactly what it needs; call [fetchById] with the
  /// returned [TripHistoryEntry.id] if it ever needs the track too.
  Future<TripHistoryEntry?> latest() async {
    final entries = await list(limit: 1);
    return entries.isEmpty ? null : entries.first;
  }

  /// One trip's full row, **including its track** — the only read in this
  /// store that loads a track at all, and only for the one trip actually
  /// being opened (the detail screen). `null` when no row has this [id], or
  /// its row is corrupt.
  Future<TripHistoryEntry?> fetchById(int id) async {
    final rows = await _db.query(
      _kTable,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    try {
      return TripHistoryEntry.fromRow(rows.single);
    } catch (_) {
      return null;
    }
  }

  Future<void> close() => _db.close();
}

/// The `trip_history.db` store for the current app-support directory —
/// opened independently of whatever instance `main.dart`'s
/// `_buildTripController` uses to record trips (same path; sqflite shares
/// one underlying connection per path within a process), mirroring how
/// `game/game_state_provider.dart`'s `gameJournalProvider` independently
/// resolves the same `GameJournal` path `ExplorationRecorder` writes to.
final tripHistoryStoreProvider = FutureProvider<TripHistoryStore>((ref) async {
  final dir = await getApplicationSupportDirectory();
  final store = await TripHistoryStore.open('${dir.path}/trip_history.db');
  ref.onDispose(() {
    // Best-effort: a provider disposed mid-await (e.g. the app closing)
    // must never throw out of a dispose callback.
    store.close().catchError((_) {});
  });
  return store;
});

/// Every recorded trip, newest first — re-reads on every access
/// (`autoDispose`) since this is only ever watched by a screen freshly
/// pushed onto the navigator, not a long-lived background subscription like
/// `gameStateProvider`.
final tripHistoryListProvider =
    FutureProvider.autoDispose<List<TripHistoryEntry>>((ref) async {
      final store = await ref.watch(tripHistoryStoreProvider.future);
      return store.list();
    });

/// One trip's full row (including its track), keyed by
/// [TripHistoryEntry.id] — what `TripHistoryDetailScreen` watches instead of
/// reusing the summary-only entry the list screen already has in memory
/// (review fix round 1, Critical 2: the list must never carry every trip's
/// track just so the one trip actually opened can draw its trace).
final tripHistoryDetailProvider = FutureProvider.autoDispose
    .family<TripHistoryEntry?, int>((ref, id) async {
      final store = await ref.watch(tripHistoryStoreProvider.future);
      return store.fetchById(id);
    });
