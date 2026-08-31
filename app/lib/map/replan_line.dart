/// Pure decision logic for the map's replanned-route overlay (final review
/// item 4: a replanned line drawn for one route-bound trip stayed on screen
/// for the *next* trip — a fresh start or a « Reprendre » — because the old
/// gate compared `TripSnapshot.navReplanCount`, which restarts at 0 for
/// every new follower and read that as "nothing to do" even when a
/// previous trip's replanned line was still drawn).
///
/// [MapScreenState] cannot itself be unit-tested — it owns a real
/// `MapLibreMapController` backed by a platform view — so the rule for
/// *whether the drawn route line needs to change* is kept here as a pure
/// function of two strings the widget already tracks, the same pattern
/// `nav_camera_state.dart` uses for the camera-follow rules.
library;

/// What the route line drawn on the map should do next.
enum ReplanLineSync {
  /// Nothing changed since the last draw — leave the line alone.
  none,

  /// A new (or first) replanned shape arrived — decode and draw it in
  /// place of whatever is currently drawn.
  redraw,

  /// The previously-replanned shape is gone (a fresh or resumed trip that
  /// has not replanned, most commonly) — restore the planned route's own
  /// line rather than leaving a dead replan drawn over it.
  restoreBase,
}

/// Decides [ReplanLineSync] from the encoded shape strings themselves, not
/// from a replan counter: a fresh or resumed trip's `navReplanCount` starts
/// back at 0, which the old gate read as "nothing to do" while a previous
/// trip's replanned line was still on screen (see `TripController
/// .resumeInterrupted`'s nav-blanking fix for the seed-side half of the
/// same bug — it stops a stale [currentShapeEnc] from ever reaching here in
/// the first place, but this comparison is what makes the *screen* honest
/// even if a stale value did).
///
/// [currentShapeEnc] and [lastDrawnShapeEnc] must both already be
/// normalised so an empty string reads the same as `null` (the caller's
/// job — decoding an empty polyline is meaningless either way).
///
/// A trip that is not route-bound is always [ReplanLineSync.none]: a free
/// trip has no replanned-line state of its own to reconcile — the
/// leftover-drawn-line scenario this exists for is specific to a
/// route-bound trip inheriting *another* route-bound trip's leftover
/// state, not a free trip picking one up.
ReplanLineSync decideReplanLineSync({
  required bool isRouteBound,
  required String? currentShapeEnc,
  required String? lastDrawnShapeEnc,
}) {
  if (!isRouteBound) return ReplanLineSync.none;
  if (currentShapeEnc == lastDrawnShapeEnc) return ReplanLineSync.none;
  return currentShapeEnc == null
      ? ReplanLineSync.restoreBase
      : ReplanLineSync.redraw;
}
