import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';

import '../tracking/trip_snapshot.dart';
import 'events.dart';
import 'grid.dart';
import 'reducers.dart';

/// XP awarded for a landmark's FIRST-EVER visit, any kind (Global
/// Constraints: "+25/landmark"). A cooldown-passing revisit earns its own
/// kind's reward (coins/energy) again, but never this XP a second time —
/// see [GameVisitConsumer._process]'s `firstVisit` check.
const kLandmarkXp = 25;

/// Reveal radius (meters) around a `reveal`-kind landmark once visited —
/// Global Constraints: "sync points (place_of_worship, tourism=viewpoint,
/// man_made=tower, historic=*) révèlent rayon 400 m".
const kLandmarkRevealRadiusM = 400.0;

/// Fraction of a quartier that must be revealed for the `quartier_25` badge
/// — same threshold `ExplorationRecorder` uses for a trip's own corridor
/// reveal; kept in sync here since a landmark's disc can just as well cross
/// it.
const kQuartierBadgeThreshold = 0.25;

/// Same physical Android notification channel id as
/// `tracking/tracking_service.dart`'s guidance-alert channel
/// (`_kAlertChannelId`, private there) — duplicated as a literal rather than
/// imported so this UI-isolate notifier and that service-isolate one stay
/// decoupled; the two isolates cannot share a Dart constant *instance*
/// anyway, only its value, and matching that value is all that is needed for
/// both to land on the same Android notification channel (created once, by
/// whichever side calls `show`/`initialize` first).
const _kGuidanceChannelId = 'guidance';

/// Distinct from the service's own alert notification id
/// (`_kAlertNotificationId`, tracking_service.dart) so a landmark alert
/// never clobbers — or is clobbered by — an in-flight turn-by-turn maneuver
/// alert.
const kLandmarkNotificationId = 4213;

/// Turns the service's `TripSnapshot.pendingVisits` into journal events (per
/// the M4 event contract's locked payload schema — see task-1-report.md)
/// and a discreet alert, one call per detected visit.
///
/// **Event order per visit** (the plan's binding decision): `landmark_visited`
/// first, then — for `kind == 'reveal'` only — `cell_revealed` (and a
/// `quartier_25` `badge_unlocked` if that reveal crosses the threshold),
/// then `xp_earned` for every FIRST-EVER visit to that `poiId` (any kind).
/// A cooldown-blocked revisit therefore emits `landmark_visited` alone.
/// Coin/energy rewards are not separate events: they live inside
/// `landmark_visited`'s own reducer logic (`reducers.dart`), so this class
/// never emits `coins_earned`/`energy_changed` itself.
///
/// **Idempotency, not just dedup**: [consume] skips any `(poiId, ts)` pair
/// already seen (see [_seen]) purely as a performance/hygiene measure — the
/// service republishes its whole rolling window of detections on every
/// snapshot for the rest of the trip (see `TripSnapshot.pendingVisits`'s doc
/// comment), and without this a long trip would re-append/re-alert on the
/// same old visit over and over. Correctness does not depend on it, though:
/// every event this class emits for a visit carries that visit's OWN
/// timestamp ([PendingVisit.ts]), never "now", which is what makes
/// reprocessing an identical [PendingVisit] a true no-op even if [_seen]
/// were somehow lost (a UI process restart, in production) — replaying an
/// identical `landmark_visited` a second time evaluates
/// `ts.difference(lastRewardedTs) == Duration.zero`, which never clears a
/// cooldown, and the companion `xp_earned` is gated on
/// `state.visitedPoiIds` (already true from the first, real append), not on
/// anything only this class remembers.
class GameVisitConsumer {
  final GameJournal journal;

  /// Posts the discreet alert (« ⚑ Nom — +25 XP », coin/energy phrasing) —
  /// null in tests that do not care, wired to [GuidanceAlertNotifier] in
  /// `main.dart` in production.
  final Future<void> Function(String text)? notify;

  final String Function() _newId;

  /// `(poiId, ts)` pairs already processed, oldest-first — see the class
  /// doc comment. Bounded at [kPendingVisitsMax] (the service's own cap on
  /// how many visits [TripSnapshot.pendingVisits] can ever carry at once),
  /// so this never needs to remember more than the source could contain.
  final List<String> _seenOrder = [];
  final Set<String> _seen = {};

  GameVisitConsumer({
    required this.journal,
    this.notify,
    String Function()? newId,
  }) : _newId = newId ?? (() => const Uuid().v4());

