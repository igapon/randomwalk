package fr.lmqc.randomwalk

import android.Manifest
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import com.google.android.gms.location.ActivityRecognition
import com.google.android.gms.location.ActivityTransition
import com.google.android.gms.location.ActivityTransitionRequest
import com.google.android.gms.location.ActivityTransitionResult
import com.google.android.gms.location.DetectedActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Low-power mode (M5 Task 2d, owner brief): bridges the Activity Recognition Transition API
 * (`com.google.android.gms.location.ActivityRecognitionClient`) to Dart over the
 * `randomwalk/motion` MethodChannel, in the same registration shape as
 * [ValhallaChannel]/[DeviceChannel]/[TtsChannel] — a thin channel, registering/unregistering the
 * native transition listener and forwarding its events, with all of the actual pause/resume
 * *policy* living in Dart (`motion_policy.dart`'s `MotionPolicy`) rather than here.
 *
 * Unlike this app's other channels, this one is push-based: once [start] has registered the
 * listener, [receiver] fires on its own — whenever the OS actually decides the device has entered
 * or exited [DetectedActivity.STILL] — and each event is forwarded to Dart as
 * `channel.invokeMethod("onTransition", mapOf("stillEntered" to Boolean))`. [MethodChannel] is
 * bidirectional by design (see the Flutter platform-channels docs): a native `invokeMethod` call
 * reaches whatever `setMethodCallHandler` the Dart side (`MotionChannel.transitions`) installed,
 * the same mechanism this app's other channels use in the other direction.
 *
 * [start] degrades to `false` — never throws across the channel — for every way this can
 * legitimately not work: `ACTIVITY_RECOGNITION` not granted, no Play Services on the device, or
 * the emulator's own lack of real Activity Recognition (the CI integration job's exact situation,
 * per the task brief — this is the emulator's expected, silent path, not a bug to chase). The
 * Dart side (`TripTaskHandler`) reads any of those the same way: fall back to the step/GPS
 * detector instead of failing the trip.
 *
 * Uses an explicit, **per-instance** broadcast action (see [actionString]) rather than one shared
 * literal — [RandomwalkPlugin]'s own doc comment establishes that two engines (the UI's and the
 * background tracking service's) can be attached at once, each with its own [MotionChannel]
 * instance; a shared action name would mean both instances' dynamically-registered [receiver]s
 * receive every event, double-delivering it to whichever engine did *not* actually call [start].
 * Same rationale, same technique as [ValhallaChannel.configFileName].
 */
class MotionChannel(private val context: Context) {
    private var channel: MethodChannel? = null
    private var registered = false

    // See the class doc comment — unique per instance so two engines' listeners never cross-talk.
    private val requestCode = System.identityHashCode(this)
    private val actionString = "fr.lmqc.randomwalk.MOTION_TRANSITION_$requestCode"

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(receivedContext: Context, intent: Intent) {
            if (!ActivityTransitionResult.hasResult(intent)) return
            val result = ActivityTransitionResult.extractResult(intent) ?: return
            for (event in result.transitionEvents) {
                if (event.activityType != DetectedActivity.STILL) continue
                val stillEntered =
                    event.transitionType == ActivityTransition.ACTIVITY_TRANSITION_ENTER
                channel?.invokeMethod("onTransition", mapOf("stillEntered" to stillEntered))
            }
        }
    }

    fun register(messenger: BinaryMessenger) {
        val methodChannel = MethodChannel(messenger, "randomwalk/motion")
        channel = methodChannel
        methodChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(result)
                "stop" -> stop(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Registers [receiver] and requests STILL enter/exit transition updates. Answers `true` once
     * the request has actually been accepted by Play Services, `false` on any failure —
     * `ACTIVITY_RECOGNITION` not granted (checked up front, since
     * `requestActivityTransitionUpdates` can also throw `SecurityException` for the same reason —
     * both paths are handled the same way here), no Play Services / no Activity Recognition
     * support on the device, or the request itself failing.
     */
    private fun start(result: MethodChannel.Result) {
        if (registered) {
            result.success(true)
            return
        }
        // Android 10+ (API 29): ACTIVITY_RECOGNITION is a runtime permission, already part of
        // this app's own permission flow (see DeviceChannel.kt's doc comment on the step
        // counter's identical requirement) — a missing grant here means the Dart side asked
        // before the user accepted it, or a device below API 29 where the permission is implicit.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
            context.checkSelfPermission(Manifest.permission.ACTIVITY_RECOGNITION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(false)
            return
        }
        try {
            registerReceiver()
            val transitions = listOf(
                ActivityTransition.Builder()
                    .setActivityType(DetectedActivity.STILL)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_ENTER)
                    .build(),
                ActivityTransition.Builder()
                    .setActivityType(DetectedActivity.STILL)
                    .setActivityTransition(ActivityTransition.ACTIVITY_TRANSITION_EXIT)
                    .build(),
            )
            ActivityRecognition.getClient(context)
                .requestActivityTransitionUpdates(
                    ActivityTransitionRequest(transitions),
                    pendingIntent(),
                )
                .addOnSuccessListener {
                    registered = true
                    result.success(true)
                }
                .addOnFailureListener {
                    unregisterReceiverSafely()
                    result.success(false)
                }
        } catch (_: Exception) {
            // SecurityException (permission refused after all, on some OEM builds), or Play
            // Services missing entirely — either way, this device simply cannot use the native
            // signal; the Dart side falls back to the step/GPS detector.
            unregisterReceiverSafely()
            result.success(false)
        }
    }

    /**
     * Removes the transition updates request and unregisters [receiver]. Always answers
     * `success` — there is nothing meaningful for Dart to do with a failed unregistration, and
     * [dispose] needs this same best-effort behaviour with no [MethodChannel.Result] to answer at
     * all.
     */
    private fun stop(result: MethodChannel.Result?) {
        if (!registered) {
            result?.success(null)
            return
        }
        registered = false
        try {
            ActivityRecognition.getClient(context)
                .removeActivityTransitionUpdates(pendingIntent())
                .addOnCompleteListener {
                    unregisterReceiverSafely()
                    result?.success(null)
                }
        } catch (_: Exception) {
            unregisterReceiverSafely()
            result?.success(null)
        }
    }

    private fun registerReceiver() {
        val filter = IntentFilter(actionString)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // Only this instance's own PendingIntent (below) ever broadcasts [actionString], so
            // there is no legitimate external sender to allow — NOT_EXPORTED is strictly safer
            // and matches the framework's own default recommendation for an app-internal signal.
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            context.registerReceiver(receiver, filter)
        }
    }

    private fun unregisterReceiverSafely() {
        try {
            context.unregisterReceiver(receiver)
        } catch (_: IllegalArgumentException) {
            // Not currently registered (start() never got far enough, or this is a second
            // stop()/dispose() call) — nothing to undo.
        }
    }

    private fun pendingIntent(): PendingIntent {
        val intent = Intent(actionString).setPackage(context.packageName)
        // The system fills in this Intent's extras (the ActivityTransitionResult) when it
        // delivers the broadcast — same requirement as geofencing's identical PendingIntent
        // pattern — so FLAG_MUTABLE is required from API 31 (S) on, where immutable became the
        // default.
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
            (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
        return PendingIntent.getBroadcast(context, requestCode, intent, flags)
    }

    /**
     * Detaches the method call handler and releases the transition listener (if registered) when
     * the Flutter engine tears down — call this from `RandomwalkPlugin.onDetachedFromEngine`, same
     * bracket as [DeviceChannel.dispose]/[TtsChannel.dispose]. Fire-and-forget on the Play
     * Services `Task`, like [ValhallaChannel.dispose]'s executor shutdown — engine teardown does
     * not wait for it, and a registration left dangling past this point would otherwise survive an
     * engine that no longer has anywhere to forward its events to.
     */
    fun dispose() {
        channel?.setMethodCallHandler(null)
        if (!registered) return
        registered = false
        try {
            ActivityRecognition.getClient(context).removeActivityTransitionUpdates(pendingIntent())
        } catch (_: Exception) {
            // Best-effort; see the doc comment above.
        }
        unregisterReceiverSafely()
    }
}
