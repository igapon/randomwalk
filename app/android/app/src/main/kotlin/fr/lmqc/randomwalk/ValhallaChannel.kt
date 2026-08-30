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
 *    lifetime; the previous instance is closed before a re-`init`.
 */
class ValhallaChannel(private val context: Context) {
    private var actor: Valhalla? = null
    private val executor = Executors.newSingleThreadExecutor()

    fun register(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "randomwalk/valhalla")
            .setMethodCallHandler { call, result ->
                val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
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
                    "init" -> {
                        val configJson = call.argument<String>("configJson")!!
                        reply {
                            actor?.close()
                            val configFile =
                                File(context.filesDir, "randomwalk_valhalla_config.json")
                            configFile.writeText(configJson)
                            actor = Valhalla(configFile.absolutePath)
                            "ok"
                        }
                    }
                    "route" -> {
                        val request = call.argument<String>("request")!!
                        reply {
                            actor?.routeRaw(request)
                                ?: throw IllegalStateException("engine not initialized")
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
