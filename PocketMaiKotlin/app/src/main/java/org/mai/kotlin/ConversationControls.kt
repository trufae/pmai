@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable internal fun AttachmentButton(state: AppState, model: MaiViewModel) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var menu by remember { mutableStateOf(false) }
    var importing by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    fun import(uris: List<android.net.Uri>) {
        scope.launch {
            importing = true
            val staged = mutableListOf<Attachment>()
            try {
                withContext(Dispatchers.IO) { uris.forEach { staged += AttachmentImporter.import(context, it, state.isRemote) } }
                model.addAttachments(staged)
            } catch (failure: Exception) {
                staged.forEach { java.io.File(it.path).delete() }
                error = failure.localizedMessage.orEmpty()
            } finally { importing = false }
        }
    }
    val photos = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(8)) { import(it) }
    val documents = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { import(it) }
    Box {
        IconButton(onClick = { menu = true }, enabled = !importing && !state.busy, modifier = Modifier.size(48.dp)) {
            if (importing) CircularProgressIndicator(Modifier.size(20.dp)) else Icon(Icons.Outlined.Add, "Add photo or document")
        }
        DropdownMenu(menu, { menu = false }) {
            DropdownMenuItem(text = { Text("Photos") }, leadingIcon = { Icon(Icons.Outlined.Photo, null) }, enabled = !state.isRemote,
                onClick = { menu = false; photos.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) })
            DropdownMenuItem(text = { Text("Documents") }, leadingIcon = { Icon(Icons.Outlined.Description, null) },
                onClick = { menu = false; documents.launch(arrayOf("*/*")) })
            if (state.isRemote) Text("Photos need a local vision model. This host accepts text documents.", Modifier.padding(16.dp), style = MaterialTheme.typography.bodySmall)
        }
    }
    if (error.isNotEmpty()) AlertDialog(onDismissRequest = { error = "" }, title = { Text("Could not attach file") }, text = { Text(error) }, confirmButton = { TextButton(onClick = { error = "" }) { Text("OK") } })
}

@Composable internal fun ComposerAttachments(items: List<Attachment>, model: MaiViewModel) {
    if (items.isEmpty()) return
    LazyRow(horizontalArrangement = Arrangement.spacedBy(8.dp), contentPadding = PaddingValues(bottom = 8.dp)) {
        items(items, key = { it.path }) { attachment ->
            InputChip(selected = true, onClick = { model.removeAttachment(attachment) }, label = { Text(attachment.name, maxLines = 1) },
                leadingIcon = { Icon(if (attachment.mime.startsWith("image/")) Icons.Outlined.Image else Icons.Outlined.Description, null, Modifier.size(18.dp)) },
                trailingIcon = { Icon(Icons.Outlined.Close, "Remove ${attachment.name}", Modifier.size(18.dp)) })
        }
    }
}

@Composable internal fun MessageAttachments(items: List<Attachment>) {
    items.forEach { attachment ->
        if (attachment.mime.startsWith("image/") && attachment.path.isNotEmpty()) {
            val bitmap = remember(attachment.path) { BitmapFactory.decodeFile(attachment.path)?.asImageBitmap() }
            if (bitmap != null) Image(bitmap, attachment.name, Modifier.fillMaxWidth().heightIn(max = 260.dp).padding(bottom = 8.dp), contentScale = ContentScale.Fit)
        } else SuggestionChip(onClick = {}, label = { Text(attachment.name) }, icon = { Icon(Icons.Outlined.Description, null) })
    }
}

