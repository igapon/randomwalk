package fr.lmqc.randomwalk

import android.content.Context
import android.speech.tts.TextToSpeech
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.Locale
import java.util.concurrent.atomic.AtomicInteger

/**
 * Bridges Android's on-device `android.speech.tts.TextToSpeech` to Dart over the
 * `randomwalk/tts` MethodChannel, in the same shape as [ValhallaChannel]/[DeviceChannel].
 *
 * A local plugin channel, not a pub package, specifically because `flutter_tts` — the
 * obvious pub alternative — cannot currently build against this app's Android toolchain:
 * its `android/build.gradle` unconditionally applies the legacy `kotlin-android` plugin,
 * which AGP 9's built-in Kotlin support (required here by `maplibre_gl`, see
 * `android/gradle.properties`) refuses to coexist with — confirmed as a currently open,
 * unresolved upstream issue (`github.com/dlutton/flutter_tts` issue #647). See
 * `nav/tts.dart`'s `NoopTtsSpeaker` doc comment for the full account. `android.speech.tts`
 * is a platform API with no Gradle plugin of its own, so it sidesteps that conflict
 * entirely.
 *
 * `init` is the one call answered asynchronously: `TextToSpeech`'s constructor takes an
 * `OnInitListener` fired once the engine has (or has not) actually started, so the
 * `MethodChannel.Result` is completed from that callback rather than immediately.
 * `LANG_MISSING_DATA`/`LANG_NOT_SUPPORTED` (no French voice data installed, or no TTS
 * engine on the device at all) both resolve `init` to `false` rather than an error — "no
 * French TTS here" is a normal, expected outcome the Dart side (`NativeTtsSpeaker`) is
 * built to fall back from, not a failure worth surfacing as one.
 *
 * Lazy by design: the engine is constructed on the first `init` call, never at [register]
 * — a trip that never enables "Guidage vocal" must never pay for it, on either engine this
 * is attached to.
 */
class TtsChannel(private val context: Context) {
    private var tts: TextToSpeech? = null
    private var channel: MethodChannel? = null
    private val nextUtteranceId = AtomicInteger(0)

    fun register(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, "randomwalk/tts")
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> init(result)
                "speak" -> {
                    val text = call.argument<String>("text")
                    if (text == null) {
                        result.error("ARGUMENT", "speak requires a text string", null)
                    } else {
                        speak(text)
                        result.success(null)
                    }
                }
                "shutdown" -> {
                    shutdown()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Constructs the engine on first call and answers [result] with whether fr-FR is
     * actually usable on it. A second `init` while an engine already exists re-answers
     * from that same engine's `setLanguage` result computed synchronously, rather than
     * constructing (and leaking) a second `TextToSpeech` — defensive, not the expected
     * path: the Dart side guards against calling `init` more than once per trip.
     */
    private fun init(result: MethodChannel.Result) {
        val existing = tts
        if (existing != null) {
            result.success(applyFrenchLocale(existing))
            return
        }
        tts = TextToSpeech(context) { status ->
            val engine = tts
            if (status != TextToSpeech.SUCCESS || engine == null) {
                result.success(false)
            } else {
                result.success(applyFrenchLocale(engine))
            }
        }
    }

    private fun applyFrenchLocale(engine: TextToSpeech): Boolean {
        val availability = engine.setLanguage(Locale.FRANCE)
        return availability != TextToSpeech.LANG_MISSING_DATA &&
            availability != TextToSpeech.LANG_NOT_SUPPORTED
    }

    /** A no-op if `init` never ran, or answered unavailable — `tts` is null either way. */
    private fun speak(text: String) {
        tts?.speak(
            text,
            TextToSpeech.QUEUE_FLUSH,
            null,
            "randomwalk-${nextUtteranceId.incrementAndGet()}",
        )
    }

    private fun shutdown() {
        tts?.stop()
        tts?.shutdown()
        tts = null
    }

    /**
     * Detaches the method call handler and releases the `TextToSpeech` engine (if any) —
     * call this from `RandomwalkPlugin.onDetachedFromEngine`, same bracket as
     * [ValhallaChannel.dispose]/[DeviceChannel.dispose].
     */
    fun dispose() {
        channel?.setMethodCallHandler(null)
        shutdown()
    }
}
