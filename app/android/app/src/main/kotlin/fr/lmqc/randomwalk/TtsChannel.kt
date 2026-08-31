package fr.lmqc.randomwalk

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
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
 *
 * [State.FAILED] is *not* cached forever: `OnInitListener` reporting non-`SUCCESS` can be a
 * transient cold-start hiccup in the system TTS service (a real-world Android quirk, not
 * hypothetical), and a walker who enables "Guidage vocal" once is not well served by a
 * permanent "unavailable" verdict from whatever the engine happened to be doing the first
 * time it was asked. A later `init` while `FAILED` retries — a fresh `TextToSpeech`, not the
 * broken one — up to [maxInitAttempts] times within [failureWindowMs] of the first failure in
 * that run; once that budget is spent *and* the window has not yet elapsed, `init` stops
 * retrying and just answers unavailable. Task-7 item 1/carry-over item 13: the budget is
 * windowed in time, not permanent for the whole attachment — [failureWindowMs] after the
 * first failure of a run, the window (and the count with it) resets, so a device that had a
 * bad cold-start ten minutes ago gets a fresh budget rather than being stuck answering
 * unavailable for the rest of the process's life purely because it used up 3 attempts once,
 * long ago. This is deliberately narrower than retrying a *successful* bind that merely lacks
 * French voice data ([State.READY] with `available == false`): the engine itself came up fine
 * in that case, and nothing about asking again would change the answer short of the user
 * installing a language pack in between — out of scope here, same as it was in fix round 2.
 */
class TtsChannel(private val context: Context) {
    private enum class State { NONE, PENDING, READY, FAILED }

    /** See the class doc comment's note on [State.FAILED] not being permanent. */
    private val maxInitAttempts = 3

    /**
     * How long the [failedAttempts] budget stays exhausted for before resetting — see the
     * class doc comment's note on [State.FAILED]/item 1. Measured from [SystemClock]'s boot
     * clock (via [windowStartElapsedMs]), not wall-clock time: immune to the user (or the OS,
     * around a timezone/DST change) moving the clock, which a `System.currentTimeMillis()`
     * window would not be.
     */
    private val failureWindowMs = 10 * 60 * 1000L

    private var tts: TextToSpeech? = null
    private var state = State.NONE
    private var available = false
    private var failedAttempts = 0

    /**
     * [SystemClock.elapsedRealtime] at the *first* failure of the current run — `0L` when no
     * failure is currently being counted (no failures yet, or the last reset already cleared
     * it). See [failureWindowMs].
     */
    private var windowStartElapsedMs = 0L

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

    /**
     * Item 4: the [AudioAttributes] a spoken turn-by-turn instruction is — navigation
     * guidance, not media/notification/alarm — so the system (and any other app currently
     * playing audio) treats it accordingly: ducked-under by music apps that respect audio
     * focus, not silently mixed as if it were a notification chime. Applied once, right after
     * the engine successfully binds (see [onEngineInitialized]), the same place
     * [applyFrenchLocale] runs — `TextToSpeech.setAudioAttributes` is an engine-level setting
     * that applies to every synthesis request after it, not a per-utterance one.
     */
    private val ttsAudioAttributes: AudioAttributes =
        AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

    private val audioManager: AudioManager? =
        context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager

    /**
     * The `AudioFocusRequest` currently held, API 26+ only (see [requestFocus]/[abandonFocus] —
     * the API < 26 path uses the legacy `requestAudioFocus(listener, stream, gain)` instead,
     * which needs no request object). Rebuilt fresh in every [requestFocus] call, since
     * `AudioFocusRequest` is immutable; tracked here only so [abandonFocus] can hand the exact
     * same instance back to `abandonAudioFocusRequest`, which that API requires — unlike the
     * legacy `abandonAudioFocus(listener)`, which only needs the listener.
     */
    private var focusRequest: AudioFocusRequest? = null

    /**
     * One shared, do-nothing listener for every focus request, on both the modern and legacy
     * (API < 26) audio-focus APIs. A real callback (pausing/resuming *our own* playback on
     * `AUDIOFOCUS_LOSS`) would matter for a media player; it does not for one-shot navigation
     * cues that already play-and-forget via [UtteranceProgressListener] — there is nothing
     * ongoing here for a focus-loss callback to meaningfully pause. Required by both focus
     * APIs regardless: `requestAudioFocus` needs a non-null listener to hand a loss
     * notification to, even when — as here — that notification is deliberately unused.
     */
    private val legacyFocusListener = AudioManager.OnAudioFocusChangeListener { }

