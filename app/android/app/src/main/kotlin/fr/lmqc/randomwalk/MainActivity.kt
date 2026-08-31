package fr.lmqc.randomwalk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var valhallaChannel: ValhallaChannel? = null
    private var deviceChannel: DeviceChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        valhallaChannel = ValhallaChannel(applicationContext).also { it.register(flutterEngine) }
        // Attached to the UI engine only, not to the foreground service's background engine:
        // the step counter is read from the UI isolate (see DeviceChannel.kt's doc), and the
        // background engine's plugin registrant only covers pub packages anyway.
        deviceChannel = DeviceChannel(applicationContext).also { it.register(flutterEngine) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        valhallaChannel?.dispose()
        valhallaChannel = null
        deviceChannel?.dispose()
        deviceChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
