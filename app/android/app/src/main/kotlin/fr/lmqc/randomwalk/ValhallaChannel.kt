package fr.lmqc.randomwalk

import android.content.Context
import com.valhalla.valhalla.Valhalla
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

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
 *    `MainActivity.cleanUpFlutterEngine`.
 */
class ValhallaChannel(private val context: Context) {
    private var actor: Valhalla? = null
    private val executor = Executors.newSingleThreadExecutor()

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "randomwalk/valhalla")
            .setMethodCallHandler { call, result ->
                val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
                // Argument extraction happens *inside* the executed block, not before dispatch:
                // a missing/wrong-typed argument must reach the caller as a MethodChannel error,
                // not throw on the platform thread before reply() ever gets a chance to catch it.
                fun reply(block: () -> String) = executor.execute {
                    try {
                        val out = block()
                        mainHandler.post { result.success(out) }
                    } catch (t: Throwable) {
                        mainHandler.post {
                            result.error("VALHALLA", t.message ?: t.javaClass.name, null)
                        }
                    }
                }
                when (call.method) {
                    "init" -> reply {
                        val configJson = call.argument<String>("configJson")
                            ?: throw IllegalArgumentException("init requires a configJson string")
                        actor?.close()
                        val configFile =
                            File(context.filesDir, "randomwalk_valhalla_config.json")
                        configFile.writeText(configJson)
                        actor = Valhalla(configFile.absolutePath)
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
     * Releases the native actor (if any) and shuts down the worker thread. Call this from
     * `cleanUpFlutterEngine` — nothing else frees the native handle or the mmapped tiles, and a
     * leaked executor thread survives engine teardown otherwise.
     */
    fun dispose() {
        executor.execute { actor?.close() }
        executor.shutdown()
    }
}
