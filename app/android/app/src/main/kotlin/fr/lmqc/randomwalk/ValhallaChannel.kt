package fr.lmqc.randomwalk

import android.content.Context
import com.valhalla.valhalla.Valhalla
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/**
 * Bridges the embedded Valhalla routing engine (io.github.rallista:valhalla-mobile:0.6.3) to
 * Dart over the `randomwalk/valhalla` MethodChannel.
 *
 * Real API found by inspecting the AAR's sources jar (the brief's skeleton guessed at the
 * class name, which turned out right, but not at the constructor or route method):
 *  - `com.valhalla.valhalla.Valhalla` has no `Valhalla(configJson: String)` constructor. It only
 *    accepts a config already on disk (`Valhalla(configPath: String)`) or a typed
 *    `ValhallaConfig` object plus a `Context` (`Valhalla(context, config)`). Since Dart already
 *    hands us a complete, patched config JSON string, `init` writes it to internal storage and
 *    opens the engine from that path.
 *  - The JSON-in/JSON-out route call is `Valhalla.routeRaw(requestJson): String`, not
 *    `route(String): String`. It forwards the request to the native actor and returns Valhalla's
 *    raw trip JSON (or throws `ValhallaException.Internal` for the native error envelope).
 *  - `Valhalla` is `Closeable` and holds a native actor (incl. the mmapped tiles) for its whole
 *    lifetime; the previous instance is closed before a re-`init`, and [dispose] closes it (and
 *    shuts down the worker thread) when the Flutter engine tears down — see
 *    `RandomwalkPlugin.onDetachedFromEngine`.
 *
 * One instance is created per [io.flutter.embedding.engine.FlutterEngine] it is registered on
 * (see `RandomwalkPlugin`), each with its own native actor, worker thread and on-disk config
 * copy — [configFileName] is unique per instance precisely so that two engines attached at once
 * (the UI engine and, during active navigation, the background tracking engine; or, transiently,
 * two overlapping background engines during `ForegroundService.createForegroundTask`) each write
 * and read their own file instead of racing a shared one (one engine's `init` truncating the
 * file mid-read of another's concurrent `init` would produce a torn config and a confusing
 * native-side parse failure). Two actors mmapping the same underlying tile files, by contrast, is
 * fine — the OS shares those mmapped pages between them.
 */
class ValhallaChannel(private val context: Context) {
    private var actor: Valhalla? = null
    private val executor = Executors.newSingleThreadExecutor()
    private var channel: MethodChannel? = null

    // System.identityHashCode is not guaranteed globally unique across the JVM's lifetime, but a
    // collision would require two *simultaneously live* ValhallaChannel instances to share it,
    // which the JVM cannot produce (identity hash codes are only reused after the earlier object
    // is garbage collected) — sufficient for "unique among instances actually racing this path".
    private val configFileName = "randomwalk_valhalla_config_${System.identityHashCode(this)}.json"

    fun register(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, "randomwalk/valhalla")
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
            // Argument extraction happens *inside* the executed block, not before dispatch:
            // a missing/wrong-typed argument must reach the caller as a MethodChannel error,
            // not throw on the platform thread before reply() ever gets a chance to catch it.
            fun reply(block: () -> String) {
                try {
                    executor.execute {
                        try {
                            val out = block()
                            mainHandler.post { result.success(out) }
                        } catch (t: Throwable) {
                            mainHandler.post {
                                result.error("VALHALLA", t.message ?: t.javaClass.name, null)
                            }
                        }
                    }
                } catch (_: RejectedExecutionException) {
                    // dispose() already shut this instance's executor down (its engine was
                    // detached) but a call was still in flight from the Dart side — answer it
                    // with an explicit error instead of letting the exception escape onto the
                    // platform thread and crash the process.
                    result.error("DISPOSED", "ValhallaChannel has been disposed", null)
                }
            }
            when (call.method) {
                "init" -> reply {
                    val configJson = call.argument<String>("configJson")
                        ?: throw IllegalArgumentException("init requires a configJson string")
                    // Close and clear the old actor *before* trying to build the new one, and
                    // only assign the field once the replacement actually exists. Assigning
                    // straight into `actor` (old code: `actor = Valhalla(...)`) would leave it
                    // pointing at the just-closed handle for the rest of this block if
                    // `writeText` or the `Valhalla` constructor threw — every `route()` call
                    // after that reads a closed native actor, which is a crash, not a Dart-
                    // visible error. Building into a local first means a failure here leaves
                    // `actor` cleanly null instead.
                    actor?.close()
                    actor = null
                    val configFile = File(context.filesDir, configFileName)
                    configFile.writeText(configJson)
                    val fresh = Valhalla(configFile.absolutePath)
                    actor = fresh
                    "ok"
                }
                "route" -> reply {
                    val request = call.argument<String>("request")
                        ?: throw IllegalArgumentException("route requires a request string")
                    actor?.routeRaw(request)
                        ?: throw IllegalStateException("engine not initialized")
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Detaches the method call handler, releases the native actor (if any), shuts down the
     * worker thread and deletes this instance's on-disk config copy. Call this from
     * `RandomwalkPlugin.onDetachedFromEngine` — nothing else frees the native handle or the
     * mmapped tiles, and a leaked executor thread (or a stray call landing on a shut-down one)
     * survives engine teardown otherwise.
     *
     * `setMethodCallHandler(null)` matters even though the engine may still be alive when this
     * runs: [RandomwalkTaskLifecycleListener] can detach this channel's plugin explicitly, ahead
     * of (or instead of, if the isolate is wedged) the engine's own destruction, so the
     * `BinaryMessenger` this channel was registered on can otherwise keep routing calls to it.
     */
    fun dispose() {
        channel?.setMethodCallHandler(null)
        executor.execute {
            actor?.close()
            File(context.filesDir, configFileName).delete()
        }
        executor.shutdown()
    }
}
