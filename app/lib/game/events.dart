import 'dart:convert';
import 'dart:io';

/// Event type constants for [GameEvent.type].
///
/// This is the closed set of M4 event types. [GameJournal] accepts any
/// string (forward compat with events written by a newer app version), and
/// the reducers in `reducers.dart` ignore any type they don't recognize —
/// so a future type showing up in an old journal never crashes replay.
class GameEventTypes {
  GameEventTypes._();

  static const edgeCoveredBatch = 'edge_covered_batch';
  static const cellRevealed = 'cell_revealed';
  static const landmarkVisited = 'landmark_visited';
  static const coinsEarned = 'coins_earned';
  static const coinsSpent = 'coins_spent';
  static const energyChanged = 'energy_changed';
  static const xpEarned = 'xp_earned';
  static const badgeUnlocked = 'badge_unlocked';
  static const streakUpdated = 'streak_updated';
}

/// A single fact appended to the game's event journal.
///
/// Every piece of game state (coins, energy, XP, badges, streaks, visited
/// places, covered edges) is derived by replaying a sequence of these
/// through the pure reducers in `reducers.dart` — this class carries no
/// behaviour of its own, only data. [ts] is the authoritative clock for the
/// reducers: nothing in this layer calls `DateTime.now()`.
class GameEvent {
  final String id;
  final DateTime ts;
  final String type;
  final Map<String, dynamic> payload;

  const GameEvent({
    required this.id,
    required this.ts,
    required this.type,
    this.payload = const {},
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'ts': ts.toIso8601String(),
        'type': type,
        'payload': payload,
      };

  factory GameEvent.fromJson(Map<String, dynamic> json) => GameEvent(
        id: json['id'] as String,
        ts: DateTime.parse(json['ts'] as String),
        type: json['type'] as String,
        payload: json['payload'] == null
            ? const {}
            : Map<String, dynamic>.from(json['payload'] as Map),
      );
}

/// Append-only JSONL journal of [GameEvent]s, the foundation for both the
/// M4 game state (via the pure reducers) and the future M5 sync.
///
/// The backing file (`game_events.jsonl`) lives inside [dir], which the
/// caller injects — tests pass a temp directory, production wires the
/// platform's app-support directory. Missing directories are created lazily
/// on first [append]; a missing or empty file reads back as `[]`.
class GameJournal {
  final Directory dir;
  GameJournal(this.dir);

  /// Number of lines [readAll] had to skip on its most recent call because
  /// they failed to parse as a JSON object or as a [GameEvent] (e.g. a
  /// truncated line from a write interrupted by a crash/power loss, or a
  /// stray blank/whitespace-only line). Reflects only the latest call, not
  /// a running total across the journal's lifetime.
  int get skippedLines => _skippedLines;
  int _skippedLines = 0;

  String get _path => '${dir.path}/game_events.jsonl';

  /// Appends [event] as one JSON-object-per-line write, terminated by `\n`.
  ///
  /// The encoded line is written and flushed in a single `writeAsString`
  /// call opened in append mode, so a concurrent reader never observes a
  /// half-written line — the write either lands whole or (on a crash
  /// beforehand) not at all.
  Future<void> append(GameEvent event) async {
    await dir.create(recursive: true);
    final line = '${jsonEncode(event.toJson())}\n';
    await File(_path).writeAsString(
      line,
      mode: FileMode.append,
      flush: true,
    );
  }

  /// Reads every event from the journal, in file (append) order.
  ///
  /// A missing file yields `[]`. Lines that fail to decode — corrupt or
  /// truncated JSON, or JSON that isn't a valid [GameEvent] — are skipped
  /// rather than aborting the whole read; [skippedLines] reports how many
  /// were dropped so callers can log/telemeter it. This is what lets the
  /// game degrade gracefully instead of blocking the app when the journal
  /// is damaged.
  Future<List<GameEvent>> readAll() async {
    final file = File(_path);
    _skippedLines = 0;
    if (!await file.exists()) return const [];

    final events = <GameEvent>[];
    final lines = await file.readAsLines();
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      try {
        final json = jsonDecode(line);
        events.add(GameEvent.fromJson(json as Map<String, dynamic>));
      } catch (_) {
        _skippedLines++;
      }
    }
    return events;
  }
}
