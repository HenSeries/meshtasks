package dev.henseries.meshtasks

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.media.AudioAttributes
import android.media.Ringtone
import android.media.RingtoneManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.util.TypedValue
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Full-screen alarm, shown over the lock screen and over other apps.
 * Rings and vibrates until the user picks Done / Snooze / Open, or for two
 * minutes at most (the notification stays so it isn't lost).
 */
class AlarmActivity : Activity() {
    private var ringtone: Ringtone? = null
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var reminder: Reminder

    companion object {
        fun intent(ctx: Context, r: Reminder): Intent =
            r.toIntent(ctx, "show").setClass(ctx, AlarmActivity::class.java)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setShowWhenLocked(true)
        setTurnScreenOn(true)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        show(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        stopRinging()
        show(intent)
    }

    private fun dp(v: Int) = TypedValue.applyDimension(
        TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics,
    ).toInt()

    private fun show(i: Intent) {
        reminder = Reminder.fromIntent(i)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.rgb(28, 16, 18))
            setPadding(dp(32), dp(48), dp(32), dp(48))
        }
        fun text(s: String, size: Float, bold: Boolean = false, alpha: Float = 1f) =
            TextView(this).apply {
                text = s
                textSize = size
                setTextColor(Color.WHITE)
                this.alpha = alpha
                gravity = Gravity.CENTER
                if (bold) setTypeface(typeface, Typeface.BOLD)
                setPadding(0, dp(8), 0, dp(8))
            }
        fun button(label: String, color: Int, onTap: () -> Unit) = Button(this).apply {
            text = label
            textSize = 18f
            setTextColor(Color.WHITE)
            isAllCaps = false
            background = GradientDrawable().apply {
                cornerRadius = dp(28).toFloat()
                setColor(color)
            }
            setOnClickListener { onTap() }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, dp(56),
            ).apply { topMargin = dp(14) }
        }
        root.addView(text("⏰", 64f))
        root.addView(text(reminder.title, 30f, bold = true))
        if (reminder.body.isNotBlank()) root.addView(text(reminder.body, 17f, alpha = 0.8f))
        root.addView(LinearLayout(this).apply { minimumHeight = dp(32) })
        root.addView(button("✓  ${Strings.done}", Color.rgb(5, 133, 39)) {
            Reminders.queueAction(this, "complete", reminder.taskId)
            close()
        })
        root.addView(button("💤  ${Strings.snooze}", Color.rgb(105, 46, 194)) {
            Reminders.snooze(this, reminder)
            close(cancel = false)
        })
        root.addView(button(Strings.open, Color.rgb(70, 70, 70)) {
            startActivity(MainActivity.openTask(this, reminder.taskId))
            close()
        })
        setContentView(root)
        startRinging()
    }

    private fun startRinging() {
        val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
        ringtone = RingtoneManager.getRingtone(this, uri)?.apply {
            audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
            isLooping = true
            play()
        }
        vibrator()?.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 700, 500), 0))
        handler.postDelayed({ stopRinging() }, 2 * 60_000L)
    }

    private fun stopRinging() {
        handler.removeCallbacksAndMessages(null)
        ringtone?.stop()
        ringtone = null
        vibrator()?.cancel()
    }

    @Suppress("DEPRECATION")
    private fun vibrator(): Vibrator? =
        if (Build.VERSION.SDK_INT >= 31) getSystemService(VibratorManager::class.java)?.defaultVibrator
        else getSystemService(Vibrator::class.java)

    private fun close(cancel: Boolean = true) {
        stopRinging()
        if (cancel) Reminders.cancelNotification(this, reminder.id)
        finish()
    }

    override fun onDestroy() {
        stopRinging()
        super.onDestroy()
    }
}
