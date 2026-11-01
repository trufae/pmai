@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.content.Intent
import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable internal fun RemoteWorkspaceScreen(remote: RemoteState, model: MaiViewModel,
    console: Boolean = false, archivesOnly: Boolean = false, onClose: () -> Unit) {
    DisposableEffect(remote.hostID, remote.folder) {
        onDispose { model.command("workspaceDismiss") }
    }
    LaunchedEffect(remote.hostID, remote.folder) {
        model.command("workspaceOpen", "kind" to if (console) "console" else "files")
        if (!console) model.command("browse", "path" to remote.browserPath)
    }
    BackHandler(onBack = onClose)
    Scaffold(topBar = { TopAppBar(title = { Column {
        Text(if (console) "Console" else "Files")
        Text(remote.folder, style = MaterialTheme.typography.labelSmall, maxLines = 1)
    } }, navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            if (remote.workspaceError.isNotEmpty()) SelectionContainer {
                Text(remote.workspaceError, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
            }
            if (console) RemoteConsole(remote, model, Modifier.weight(1f))
            else RemoteFiles(remote, model, archivesOnly, Modifier.weight(1f))
        }
    }
}

@Composable private fun RemoteFiles(remote: RemoteState, model: MaiViewModel, archivesOnly: Boolean, modifier: Modifier) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var localError by remember { mutableStateOf("") }
    var viewing by rememberSaveable { mutableStateOf(false) }
    var editing by rememberSaveable { mutableStateOf(false) }
    var text by remember { mutableStateOf("") }
    var folderName by rememberSaveable { mutableStateOf<String?>(null) }
    var path by rememberSaveable { mutableStateOf(remote.browserPath) }
    LaunchedEffect(remote.browserPath) { path = remote.browserPath }
    LaunchedEffect(remote.filePath) {
        if (remote.filePath.isNotEmpty()) { viewing = true; editing = false; text = remote.previewText.orEmpty() }
    }
    BackHandler(enabled = viewing) { viewing = false; editing = false }
    val save = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        if (uri != null) scope.launch {
            try { withContext(Dispatchers.IO) {
                requireNotNull(context.contentResolver.openOutputStream(uri)).use { out -> File(remote.filePath).inputStream().use { it.copyTo(out) } }
            } } catch (e: Exception) { localError = e.localizedMessage.orEmpty() }
        }
    }
    val upload = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) scope.launch {
            try {
                val staged = withContext(Dispatchers.IO) { stageAttachment(context, uri) }
                model.command("fileUpload", "path" to staged.path, "name" to staged.name)
            } catch (e: Exception) { localError = e.localizedMessage.orEmpty() }
        }
    }
    Column(modifier.fillMaxWidth()) {
        if (remote.workspaceBusy) LinearProgressIndicator(Modifier.fillMaxWidth())
        if (localError.isNotEmpty()) Text(localError, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
        if (viewing) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                TextButton(onClick = { viewing = false; editing = false }) { Text("Files") }
                Spacer(Modifier.weight(1f))
                if (remote.writeEnabled && remote.previewText != null) TextButton(enabled = !remote.workspaceBusy, onClick = {
                    if (editing) { model.command("fileSave", "text" to text); editing = false } else editing = true
                }) { Text(if (editing) "Save" else "Edit") }
                IconButton(onClick = { save.launch(File(remote.previewPath).name) }) { Icon(Icons.Outlined.Download, "Save to device") }
                IconButton(onClick = {
                    scope.launch {
                        try {
                            val uri = withContext(Dispatchers.IO) {
                                val folder = File(context.cacheDir, "exports").apply { mkdirs() }
                                val copy = File(folder, File(remote.previewPath).name)
                                File(remote.filePath).copyTo(copy, overwrite = true)
                                FileProvider.getUriForFile(context, context.packageName + ".files", copy)
                            }
                            context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
                                type = "application/octet-stream"; putExtra(Intent.EXTRA_STREAM, uri)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }, "Share file"))
                        } catch (e: Exception) { localError = e.localizedMessage.orEmpty() }
                    }
                }) { Icon(Icons.Outlined.Share, "Share file") }
            }
            Text(remote.previewPath, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelSmall)
            if (editing) OutlinedTextField(text, { text = it }, Modifier.fillMaxSize().padding(12.dp),
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace))
            else if (remote.previewText != null) SelectionContainer(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(16.dp)) {
                Text(remote.previewText, fontFamily = FontFamily.Monospace)
            } else Text("Preview unavailable for this file. Save it or share it to open in another app.", Modifier.padding(16.dp))
        } else {
            Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(enabled = !remote.workspaceBusy && remote.browserRoot.isNotEmpty() && remote.browserPath != remote.browserRoot,
                    onClick = { model.command("filesUp") }) { Icon(Icons.Outlined.ArrowUpward, "Parent folder") }
                OutlinedTextField(path, { path = it }, Modifier.weight(1f), singleLine = true, label = { Text("Path") })
                IconButton(enabled = !remote.workspaceBusy, onClick = { model.command("browse", "path" to path) }) { Icon(Icons.Outlined.Refresh, "Open folder") }
            }
            Row(Modifier.padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                FilterChip(selected = remote.showHidden, onClick = { model.command("filesHidden", "enabled" to (!remote.showHidden).toString()) },
                    label = { Text("Hidden files") }, enabled = !remote.workspaceBusy)
                Spacer(Modifier.weight(1f))
                if (remote.writeEnabled) {
                    IconButton(enabled = !remote.workspaceBusy, onClick = { folderName = "" }) { Icon(Icons.Outlined.CreateNewFolder, "New folder") }
                    IconButton(enabled = !remote.workspaceBusy, onClick = { upload.launch(arrayOf("*/*")) }) { Icon(Icons.Outlined.Upload, "Upload file") }
                } else Text("Read only", style = MaterialTheme.typography.labelSmall)
            }
            LazyColumn(Modifier.weight(1f)) {
                items(remote.files.filter { !archivesOnly || it.directory || it.name.endsWith(".xdc", true) }, key = { it.path }) { file ->
                    ListItem(headlineContent = { Text(file.name) }, leadingContent = { Icon(if (file.directory) Icons.Outlined.Folder else Icons.AutoMirrored.Outlined.InsertDriveFile, null) },
                        modifier = Modifier.clickable(enabled = !remote.workspaceBusy) {
                            model.command(if (file.directory) "browse" else if (archivesOnly) "downloadXdc" else "fileOpen", "path" to file.path)
                        })
                }
                if (remote.hasMoreFiles) item { TextButton(enabled = !remote.workspaceBusy,
                    onClick = { model.command("filesMore") }, modifier = Modifier.fillMaxWidth()) { Text("Load more files") } }
                if (remote.files.isEmpty() && !remote.workspaceBusy) item { Text("This folder is empty.", Modifier.padding(24.dp)) }
            }
        }
    }
    folderName?.let { name -> AlertDialog(onDismissRequest = { folderName = null }, title = { Text("New folder") },
        text = { OutlinedTextField(name, { folderName = it }, singleLine = true, label = { Text("Name") }) },
        confirmButton = { TextButton(enabled = name.isNotBlank() && !name.contains('/') && !name.contains('\\'), onClick = {
            model.command("fileMkdir", "name" to name); folderName = null
        }) { Text("Create") } }, dismissButton = { TextButton(onClick = { folderName = null }) { Text("Cancel") } }) }
}

