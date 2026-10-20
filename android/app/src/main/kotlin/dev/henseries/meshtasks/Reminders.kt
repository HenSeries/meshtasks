package dev.henseries.meshtasks

import android.Manifest
import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.provider.Settings
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/** One reminder as sent from Dart (see lib/model/reminders.dart). */
data class Reminder(
    val id: Int,
    val taskId: String,
    val at: Long,
    val title: String,
    val body: String,
    val alarm: Boolean,
) {
    fun toJson(): JSONObject = JSONObject()
        .put("id", id).put("taskId", taskId).put("at", at)
        .put("title", title).put("body", body).put("alarm", alarm)

    fun toIntent(ctx: Context, action: String): Intent =
        Intent(ctx, ReminderReceiver::class.java).setAction(action)
            .putExtra("id", id).putExtra("taskId", taskId).putExtra("at", at)
            .putExtra("title", title).putExtra("body", body).putExtra("alarm", alarm)

    companion object {
        fun fromJson(o: JSONObject) = Reminder(
            o.getInt("id"), o.getString("taskId"), o.getLong("at"),
            o.getString("title"), o.optString("body"), o.optBoolean("alarm"),
        )

        fun fromIntent(i: Intent) = Reminder(
            i.getIntExtra("id", 0), i.getStringExtra("taskId") ?: "", i.getLongExtra("at", 0),
            i.getStringExtra("title") ?: "", i.getStringExtra("body") ?: "",
            i.getBooleanExtra("alarm", false),
        )
    }
}

/** UI strings for the native parts (notifications, alarm screen). */
object Strings {
    private val es get() = Locale.getDefault().language == "es"
    val done get() = if (es) "Hecho" else "Done"
    val snooze get() = if (es) "Posponer 10 min" else "Snooze 10 min"
    val open get() = if (es) "Abrir" else "Open"
    val reminders get() = if (es) "Recordatorios" else "Reminders"
    val alarms get() = if (es) "Alarmas" else "Alarms"
    val events get() = if (es) "Actividad del equipo" else "Team activity"
}

/**
 * Schedules reminders with AlarmManager so they fire even when the app is
 * closed or the phone is dozing, and re-creates them after a reboot.
 */
object Reminders {
    const val FIRE = "dev.henseries.meshtasks.FIRE"
    const val DONE = "dev.henseries.meshtasks.DONE"
    const val SNOOZE = "dev.henseries.meshtasks.SNOOZE"
    const val CH_REMINDERS = "reminders"
    const val CH_ALARMS = "alarms_v1"
    const val CH_EVENTS = "events"
    private const val PREFS = "meshtasks_reminders"

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun ensureChannels(ctx: Context) {
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CH_REMINDERS, Strings.reminders, NotificationManager.IMPORTANCE_HIGH)
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_ALARMS, Strings.alarms, NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(
                    RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
                    AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build(),
                )
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 600, 400, 600, 400, 600)
            }
        )
        nm.createNotificationChannel(
            NotificationChannel(CH_EVENTS, Strings.events, NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun firePending(ctx: Context, r: Reminder): PendingIntent = PendingIntent.getBroadcast(
        ctx, r.id, r.toIntent(ctx, FIRE),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    /** Replaces every scheduled reminder with [list]. */
    fun replaceAll(ctx: Context, list: List<Reminder>) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        val old = prefs(ctx).getString("scheduled", "[]")!!
        val oldArr = JSONArray(old)
        for (i in 0 until oldArr.length()) {
            val r = Reminder.fromJson(oldArr.getJSONObject(i))
            am.cancel(firePending(ctx, r))
        }
        val now = System.currentTimeMillis()
        val keep = JSONArray()
        for (r in list) {
            if (r.at <= now) continue
            schedule(ctx, r)
            keep.put(r.toJson())
        }
        prefs(ctx).edit().putString("scheduled", keep.toString()).apply()
    }

    fun schedule(ctx: Context, r: Reminder) {
        val am = ctx.getSystemService(AlarmManager::class.java)
        val pi = firePending(ctx, r)
        try {
            scheduleExact(ctx, am, r, pi)
        } catch (e: SecurityException) {
            // Exact alarms not allowed on this device: still remind, a bit late.
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, r.at, pi)
        }
    }

    private fun scheduleExact(ctx: Context, am: AlarmManager, r: Reminder, pi: PendingIntent) {
        when {
            // Alarm-clock alarms are exact, wake the device and are exempt from
            // Doze; Android also shows them as the "next alarm".
            r.alarm -> {
                val show = PendingIntent.getActivity(
                    ctx, r.id, MainActivity.openTask(ctx, r.taskId),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                am.setAlarmClock(AlarmManager.AlarmClockInfo(r.at, show), pi)
            }
            canExact(ctx) -> am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, r.at, pi)
            else -> am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, r.at, pi)
        }
    }

    fun rescheduleSaved(ctx: Context) {
        val arr = JSONArray(prefs(ctx).getString("scheduled", "[]")!!)
        replaceAll(ctx, (0 until arr.length()).map { Reminder.fromJson(arr.getJSONObject(it)) })
    }

    fun snooze(ctx: Context, r: Reminder, minutes: Int = 10) {
        cancelNotification(ctx, r.id)
        schedule(ctx, r.copy(at = System.currentTimeMillis() + minutes * 60_000L))
    }

    fun canExact(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 31 || ctx.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    fun canNotify(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 33 ||
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun canOverlay(ctx: Context): Boolean = Settings.canDrawOverlays(ctx)

    fun canFullScreen(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 34 ||
            ctx.getSystemService(NotificationManager::class.java).canUseFullScreenIntent()

    fun cancelNotification(ctx: Context, id: Int) =
        ctx.getSystemService(NotificationManager::class.java).cancel(id)

    // ---- actions taken outside the app, applied by Dart when it runs ----

    fun queueAction(ctx: Context, type: String, taskId: String) {
        val arr = JSONArray(prefs(ctx).getString("actions", "[]")!!)
        arr.put(JSONObject().put("type", type).put("taskId", taskId).put("at", System.currentTimeMillis()))
        prefs(ctx).edit().putString("actions", arr.toString()).apply()
    }

    fun takeActions(ctx: Context): String {
        val p = prefs(ctx)
        val s = p.getString("actions", "[]")!!
        p.edit().putString("actions", "[]").apply()
        return s
    }
}
