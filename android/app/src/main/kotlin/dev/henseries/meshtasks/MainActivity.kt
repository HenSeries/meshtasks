package dev.henseries.meshtasks

import android.Manifest
import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    /** Task to open, from a tapped notification or the alarm's Open button. */
    private var launchTask: String? = null

    companion object {
        fun openTask(ctx: Context, taskId: String): Intent =
            Intent(ctx, MainActivity::class.java)
                .putExtra("openTask", taskId)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
    }

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        launchTask = intent?.getStringExtra("openTask")
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra("openTask")?.let { launchTask = it }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, "meshtasks/net").setMethodCallHandler { call, result ->
            when (call.method) {
                // Without this lock many phones drop the LAN discovery beacons.
                "acquireMulticastLock" -> {
                    if (multicastLock == null) {
                        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                        multicastLock = wifi.createMulticastLock("meshtasks").apply {
                            setReferenceCounted(false)
                            acquire()
                        }
                    }
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, "meshtasks/alarms").setMethodCallHandler { call, result ->
            val ctx = applicationContext
            Reminders.ensureChannels(ctx)
            when (call.method) {
                "schedule" -> {
                    val arr = JSONArray(call.arguments as String)
                    Reminders.replaceAll(ctx, (0 until arr.length()).map { Reminder.fromJson(arr.getJSONObject(it)) })
                    result.success(true)
                }
                "show" -> {
                    showEvent(call.argument<Int>("id")!!, call.argument<String>("title")!!,
                        call.argument<String>("body") ?: "", call.argument<String>("taskId"))
                    result.success(true)
                }
                "takeActions" -> result.success(Reminders.takeActions(ctx))
                "takeLaunchTask" -> {
                    result.success(launchTask)
                    launchTask = null
                }
                "permissions" -> result.success(
                    mapOf(
                        "notifications" to Reminders.canNotify(ctx),
                        "exactAlarms" to Reminders.canExact(ctx),
                        "overlay" to Reminders.canOverlay(ctx),
                        "fullScreen" to Reminders.canFullScreen(ctx),
                    )
                )
                "request" -> {
                    request(call.arguments as String)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Asks for a permission, or opens the settings page where it's granted. */
    private fun request(what: String) {
        val pkg = Uri.parse("package:$packageName")
        when (what) {
            "notifications" -> if (Build.VERSION.SDK_INT >= 33) {
                requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
            }
            "overlay" -> startActivity(Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, pkg))
            "exactAlarms" -> if (Build.VERSION.SDK_INT >= 31) {
                startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, pkg))
            }
            // Where "Allow restricted settings" lives (⋮ menu) for apps
            // installed from a file rather than a store.
            "appDetails" -> startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, pkg))
            "fullScreen" -> if (Build.VERSION.SDK_INT >= 34) {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, pkg))
            }
        }
    }

    /** Team activity (assignments, comments, points) shown right away. */
    private fun showEvent(id: Int, title: String, body: String, taskId: String?) {
        if (!Reminders.canNotify(this)) return
        val open = PendingIntent.getActivity(
            this, id,
            if (taskId != null) openTask(this, taskId) else Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(this, Reminders.CH_EVENTS)
            .setSmallIcon(R.drawable.ic_stat_meshtasks)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        getSystemService(NotificationManager::class.java).notify(id, n)
    }

    override fun onDestroy() {
        multicastLock?.release()
        super.onDestroy()
    }
}