  /// Processes every visit in [visits] not already seen. Never throws — a
  /// broken journal write, a malformed [PendingVisit], or a misbehaving
  /// [notify] callback must never escape into `TripController`'s
  /// fire-and-forget caller (a second, independent guard on top of that
  /// caller's own `catchError`, same relationship `ExplorationRecorder.process`
  /// has to its own internals).
  ///
  /// Fix round 1 (Task 5 review, item 2): the journal is read — and reduced
  /// to a starting [GameState] — exactly ONCE per call, not once per visit.
  /// Each visit's own effect is then folded onto that running state via
  /// [reduceOne] (a single left-fold step) rather than by re-reading and
  /// fully re-replaying the whole journal again to see it: for a batch of
  /// N already-undetected visits this is one `readAll`/one base `reduceAll`
  /// plus N cheap single-event folds, instead of up to 2N full replays.
  Future<void> consume(List<PendingVisit> visits) async {
    final toProcess = <PendingVisit>[];
    for (final visit in visits) {
      final key = '${visit.poiId}@${visit.ts.toIso8601String()}';
      if (_seen.contains(key)) continue;
      _remember(key);
      toProcess.add(visit);
    }
    if (toProcess.isEmpty) return;

    GameState state;
    try {
      state = reduceAll(await journal.readAll());
    } catch (_) {
      // Can't safely proceed without a known starting state; the next
      // snapshot's republished visits (see the "ack design" doc comment on
      // `TripSnapshot.pendingVisits`) will simply retry this batch later.
      return;
    }

    for (final visit in toProcess) {
      try {
        state = await _process(visit, state);
      } catch (_) {
        // A single bad visit must never stop the rest of this batch, or the
        // trip it came from — `state` deliberately stays whatever it was
        // before this visit, so a later visit in the same batch never folds
        // onto a partially-applied one.
      }
    }
  }

  void _remember(String key) {
    _seen.add(key);
    _seenOrder.add(key);
    while (_seenOrder.length > kPendingVisitsMax) {
      _seen.remove(_seenOrder.removeAt(0));
    }
  }

  /// Processes one [visit] against the already-known [before] state (the
  /// running fold from [consume], not a fresh read of the journal) and
  /// returns the resulting state for [consume] to carry into the next visit
  /// in the same batch.
  Future<GameState> _process(PendingVisit visit, GameState before) async {
    final toAppend = <GameEvent>[];

    final payload = <String, dynamic>{
      'poiId': visit.poiId,
      'kind': visit.kind,
      // Fix round 1 (Task 5 review, item 1): ALWAYS present for an
      // energy-kind visit, even when `visit.subkind` is null — a malformed
      // dataset entry (`GamePoi.subkind` is nullable by design) must not
      // omit this key. The reducer tolerates an empty/unrecognized subkind
      // (no reward, no cooldown write — see `reducers.dart`'s
      // `_reduceLandmarkVisited`), but only if the event applies
      // successfully in the first place; omitting the key here made the
      // OLD reducer throw on an unconditional cast, which discarded the
      // WHOLE event (including `visitedPoiIds`) and let every future visit
      // to that same broken landmark mint another `xp_earned` forever.
      if (visit.kind == 'energy') 'subkind': visit.subkind ?? '',
    };
    toAppend.add(_event(GameEventTypes.landmarkVisited, payload, visit.ts));

    if (visit.kind == 'reveal') {
      _appendReveal(toAppend, visit, before);
    }

    final firstVisit = !before.visitedPoiIds.contains(visit.poiId);
    if (firstVisit) {
      toAppend.add(_event(GameEventTypes.xpEarned,
          {'amount': kLandmarkXp, 'preMultiplied': false}, visit.ts));
    }

    await journal.appendAll(toAppend);

    var after = before;
    for (final event in toAppend) {
      after = reduceOne(after, event);
    }
    await _maybeAlert(visit, before: before, after: after);
    return after;
  }

