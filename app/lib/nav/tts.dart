import 'package:flutter_tts/flutter_tts.dart';

/// Speaks a piece of guidance text aloud. The seam between the tracking
/// handler's alert wiring and flutter_tts, so that wiring is testable
/// without a real text-to-speech engine, and so "Guidage vocal" being off is
/// just a different object rather than a branch scattered through the
/// caller.
abstract class TtsSpeaker {
  Future<void> speak(String text);
}

/// « Guidage vocal » off (or unavailable): does nothing. The default a
/// caller should hold until it has a reason to build the real thing.
class NoopTtsSpeaker implements TtsSpeaker {
  const NoopTtsSpeaker();

  @override
  Future<void> speak(String text) async {}
}

/// French voice guidance via flutter_tts.
///
/// Configured for fr-FR lazily, on the first [speak] call rather than at
/// construction — the plugin's own Android side already spins up a
/// `TextToSpeech` engine the instant it is attached to a Flutter engine
/// (verified in `flutter_tts`'s `FlutterTtsPlugin.onAttachedToEngine`, which
/// is unconditional and outside this class's control), so this is not what
/// keeps that cost out of a trip that never speaks — it only keeps this
/// class's own Dart-side setup (language, speech rate) from running before
/// it is ever needed.
class FlutterTtsSpeaker implements TtsSpeaker {
  final FlutterTts _tts;
  bool _configured = false;

  FlutterTtsSpeaker([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  @override
  Future<void> speak(String text) async {
    if (!_configured) {
      await _tts.setLanguage('fr-FR');
      // Guidance read at a measured pace — 1.0 is flutter_tts's "normal"
      // speed, and a walker glancing at a locked screen has time to listen.
      await _tts.setSpeechRate(0.5);
      _configured = true;
    }
    await _tts.speak(text);
  }
}
