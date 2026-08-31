package fr.lmqc.randomwalk

import android.app.Application
import com.pravera.flutter_foreground_task.FlutterForegroundTaskPlugin

/**
 * Registers [RandomwalkTaskLifecycleListener] as soon as the process exists, before
 * `MainActivity` or the foreground service's background `FlutterEngine` are created.
 *
 * This must live in `Application.onCreate`, not `MainActivity.onCreate`: the tracking service
 * can (re)start the process by itself with no Activity involved at all — e.g.
 * flutter_foreground_task's own `RestartReceiver` bringing the service back after it was killed,
 * or `RebootReceiver` after the device restarts — and the listener needs to already be
 * registered by the time `ForegroundTask.init` builds that engine. `Application.onCreate` is
 * guaranteed to run first regardless of which component started the process.
 *
 * Declared as the app's `<application android:name=...>` in AndroidManifest.xml, replacing the
 * default `${applicationName}` placeholder (which the Flutter Gradle plugin otherwise resolves
 * to plain `android.app.Application` — see `BaseApplicationNameHandler.kt` in
 * `flutter_tools/gradle`).
 */
class RandomwalkApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        FlutterForegroundTaskPlugin.addTaskLifecycleListener(RandomwalkTaskLifecycleListener)
    }
}
