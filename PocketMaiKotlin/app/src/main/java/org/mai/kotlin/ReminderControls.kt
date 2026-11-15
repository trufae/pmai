package org.mai.kotlin

import android.Manifest
import android.app.DatePickerDialog
import android.app.NotificationManager
import android.app.TimePickerDialog
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.text.format.DateFormat
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import java.time.Instant
import java.util.Calendar
import java.util.Date

@Composable internal fun ReminderControls(state: AppState, model: MaiViewModel, editable: Boolean) {
    val reminders by ReminderNotifications.state.collectAsState()
    val context = LocalContext.current
    val manager = context.getSystemService(NotificationManager::class.java)
    var notificationAllowed by remember { mutableStateOf(manager.areNotificationsEnabled()) }
    var exactAllowed by remember { mutableStateOf(ReminderNotifications.canScheduleExact(context)) }
    val notificationRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        notificationAllowed = manager.areNotificationsEnabled()
        ReminderNotifications.refresh(context.applicationContext)
    }
    val systemSettings = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        notificationAllowed = manager.areNotificationsEnabled()
        exactAllowed = ReminderNotifications.canScheduleExact(context)
        ReminderNotifications.refresh(context.applicationContext)
    }
    var editing by remember { mutableStateOf<ReminderEntry?>(null) }
    var adding by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf<ReminderEntry?>(null) }

    ListItem(headlineContent = { Text("Allow the assistant to change reminders") },
        trailingContent = {
            Switch(state.agent.remindersWriteEnabled, {
                model.command("remindersWriteEnabled", "enabled" to it.toString())
            }, enabled = editable)
        })
    ListItem(headlineContent = { Text("Reminder alerts") },
        trailingContent = {
            Switch(reminders.enabled, { model.command("remindersAlerts", "enabled" to it.toString()) })
        })
    if (!notificationAllowed) {
        TextButton(onClick = {
            if (Build.VERSION.SDK_INT >= 33) notificationRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
            else systemSettings.launch(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(
                Settings.EXTRA_APP_PACKAGE, context.packageName))
        }) { Text("Allow notifications") }
        TextButton(onClick = {
            systemSettings.launch(Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(
                Settings.EXTRA_APP_PACKAGE, context.packageName))
        }) { Text("Notification settings") }
    }
    if (Build.VERSION.SDK_INT >= 31 && !exactAllowed) {
        ListItem(headlineContent = { Text("Android may delay reminder alerts") },
            trailingContent = {
                TextButton(onClick = {
                    systemSettings.launch(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                        Uri.parse("package:${context.packageName}")))
                }) { Text("Allow exact alarms") }
            })
    }
    if (reminders.error.isNotEmpty()) Text(reminders.error, color = MaterialTheme.colorScheme.error)
    TextButton(onClick = { adding = true }) { Text("Add reminder") }
    reminders.reminders.sortedBy { it.due ?: Long.MAX_VALUE }.forEach { item ->
        ListItem(
            headlineContent = { Text(item.title) },
            supportingContent = { item.due?.let { Text(java.text.DateFormat.getDateTimeInstance().format(Date(it))) } },
            leadingContent = {
                Checkbox(item.completed, { model.command("reminders_update", "id" to item.id, "completed" to it.toString()) })
            },
            trailingContent = {
                Column {
                    TextButton(onClick = { editing = item }) { Text("Edit") }
                    TextButton(onClick = { deleting = item }) { Text("Delete") }
                }
            }
        )
    }
    if (adding || editing != null) {
        val item = editing
        ReminderEditor(item, dismiss = { adding = false; editing = null }) { title, due, alert ->
            val fields = mutableListOf("title" to title, "alert" to alert)
            if (due != null) fields.add("due" to Instant.ofEpochMilli(due).toString())
            if (item != null) {
                fields.add("id" to item.id)
                if (due == null) fields.add("clear_due" to "true")
            }
            model.command(if (item == null) "reminders_add" else "reminders_update", *fields.toTypedArray())
            adding = false
            editing = null
        }
    }
    deleting?.let { item ->
        AlertDialog(onDismissRequest = { deleting = null }, title = { Text("Delete reminder?") },
            text = { Text(item.title) },
            confirmButton = { TextButton(onClick = {
                model.command("reminders_remove", "id" to item.id)
                deleting = null
            }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } })
    }
}

@Composable private fun ReminderEditor(item: ReminderEntry?, dismiss: () -> Unit,
    save: (String, Long?, String) -> Unit) {
    val context = LocalContext.current
    var title by remember(item) { mutableStateOf(item?.title.orEmpty()) }
    var scheduled by remember(item) { mutableStateOf(item?.due != null) }
    var due by remember(item) { mutableLongStateOf(item?.due ?: (System.currentTimeMillis() + 3_600_000)) }
    var alert by remember(item) { mutableStateOf(item?.alert ?: "notification") }
    val time = Calendar.getInstance().apply { timeInMillis = due }
    AlertDialog(onDismissRequest = dismiss,
        title = { Text(if (item == null) "Add reminder" else "Edit reminder") },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState())) {
                OutlinedTextField(title, { title = it }, label = { Text("Title") }, singleLine = true)
                Row {
                    Switch(scheduled, { scheduled = it })
                    Text("Due date")
                }
                if (scheduled) {
                    TextButton(onClick = {
                        DatePickerDialog(context, { _, year, month, day ->
                            time.set(year, month, day)
                            TimePickerDialog(context, { _, hour, minute ->
                                time.set(Calendar.HOUR_OF_DAY, hour)
                                time.set(Calendar.MINUTE, minute)
                                time.set(Calendar.SECOND, 0)
                                time.set(Calendar.MILLISECOND, 0)
                                due = time.timeInMillis
                            }, time.get(Calendar.HOUR_OF_DAY), time.get(Calendar.MINUTE), DateFormat.is24HourFormat(context)).show()
                        }, time.get(Calendar.YEAR), time.get(Calendar.MONTH), time.get(Calendar.DAY_OF_MONTH)).show()
                    }) { Text(java.text.DateFormat.getDateTimeInstance().format(Date(due))) }
                    listOf("none" to "None", "notification" to "Notification", "alarm" to "Audible alarm").forEach { (value, label) ->
                        Row {
                            RadioButton(alert == value, { alert = value })
                            Text(label)
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(enabled = title.trim().length in 1..256, onClick = {
                save(title.trim(), due.takeIf { scheduled }, if (scheduled) alert else "none")
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = dismiss) { Text("Cancel") } })
}
