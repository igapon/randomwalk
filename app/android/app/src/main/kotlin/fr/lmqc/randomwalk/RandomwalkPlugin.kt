package fr.lmqc.randomwalk

import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * Bundles [ValhallaChannel], [DeviceChannel] and [TtsChannel] as a single `FlutterPlugin` so one
 * `flutterEngine.plugins.add(RandomwalkPlugin())` attaches `randomwalk/valhalla`,
 * `randomwalk/device` and `randomwalk/tts` to a given [io.flutter.embedding.engine.FlutterEngine].
 *
 * This plugin is attached to two different engines in practice:
 *  - the app's UI engine, from `MainActivity.configureFlutterEngine`;
 *  - the background engine flutter_foreground_task creates for the tracking service, via
 *    [RandomwalkTaskLifecycleListener] (see that file for why a plain `FlutterPlugin` is not
 *    enough on its own to reach that engine).
 *
 * Each attachment gets its own instance (own [ValhallaChannel] actor, own [DeviceChannel]
 * sensor listener, own [TtsChannel] `TextToSpeech` engine) — `flutterEngine.plugins.add` calls
 * [onAttachedToEngine] once per engine, and the engine's teardown (`flutterEngine.destroy()`, or
 * an explicit `flutterEngine.plugins.remove`) calls [onDetachedFromEngine] exactly once for that
 * same instance. Two engines attached at once (UI + background service, during active
 * navigation) means two Valhalla actors, each mmapping the same on-disk tile files —
 * acceptable, since the OS shares the mmapped pages between them; it is not a double-allocation
 * of tile data. Likewise two independent `TextToSpeech` engines, one per attached engine — each
 * lazy, so neither costs anything unless its own side actually speaks.
 */
class RandomwalkPlugin : FlutterPlugin {
    private var valhallaChannel: ValhallaChannel? = null
    private var deviceChannel: DeviceChannel? = null
    private var ttsChannel: TtsChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val messenger = binding.binaryMessenger
        valhallaChannel = ValhallaChannel(context).also { it.register(messenger) }
        deviceChannel = DeviceChannel(context).also { it.register(messenger) }
        ttsChannel = TtsChannel(context).also { it.register(messenger) }
        // Cheap, deliberate breadcrumb: this is the only signal (short of a debugger) that the
        // background service's engine actually got the plugin — see Task 5 device QA notes.
        Log.i(TAG, "attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        valhallaChannel?.dispose()
        valhallaChannel = null
        deviceChannel?.dispose()
        deviceChannel = null
        ttsChannel?.dispose()
        ttsChannel = null
        // Symmetric with the attach breadcrumb — lets QA confirm the background service's engine
        // was actually detached from (and not just attached to) during teardown.
        Log.i(TAG, "detached from engine")
    }

    private companion object {
        const val TAG = "RandomwalkPlugin"
    }
}
