package fr.lmqc.randomwalk

import com.pravera.flutter_foreground_task.FlutterForegroundTaskLifecycleListener
import com.pravera.flutter_foreground_task.FlutterForegroundTaskStarter
import io.flutter.embedding.engine.FlutterEngine

/**
 * Attaches [RandomwalkPlugin] to the [FlutterEngine] that flutter_foreground_task creates for
 * its background isolate (the one the tracking service runs its Dart callback on).
 *
 * Why this exists instead of relying on `GeneratedPluginRegistrant`, and why a *local Flutter
 * plugin package* would not have solved this either — both findings come from reading the
 * installed flutter_foreground_task:11.0.1 sources directly (pub cache path:
 * `flutter_foreground_task-11.0.1/android/src/main/kotlin/com/pravera/flutter_foreground_task/`):
 *
 *  - `service/ForegroundTask.kt`'s `init` block builds the background engine by hand
 *    (`flutterEngine = FlutterEngine(context)`) and never calls
 *    `GeneratedPluginRegistrant.registerWith(flutterEngine)` on it — that call only happens on
 *    the UI engine, via `FlutterActivity`'s default `configureFlutterEngine`.
 *  - The package's own example app confirms this is intentional, not an oversight:
 *    `example/android/app/.../MainActivity.kt` is a bare `class MainActivity : FlutterActivity()`
 *    with no custom engine wiring, i.e. the example relies on exactly zero automatic plugin
 *    registration on the background engine.
 *  - Consequently, converting `RandomwalkPlugin` into a separate local *pub* plugin package
 *    (its own `pubspec.yaml` + `flutter.plugin.platforms.android`) would not have helped:
 *    `GeneratedPluginRegistrant.registerWith` is exactly the mechanism that never runs on this
 *    engine, pub package or not. It would have added real gradle/AGP-compatibility risk (a
 *    second Android Gradle module, verifiable only via CI since local gradle is broken on this
 *    machine) for no benefit.
 *  - What the package *does* provide, as its documented extension point for this exact need, is
 *    `FlutterForegroundTaskLifecycleListener` (see that file's doc comments) plus the static
 *    `FlutterForegroundTaskPlugin.addTaskLifecycleListener` / `removeTaskLifecycleListener`
 *    registration functions. `onEngineCreate(engine)` fires right after the background engine is
 *    constructed and before the task's Dart callback runs; `onEngineWillDestroy()` fires right
 *    before `flutterEngine.destroy()` tears it down. This listener is the robust path.
 *
 * Registered once, from [RandomwalkApplication.onCreate] — not from `MainActivity` — because the
 * service can (re)create its engine without any Activity ever running (e.g. `RestartReceiver`
 * after the service was killed, or a reboot), and the listener must already be in place by the
 * time that happens.
 */
object RandomwalkTaskLifecycleListener : FlutterForegroundTaskLifecycleListener {
    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        flutterEngine?.plugins?.add(RandomwalkPlugin())
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() {
        // No explicit `plugins.remove` needed: `ForegroundTask.destroy()` calls this and then
        // immediately calls `flutterEngine.destroy()`, whose `pluginRegistry.destroy()` detaches
        // (and thus disposes, via RandomwalkPlugin.onDetachedFromEngine) every plugin attached to
        // that engine on its own.
    }
}
