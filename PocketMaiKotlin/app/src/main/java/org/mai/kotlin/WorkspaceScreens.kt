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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

@Composable internal fun RemoteWorkspaceScreen(remote: RemoteState, model: MaiViewModel,
    archivesOnly: Boolean = false, onClose: () -> Unit) {
    DisposableEffect(remote.hostID, remote.folder) {
        onDispose { model.command("workspaceDismiss") }
    }
    LaunchedEffect(remote.hostID, remote.folder) {
        model.command("workspaceOpen", "kind" to "files")
        model.command("browse", "path" to remote.browserPath)
    }
    BackHandler(onBack = onClose)
    Scaffold(topBar = { TopAppBar(title = { Column {
        Text("Files")
        Text(remote.folder, style = MaterialTheme.typography.labelSmall, maxLines = 1)
    } }, navigationIcon = { IconButton(onClick = onClose) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back") } }) }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding).imePadding()) {
            if (remote.workspaceError.isNotEmpty()) SelectionContainer {
                Text(remote.workspaceError, Modifier.padding(16.dp), color = MaterialTheme.colorScheme.error)
            }
            RemoteFiles(remote, model, archivesOnly, Modifier.weight(1f))
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
