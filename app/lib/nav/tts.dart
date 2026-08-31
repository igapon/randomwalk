/// Speaks a piece of guidance text aloud. The seam between the tracking
/// handler's alert wiring and whatever text-to-speech engine actually does
/// it, so that wiring is testable without a real one, and so "Guidage vocal"
/// being off (or unavailable) is just a different object rather than a
/// branch scattered through the caller.
///
/// No implementation ships yet — see [NoopTtsSpeaker]'s doc comment for why
/// — but the rest of the maneuver-alert path (`AlertPolicy`, the settings
/// toggle, the seed/live-refresh plumbing in `TripTaskHandler`) is built
/// against this interface exactly as if one did, so wiring a real one back
/// in later is a one-class change.
abstract class TtsSpeaker {
  Future<void> speak(String text);
}

/// Does nothing. The only [TtsSpeaker] this app currently ships.
///
/// `flutter_tts` (the obvious implementation) was tried for this task and
/// pulled back out: its Android module unconditionally applies the
/// `kotlin-android` Gradle plugin (`flutter_tts-4.2.5/android/build.gradle`),
/// which Android Gradle Plugin 9's built-in Kotlin support (enabled here via
/// `android.builtInKotlin=true` in `android/gradle.properties`, itself
/// required by `maplibre_gl`) refuses outright: "the 'org.jetbrains.
/// kotlin.android' plugin is no longer required ... since AGP 9.0" —
/// confirmed as a currently open, unresolved upstream issue
/// (github.com/dlutton/flutter_tts issue #647). Flipping
/// `android.builtInKotlin` back to `false` would fix `flutter_tts` but
/// breaks `maplibre_gl` the same way in the other direction (documented in
/// `gradle.properties`) — the two plugins disagree about which side of the
/// AGP 9 migration they are on, and nothing short of forking one of them or
/// downgrading the whole app off AGP 9 resolves that. Out of scope for a
/// single task.
///
/// "Guidage vocal" therefore persists and reaches the service (see
/// `AlertSettingsStore`, `TripTaskHandler`) but has no audible effect right
/// now — the sound/vibration alert (`AndroidNotificationDetails` in
/// `tracking_service.dart`) is what the brief calls "la voie garantie écran
/// éteint", and is unaffected by any of this.
class NoopTtsSpeaker implements TtsSpeaker {
  const NoopTtsSpeaker();

  @override
  Future<void> speak(String text) async {}
}
