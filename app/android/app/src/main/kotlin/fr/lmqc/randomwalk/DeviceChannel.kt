package fr.lmqc.randomwalk

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Small platform facts over the `randomwalk/device` MethodChannel, in the same shape as
 * [ValhallaChannel].
 *
 *  - `manufacturer`: `Build.MANUFACTURER`, used by Settings to decide whether to show the
 *    "Suivi fiable en arrière-plan" tile for OEMs known to kill background location aggressively
 *    (see `battery_optimization.dart`'s `isAggressiveBatteryOem`).
 *
 *  - `sdkInt`: the running API level, so the Dart permission flow can skip prompts that do not
 *    exist on the device (POST_NOTIFICATIONS is Android 13+, ACTIVITY_RECOGNITION Android 10+).
 *
 *  - the hardware step counter. `Sensor.TYPE_STEP_COUNTER` is a low-power composite sensor that
 *    reports the number of steps since the device booted and keeps counting through doze. It is
 *    an *on-change* sensor, so the first event after `registerListener` carries the current value
 *    without waiting for a step. We keep that value cached and hand it to Dart on request rather
 *    than pushing a stream: Dart only ever needs the count while the app is on screen (the trip's
 *    step total is a diff against the value at trip start), and pulling means the screen-off
 *    delivery gap that plagues stream-based step plugins simply does not apply.
 *
 * Registering the listener requires ACTIVITY_RECOGNITION from API 29 — hence `startStepCounter`
 * being an explicit call the Dart side makes only after the permission flow has run, rather than
 * something this class does on attach.
 *
 * Like [ValhallaChannel], one instance now lives on every engine this is registered on (UI and,
 * via `RandomwalkTaskLifecycleListener`, the background tracking engine) — harmless by design,
 * since the sensor listener is only ever actually registered in response to an explicit
 * `startStepCounter` call from Dart, not on attach.
 */
class DeviceChannel(private val context: Context) {
    private val sensorManager: SensorManager? =
        context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager

    private var stepCount: Long? = null
    private var listening = false
    private var channel: MethodChannel? = null

    private val listener = object : SensorEventListener {
        override fun onSensorChanged(event: SensorEvent) {
            // values[0] is a float carrying an integral count; it is exact well past any
            // plausible lifetime step total.
            stepCount = event.values.firstOrNull()?.toLong() ?: return
        }

        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit
    }

    fun register(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, "randomwalk/device")
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                // Settings' "Suivi fiable en arrière-plan" tile — see
                // battery_optimization.dart's isAggressiveBatteryOem.
                "manufacturer" -> result.success(Build.MANUFACTURER)
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "startStepCounter" -> result.success(startStepCounter())
                // Int, not Long: the MethodChannel codec maps Kotlin Long to Dart int too,
                // but Dart's `invokeMethod<int>` is happiest with the 32-bit form and no
                // step counter will ever approach Int.MAX_VALUE.
                "stepCount" -> result.success(stepCount?.toInt())
                "stopStepCounter" -> {
                    stopStepCounter()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startStepCounter(): Boolean {
        if (listening) return true
        val manager = sensorManager ?: return false
        val sensor = manager.getDefaultSensor(Sensor.TYPE_STEP_COUNTER) ?: return false
        listening = try {
            // Throws SecurityException if ACTIVITY_RECOGNITION was refused; returns false if the
            // sensor cannot be enabled. Both mean "no steps", not "crash the trip".
            manager.registerListener(listener, sensor, SensorManager.SENSOR_DELAY_NORMAL)
        } catch (_: SecurityException) {
            false
        }
        return listening
    }

    private fun stopStepCounter() {
        if (!listening) return
        sensorManager?.unregisterListener(listener)
        listening = false
        // Deliberately keeps the last cached value: Dart may read it once more while finalising
        // the trip.
    }

    /**
     * Detaches the method call handler and releases the sensor listener when the Flutter engine
     * tears down (or is detached from early — see the equivalent note on
     * `ValhallaChannel.dispose`).
     */
    fun dispose() {
        channel?.setMethodCallHandler(null)
        stopStepCounter()
    }
}
