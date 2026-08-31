/// Pure camera-follow rules for the map screen during turn-by-turn
/// navigation (Task 7 device-QA addendum, point 3: "carte incontrôlable en
/// navigation").
///
/// [MapScreenState] cannot itself be unit-tested — it owns a real
/// `MapLibreMapController` backed by a platform view — but the rule for
/// *when the "recentrer" button should appear* has nothing to do with the
/// map itself: it is a function of two booleans the widget already tracks
/// (is a route-bound trip recording, has the last user gesture released
/// tracking). Kept here, and tested here, so that rule cannot silently
/// drift from what the button actually does.
library;

/// Whether the "recentrer" button (waymark diamond, inset-safe) should be
/// shown: only while navigating, and only once a user gesture has released
/// the camera from following the walker (see
/// `MapLibreMap.onCameraTrackingDismissed`). Recording continues in the
/// service regardless of either — this only ever hides or shows a button.
bool shouldShowRecenterButton({
  required bool isNavigating,
  required bool trackingReleased,
}) =>
    isNavigating && trackingReleased;

/// Whether a map remount (`_redrawAfterRemount` — a theme flip mid-trip is
/// the practical trigger, since that rebuilds `MapLibreMap` under a fresh
/// `ValueKey`) should re-engage camera-follow.
///
/// Fix-round finding: the remount path used to re-engage tracking whenever
/// `isRecording && isRouteBound`, ignoring [trackingReleased] entirely —
/// silently overriding a release the walker's last gesture asked for, and
/// leaving the "recentrer" button visible (per [shouldShowRecenterButton])
/// pointing at a camera that was already tracking, so tapping it was a
/// no-op. This mirrors [shouldShowRecenterButton]'s own inputs so the two
/// rules cannot drift apart: a remount must respect exactly the same
/// release state the button's visibility already reflects.
bool shouldReengageTrackingOnRemount({
  required bool isRecording,
  required bool isRouteBound,
  required bool trackingReleased,
}) =>
    isRecording && isRouteBound && !trackingReleased;