    /**
     * The utterance id [speak] most recently enqueued, so the [UtteranceProgressListener]
     * (registered once in [onEngineInitialized]) knows whether a completion callback is for
     * the *current* utterance — and safe to [abandonFocus] on — or a stale one for an
     * utterance a newer [speak] call already superseded via `QUEUE_FLUSH`. Without this guard,
     * a late `onStop` for an interrupted utterance could abandon focus out from under the
     * newer one that replaced it (see [speak]'s doc comment).
     */
    private var activeUtteranceId: String? = null

    /**
     * How long [startEngine] waits for `OnInitListener` before giving up on its own. A
     * cold-start TextToSpeech service can simply never call back — no success, no error,
     * nothing (a real-world Android quirk, not hypothetical) — and without a bound, [state]
     * is wedged at [State.PENDING] forever: every later `init()` call, this trip's or the
     * next one's, just queues onto [pendingInitResults] behind a listener that is never
     * coming, and no trip ever gets GPS subscribed (see `TrackingService.onStart`, which
     * used to `await` this).
     */
    private val initTimeoutMs = 5_000L

    /** The pending timeout for the current [State.PENDING] engine, if any; see [startEngine]. */
    private var initTimeoutRunnable: Runnable? = null

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
     * successfully ([State.READY]); queues [result] alongside any other caller waiting on
     * the *same* still-starting engine ([State.PENDING]); starts a fresh engine (queuing
     * [result] the same as [State.NONE]) if the last one [State.FAILED] and there is still
     * retry budget left ([failedAttempts] `< `[maxInitAttempts]) *or* [failureWindowMs] has
     * elapsed since the first failure of the exhausted run (item 1: the budget resets rather
     * than staying spent forever); or, once that budget is spent and the window has not yet
     * elapsed, answers `false` without trying again — a device genuinely missing a TTS engine
     * must not retry forever.
     */
    private fun init(result: MethodChannel.Result) {
        when (state) {
            State.READY -> result.success(available)
            State.PENDING -> pendingInitResults.add(result)
            State.FAILED -> {
                if (windowExpired()) {
                    failedAttempts = 0
                    windowStartElapsedMs = 0L
                }
                if (failedAttempts >= maxInitAttempts) {
                    result.success(available)
                } else {
                    startEngine(result)
                }
            }
            State.NONE -> startEngine(result)
        }
    }

    /**
     * Whether the current failure run's [failureWindowMs] window has elapsed — true both when
     * there is no window currently open ([windowStartElapsedMs] `== 0L`, defensive: [State.FAILED]
     * cannot actually be reached without at least one failure having opened one) and when the
     * budget was exhausted long enough ago to earn a fresh one. See [init]'s [State.FAILED]
     * branch, the only caller.
     */
    private fun windowExpired(): Boolean {
        val start = windowStartElapsedMs
        return start == 0L || SystemClock.elapsedRealtime() - start >= failureWindowMs
    }

    /**
     * Constructs a fresh `TextToSpeech`, discarding any previous one first — relevant only
     * on a retry after [State.FAILED], where `tts` may already hold a non-`null` reference to
     * the engine that just failed to bind; [State.NONE] never has one to discard.
     */
    private fun startEngine(result: MethodChannel.Result) {
        tts?.let {
            it.stop()
            it.shutdown()
        }
        state = State.PENDING
        pendingInitResults.add(result)
        val generation = ++initGeneration
        tts = TextToSpeech(context) { status ->
            mainHandler.post { onEngineInitialized(generation, status) }
        }
        // See [initTimeoutMs]'s doc comment: synthesize a failure if the real listener
        // hasn't answered by then. Cancelled by [onEngineInitialized] the moment either
        // side actually answers first.
        val timeout = Runnable { onEngineInitialized(generation, TextToSpeech.ERROR) }
        initTimeoutRunnable = timeout
        mainHandler.postDelayed(timeout, initTimeoutMs)
    }

