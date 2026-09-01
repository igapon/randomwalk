import '../game/reducers.dart' show GameBadges;

/// French display labels for every M4 badge id (see `GameBadges` in
/// `game/reducers.dart` — the exact strings that travel in
/// `badge_unlocked.payload['badge']`). Kept as its own small pure mapping so
/// the badges sheet never has to embed French copy inline, and so the
/// mapping itself is unit-testable without pumping any widget.
const Map<String, String> kBadgeLabels = {
  GameBadges.firstTrip: 'Premier trajet',
  GameBadges.firstLoop: 'Première boucle',
  GameBadges.km10: '10 km parcourus',
  GameBadges.km50: '50 km parcourus',
  GameBadges.km100: '100 km parcourus',
  GameBadges.landmarks10: '10 repères visités',
  GameBadges.streak7: '7 jours de suite',
  GameBadges.quartier25: "25 % d'un quartier",
};

/// The fixed display order for the badges grid — `GameState.badges` is a
/// `Set<String>`, whose iteration order is not guaranteed to be stable or
/// meaningful, so the sheet always walks this list instead (unlocked ids
/// come from [kBadgeOrder]'s membership in `GameState.badges`, not from
/// iterating the set itself).
const List<String> kBadgeOrder = [
  GameBadges.firstTrip,
  GameBadges.firstLoop,
  GameBadges.km10,
  GameBadges.km50,
  GameBadges.km100,
  GameBadges.landmarks10,
  GameBadges.streak7,
  GameBadges.quartier25,
];

/// The French label for [badgeId], or the id itself as a last-resort
/// fallback (forward compat: a badge id from a newer app version that this
/// build doesn't have copy for yet still renders as *something* rather than
/// throwing).
String badgeLabel(String badgeId) => kBadgeLabels[badgeId] ?? badgeId;