@Composable private fun RemoteConsole(remote: RemoteState, model: MaiViewModel, modifier: Modifier) {
    val context = LocalContext.current
    val prefs = remember { context.getSharedPreferences("appearance", 0) }
    var fontSize by remember { mutableFloatStateOf(prefs.getFloat("consoleFontSize", 14f)) }
    var command by rememberSaveable(remote.hostID, remote.folder) { mutableStateOf("") }
    var history by remember { mutableStateOf(false) }
    var historySearch by rememberSaveable { mutableStateOf("") }
    var historyIndex by remember { mutableStateOf<Int?>(null) }
    var savedDraft by remember { mutableStateOf("") }
    var follow by remember { mutableStateOf(true) }
    val scroll = rememberLazyListState()
    val dragging by scroll.interactionSource.collectIsDraggedAsState()
    LaunchedEffect(dragging) { if (dragging) follow = false }
    val scope = rememberCoroutineScope()
    fun recall(direction: Int) {
        if (remote.terminalHistory.isEmpty()) return
        if (historyIndex == null) { if (direction > 0) return; savedDraft = command }
        val next = ((historyIndex ?: remote.terminalHistory.size) + direction).coerceIn(0, remote.terminalHistory.size)
        historyIndex = next.takeIf { it < remote.terminalHistory.size }
        command = historyIndex?.let { remote.terminalHistory[it] } ?: savedDraft
    }
    fun submit(value: String) {
        if (value.isBlank() || remote.terminalRunning) return
        model.command("consoleRun", "command" to value)
        command = ""; historyIndex = null; follow = true
    }
    LaunchedEffect(remote.terminalEntries) {
        if (follow && !scroll.isScrollInProgress) scroll.scrollToItem(remote.terminalEntries.size)
    }
    Column(modifier.fillMaxWidth().background(Color.Black).padding(12.dp)) {
        Text("Each command starts in this project directory.", color = Color.Gray, fontSize = 12.sp)
        LazyColumn(state = scroll, modifier = Modifier.weight(1f).fillMaxWidth()
            .pinchToResizeFont(onZoom = { fontSize = (fontSize * it).coerceIn(10f, 32f) },
                onFinished = { prefs.edit().putFloat("consoleFontSize", fontSize).apply() })) {
            items(remote.terminalEntries, key = { it.id }) { entry ->
                Column(Modifier.fillMaxWidth().padding(vertical = 6.dp)) {
                    TextButton(onClick = { command = entry.command; historyIndex = null }) {
                        Text("$ " + entry.command, color = Color.Green, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                    }
                    SelectionContainer { Text(entry.output, color = if (entry.error) Color(0xffff7777) else Color.White,
                        fontFamily = FontFamily.Monospace, fontSize = fontSize.sp) }
                    if (!entry.complete) Text("Running…", color = Color.Gray)
                }
            }
            item { Spacer(Modifier.height(1.dp)) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(enabled = remote.terminalHistory.isNotEmpty(), onClick = { recall(-1) }) { Icon(Icons.Outlined.ArrowUpward, "Previous command", tint = Color.White) }
            IconButton(enabled = historyIndex != null, onClick = { recall(1) }) { Icon(Icons.Outlined.ArrowDownward, "Next command", tint = Color.White) }
            IconButton(onClick = { history = true }) { Icon(Icons.Outlined.History, "Command history", tint = Color.White) }
            TextButton(onClick = { follow = !follow; if (follow) scope.launch { scroll.scrollToItem(remote.terminalEntries.size) } }) {
                Text(if (follow) "Pause scroll" else "Follow output")
            }
            IconButton(enabled = !remote.terminalRunning, onClick = { model.command("consoleClear") }) { Icon(Icons.Outlined.DeleteOutline, "Clear scrollback", tint = Color.White) }
        }
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(command, { command = it }, Modifier.weight(1f), label = { Text("$ Command") }, maxLines = 5,
                keyboardOptions = KeyboardOptions(autoCorrectEnabled = false, imeAction = ImeAction.Go),
                keyboardActions = KeyboardActions(onGo = { submit(command) }),
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = Color.White, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp),
                colors = OutlinedTextFieldDefaults.colors(focusedLabelColor = Color.Gray, unfocusedLabelColor = Color.Gray, cursorColor = Color.Green))
            if (remote.terminalRunning) IconButton(onClick = { model.command("consoleStop") }) { Icon(Icons.Outlined.Stop, "Stop command", tint = Color.White) }
            else IconButton(enabled = command.isNotBlank(), onClick = { submit(command) }) { Icon(Icons.Outlined.PlayArrow, "Run command", tint = Color.White) }
        }
    }
    if (history) ModalBottomSheet(onDismissRequest = { history = false }) {
        Column(Modifier.fillMaxWidth().imePadding().padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Command history", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                TextButton(onClick = { model.command("consoleClear", "history" to "true") }) { Text("Clear") }
            }
            OutlinedTextField(historySearch, { historySearch = it }, Modifier.fillMaxWidth(), label = { Text("Search commands") })
            LazyColumn(Modifier.heightIn(max = 420.dp)) {
                items(remote.terminalHistory.asReversed().filter { it.contains(historySearch, ignoreCase = true) }, key = { it }) { saved ->
                    ListItem(headlineContent = { Text(saved, fontFamily = FontFamily.Monospace) },
                        modifier = Modifier.clickable { command = saved; historyIndex = null; history = false },
                        trailingContent = { IconButton(enabled = !remote.terminalRunning, onClick = { submit(saved); history = false }) { Icon(Icons.Outlined.PlayArrow, "Run command") } })
                }
            }
        }
    }
}

private fun stageAttachment(context: Context, uri: Uri): Attachment {
    val name = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
        if (it.moveToFirst()) it.getString(0) else null
    }?.substringAfterLast('/')?.substringAfterLast('\\') ?: "file"
    val output = File(context.cacheDir, "upload-${java.util.UUID.randomUUID()}")
    try {
        requireNotNull(context.contentResolver.openInputStream(uri)).use { input ->
            output.outputStream().use { stream ->
                var size = 0
                val buffer = ByteArray(16384)
                while (true) {
                    val count = input.read(buffer); if (count < 0) break
                    size += count; require(size <= 32_000_000) { "Files are limited to 32 MB." }
                    stream.write(buffer, 0, count)
                }
            }
        }
        return Attachment(output.path, name, "application/octet-stream")
    } catch (error: Exception) { output.delete(); throw error }
}
