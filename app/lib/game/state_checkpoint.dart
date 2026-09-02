import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'events.dart';
import 'reducers.dart';

/// Format version for the JSON [GameStateCheckpoint.toJson] writes.
///
/// [GameStateCheckpoint.fromJson] rejects any other value outright (throws,
/// caught by [GameStateCheckpointStore.read]) — including a NEWER version a
/// future app build might write, which this build cannot know how to
/// interpret. Either way [loadStateFast] just falls back to a full
/// [reduceAll] replay: an unrecognized/corrupt checkpoint is never a crash,
/// only a slower load, per this task's binding requirement.
const kGameStateCheckpointVersion = 1;

/// How many new events must have accumulated, in file order, past the
/// current checkpoint's [GameStateCheckpoint.fileEventCount] before
/// [loadStateFast] bothers writing a fresh one. Keeps checkpointing
/// "périodique" (the plan's own word) instead of on every single call: at
/// the default, a 10k-event journal accumulates on the order of tens of
/// checkpoint writes over its life, and [loadStateFast]'s tail replay never
/// has to fold more than roughly this many events by hand.
const kGameStateCheckpointIntervalEvents = 200;

/// A periodic snapshot of [GameState] plus enough bookkeeping to know
/// whether it can still be safely combined with whatever the journal has
/// grown by since — see [loadStateFast]'s dartdoc for the full validity
/// invariant this bookkeeping exists to enforce.
class GameStateCheckpoint {
  /// Number of events, in [GameJournal.readAll]'s file (append) order, that
  /// [state] already reflects. A prefix boundary in FILE order — NOT a
  /// position in [reduceAll]'s sorted replay order, which can differ once
  /// M5 sync merges a remote event with an older `ts` onto the journal tail
  /// (`sync/sync_engine.dart`).
  final int fileEventCount;

  /// [GameJournal.skippedLines] at the moment this checkpoint was written —
  /// mirrors `SyncCursorState.knownSkippedLines` (`sync/sync_state_store
  /// .dart`)'s identical concern: a line that used to fail to parse (or now
  /// does) shifts every index `readAll()`'s parsed result implies, so a
  /// changed count invalidates the checkpoint outright rather than trying
  /// to reconcile it.
  final int skippedLinesAtCheckpoint;

  /// The maximum [GameEvent.ts] among the [fileEventCount] checkpointed
  /// events, or `null` only when [fileEventCount] is 0 (never actually
  /// written by [loadStateFast], which skips checkpointing an empty
  /// journal, but tolerated on read for a hand-built [GameStateCheckpoint]
  /// in tests).
  final DateTime? maxTs;

  /// A cheap `sha256` **boundary fingerprint** of the [fileEventCount]-event
  /// prefix — over the count plus the first and last checkpointed event's
  /// `(id, ts, type)` only, deliberately NOT the full prefix content. Its
  /// job is the plan's "hash de préfixe simple" invalidation trigger:
  /// detect the prefix having been rewritten/reordered/replaced since this
  /// checkpoint was taken, even when the file still has at least
  /// [fileEventCount] lines.
  ///
  /// **Deliberately O(1), not O(prefix), even though that means it cannot
  /// catch every conceivable rewrite** (a hypothetical edit that changes
  /// only events strictly BETWEEN the first and last of the prefix, while
  /// leaving both boundary events byte-identical, would slip through). See
  /// [loadStateFast]'s dartdoc for why: [GameJournal] itself never rewrites
  /// existing lines (only appends), so this only defends a hypothetical
  /// FUTURE compaction feature or direct file tampering — and hashing the
  /// full, potentially-thousands-of-events prefix on every single
  /// [loadStateFast] call (checkpoint hit or not) was measured to erase
  /// most of the fast path's own benefit, since it is exactly as expensive
  /// as the [reduceAll] work the checkpoint exists to avoid repeating.
  final String prefixHash;

  /// The [GameState] that replaying [fileEventCount] file-order events,
  /// sorted the way [reduceAll] sorts them, through the pure reducers
  /// produces.
  final GameState state;

