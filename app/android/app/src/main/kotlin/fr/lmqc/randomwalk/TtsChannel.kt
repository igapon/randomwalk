package fr.lmqc.randomwalk

import android.content.Context
import android.os.Handler
import android.os.Looper
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
 * `init` is the one call answered asynchronously, and the one this class has to be careful
 * about concurrent callers for: `TextToSpeech`'s constructor takes an `OnInitListener`
 * fired once the engine has (or has not) actually started, so the *first* `init`'s
 * `MethodChannel.Result` can only be completed from that callback, not immediately. A
 * naive "does `tts` already exist?" check for a *second*, concurrent `init` is wrong —
 * `tts` is assigned the instant the constructor returns, well before `OnInitListener` ever
 * fires, so that second caller would call `setLanguage` on an engine that has not finished
 * binding yet. `TextToSpeech.setLanguage` on such an engine answers `ERROR` (`-1`), which is
 * numerically identical to `LANG_MISSING_DATA` (also `-1`) — so the second caller would be
 * told French TTS is unavailable even when it is perfectly fine, purely because it asked a
 * few milliseconds too early. [state] makes the three phases explicit instead of inferring
 * them from `tts`'s nullability, and every caller that arrives while a `PENDING` engine is
 * still starting up is queued in [pendingInitResults] and answered — all of them, with the
 * one true answer — from the single `OnInitListener` callback that eventually fires,
 * posted through [mainHandler] since that callback's own thread is not documented and
 * `MethodChannel.Result` must be completed on the platform thread.
 *
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
    private enum class State { NONE, PENDING, READY, FAILED }

    private var tts: TextToSpeech? = null
    private var state = State.NONE
    private var available = false
    private val pendingInitResults = mutableListOf<MethodChannel.Result>()

    /**
     * Bumped every time a *new* engine construction starts, and again on [shutdown].
     * [onEngineInitialized] captures the value current when its `TextToSpeech` was
     * constructed and discards its own callback if the number has since moved on — the one
     * way a stale `OnInitListener` firing after a [shutdown] (with no new `init` yet, so
     * [state] is merely `NONE` again rather than pointing at a different engine already)
     * could otherwise resurrect answers for a trip that already tore this down.
     */
    private var initGeneration = 0

    private var channel: MethodChannel? = null
    private val nextUtteranceId = AtomicInteger(0)
    private val mainHandler = Handler(Looper.getMainLooper())

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
     * Answers immediately from the cached [available] once the engine has settled
     * ([State.READY]/[State.FAILED]); queues [result] alongside any other caller waiting on
     * the *same* still-starting engine ([State.PENDING]); or, the first time, starts that
     * engine and queues [result] to be the first entry [onEngineInitialized] completes.
     */
    private fun init(result: MethodChannel.Result) {
        when (state) {
            State.READY, State.FAILED -> result.success(available)
            State.PENDING -> pendingInitResults.add(result)
            State.NONE -> {
                state = State.PENDING
                pendingInitResults.add(result)
                val generation = ++initGeneration
                tts = TextToSpeech(context) { status ->
                    mainHandler.post { onEngineInitialized(generation, status) }
                }
            }
        }
    }

    private fun onEngineInitialized(generation: Int, status: Int) {
        // Superseded by a shutdown() (and possibly a fresh init()) that ran before this
        // callback arrived — nothing here is still relevant to the current engine, if any.
        if (generation != initGeneration) return

        val engine = tts
        val succeeded = status == TextToSpeech.SUCCESS && engine != null
        available = if (succeeded) applyFrenchLocale(engine!!) else false
        state = if (succeeded) State.READY else State.FAILED
        completePendingInitResults()
    }

    private fun completePendingInitResults() {
        val pending = pendingInitResults.toList()
        pendingInitResults.clear()
        for (result in pending) {
            result.success(available)
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
        state = State.NONE
        available = false
        // Invalidates any OnInitListener callback still in flight for the engine just torn
        // down (see [initGeneration]'s doc comment).
        initGeneration++
        // Anyone still waiting on that engine's init() must not have their Result leak
        // across this teardown — answered as unavailable, the same honest "no TTS here"
        // contract every other failure path already uses.
        completePendingInitResults()
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