@Composable internal fun MessageActions(message: Message, state: AppState, model: MaiViewModel, onDismiss: () -> Unit) {
    val context = LocalContext.current
    var editing by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    var resubmitting by remember { mutableStateOf(false) }
    var restarting by remember { mutableStateOf(false) }
    var editedText by remember { mutableStateOf(message.text) }
    val remoteReady = state.remote.canRewind && message.remoteID.isNotEmpty()
    val canEdit = !state.busy && message.role in listOf("user", "assistant") && (!state.isRemote || (remoteReady && message.role == "user"))
    val canDelete = !state.busy && (!state.isRemote || remoteReady)
    val canRetry = !state.busy && message.role == "user" &&
        (if (state.isRemote) state.remote.connected && remoteReady else state.model.isNotEmpty())
    if (!editing && !deleting && !resubmitting) ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
            Text("Message", Modifier.padding(horizontal = 24.dp, vertical = 12.dp), style = MaterialTheme.typography.titleLarge)
            TextButton(onClick = {
                (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("PocketMai", message.text)); onDismiss()
            }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.ContentCopy, null); Spacer(Modifier.width(12.dp)); Text("Copy") }
            TextButton(onClick = {
                context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply { type = "text/plain"; putExtra(Intent.EXTRA_TEXT, message.text) }, "Share message")); onDismiss()
            }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Share, null); Spacer(Modifier.width(12.dp)); Text("Share") }
            if (message.role == "user") {
                TextButton(onClick = { restarting = false; resubmitting = true }, enabled = canRetry, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.Refresh, null); Spacer(Modifier.width(12.dp)); Text("Retry from here")
                }
                TextButton(onClick = { restarting = true; resubmitting = true }, enabled = canRetry, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Outlined.RestartAlt, null); Spacer(Modifier.width(12.dp)); Text("Restart from here")
                }
            }
            TextButton(onClick = { editing = true }, enabled = canEdit, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.Edit, null); Spacer(Modifier.width(12.dp)); Text(if (state.isRemote) "Edit and resend" else "Edit")
            }
            TextButton(onClick = { deleting = true }, enabled = canDelete, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.DeleteOutline, null); Spacer(Modifier.width(12.dp)); Text(if (state.isRemote) "Delete from here" else "Delete")
            }
            if (state.isRemote && !remoteReady) Text("This host has not exposed editable history for this message.", Modifier.padding(24.dp), style = MaterialTheme.typography.bodySmall)
        }
    }
    if (resubmitting) AlertDialog(onDismissRequest = onDismiss, title = { Text(if (restarting) "Restart from here?" else "Retry from here?") },
        text = { Text(if (restarting) "All current messages will be removed before starting again from this message." else "Messages after this point will be removed before the response is regenerated.") },
        confirmButton = { TextButton(onClick = {
            val action = if (state.isRemote) { if (restarting) "remoteRestart" else "remoteRetry" }
                else { if (restarting) "restartMessage" else "retryMessage" }
            model.command(action, "id" to message.id); onDismiss()
        }, enabled = canRetry) { Text(if (restarting) "Restart from here" else "Retry from here") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
    if (editing) AlertDialog(onDismissRequest = onDismiss, title = { Text(if (state.isRemote) "Edit and resend" else "Edit message") },
        text = { OutlinedTextField(editedText, { editedText = it }, minLines = 4, maxLines = 12, modifier = Modifier.fillMaxWidth()) },
        confirmButton = { TextButton(onClick = { model.command(if (state.isRemote) "remoteEdit" else "editMessage", "id" to message.id, "text" to editedText); onDismiss() }, enabled = editedText.isNotBlank() || message.attachments.isNotEmpty()) { Text(if (state.isRemote) "Resend" else "Save") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
    if (deleting) AlertDialog(onDismissRequest = onDismiss, title = { Text(if (state.isRemote) "Delete this message and later messages?" else "Delete message?") },
        text = { Text(if (state.isRemote) "The remote host will rewind this conversation to before this message." else "This removes the message from the saved conversation.") },
        confirmButton = { TextButton(onClick = { model.command(if (state.isRemote) "remoteDelete" else "deleteMessage", "id" to message.id); onDismiss() }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } })
}

@Composable internal fun FolderSelector(state: AppState, model: MaiViewModel) {
    var menu by remember { mutableStateOf(false) }
    var managing by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Box(Modifier.weight(1f)) {
            TextButton(onClick = { menu = true }) {
                Icon(Icons.Outlined.Folder, null); Spacer(Modifier.width(8.dp))
                Text(when (state.folderID) { "all" -> "All chats"; "unfiled" -> "Unfiled"; else -> state.folders.firstOrNull { it.id == state.folderID }?.name ?: "All chats" })
                Icon(Icons.Outlined.ArrowDropDown, null)
            }
            DropdownMenu(menu, { menu = false }) {
                (listOf(ChatFolder("all", "All chats"), ChatFolder("unfiled", "Unfiled")) + state.folders).forEach { folder ->
                    DropdownMenuItem(text = { Text(folder.name) }, onClick = { menu = false; model.command("selectFolder", "id" to folder.id) })
                }
            }
        }
        IconButton(onClick = { managing = true }) { Icon(Icons.Outlined.CreateNewFolder, "Manage conversation folders") }
    }
    if (managing) FolderManager(state, model, onDismiss = { managing = false })
}

@Composable internal fun MoveChatSheet(state: AppState, chat: ChatSummary, model: MaiViewModel, onDismiss: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(20.dp)) {
            Text("Move ${chat.title}", style = MaterialTheme.typography.titleLarge)
            (listOf(ChatFolder("unfiled", "Unfiled")) + state.folders).forEach { folder ->
                TextButton(onClick = { model.command("moveChat", "id" to chat.id, "folderID" to folder.id); onDismiss() }, modifier = Modifier.fillMaxWidth()) { Icon(Icons.Outlined.Folder, null); Spacer(Modifier.width(12.dp)); Text(folder.name) }
            }
        }
    }
}

@Composable private fun FolderManager(state: AppState, model: MaiViewModel, onDismiss: () -> Unit) {
    var editing by remember { mutableStateOf<ChatFolder?>(null) }
    var creating by remember { mutableStateOf(false) }
    var removing by remember { mutableStateOf<ChatFolder?>(null) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.padding(20.dp)) {
            Text("Conversation folders", style = MaterialTheme.typography.headlineSmall)
            TextButton(onClick = { creating = true }) { Icon(Icons.Outlined.Add, null); Spacer(Modifier.width(8.dp)); Text("New folder") }
            state.folders.forEach { folder ->
                ListItem(headlineContent = { Text(folder.name) }, leadingContent = { Icon(Icons.Outlined.Folder, null) }, trailingContent = { Row {
                    IconButton(onClick = { editing = folder }) { Icon(Icons.Outlined.Edit, "Rename ${folder.name}") }
                    IconButton(onClick = { removing = folder }) { Icon(Icons.Outlined.DeleteOutline, "Delete ${folder.name}") }
                } })
            }
        }
    }
    if (creating || editing != null) {
        var name by remember(editing?.id) { mutableStateOf(editing?.name.orEmpty()) }
        AlertDialog(onDismissRequest = { creating = false; editing = null }, title = { Text(if (creating) "New folder" else "Rename folder") },
            text = { OutlinedTextField(name, { name = it }, label = { Text("Folder name") }, singleLine = true) },
            confirmButton = { TextButton(onClick = { model.command("saveFolder", "id" to editing?.id.orEmpty(), "name" to name); creating = false; editing = null }, enabled = name.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton(onClick = { creating = false; editing = null }) { Text("Cancel") } })
    }
    removing?.let { folder -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Delete ${folder.name}?") }, text = { Text("Its conversations will move to Unfiled.") },
        confirmButton = { TextButton(onClick = { model.command("removeFolder", "id" to folder.id); removing = null }) { Text("Delete folder") } }, dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}