  /// Reveal-kind visits also reveal a [kLandmarkRevealRadiusM]-meter disc
  /// around the landmark (Global Constraints: "sync points ... révèlent
  /// rayon 400 m") — the same `cell_revealed`/`quartier_25` treatment
  /// `ExplorationRecorder` gives a trip's own corridor, applied here too so
  /// a quartier can cross 25% from a landmark's reveal just as well as from
  /// ground actually walked.
  void _appendReveal(
      List<GameEvent> toAppend, PendingVisit visit, GameState before) {
    // Fix round 1 (Task 5 review, item 3): diff directly against the
    // string keys `before.revealedCellKeys` already stores, instead of
    // first parsing the WHOLE revealed-cell set into `CellId`s just to
    // compute a difference — this runs on every reveal-kind visit
    // (including cooldown-repeats that produce no new cells), so avoiding
    // an O(all revealed cells) parse on the common path matters as a game
    // gets played for a while.
    final disc = discCells(visit.lat, visit.lon, kLandmarkRevealRadiusM);
    final newCells =
        disc.where((c) => !before.revealedCellKeys.contains(c.key)).toSet();
    if (newCells.isEmpty) return;

    toAppend.add(_event(
        GameEventTypes.cellRevealed,
        {'cells': [for (final c in newCells) c.key]},
        visit.ts));

    if (!before.badges.contains(GameBadges.quartier25)) {
      // Only parse the full revealed-cell-key set into `CellId`s when a
      // quartier-completion check might actually need it — the common case
      // (badge already unlocked) never pays this cost at all.
      final revealedIds = <CellId>{
        for (final key in before.revealedCellKeys)
          if (CellId.parseKey(key) case final parsed?) parsed,
      };
      final revealedAfter = {...revealedIds, ...newCells};
      final crossed = newCells.any((c) =>
          quartierCompletion(c, revealedAfter) >= kQuartierBadgeThreshold);
      if (crossed) {
        toAppend.add(_event(GameEventTypes.badgeUnlocked,
            {'badge': GameBadges.quartier25}, visit.ts));
      }
    }
  }

  /// Discreet alert, only when this visit actually produced SOME reward —
  /// a cooldown-blocked revisit (`landmark_visited` alone, no `xp_earned`,
  /// no coin/energy change) stays silent per the brief. Computed by diffing
  /// [before]/[after] rather than re-deriving the reducer's own cooldown
  /// logic here — the simplest-correct approach the brief itself names.
  Future<void> _maybeAlert(
    PendingVisit visit, {
    required GameState before,
    required GameState after,
  }) async {
    final coinsDelta = after.coins - before.coins;
    final energyDelta = after.energy - before.energy;
    final xpDelta = after.xp - before.xp;
    if (coinsDelta == 0 && energyDelta == 0 && xpDelta == 0) return;
    final notifyFn = notify;
    if (notifyFn == null) return;
    try {
      await notifyFn(_alertText(visit,
          coinsDelta: coinsDelta, energyDelta: energyDelta, xpDelta: xpDelta));
    } catch (_) {
      // A notification-plugin hiccup must never surface past this.
    }
  }

  String _alertText(
    PendingVisit visit, {
    required int coinsDelta,
    required double energyDelta,
    required int xpDelta,
  }) {
    final label = visit.name ?? _defaultLabel(visit.kind);
    final parts = <String>[
      if (coinsDelta > 0) '+$coinsDelta pièces',
      if (energyDelta > 0) '+${energyDelta.round()} énergie',
      if (xpDelta > 0) '+$xpDelta XP',
    ];
    return '⚑ $label — ${parts.join(' · ')}';
  }

  static String _defaultLabel(String kind) => switch (kind) {
        'coins' => 'Banque',
        'energy' => 'Pause',
        _ => 'Point de repère',
      };

  GameEvent _event(String type, Map<String, dynamic> payload, DateTime ts) =>
      GameEvent(id: _newId(), ts: ts, type: type, payload: payload);
}

/// Posts a landmark-visit alert on the same « guidage » notification
/// channel `TripTaskHandler._postAlertNotification` uses for maneuver
/// alerts — same sober, low-key styling, a distinct notification id (see
/// [kLandmarkNotificationId]) so a landmark alert never clobbers an
/// in-flight turn alert.
///
/// Runs in the UI isolate — unlike the service's own instance,
/// `flutter_local_notifications` keeps no state across isolates, so each
/// side needs its own `initialize()` call (see tracking_service.dart's own
/// doc comment on the same point).
class GuidanceAlertNotifier {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  GuidanceAlertNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  Future<void> call(String text) async {
    if (!_ready) {
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _ready = true;
    }
    await _plugin.show(
      id: kLandmarkNotificationId,
      title: 'RandomWalk',
      body: text,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _kGuidanceChannelId,
          'Guidage',
          channelDescription:
              "Alerte sonore et vibration à l'approche d'une manœuvre.",
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
          enableVibration: true,
          timeoutAfter: 8000,
        ),
      ),
    );
  }
}
