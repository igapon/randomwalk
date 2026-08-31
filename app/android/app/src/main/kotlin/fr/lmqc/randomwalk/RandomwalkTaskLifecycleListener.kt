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
 *    constructed and before the task's Dart callback runs; `onEngineWillDestroy()` — this
 *    package's own, with no engine parameter — fires right before `flutterEngine.destroy()` is
 *    normally about to tear it down. This listener is the robust path for *attaching*; see below
 *    for why *detaching* uses a different, engine-scoped hook instead of this method.
 *
 * Registered once, from [RandomwalkApplication.onCreate] — not from `MainActivity` — because the
 * service can (re)create its engine without any Activity ever running (e.g. `RestartReceiver`
 * after the service was killed, or a reboot), and the listener must already be in place by the
 * time that happens.
 */
object RandomwalkTaskLifecycleListener : FlutterForegroundTaskLifecycleListener {
    override fun onEngineCreate(flutterEngine: FlutterEngine?) {
        val engine = flutterEngine ?: return
        engine.plugins.add(RandomwalkPlugin())

        // Detach by pairing with THIS specific engine, not with flutter_foreground_task's
        // engine-less onEngineWillDestroy() below. Two reasons, both found by reading
        // ForegroundTask.kt / ForegroundService.kt in the installed
        // flutter_foreground_task:11.0.1 sources:
        //
        //  1. `ForegroundTask.destroy()` can defer its own `flutterEngine.destroy()` behind a
        //     reply from the task's own Dart isolate (when a callback handle is set, `onDestroy`
        //     is `invokeMethod`'d and the engine is only destroyed inside that call's completion
        //     callback) — a wedged isolate never replies, so relying on that destroy() to trigger
        //     cleanup can leak the native Valhalla actor and its worker thread indefinitely.
        //  2. `ForegroundService.createForegroundTask` can construct a replacement `ForegroundTask`
        //     (and engine) before the previous one's deferred destroy() completes, so two engines
        //     can be transiently alive at once. flutter_foreground_task's own
        //     `onEngineWillDestroy()` carries no engine reference (an interface constraint), so
        //     there is no way to tell, from that callback alone, WHICH of possibly several
        //     attached engines it refers to — an earlier fix here queued attached engines FIFO to
        //     guess, but a permanently-wedged engine that never actually gets destroyed poisons
        //     that queue forever: every later `onEngineWillDestroy` would keep removing the queue
        //     head (the wedged, still-running engine) instead of the engine actually being
        //     destroyed, misaligning every subsequent pairing.
        //
        // `FlutterEngine.addEngineLifecycleListener` sidesteps both problems: it is Flutter's own
        // per-engine hook (`io.flutter.embedding.engine.FlutterEngine.EngineLifecycleListener`,
        // verified against the installed embedding sources), the closure below captures exactly
        // the [engine] it was registered on, and `FlutterEngine.destroy()` calls it before
        // `pluginRegistry.destroy()` — so it fires precisely when (and only when) destroy()
        // actually runs on *this* engine, deferred or not, and correctly does nothing for an
        // engine that never gets destroyed at all.
        engine.addEngineLifecycleListener(object : FlutterEngine.EngineLifecycleListener {
            override fun onPreEngineRestart() = Unit

            override fun onEngineWillDestroy() {
                // Idempotent: pluginRegistry.destroy() -> removeAll(), called right after this by
                // the same FlutterEngine.destroy(), is a no-op for a plugin already removed.
                engine.plugins.remove(RandomwalkPlugin::class.java)
            }
        })
    }

    override fun onTaskStart(starter: FlutterForegroundTaskStarter) = Unit

    override fun onTaskRepeatEvent() = Unit

    override fun onTaskDestroy() = Unit

    // No-op by design: detach is owned by the per-engine EngineLifecycleListener registered in
    // onEngineCreate above, which is the only hook that can be reliably paired with the specific
    // engine being destroyed. A residual is accepted and not solvable from here: if an engine's
    // Dart isolate is wedged badly enough that `flutterEngine.destroy()` is never called for it at
    // all (not even eventually), its RandomwalkPlugin instance — and the native actor/worker
    // thread it owns — is never detached/disposed either. Bounding that would need an explicit
    // timeout independent of flutter_foreground_task's own teardown path, which is out of scope
    // here; flagged in the Task 4 report for Task 5 device QA to watch for.
    override fun onEngineWillDestroy() = Unit
}
