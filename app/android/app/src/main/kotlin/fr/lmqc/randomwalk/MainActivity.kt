package fr.lmqc.randomwalk

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var randomwalkPlugin: RandomwalkPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // RandomwalkPlugin is a local (non-pub) plugin, so GeneratedPluginRegistrant does not
        // know about it and it must be added by hand here — same as before this refactor. What
        // changed is that the same plugin class is now also attached to the tracking service's
        // background engine, via RandomwalkTaskLifecycleListener (see that file and
        // RandomwalkApplication for why, and why that needed a different mechanism than this
        // one).
        randomwalkPlugin = RandomwalkPlugin().also { flutterEngine.plugins.add(it) }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        randomwalkPlugin?.let { flutterEngine.plugins.remove(it::class.java) }
        randomwalkPlugin = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
