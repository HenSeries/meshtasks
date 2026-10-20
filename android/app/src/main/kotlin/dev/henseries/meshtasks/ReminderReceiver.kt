package dev.henseries.meshtasks

import android.app.Notification
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Fires reminders and handles the Done / Snooze notification buttons. */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        val r = Reminder.fromIntent(intent)
        Reminders.ensureChannels(ctx)
        when (intent.action) {
            Reminders.FIRE -> if (r.alarm) ring(ctx, r) else notify(ctx, r)
            Reminders.DONE -> {
                Reminders.queueAction(ctx, "complete", r.taskId)
                Reminders.cancelNotification(ctx, r.id)
            }
            Reminders.SNOOZE -> Reminders.snooze(ctx, r)
        }
    }

    private fun actions(ctx: Context, r: Reminder): List<Notification.Action> {
        fun button(action: String, label: String) = Notification.Action.Builder(
            null, label,
            PendingIntent.getBroadcast(
                ctx, r.id * 4 + action.length, r.toIntent(ctx, action),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            ),
        ).build()
        return listOf(button(Reminders.DONE, Strings.done), button(Reminders.SNOOZE, Strings.snooze))
    }

    private fun openApp(ctx: Context, r: Reminder): PendingIntent = PendingIntent.getActivity(
        ctx, r.id, MainActivity.openTask(ctx, r.taskId),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    private fun notify(ctx: Context, r: Reminder) {
        val n = Notification.Builder(ctx, Reminders.CH_REMINDERS)
            .setSmallIcon(R.drawable.ic_stat_meshtasks)
            .setContentTitle(r.title)
            .setContentText(r.body)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setContentIntent(openApp(ctx, r))
            .setAutoCancel(true)
            .setActions(*actions(ctx, r).toTypedArray())
            .build()
        if (Reminders.canNotify(ctx)) ctx.getSystemService(android.app.NotificationManager::class.java).notify(r.id, n)
    }

    /**
     * Alarm: a full-screen notification (takes over the lock screen) and, when
     * the user allowed "display over other apps", the alarm screen right away
     * on top of whatever app is open.
     */
    private fun ring(ctx: Context, r: Reminder) {
        val screen = PendingIntent.getActivity(
            ctx, r.id, AlarmActivity.intent(ctx, r),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val n = Notification.Builder(ctx, Reminders.CH_ALARMS)
            .setSmallIcon(R.drawable.ic_stat_meshtasks)
            .setContentTitle("⏰ ${r.title}")
            .setContentText(r.body)
            .setCategory(Notification.CATEGORY_ALARM)
            .setFullScreenIntent(screen, true)
            .setContentIntent(screen)
            .setOngoing(true)
            .setActions(*actions(ctx, r).toTypedArray())
            .build()
        if (Reminders.canNotify(ctx)) ctx.getSystemService(android.app.NotificationManager::class.java).notify(r.id, n)
        if (Reminders.canOverlay(ctx)) {
            // Apps allowed to draw over others may start activities from the
            // background, which is what puts the alarm on top of other apps.
            ctx.startActivity(AlarmActivity.intent(ctx, r).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }
}

/** Re-creates reminders after a reboot, an app update or a clock change. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        Reminders.ensureChannels(ctx)
        Reminders.rescheduleSaved(ctx)
    }
}