    private fun onEngineInitialized(generation: Int, status: Int) {
        // Superseded by a shutdown() (and possibly a fresh init()) that ran before this
        // callback arrived — nothing here is still relevant to the current engine, if any.
        // The `state != PENDING` half guards the other direction: the real listener and
        // the [initTimeoutMs] timeout can both eventually call this for the same
        // generation (a late real callback arriving after the synthetic timeout already
        // gave up, or vice versa) — whichever lands first moves state off PENDING, and
        // the second arrival is a no-op rather than re-deciding an already-settled answer.
        if (generation != initGeneration || state != State.PENDING) return

        initTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        initTimeoutRunnable = null

        val engine = tts
        val succeeded = status == TextToSpeech.SUCCESS && engine != null
        if (succeeded) {
            // Item 4: applied once here, right as the engine comes up — see
            // [ttsAudioAttributes]'s doc comment for why this is engine-level, not
            // per-utterance.
            engine!!.setAudioAttributes(ttsAudioAttributes)
            engine.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) = Unit
                override fun onDone(utteranceId: String?) = onUtteranceEnded(utteranceId)
                override fun onStop(utteranceId: String?, interrupted: Boolean) =
                    onUtteranceEnded(utteranceId)

                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) = onUtteranceEnded(utteranceId)
                override fun onError(utteranceId: String?, errorCode: Int) =
                    onUtteranceEnded(utteranceId)
            })
        }
        available = if (succeeded) applyFrenchLocale(engine!!) else false
        state = if (succeeded) {
            failedAttempts = 0
            windowStartElapsedMs = 0L
            State.READY
        } else {
            // The window opens on the first failure of a run; a later failure within
            // the same still-open window does not push it back out (see
            // [failureWindowMs]'s doc comment) — it counts against the same budget,
            // it does not start a new one.
            if (failedAttempts == 0) windowStartElapsedMs = SystemClock.elapsedRealtime()
            failedAttempts++
            State.FAILED
        }
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

    /**
     * A no-op if `init` never ran, or answered unavailable — `tts` is null either way.
     *
     * Item 4: requests transient, ducking-friendly audio focus before enqueueing the
     * utterance — `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, matching [ttsAudioAttributes]'
     * navigation-guidance intent: briefly interrupt/duck whatever else is playing (podcast,
     * music) for one spoken instruction, not seize focus outright the way a media app
     * starting playback would. [QUEUE_FLUSH] means at most one utterance is ever actually
     * in flight, so [activeUtteranceId] tracks that single utterance's id — set *before*
     * `speak()` is called, so a synchronous/near-immediate completion callback (short
     * utterances on a fast engine are not hypothetical) can never observe it still null.
     * Focus is released once that utterance's own progress listener callback confirms it is
     * done — see [onUtteranceEnded] — not eagerly here, so a still-playing instruction is not
     * cut loose to un-duck mid-sentence.
     */
    private fun speak(text: String) {
        val engine = tts ?: return
        val utteranceId = "randomwalk-${nextUtteranceId.incrementAndGet()}"
        activeUtteranceId = utteranceId
        requestFocus()
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, utteranceId)
    }

    /**
     * Called from [UtteranceProgressListener]'s callbacks (which do not run on a documented
     * thread) via [mainHandler] to keep every read/write of [activeUtteranceId]/[focusRequest]
     * on one thread. Only actually abandons focus when [utteranceId] is still the one [speak]
     * most recently started — an `onStop` for an utterance a newer [speak] call already
     * interrupted via `QUEUE_FLUSH` must not tear down the *new* utterance's still-held focus.
     */
    private fun onUtteranceEnded(utteranceId: String?) {
        mainHandler.post {
            if (utteranceId == null || utteranceId != activeUtteranceId) return@post
            activeUtteranceId = null
            abandonFocus()
        }
    }

    private fun requestFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
                .setAudioAttributes(ttsAudioAttributes)
                .setOnAudioFocusChangeListener(legacyFocusListener)
                .build()
            focusRequest = request
            manager.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            manager.requestAudioFocus(
                legacyFocusListener,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK,
            )
        }
    }

    private fun abandonFocus() {
        val manager = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { manager.abandonAudioFocusRequest(it) }
            focusRequest = null
        } else {
            @Suppress("DEPRECATION")
            manager.abandonAudioFocus(legacyFocusListener)
        }
    }

    private fun shutdown() {
        initTimeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        initTimeoutRunnable = null
        tts?.stop()
        tts?.shutdown()
        tts = null
        state = State.NONE
        available = false
        // A trip ending (or the engine tearing down) mid-utterance must not leave focus held
        // forever — [tts]?.stop() above does not itself fire the progress listener, so this is
        // the only remaining path back to [abandonFocus] for that case.
        activeUtteranceId = null
        abandonFocus()
        // A full, deliberate reset (as opposed to a same-state retry after State.FAILED)
        // earns a fresh retry budget too — the alternative, leaving a spent budget in place
        // across an explicit shutdown, would make [maxInitAttempts] silently unenforceable
        // (a later init() lands in the State.NONE branch, which does not consult it at all)
        // rather than actually resetting anything. Same reasoning extends the window reset
        // to [windowStartElapsedMs] — item 13: shutdown() is a deliberate teardown, not a
        // transient failure, and must still reset fully even though [failureWindowMs] now
        // also resets it on its own after enough time passes.
        failedAttempts = 0
        windowStartElapsedMs = 0L
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
