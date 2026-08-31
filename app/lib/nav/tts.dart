import 'package:flutter/services.dart';

/// Speaks a piece of guidance text aloud. The seam between the tracking
/// handler's alert wiring and whatever text-to-speech engine actually does
/// it, so that wiring is testable without a real one, and so "Guidage vocal"
/// being off (or unavailable) is just a different object rather than a
/// branch scattered through the caller.
abstract class TtsSpeaker {
  Future<void> speak(String text);
}

/// A [TtsSpeaker] that must be asked to [init] before it is any use — the
/// contract [NativeTtsSpeaker] implements. Factored out so
/// `TripTaskHandler` can point its speaker construction at a fake for tests
/// (`TripTaskHandler.speakerFactory`) instead of the real native channel —
/// in particular a fake whose [init] never completes, the hang scenario
/// `TtsChannel.startEngine`'s own timeout exists for on the native side.
abstract class InitializableTtsSpeaker implements TtsSpeaker {
  Future<bool> init();
}

/// Does nothing. Used whenever « Guidage vocal » is off, or the device has
/// no usable French TTS — see [NativeTtsSpeaker]'s doc comment for how that
/// is determined.
///
/// `flutter_tts` (the obvious pub-package implementation) was tried for this
/// task and pulled back out: its Android module unconditionally applies the
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
/// downgrading the whole app off AGP 9 resolves that. Replaced with
/// [NativeTtsSpeaker] instead: this app's own local plugin channel over the
/// bare platform `android.speech.tts.TextToSpeech`, which has no Gradle
/// plugin of its own to conflict with anything.
class NoopTtsSpeaker implements TtsSpeaker {
  const NoopTtsSpeaker();

  @override
  Future<void> speak(String text) async {}
}

/// French voice guidance via this app's own native TTS channel
/// (`randomwalk/tts` — see `RandomwalkPlugin`/`TtsChannel` on the Android
/// side), not the `flutter_tts` pub package (see [NoopTtsSpeaker]'s doc
/// comment for why).
///
/// [init] must be called, and awaited, before [speak] does anything — it
/// asks the native side to construct (or reuse) its `TextToSpeech` engine
/// and select fr-FR, and reports whether that actually worked. A device
/// with no French voice data installed — or no TTS engine at all — answers
/// `false`, and this class then behaves exactly like [NoopTtsSpeaker] for
/// every [speak] that follows, rather than throwing: "no TTS here" is this
/// facade's expected unhappy path, not a caller-visible error.
///
/// `TripTaskHandler` constructs a *fresh* [NativeTtsSpeaker] every time
/// "Guidage vocal" turns on (at trip start, and again if the setting flips
/// on mid-trip), so two [init] calls arriving close enough together to
/// overlap is a real scenario, not a hypothetical: two settings pushes
/// before the first `init` has resolved would otherwise fire two concurrent
/// platform `init` calls. [_pendingInit] is deliberately `static` — shared
/// across every instance, not per-instance — so the second caller awaits
/// the *same* underlying platform call instead of starting a second one:
/// whoever asks first is the only one who actually reaches
/// `TtsChannel.init` on the native side.
class NativeTtsSpeaker implements InitializableTtsSpeaker {
  /// Exposed for tests, which mock this exact channel via
  /// `TestDefaultBinaryMessengerBinding` rather than injecting a fake —
  /// there is nothing behind a `MethodChannel` worth faking separately.
  static const channel = MethodChannel('randomwalk/tts');

  static Future<bool>? _pendingInit;

  bool _initialized = false;
  bool _available = false;

  /// Whether the last [init] call reported usable French TTS. False before
  /// [init] has ever been called.
  bool get available => _available;

  /// Asks the native side to build (or reuse) its engine and select fr-FR.
  /// Never throws — a platform-channel failure is treated the same as the
  /// native side honestly answering "unavailable". Safe to call from any
  /// number of instances at once (see the class doc comment): all of them
  /// resolve to the one true answer, and the platform channel sees exactly
  /// one `init` call for the whole overlapping group.
  @override
  Future<bool> init() async {
    final inFlight = _pendingInit;
    final future = inFlight ?? _startInit();
    _pendingInit = future;
    _available = await future;
    _initialized = true;
    return _available;
  }

  static Future<bool> _startInit() async {
    try {
      return await channel.invokeMethod<bool>('init') ?? false;
    } catch (_) {
      return false;
    } finally {
      // Cleared once this call settles — a *later*, non-overlapping init()
      // (a fresh trip, say) must reach the channel again rather than reuse
      // a resolved Future forever; only genuinely concurrent callers should
      // ever share one.
      _pendingInit = null;
    }
  }

  @override
  Future<void> speak(String text) async {
    if (!_initialized || !_available) return;
    try {
      await channel.invokeMethod('speak', {'text': text});
      // A speech failure costs this one alert its voice, never the trip —
      // the same swallow-everything philosophy as the rest of the alert
      // path (see TripTaskHandler._maybeAlert).
    } catch (_) {
      return;
    }
  }

  /// Releases the native `TextToSpeech` engine. Not currently called by
  /// `TripTaskHandler` — the engine's own teardown already disposes
  /// `TtsChannel` when the Flutter engine it lives on is destroyed (see
  /// `RandomwalkPlugin.onDetachedFromEngine`) — but kept as a real,
  /// independently-usable operation rather than dead API surface.
  Future<void> shutdown() async {
    if (!_initialized) return;
    try {
      await channel.invokeMethod('shutdown');
    } catch (_) {
      return;
    }
  }
}
