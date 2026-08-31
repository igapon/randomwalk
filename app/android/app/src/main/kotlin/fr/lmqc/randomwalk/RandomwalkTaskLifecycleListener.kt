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
    // FIFO of engines attached but not yet explicitly detached. `ForegroundTask.destroy()` can
    // defer its `flutterEngine.destroy()` behind a reply from the task's own Dart isolate (see
    // ForegroundTask.kt: when a callback handle is set, `onDestroy` is `invokeMethod`'d and the
    // engine is only destroyed inside that call's completion callback), while
    // `ForegroundService.createForegroundTask` constructs the replacement `ForegroundTask` (and
    // its engine) immediately afterwards. So `onEngineCreate` for a new engine can fire before
    // `onEngineWillDestroy` for the previous one arrives — or, if the old isolate is wedged and
    // never replies, before it arrives at all. `onEngineWillDestroy()` carries no engine
    // reference (an interface constraint of FlutterForegroundTaskLifecycleListener), so a single
    // "last engine" field would risk detaching the plugin from the wrong — still live — engine
    // during that overlap. A FIFO queue instead pairs each `onEngineWillDestroy` with whichever
    // attached engine has been waiting longest, which is exactly the one flutter_foreground_task
    // is (or would be, if the isolate weren't wedged) about to destroy: engine lifecycles here
    // are created and torn down in strict chronological order, never reordered, even though they
    // can overlap.
    //
    // All of this runs on the service process's main thread — Android component callbacks and
    // FlutterEngine lifecycle calls are never concurrent with each other — so no locking is
    // needed around the queue.
    private val attachedEngines = ArrayDeque<FlutterEngine>()

    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        flutterEngine ?: return
        flutterEngine.plugins.add(RandomwalkPlugin())
        attachedEngines.addLast(flutterEngine)
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    override fun onTaskDestroy() = Unit

    override fun onEngineWillDestroy() {
        // Detach explicitly and synchronously here, rather than relying on the later
        // `flutterEngine.destroy()` to do it: that `destroy()` call can be wedged behind the very
        // same unresponsive Dart isolate this teardown is for (see the class doc above), in which
        // case it may be delayed indefinitely or never happen at all — leaving the native
        // Valhalla actor and its worker thread leaked for as long as the process lives.
        // `PluginRegistry.remove(Class)` is a plain map lookup-and-detach and a no-op if nothing
        // is registered under that class anymore, so it is harmless to also let the eventual
        // (possibly never-arriving) `flutterEngine.destroy()` call it a second time.
        if (attachedEngines.isNotEmpty()) {
            attachedEngines.removeFirst().plugins.remove(RandomwalkPlugin::class.java)
        }
    }
}