  const GameStateCheckpoint({
    required this.fileEventCount,
    required this.skippedLinesAtCheckpoint,
    required this.maxTs,
    required this.prefixHash,
    required this.state,
  });

  Map<String, dynamic> toJson() => {
    'version': kGameStateCheckpointVersion,
    'fileEventCount': fileEventCount,
    'skippedLinesAtCheckpoint': skippedLinesAtCheckpoint,
    'maxTs': maxTs?.toIso8601String(),
    'prefixHash': prefixHash,
    'state': _stateToJson(state),
  };

  /// Throws (`FormatException`/`TypeError`/similar) on anything that
  /// doesn't decode cleanly, INCLUDING an unrecognized `version` —
  /// [GameStateCheckpointStore.read] catches every such failure and treats
  /// it as "no usable checkpoint".
  factory GameStateCheckpoint.fromJson(Map<String, dynamic> json) {
    if (json['version'] != kGameStateCheckpointVersion) {
      throw const FormatException('unsupported game state checkpoint version');
    }
    final maxTsRaw = json['maxTs'] as String?;
    return GameStateCheckpoint(
      fileEventCount: json['fileEventCount'] as int,
      skippedLinesAtCheckpoint: json['skippedLinesAtCheckpoint'] as int,
      maxTs: maxTsRaw == null ? null : DateTime.parse(maxTsRaw),
      prefixHash: json['prefixHash'] as String,
      state: _stateFromJson(json['state'] as Map<String, dynamic>),
    );
  }
}

Map<String, dynamic> _stateToJson(GameState s) => {
  'coins': s.coins,
  'energy': s.energy,
  'xp': s.xp,
  'level': s.level,
  'badges': s.badges.toList(),
  'streakDays': s.streakDays,
  'lastActivityDay': s.lastActivityDay?.toIso8601String(),
  'visitedPoiIds': s.visitedPoiIds.toList(),
  'lastVisitByPoi': s.lastVisitByPoi.map(
    (k, v) => MapEntry(k, v.toIso8601String()),
  ),
  'visitCountByPoi': s.visitCountByPoi,
  'landmarksVisited': s.landmarksVisited,
  'totalKm': s.totalKm,
  'cellsRevealed': s.cellsRevealed,
  'loopsCompleted': s.loopsCompleted,
  'activeDays': s.activeDays.toList(),
  'revealedCellKeys': s.revealedCellKeys.toList(),
};

GameState _stateFromJson(Map<String, dynamic> j) => GameState(
  coins: j['coins'] as int,
  energy: (j['energy'] as num).toDouble(),
  xp: j['xp'] as int,
  level: j['level'] as int,
  badges: Set<String>.from(j['badges'] as List),
  streakDays: j['streakDays'] as int,
  lastActivityDay: j['lastActivityDay'] == null
      ? null
      : DateTime.parse(j['lastActivityDay'] as String),
  visitedPoiIds: Set<String>.from(j['visitedPoiIds'] as List),
  lastVisitByPoi: (j['lastVisitByPoi'] as Map<String, dynamic>).map(
    (k, v) => MapEntry(k, DateTime.parse(v as String)),
  ),
  visitCountByPoi: Map<String, int>.from(j['visitCountByPoi'] as Map),
  landmarksVisited: j['landmarksVisited'] as int,
  totalKm: (j['totalKm'] as num).toDouble(),
  cellsRevealed: j['cellsRevealed'] as int,
  loopsCompleted: j['loopsCompleted'] as int,
  activeDays: Set<String>.from(j['activeDays'] as List),
  revealedCellKeys: Set<String>.from(j['revealedCellKeys'] as List),
);

/// Persists/restores a single [GameStateCheckpoint] in a JSON file living
/// next to the journal (`GameJournal.dir`, "à côté du journal" per the
/// plan) — `game_state_checkpoint.json`, a sibling of `game_events.jsonl`.
class GameStateCheckpointStore {
  final Directory dir;

  const GameStateCheckpointStore(this.dir);

  String get _path => '${dir.path}/game_state_checkpoint.json';

