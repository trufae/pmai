package org.mai.kotlin

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.FileObserver
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONObject
import java.io.File

internal data class ReminderEntry(
    val id: String, val title: String, val due: Long?, val alert: String, val completed: Boolean,
)

internal data class ReminderState(
    val enabled: Boolean = true,
    val reminders: List<ReminderEntry> = emptyList(),
    val error: String = "",
)

internal object ReminderNotifications {
    private const val CHANNEL = "reminders"
    private const val ALARM_CHANNEL = "reminder_alarms"
    private const val ORDINARY = "org.mai.pocketmai.kotlin.REMINDER"
    private const val EXACT = "org.mai.pocketmai.kotlin.REMINDER_EXACT"
    private const val NOTIFICATION_ID = 1
    private val current = MutableStateFlow(ReminderState())
    val state = current.asStateFlow()
    private var observer: FileObserver? = null

    @Suppress("DEPRECATION") // FileObserver(File, ...) requires API 29.
    fun start(context: Context) {
        val directory = context.filesDir.resolve("pocketmai")
        directory.mkdirs()
        val main = Handler(Looper.getMainLooper())
        val refresh = Runnable { refresh(context) }
        observer = object : FileObserver(directory.path, CLOSE_WRITE or MOVED_TO or DELETE) {
            override fun onEvent(event: Int, path: String?) {
                if (path == "reminders.json") {
                    main.removeCallbacks(refresh)
                    main.post(refresh)
                }
            }
        }.also { it.startWatching() }
        refresh(context)
    }

    fun canScheduleExact(context: Context): Boolean =
        Build.VERSION.SDK_INT < 31 || context.getSystemService(AlarmManager::class.java).canScheduleExactAlarms()

    // Runs on Android's main looper, including from the alarm and boot receiver.
    fun refresh(context: Context) {
        val alarms = context.getSystemService(AlarmManager::class.java)
        val notifications = context.getSystemService(NotificationManager::class.java)
        val file = context.filesDir.resolve("pocketmai/reminders.json")
        val snapshot = try {
            read(file)
        } catch (error: Exception) {
            current.value = current.value.copy(error = error.localizedMessage ?: "Cannot read reminders.")
            Log.w("PocketMai", "Cannot read saved reminders", error)
            return
        }
        current.value = snapshot
        val preferences = context.getSharedPreferences("reminder_delivery", Context.MODE_PRIVATE)
        val pending = snapshot.reminders.filter {
            snapshot.enabled && !it.completed && it.due != null && it.alert in listOf("notification", "alarm")
        }.associateBy { it.id }
        val delivered = preferences.all
        val changes = preferences.edit()
        val knownIDs = snapshot.reminders.map { it.id }.toSet()
        delivered.forEach { (id, oldDate) ->
            if (pending[id]?.due != oldDate) notifications.cancel(id, NOTIFICATION_ID)
            if (id !in knownIDs) changes.remove(id)
        }
        val ordinary = intent(context, ORDINARY)
        val exact = intent(context, EXACT)
        val awaiting = pending.values.filter { delivered[it.id] != it.due }
            .sortedBy { it.due }
        val allowed = notifications.areNotificationsEnabled()
        if (allowed) createChannels(notifications)
        val now = System.currentTimeMillis()
        var next: Long? = null
        if (allowed) {
            for (reminder in awaiting) {
                val due = requireNotNull(reminder.due)
                if (due > now) {
                    next = due
                    break
                }
                val audible = reminder.alert == "alarm"
                val open = context.packageManager.getLaunchIntentForPackage(context.packageName)
                val content = open?.let {
                    PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE)
                }
                val notification = Notification.Builder(context, if (audible) ALARM_CHANNEL else CHANNEL)
                    .setSmallIcon(android.R.drawable.ic_popup_reminder)
                    .setContentTitle(reminder.title)
                    .setCategory(if (audible) Notification.CATEGORY_ALARM else Notification.CATEGORY_REMINDER)
                    .setContentIntent(content)
                    .setVisibility(Notification.VISIBILITY_PRIVATE)
                    .setOnlyAlertOnce(true)
                    .setAutoCancel(true)
                    .build()
                try {
                    notifications.notify(reminder.id, NOTIFICATION_ID, notification)
                    changes.putLong(reminder.id, due)
                } catch (error: SecurityException) {
                    Log.w("PocketMai", "Reminder notification permission changed", error)
                    break
                }
            }
        }
        changes.apply()
        if (next == null) {
            alarms.cancel(ordinary)
            alarms.cancel(exact)
            return
        }
        // The inexact alarm survives revocation of the exact-alarm permission.
        alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, ordinary)
        if (canScheduleExact(context)) {
            try {
                alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, exact)
            } catch (error: SecurityException) {
                Log.w("PocketMai", "Exact alarm permission changed", error)
            }
        } else {
            alarms.cancel(exact)
        }
    }

    private fun read(file: File): ReminderState {
        if (!file.exists()) return ReminderState()
        val data = JSONObject(file.readText())
        val reminders = data.getJSONArray("reminders").objects().map {
            ReminderEntry(it.getString("id"), it.getString("title"),
                if (it.isNull("dueAt")) null else kotlin.math.ceil(it.getDouble("dueAt") * 1000).toLong(),
                it.getString("alert"), it.getBoolean("completed"))
        }
        return ReminderState(data.getBoolean("notificationsEnabled"), reminders)
    }

    private fun intent(context: Context, action: String): PendingIntent =
        PendingIntent.getBroadcast(context, 0, Intent(context, ReminderReceiver::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE)

    private fun createChannels(manager: NotificationManager) {
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reminders", NotificationManager.IMPORTANCE_LOW)
        )
        manager.createNotificationChannel(
            NotificationChannel(ALARM_CHANNEL, "Reminder alarms", NotificationManager.IMPORTANCE_HIGH).apply {
                val audio = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).build()
                setSound(RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM), audio)
            }
        )
    }
}

class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ReminderNotifications.refresh(context.applicationContext)
    }
}
