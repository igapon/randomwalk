package fr.lmqc.randomwalk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var valhallaChannel: ValhallaChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        valhallaChannel = ValhallaChannel(applicationContext).also { it.register(flutterEngine) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        valhallaChannel?.dispose()
        valhallaChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
