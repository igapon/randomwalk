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