  /// Reads back the last checkpoint written by [write], or `null` for
  /// "nothing usable" — a missing file, an empty one, a corrupt one, or one
  /// written by an unrecognized format version. Never throws.
  Future<GameStateCheckpoint?> read() async {
    try {
      final file = File(_path);
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      return GameStateCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Atomic write — temp file + rename, the same pattern
  /// `trip/active_route_store.dart` and `tracking/trip_snapshot.dart` use —
  /// so a crash mid-write leaves the previous good checkpoint in place
  /// rather than a truncated/corrupt one. Lets any failure propagate: the
  /// caller ([_maybeWriteCheckpoint]) is the guard, so a write failure is
  /// swallowed exactly once, in exactly one place.
  Future<void> write(GameStateCheckpoint checkpoint) async {
    await dir.create(recursive: true);
    final tmp = File('$_path.tmp');
    await tmp.writeAsString(jsonEncode(checkpoint.toJson()), flush: true);
    await tmp.rename(_path);
  }
}

/// [GameStateCheckpoint.prefixHash]'s O(1) boundary fingerprint — see that
/// field's dartdoc for what it does and doesn't catch, and why. [count] is
/// separate from `events.length` so the same helper serves both
/// [_isValid] (fingerprinting exactly the checkpointed prefix, which can be
/// shorter than the current [events]) and [_maybeWriteCheckpoint]
/// (fingerprinting the whole, newly-checkpointed [events] list).
String _prefixFingerprint(List<GameEvent> events, int count) {
  if (count == 0) return sha256.convert(utf8.encode('empty')).toString();
  final first = events[0];
  final last = events[count - 1];
  final summary =
      '$count|${first.id}|${first.ts.toIso8601String()}|${first.type}|'
      '${last.id}|${last.ts.toIso8601String()}|${last.type}';
  return sha256.convert(utf8.encode(summary)).toString();
}

/// Mirrors `reducers.dart`'s private `_typePrecedence`/
/// `_byTsPrecedenceThenId` exactly — duplicated, not imported, because both
/// are library-private to `reducers.dart` and this task's brief locks that
/// file from any change.
///
/// Needed ONLY to order a checkpoint's TAIL events among THEMSELVES the way
/// [reduceAll] would — never to decide whether the checkpoint is usable at
/// all (see [loadStateFast]'s dartdoc: that decision compares raw `ts`
/// alone, deliberately, precisely so it does not need this table).
/// `state_checkpoint_test.dart`'s equivalence property test is the
/// correctness backstop that would catch any drift between this copy and
/// the real one: every same-`ts` ordering hazard `reducers.dart`'s own
/// table documents (`xp_earned`/`energy_changed`, `landmark_visited`/
/// `xp_earned`) is exercised there too, via checkpoint+tail replay compared
/// against a from-scratch [reduceAll].
int _tailTypePrecedence(String type) => switch (type) {
  GameEventTypes.landmarkVisited => 0,
  GameEventTypes.energyChanged => 2,
  _ => 1,
};

int _byTsPrecedenceThenId(GameEvent a, GameEvent b) {
  final byTs = a.ts.compareTo(b.ts);
  if (byTs != 0) return byTs;
  final byPrecedence = _tailTypePrecedence(
    a.type,
  ).compareTo(_tailTypePrecedence(b.type));
  if (byPrecedence != 0) return byPrecedence;
  return a.id.compareTo(b.id);
}

/// Loads the current [GameState] for [journal]: [checkpointStore]'s
/// checkpoint-plus-tail fast path when a valid checkpoint exists, a full
/// [reduceAll] replay otherwise. Always produces exactly the same
/// [GameState] `reduceAll(await journal.readAll())` would — see the
/// invariant below for why, and `state_checkpoint_test.dart`'s property
/// test for the equivalence check that pins it down.
///
/// ## The validity invariant (binding — see task-5-brief.md)
///
/// [reduceAll] does not replay events in file (append) order — it sorts by
/// `(ts, type-precedence, id)` first (see its own dartdoc), because M5's
/// `SyncEngine` (`sync/sync_engine.dart`) appends remote-pulled events to
/// the journal TAIL carrying whatever `ts` they were originally recorded
/// with, which can be OLDER than events already at the tail's own front —
/// "a landmark visit recorded offline, then a same-day-earlier event pulled
/// from another device after reconnecting" (`reducers.dart`'s own words). A
/// checkpoint, by construction, only ever covers a prefix of the journal in
/// FILE order. So "checkpoint + replay the file-order tail" is equivalent
/// to "full sorted replay of everything" **only when no tail event would
/// have sorted at or before the last checkpointed event** once the whole
/// journal is sorted together.
///
/// [GameStateCheckpoint.maxTs] is what makes that check cheap: a tail event
/// only needs `tailEvent.ts.isAfter(checkpoint.maxTs)` — strictly; a TIE
/// invalidates too — for its position relative to every checkpointed event
/// to be settled by `ts` alone. `ts` is the PRIMARY key of [reduceAll]'s
/// sort, so a strictly-later `ts` guarantees a strictly-later sort position
/// regardless of type-precedence/id (those only ever break a `ts` TIE).
/// This is a deliberately coarser, safe-by-construction proxy for comparing
/// full `(ts, precedence, id)` sort keys, chosen specifically so this file
/// never has to duplicate `reducers.dart`'s private type-precedence table
/// just to decide whether the checkpoint is still usable (it IS still
/// needed, but only to order the tail's own events among themselves once
/// the checkpoint has already been accepted — see [_byTsPrecedenceThenId]).
/// Any violation (some tail event's `ts` <= `checkpoint.maxTs`) invalidates
/// the checkpoint outright and falls back to a full replay — "simple,
/// correct", per the brief, not an attempt to salvage a partial checkpoint.
///
/// Three more invalidation triggers, all falling back to a full replay:
/// - the journal now has FEWER events than `checkpoint.fileEventCount`
///   (truncated, or replaced by a shorter file);
/// - `checkpoint.prefixHash` — the plan's "hash de préfixe simple" — no
///   longer matches the current first `fileEventCount` events, catching a
///   prefix that was
///   rewritten/reordered even though the file is still long enough (an O(1)
///   check — see [GameStateCheckpoint.prefixHash]'s dartdoc for exactly
///   what it does and doesn't catch, and why it is deliberately not a full
///   scan of the prefix: an earlier version of this file hashed the WHOLE
///   prefix on every call and measured out to erase most of the fast
///   path's benefit, since that is exactly as expensive as the work being
///   avoided);
/// - `journal.skippedLines` differs from
///   `checkpoint.skippedLinesAtCheckpoint` — mirrors
///   `SyncEngine._reconcileCorruption`'s identical concern for
///   `SyncCursorState.pushedIndex`/`knownSkippedLines`: a line that used to
///   fail to parse (or now does) shifts every index `readAll()`'s parsed
///   result implies, so the positional prefix boundary can no longer be
///   trusted.
///
/// All of the above are O(1) or O(tail) — none scan the checkpointed
/// prefix itself, which is what keeps [loadStateFast]'s fast path actually
/// fast on a large journal. [_replayTail] separately dedupes by id WITHIN
/// the tail (mirroring [reduceAll]'s own id-dedup, restricted to what
/// could plausibly repeat there — see its own doc comment for why a
/// prefix/tail duplicate isn't a reachable case worth an O(prefix) scan to
/// rule out).
///
/// ## Checkpoint writes never block gameplay
///
/// After computing the state to return (via either path), [loadStateFast]
/// fires off (`unawaited`, wrapped in its own try/catch) a fresh checkpoint
/// write when either there isn't a valid one yet or [intervalEvents] new
/// events have landed past the current one's
/// [GameStateCheckpoint.fileEventCount] — "snapshot périodique" per the
/// plan, not on every call. A write failure (disk full, permissions,
/// anything) is swallowed: it can only ever cost a slower NEXT load, never
/// this one.
Future<GameState> loadStateFast(
  GameJournal journal,
  GameStateCheckpointStore checkpointStore, {
  int intervalEvents = kGameStateCheckpointIntervalEvents,
}) async {
  final events = await journal.readAll();
  final skippedLines = journal.skippedLines;
  final checkpoint = await checkpointStore.read();

  final usable =
      checkpoint != null && _isValid(checkpoint, events, skippedLines);

  final state = usable ? _replayTail(checkpoint, events) : reduceAll(events);

  unawaited(
    _maybeWriteCheckpoint(
      store: checkpointStore,
      events: events,
      skippedLines: skippedLines,
      state: state,
      existingValidCheckpoint: usable ? checkpoint : null,
      intervalEvents: intervalEvents,
    ),
  );

  return state;
}

bool _isValid(
  GameStateCheckpoint checkpoint,
  List<GameEvent> events,
  int skippedLines,
) {
  if (events.length < checkpoint.fileEventCount) return false;
  if (skippedLines != checkpoint.skippedLinesAtCheckpoint) return false;

  // O(1): see GameStateCheckpoint.prefixHash's dartdoc for exactly what
  // this boundary fingerprint does and doesn't catch, and why it is
  // deliberately not a full scan of the prefix.
  if (_prefixFingerprint(events, checkpoint.fileEventCount) !=
      checkpoint.prefixHash) {
    return false;
  }

  if (events.length == checkpoint.fileEventCount) return true;

  final maxTs = checkpoint.maxTs;
  if (maxTs != null) {
    for (var i = checkpoint.fileEventCount; i < events.length; i++) {
      if (!events[i].ts.isAfter(maxTs)) return false;
    }
  }
  return true;
}

/// Folds [events]'s tail (everything past [checkpoint.fileEventCount],
/// sorted among itself the way [reduceAll] would sort it — see
/// [_byTsPrecedenceThenId]) onto [checkpoint.state] via [reduceOne], one
/// event at a time. Only ever called once [_isValid] has already confirmed
/// no tail event can sort before/among the checkpointed prefix, which is
/// what makes this equivalent to a full [reduceAll] of [events].
GameState _replayTail(GameStateCheckpoint checkpoint, List<GameEvent> events) {
  final tail = events.sublist(checkpoint.fileEventCount)
    ..sort(_byTsPrecedenceThenId);
  var state = checkpoint.state;
  // Dedup within the tail only (O(tail), not O(prefix)) — mirrors
  // reduceAll's own id-dedup loop, restricted to what could plausibly
  // repeat here. A prefix/tail duplicate is not a reachable case: every
  // writer in this codebase (GameVisitConsumer, ExplorationRecorder) mints
  // a fresh uuid per event, and SyncEngine's merge step already filters
  // pulled events against the journal's own known ids before appending —
  // so it is not worth an O(prefix) scan on every load to additionally
  // rule out.
  final seenTailIds = <String>{};
  for (final e in tail) {
    if (!seenTailIds.add(e.id)) continue;
    state = reduceOne(state, e);
  }
  return state;
}

Future<void> _maybeWriteCheckpoint({
  required GameStateCheckpointStore store,
  required List<GameEvent> events,
  required int skippedLines,
  required GameState state,
  required GameStateCheckpoint? existingValidCheckpoint,
  required int intervalEvents,
}) async {
  if (events.isEmpty) return;
  final since = events.length - (existingValidCheckpoint?.fileEventCount ?? 0);
  if (existingValidCheckpoint != null && since < intervalEvents) return;
  try {
    var maxTs = events.first.ts;
    for (final e in events) {
      if (e.ts.isAfter(maxTs)) maxTs = e.ts;
    }
    await store.write(
      GameStateCheckpoint(
        fileEventCount: events.length,
        skippedLinesAtCheckpoint: skippedLines,
        maxTs: maxTs,
        prefixHash: _prefixFingerprint(events, events.length),
        state: state,
      ),
    );
  } catch (_) {
    // Best-effort: a failed checkpoint write must never affect gameplay —
    // the next loadStateFast call simply falls back to a full replay again.
  }
}
