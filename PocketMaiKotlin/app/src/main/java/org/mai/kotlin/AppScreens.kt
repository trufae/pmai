@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.widget.TextView
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateCentroidSize
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.*
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffoldDefaults
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteType
import androidx.compose.material3.adaptive.currentWindowAdaptiveInfo
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.FileProvider
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.abs

private val LocalMessageFontSize = compositionLocalOf { 16f }

internal fun Modifier.pinchToResizeFont(onZoom: (Float) -> Unit, onFinished: () -> Unit) = pointerInput(Unit) {
    awaitEachGesture {
        awaitFirstDown(requireUnconsumed = false, pass = PointerEventPass.Initial)
        var zoom = 1f
        var pinching = false
        try {
            do {
                // Intercept a pinch before selectable Markdown TextViews or the list consume it.
                val event = awaitPointerEvent(PointerEventPass.Initial)
                if (event.changes.count { it.pressed && it.previousPressed } >= 2) {
                    val change = event.calculateZoom()
                    zoom *= change
                    if (!pinching && abs(1 - zoom) * event.calculateCentroidSize(useCurrent = false) > viewConfiguration.touchSlop) {
                        pinching = true
                        onZoom(zoom)
                    } else if (pinching) onZoom(change)
                } else if (!pinching) zoom = 1f
                if (pinching) event.changes.forEach { it.consume() }
            } while (event.changes.any { it.pressed })
        } finally {
            if (pinching) onFinished()
        }
    }
}

private enum class Destination(val label: String, val icon: ImageVector) {
    Chats("Chats", Icons.AutoMirrored.Outlined.Chat),
    Hosts("Hosts", Icons.Outlined.Dns),
    Apps("Apps", Icons.Outlined.Widgets),
    Settings("Settings", Icons.Outlined.Settings),
}

@Composable fun PocketMaiApp(
    state: AppState, draft: String, attachments: List<Attachment>, model: MaiViewModel, theme: String, onTheme: (String) -> Unit,
    invitation: String, consumeInvitation: () -> Unit,
) {
    val terminal = model.terminal.collectAsState().value
    var destination by rememberSaveable { mutableStateOf(Destination.Chats) }
    var detail by rememberSaveable { mutableStateOf(false) }
    var addingHost by rememberSaveable { mutableStateOf(false) }
    var hostInvitation by rememberSaveable { mutableStateOf("") }
    var workspaceScreen by rememberSaveable { mutableStateOf("") }
    var runningApp by rememberSaveable { mutableStateOf("") }
    LaunchedEffect(invitation) {
        if (invitation.isNotEmpty()) {
            hostInvitation = invitation; addingHost = true; destination = Destination.Hosts
            consumeInvitation()
        }
    }
    if (!state.ready) {
        Box(Modifier.fillMaxSize().safeDrawingPadding(), contentAlignment = Alignment.Center) {
            if (state.error.isEmpty()) CircularProgressIndicator()
            else EmptyState(Icons.Outlined.ErrorOutline, "PocketMai could not start", state.error)
        }
        return
    }
    BackHandler(enabled = terminal == null && (runningApp.isNotEmpty() || detail || destination != Destination.Chats)) {
        when {
            runningApp.isNotEmpty() -> runningApp = ""
            destination != Destination.Chats -> destination = Destination.Chats
            else -> detail = false
        }
    }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(state.error, state.remote.error, state.agent.error) {
        val error = state.error.ifEmpty { state.remote.error }.ifEmpty { state.agent.error }
        if (error.isNotEmpty()) snackbar.showSnackbar(error, actionLabel = "Dismiss", duration = SnackbarDuration.Long)
    }
    if (runningApp.isNotEmpty()) {
        WebXdcRunner(runningApp, state, model, onClose = { runningApp = "" })
        return
    }
    if (workspaceScreen.isNotEmpty() && state.isRemote) {
        RemoteWorkspaceScreen(state.remote, model, console = workspaceScreen == "console", onClose = {
            workspaceScreen = ""
        })
        return
    }
    val hideNavigation = destination == Destination.Chats && detail && LocalConfiguration.current.screenWidthDp < 840
    if (terminal != null) TerminalScreen(terminal, model)
    else NavigationSuiteScaffold(layoutType = if (hideNavigation) NavigationSuiteType.None
        else NavigationSuiteScaffoldDefaults.calculateFromAdaptiveInfo(currentWindowAdaptiveInfo()), navigationSuiteItems = {
        Destination.entries.forEach { item ->
            item(selected = destination == item, onClick = { destination = item },
                icon = { Icon(item.icon, contentDescription = null) }, label = { Text(item.label) })
        }
    }) {
        Scaffold(snackbarHost = { SnackbarHost(snackbar) }, contentWindowInsets = WindowInsets(0)) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                when (destination) {
                    Destination.Chats -> ChatsScreen(state, draft, attachments, model, detail, onDetail = { detail = it },
                        onHosts = { destination = Destination.Hosts }, onSettings = { destination = Destination.Settings },
                        onWorkspace = { if (it == "console") model.openTerminal() else workspaceScreen = it })
                    Destination.Hosts -> HostsScreen(state, model, onAdd = { addingHost = true }, onOpen = {
                        destination = Destination.Chats; detail = false
                    })
                    Destination.Apps -> WebXdcLibrary(state, model, onOpen = { runningApp = it })
                    Destination.Settings -> SettingsScreen(state, model, theme, onTheme)
                }
            }
        }
    }
    if (addingHost) AddHostSheet(hostInvitation, state.remote.busy, onDismiss = {
        addingHost = false; hostInvitation = ""
    }) { invitationText, name ->
        model.command("pair", "invitation" to invitationText.trim(), "name" to name)
        addingHost = false; hostInvitation = ""
    }
    state.remote.permission?.let { permission -> PermissionDialog(permission) { choice ->
        model.command("permission", "option" to choice.orEmpty())
    } }
    state.agent.approvals.firstOrNull()?.let { approval ->
        AlertDialog(onDismissRequest = { model.command("toolApproval", "id" to approval.id, "choice" to "deny") },
            title = { Text("Allow ${approval.name}?") }, text = { Column(Modifier.verticalScroll(rememberScrollState())) {
                Text(approval.description, style = MaterialTheme.typography.bodyMedium)
                SelectionContainer { Text(approval.arguments, Modifier.padding(top = 16.dp), style = MaterialTheme.typography.bodySmall) }
            } }, confirmButton = { TextButton(onClick = { model.command("toolApproval", "id" to approval.id, "choice" to "approve") }) { Text("Allow once") } },
            dismissButton = { TextButton(onClick = { model.command("toolApproval", "id" to approval.id, "choice" to "deny") }) { Text("Deny") } })
    }
}

@Composable private fun ChatsScreen(
    state: AppState, draft: String, attachments: List<Attachment>, model: MaiViewModel, detail: Boolean,
    onDetail: (Boolean) -> Unit, onHosts: () -> Unit, onSettings: () -> Unit, onWorkspace: (String) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val expanded = maxWidth >= 840.dp
        Row(Modifier.fillMaxSize()) {
            if (expanded || !detail) {
                ChatList(state, model, Modifier.then(if (expanded) Modifier.width(340.dp) else Modifier.fillMaxWidth()),
                    onOpen = { onDetail(true) }, onHosts = onHosts, onWorkspace = onWorkspace)
            }
            if (expanded) VerticalDivider()
            if (expanded || detail) ConversationScreen(state, draft, attachments, model, Modifier.weight(1f),
                showBack = !expanded, onBack = { onDetail(false) }, onSettings = onSettings, onWorkspace = onWorkspace)
        }
    }
}

@Composable private fun ChatList(state: AppState, model: MaiViewModel, modifier: Modifier, onOpen: () -> Unit, onHosts: () -> Unit, onWorkspace: (String) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    var moving by remember { mutableStateOf<ChatSummary?>(null) }
    val host = state.remote.hosts.firstOrNull { it.id == state.remote.hostID }
    val chats = (if (state.isRemote) state.remote.sessions.filter { it.cwd == state.remote.folder }
        else state.chats.filter { state.folderID == "all" || it.folderID == state.folderID })
        .filter { it.title.contains(query, ignoreCase = true) || it.subtitle.contains(query, ignoreCase = true) }
    Scaffold(modifier.fillMaxHeight(), topBar = {
        TopAppBar(title = { Column {
            Text("Chats")
            Text(host?.name ?: "On this device", style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        } }, actions = {
            if (state.isRemote) IconButton(onClick = model::openTerminal, enabled = state.remote.folder.isNotBlank()) {
                Icon(Icons.Outlined.Terminal, "Open terminal")
            }
            IconButton(onClick = onHosts) { Icon(Icons.Outlined.Dns, "Choose host") }
        })
    }, floatingActionButton = {
        ExtendedFloatingActionButton(onClick = {
            if (state.isRemote) model.command("remoteOpen", "cwd" to state.remote.folder)
            else model.command("new")
            model.draft(""); onOpen()
        }, expanded = true, icon = { Icon(Icons.Outlined.Add, null) }, text = { Text("New chat") })
    }) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            if (!state.isRemote) FolderSelector(state, model)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
                placeholder = { Text("Search chats") }, leadingIcon = { Icon(Icons.Outlined.Search, null) }, singleLine = true,
                shape = RoundedCornerShape(28.dp))
            if (state.isRemote) {
                Row(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { onWorkspace("files") }, enabled = state.remote.folder.isNotEmpty()) {
                        Icon(Icons.Outlined.Folder, null); Spacer(Modifier.width(8.dp)); Text("Files")
                    }
                    OutlinedButton(onClick = { onWorkspace("console") }, enabled = state.remote.folder.isNotEmpty()) {
                        Icon(Icons.Outlined.Terminal, null); Spacer(Modifier.width(8.dp)); Text("Console")
                    }
                }
                LazyRowFolders(state.remote, onSelect = { model.command("folder", "cwd" to it) })
                if (state.remote.busy) LinearProgressIndicator(Modifier.fillMaxWidth())
                if (state.remote.status.isNotEmpty()) Text(state.remote.status,
                    Modifier.padding(horizontal = 20.dp, vertical = 6.dp), style = MaterialTheme.typography.labelMedium)
            }
            if (chats.isEmpty()) {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    EmptyState(Icons.Outlined.ChatBubbleOutline,
                        if (query.isNotEmpty()) "No matching chats" else "A fresh start",
                        if (state.isRemote) "Choose a workspace or start a chat with this host." else "Start a conversation. Your chats are saved on this device.")
                }
            } else LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(bottom = 100.dp)) {
                var previous = ""
                chats.forEach { chat ->
                    val group = dateGroup(chat.updated)
                    if (previous != group) { item(key = "group-$group") { SectionLabel(group) }; previous = group }
                    item(key = chat.id) {
                        val selected = chat.id == if (state.isRemote) state.remote.conversationID else state.chatID
                        Surface(onClick = {
                            if (state.isRemote) model.command("remoteOpen", "id" to chat.id, "cwd" to chat.cwd)
                            else model.command("open", "id" to chat.id)
                            model.draft(""); onOpen()
                        }, color = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surface,
                            shape = RoundedCornerShape(20.dp), modifier = Modifier.padding(horizontal = 10.dp, vertical = 2.dp)) {
                            ListItem(headlineContent = { Text(chat.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                                supportingContent = { Text(chat.subtitle, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                                leadingContent = { Icon(Icons.Outlined.ChatBubbleOutline, null) },
                                trailingContent = { if (!state.isRemote) IconButton(onClick = { moving = chat }) { Icon(Icons.AutoMirrored.Outlined.DriveFileMove, "Move conversation to folder") } },
                                colors = ListItemDefaults.colors(containerColor = androidx.compose.ui.graphics.Color.Transparent))
                        }
                    }
                }
            }
        }
    }
    moving?.let { chat -> MoveChatSheet(state, chat, model, onDismiss = { moving = null }) }
}

@Composable private fun LazyRowFolders(remote: RemoteState, onSelect: (String) -> Unit) {
    androidx.compose.foundation.lazy.LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        items(remote.folders, key = { it.cwd }) { folder ->
            FilterChip(selected = folder.cwd == remote.folder, onClick = { onSelect(folder.cwd) },
                label = { Text(folder.name) }, leadingIcon = { Icon(Icons.Outlined.Folder, null, Modifier.size(18.dp)) })
        }
    }
}

@Composable private fun ConversationScreen(
    state: AppState, draft: String, attachments: List<Attachment>, model: MaiViewModel, modifier: Modifier,
    showBack: Boolean, onBack: () -> Unit, onSettings: () -> Unit, onWorkspace: (String) -> Unit,
) {
    val context = LocalContext.current
    val appearance = remember(context) { context.getSharedPreferences("appearance", Context.MODE_PRIVATE) }
    var fontSize by remember { mutableFloatStateOf(appearance.getFloat("messageFontSize", 16f).coerceIn(6f, 43f)) }
    var pinching by remember { mutableStateOf(false) }
    val list = rememberLazyListState()
    val messages = state.activeMessages
    val runs = remember(messages) { toolMessageRuns(messages) }
    val activity = remember(state.agent.activity, state.reasoning) {
        state.agent.activity + if (state.reasoning.isEmpty()) emptyList()
            else listOf(Message("active-reasoning", "thought", state.reasoning))
    }
    var selectedMessage by remember { mutableStateOf<Message?>(null) }
    val atBottom by remember { derivedStateOf {
        val last = list.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
        last >= list.layoutInfo.totalItemsCount - 2
    } }
    val contentKey = messages.lastOrNull()?.text?.length ?: 0
    LaunchedEffect(messages.size, state.streamed.length, contentKey) {
        if (!pinching && atBottom && list.layoutInfo.totalItemsCount > 0) list.scrollToItem(list.layoutInfo.totalItemsCount - 1)
    }
    Scaffold(modifier.fillMaxHeight(), topBar = {
        TopAppBar(title = { Column {
            Text(state.activeTitle, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(if (state.isRemote) state.remote.status else state.model.ifEmpty { "Choose a model in Settings" },
                modifier = Modifier.clickable(onClick = onSettings),
                style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1, overflow = TextOverflow.Ellipsis)
        } }, navigationIcon = {
            if (showBack) IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Outlined.ArrowBack, "Back to chats") }
        }, actions = {
            if (state.isRemote) {
                IconButton(onClick = { onWorkspace("files") }) { Icon(Icons.Outlined.Folder, "Browse remote files") }
            }
            if (messages.isNotEmpty()) IconButton(onClick = { shareConversation(context, state.activeTitle, messages) }) {
                Icon(Icons.Outlined.Share, "Share conversation")
            }
            if (state.isRemote) IconButton(onClick = model::openTerminal, enabled = state.remote.folder.isNotBlank()) {
                Icon(Icons.Outlined.Terminal, "Open terminal")
            }
            IconButton(onClick = onSettings) { Icon(Icons.Outlined.Tune, "Chat settings") }
        })
    }, bottomBar = {
        Surface(tonalElevation = 3.dp) {
            Column(Modifier.imePadding().navigationBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp)) {
                if (!state.isRemote && state.model.isEmpty()) TextButton(onClick = onSettings) {
                    Icon(Icons.Outlined.Settings, null); Spacer(Modifier.width(8.dp)); Text("Set up a provider to start chatting")
                }
                ComposerAttachments(attachments, model)
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    AttachmentButton(state, model)
                    OutlinedTextField(draft, model::draft, Modifier.weight(1f),
                        placeholder = { Text("Message") }, maxLines = 6, shape = RoundedCornerShape(28.dp),
                        enabled = !state.isRemote || state.remote.conversationID.isNotEmpty())
                    if (state.busy) FilledIconButton(onClick = {
                        model.command(if (state.isRemote) "remoteStop" else "stop")
                    }, Modifier.size(56.dp)) { Icon(Icons.Outlined.Stop, "Stop reply") }
                    else FilledIconButton(onClick = model::send, enabled = (draft.isNotBlank() || attachments.isNotEmpty()) &&
                        (if (state.isRemote) state.remote.connected && state.remote.conversationID.isNotEmpty() else state.model.isNotEmpty()),
                        modifier = Modifier.size(56.dp)) { Icon(Icons.AutoMirrored.Outlined.Send, "Send message") }
                }
            }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
            if (messages.isEmpty() && !state.busy) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                EmptyState(Icons.Outlined.AutoAwesome, "What’s on your mind?",
                    if (state.isRemote) "Your remote host runs the agent. You stay in control of tool approvals." else "Ask a question, work through an idea, or start something new.")
            }
            CompositionLocalProvider(LocalMessageFontSize provides fontSize) {
                LazyColumn(Modifier.fillMaxSize().widthIn(max = 900.dp).pinchToResizeFont(onZoom = {
                    pinching = true
                    fontSize = (fontSize * it).coerceIn(6f, 43f)
                }, onFinished = {
                    pinching = false
                    appearance.edit().putFloat("messageFontSize", fontSize).apply()
                }), state = list,
                    contentPadding = PaddingValues(horizontal = 20.dp, vertical = 16.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    items(runs, key = { it.first().id }) { run ->
                        if (run.first().isActivity) ToolActivity(run, onLongPress = { selectedMessage = it })
                        else MessageCard(run.first(), onLongPress = { selectedMessage = it })
                    }
                    if (!state.isRemote && state.generating && activity.isNotEmpty()) item("activity") {
                        ToolActivity(activity)
                    }
                    if (!state.isRemote && state.streamed.isNotEmpty()) item("stream") {
                        MessageCard(Message("stream", "assistant", state.streamed))
                    }
                    if (state.busy) item("working") { Row(verticalAlignment = Alignment.CenterVertically) {
                        CircularProgressIndicator(Modifier.size(18.dp), strokeWidth = 2.dp)
                        Text(if (state.isRemote) state.remote.status else state.status.ifEmpty { "Working…" },
                            Modifier.padding(start = 10.dp), style = MaterialTheme.typography.labelMedium)
                    } }
                }
            }
        }
    }
    selectedMessage?.let { message -> MessageActions(message, state, model, onDismiss = { selectedMessage = null }) }
}

@Composable private fun ToolActivity(messages: List<Message>, onLongPress: ((Message) -> Unit)? = null) {
    var expanded by rememberSaveable(messages.first().id) { mutableStateOf(false) }
    val failed = messages.count { it.toolFailed }
    val running = messages.count { it.status.lowercase() in listOf("running", "pending", "in_progress") }
    Column(Modifier.fillMaxWidth()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 48.dp).clickable(role = Role.Button) { expanded = !expanded }
                .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Activity · ${messages.size} updates", Modifier.weight(1f), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (failed > 0) Text("· $failed failed", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error)
            if (running > 0) CircularProgressIndicator(Modifier.size(14.dp), strokeWidth = 2.dp)
            Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (expanded) messages.forEach { message -> key(message.id) {
            if (message.role == "tool") ToolActivityRow(message, onLongPress)
            else MessageCard(message, onLongPress)
        } }
    }
}

@Composable private fun ToolActivityRow(message: Message, onLongPress: ((Message) -> Unit)?) {
    val context = LocalContext.current
    var expanded by rememberSaveable(message.id) { mutableStateOf(false) }
    val title = remember(message.text) { message.text.lineSequence().firstOrNull { it.isNotBlank() }?.take(180) ?: "Tool" }
    Column(Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().heightIn(min = 48.dp)
            .combinedClickable(role = Role.Button, onClick = { expanded = !expanded }, onLongClick = onLongPress?.let { { it(message) } })
            .semantics { stateDescription = if (expanded) "Expanded" else "Collapsed" },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            if (message.toolFailed) Icon(Icons.Outlined.ErrorOutline, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.error)
            Text(title, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                color = if (message.toolFailed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
            if (message.status.isNotBlank()) Text(message.status, style = MaterialTheme.typography.labelSmall,
                color = if (message.toolFailed) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(if (expanded) Icons.Outlined.ExpandLess else Icons.Outlined.ExpandMore, null, Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (expanded) Surface(color = MaterialTheme.colorScheme.surfaceContainerLow, shape = RoundedCornerShape(12.dp)) {
            Column(Modifier.padding(horizontal = 12.dp, vertical = 8.dp)) {
                MessageAttachments(message.attachments)
                Markdown(message.text, onLongPress = onLongPress?.let { { it(message) } })
                TextButton(onClick = { copyText(context, message.text) }) {
                    Icon(Icons.Outlined.ContentCopy, null, Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp)); Text("Copy tool details")
                }
            }
        }
    }
}

@Composable private fun MessageCard(message: Message, onLongPress: ((Message) -> Unit)? = null) {
    val user = message.role == "user"
    var expanded by remember(message.id) { mutableStateOf(message.role != "thought") }
    Column(Modifier.fillMaxWidth().then(if (onLongPress != null) Modifier.combinedClickable(onClick = {}, onLongClick = { onLongPress(message) }) else Modifier), horizontalAlignment = if (user) Alignment.End else Alignment.Start) {
        if (user) Surface(color = MaterialTheme.colorScheme.secondaryContainer, shape = RoundedCornerShape(24.dp, 24.dp, 4.dp, 24.dp)) {
            Column(Modifier.padding(16.dp)) {
                MessageAttachments(message.attachments)
                Markdown(message.text, onLongPress = onLongPress?.let { { it(message) } }, colorOverride = MaterialTheme.colorScheme.onSecondaryContainer)
            }
        } else {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(if (message.role == "thought") "Reasoning" else "PocketMai",
                    style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary)
                if (message.role == "thought") TextButton(onClick = { expanded = !expanded }) { Text(if (expanded) "Hide" else "Show") }
            }
            if (expanded) {
                MessageAttachments(message.attachments)
                Markdown(message.text, onLongPress = onLongPress?.let { { it(message) } })
            }
        }
    }
}

@Composable internal fun Markdown(text: String, onLongPress: (() -> Unit)? = null, colorOverride: androidx.compose.ui.graphics.Color? = null) {
    val context = LocalContext.current
    val markwon = remember(context) { Markwon.builder(context).usePlugin(TablePlugin.create(context)).build() }
    val color = (colorOverride ?: MaterialTheme.colorScheme.onSurface).toArgb()
    val link = MaterialTheme.colorScheme.primary.toArgb()
    val fontSize = LocalMessageFontSize.current
    val document = remember(markwon, text) { markwon.parse(text) }
    val markdown = remember(markwon, document, fontSize) { markwon.render(document) }
    AndroidView(factory = { TextView(it).apply { setTextIsSelectable(true); setLineSpacing(6f, 1f) } },
        modifier = Modifier.fillMaxWidth(), update = {
            it.textSize = fontSize
            it.setTextColor(color); it.setLinkTextColor(link)
            it.setTextIsSelectable(onLongPress == null)
            it.setOnLongClickListener(if (onLongPress == null) null else android.view.View.OnLongClickListener { onLongPress(); true })
            if (it.tag !== markdown) { markwon.setParsedMarkdown(it, markdown); it.tag = markdown }
        })
}

@Composable private fun HostsScreen(state: AppState, model: MaiViewModel, onAdd: () -> Unit, onOpen: () -> Unit) {
    var renaming by remember { mutableStateOf<Host?>(null) }
    var removing by remember { mutableStateOf<Host?>(null) }
    Scaffold(topBar = { TopAppBar(title = { Text("Hosts") }) }, floatingActionButton = {
        ExtendedFloatingActionButton(onClick = onAdd, icon = { Icon(Icons.Outlined.Add, null) }, text = { Text("Add host") })
    }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(bottom = 100.dp)) {
            item { SectionLabel("On this device") }
            item { ListItem(headlineContent = { Text("Local") }, supportingContent = { Text("Providers and chats on this Android device") },
                leadingContent = { Icon(Icons.Outlined.PhoneAndroid, null) },
                modifier = Modifier.clickable { model.command("local"); onOpen() }) }
            val groups = listOf("Pinned" to state.remote.hosts.filter { it.pinned },
                "Connected" to state.remote.hosts.filter { !it.pinned && it.connected },
                "Saved hosts" to state.remote.hosts.filter { !it.pinned && !it.connected })
            groups.forEach { (name, hosts) -> if (hosts.isNotEmpty()) {
                item { SectionLabel(name) }
                items(hosts, key = { it.id }) { host ->
                    var menu by remember { mutableStateOf(false) }
                    ListItem(headlineContent = { Text(host.name) }, supportingContent = {
                        Text(if (host.connected) "Connected" else host.address, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }, leadingContent = { Icon(if (host.pinned) Icons.Outlined.PushPin else Icons.Outlined.Dns, null,
                        tint = if (host.connected) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) },
                        modifier = Modifier.clickable { model.command("host", "id" to host.id); onOpen() },
                        trailingContent = { Box {
                            IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Host options") }
                            DropdownMenu(menu, { menu = false }) {
                                DropdownMenuItem(text = { Text(if (host.pinned) "Unpin" else "Pin to top") }, onClick = { menu = false; model.command("pinHost", "id" to host.id) })
                                DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; renaming = host })
                                DropdownMenuItem(text = { Text("Reconnect") }, onClick = { menu = false; model.command("host", "id" to host.id) })
                                if (host.connected) DropdownMenuItem(text = { Text("Disconnect") }, onClick = { menu = false; model.command("disconnect") })
                                DropdownMenuItem(text = { Text("Remove host") }, onClick = { menu = false; removing = host })
                            }
                        } })
                }
            } }
            if (state.remote.hosts.isEmpty()) item {
                EmptyState(Icons.Outlined.Devices, "Your agents, wherever they run",
                    "Pair with pmai on your computer using its connection link. Forwiroh connects securely across networks.")
            }
            if (state.remote.busy || state.remote.status.isNotEmpty()) item {
                Row(Modifier.padding(20.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (state.remote.busy) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    Text(state.remote.status, Modifier.weight(1f).padding(horizontal = 12.dp))
                    if (state.remote.busy) TextButton(onClick = { model.command("disconnect") }) { Text("Cancel") }
                }
            }
        }
    }
    renaming?.let { host ->
        var name by remember(host.id) { mutableStateOf(host.name) }
        AlertDialog(onDismissRequest = { renaming = null }, title = { Text("Rename host") },
            text = { OutlinedTextField(name, { name = it }, label = { Text("Host name") }, singleLine = true) },
            confirmButton = { TextButton(onClick = { model.command("renameHost", "id" to host.id, "name" to name); renaming = null }, enabled = name.isNotBlank()) { Text("Save") } },
            dismissButton = { TextButton(onClick = { renaming = null }) { Text("Cancel") } })
    }
    removing?.let { host -> AlertDialog(onDismissRequest = { removing = null }, title = { Text("Remove ${host.name}?") },
        text = { Text("This removes its saved connection and cached chats from this device.") },
        confirmButton = { TextButton(onClick = { model.command("removeHost", "id" to host.id); removing = null }) { Text("Remove") } },
        dismissButton = { TextButton(onClick = { removing = null }) { Text("Cancel") } }) }
}

@Composable private fun AddHostSheet(initial: String, busy: Boolean, onDismiss: () -> Unit, onPair: (String, String) -> Unit) {
    val context = LocalContext.current
    var invitation by rememberSaveable { mutableStateOf(initial) }
    var name by rememberSaveable { mutableStateOf("") }
    var scanning by remember { mutableStateOf(false) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            Text("Connect a remote host", style = MaterialTheme.typography.headlineSmall)
            Text("On your computer, run /remote serve --protocol forwiroh in pmai. Paste its connection link, then approve this device on the host. For OpenCode, paste the pairing link from opencode pair --remote.")
            OutlinedButton(onClick = { scanning = true }, modifier = Modifier.fillMaxWidth()) {
                Icon(Icons.Outlined.QrCodeScanner, null); Spacer(Modifier.width(8.dp)); Text("Scan host QR code")
            }
            OutlinedTextField(invitation, { invitation = it }, label = { Text("Connection link") }, minLines = 2, maxLines = 5, modifier = Modifier.fillMaxWidth())
            TextButton(onClick = {
                val clip = (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).primaryClip
                invitation = clip?.getItemAt(0)?.coerceToText(context)?.toString().orEmpty()
            }) { Icon(Icons.Outlined.ContentPaste, null); Spacer(Modifier.width(8.dp)); Text("Paste link") }
            OutlinedTextField(name, { name = it }, label = { Text("Host name (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Button(onClick = { onPair(invitation, name) }, enabled = invitation.trim().startsWith("pmai-acp://connect/") && !busy,
                modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp)) { Text("Pair host") }
        }
    }
    if (scanning) ScanHostQr(onClose = { scanning = false }, onResult = { value ->
        invitation = value; scanning = false
    })
}

@Composable private fun PermissionDialog(permission: JSONObject, answer: (String?) -> Unit) {
    val tool = permission.optJSONObject("toolCall")
    AlertDialog(onDismissRequest = { answer(null) }, title = { Text(tool?.optString("title") ?: "Tool approval") },
        text = { Column(Modifier.verticalScroll(rememberScrollState())) {
            Text(tool?.toString(2) ?: "The remote agent is requesting permission to run a tool.")
            permission.optJSONArray("options").objects().forEach { option ->
                OutlinedButton(onClick = { answer(option.getString("optionId")) }, modifier = Modifier.fillMaxWidth()) {
                    Text(option.optString("name", option.getString("optionId")))
                }
            }
        } }, confirmButton = {}, dismissButton = { TextButton(onClick = { answer(null) }) { Text("Deny") } })
}

@Composable private fun SettingsScreen(state: AppState, model: MaiViewModel, theme: String, onTheme: (String) -> Unit) {
    var section by rememberSaveable { mutableStateOf("General") }
    var editingPrompt by remember { mutableStateOf<Prompt?>(null) }
    var addingPrompt by remember { mutableStateOf(false) }
    val sections = listOf("General", "Tools", "MCP", "Skills") + if (state.isRemote) listOf("Remote") else emptyList()
    Scaffold(topBar = { Column {
        TopAppBar(title = { Text("Settings") })
        SecondaryScrollableTabRow(selectedTabIndex = sections.indexOf(section).coerceAtLeast(0), edgePadding = 12.dp) {
            sections.forEach { name -> Tab(selected = name == section, onClick = { section = name }, text = { Text(name) }) }
        }
    } }) { padding ->
        if (section != "General") {
            AgentSettings(state, model, section, Modifier.padding(padding))
            return@Scaffold
        }
        LazyColumn(Modifier.fillMaxSize().padding(padding), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            item { Text("Make it yours", style = MaterialTheme.typography.headlineSmall) }
            item { Text("Appearance", style = MaterialTheme.typography.titleMedium) }
            item { SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                listOf("system", "light", "dark").forEachIndexed { index, item ->
                    SegmentedButton(selected = theme == item, onClick = { onTheme(item) }, shape = SegmentedButtonDefaults.itemShape(index, 3)) { Text(item.replaceFirstChar { it.uppercase() }) }
                }
            } }
            item { HorizontalDivider(); ProviderManager(state, model) }
            if (state.loadingModels) item { LinearProgressIndicator(Modifier.fillMaxWidth()) }
            if (state.status == "Provider saved") item { Text("Provider saved", color = MaterialTheme.colorScheme.primary) }
            items(state.models, key = { it }) { id -> ListItem(headlineContent = { Text(id) }, leadingContent = {
                RadioButton(selected = state.model == id, onClick = null)
            }, modifier = Modifier.clickable(enabled = !state.generating) { model.command("model", "id" to id) }) }
            item { HorizontalDivider(); Spacer(Modifier.height(16.dp)); Row(verticalAlignment = Alignment.CenterVertically) {
                Text("System prompts", style = MaterialTheme.typography.titleLarge, modifier = Modifier.weight(1f))
                IconButton(onClick = { addingPrompt = true }, enabled = !state.generating) { Icon(Icons.Outlined.Add, "Add prompt") }
            } }
            items(state.prompts, key = { it.id }) { prompt ->
                ListItem(headlineContent = { Text(prompt.name) }, supportingContent = { Text(prompt.text, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                    leadingContent = { RadioButton(selected = prompt.id == state.selectedPromptID, onClick = null) },
                    trailingContent = { IconButton(onClick = { editingPrompt = prompt }, enabled = !state.generating) { Icon(Icons.Outlined.Edit, "Edit prompt") } },
                    modifier = Modifier.clickable(enabled = !state.generating) { model.command("selectPrompt", "id" to prompt.id) })
            }
            item { Text("PocketMai · Kotlin + MaiCore", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(vertical = 24.dp)) }
        }
    }
    if (addingPrompt || editingPrompt != null) {
        var name by remember(editingPrompt?.id) { mutableStateOf(editingPrompt?.name.orEmpty()) }
        var text by remember(editingPrompt?.id) { mutableStateOf(editingPrompt?.text.orEmpty()) }
        ModalBottomSheet(onDismissRequest = { addingPrompt = false; editingPrompt = null }) {
            Column(Modifier.fillMaxWidth().imePadding().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(if (addingPrompt) "New system prompt" else "Edit system prompt", style = MaterialTheme.typography.headlineSmall)
                OutlinedTextField(name, { name = it }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(text, { text = it }, label = { Text("Instructions") }, minLines = 5, maxLines = 12, modifier = Modifier.fillMaxWidth())
                Button(onClick = { model.command("prompt", "id" to editingPrompt?.id.orEmpty(), "name" to name, "text" to text); addingPrompt = false; editingPrompt = null },
                    enabled = name.isNotBlank(), modifier = Modifier.fillMaxWidth()) { Text("Save prompt") }
            }
        }
    }
}

@Composable internal fun EmptyState(icon: ImageVector, title: String, description: String) {
    Column(Modifier.widthIn(max = 420.dp).padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.secondaryContainer) {
            Icon(icon, null, Modifier.padding(22.dp).size(36.dp), tint = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Text(title, style = MaterialTheme.typography.headlineSmall)
        Text(description, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}
@Composable private fun SectionLabel(text: String) { Text(text, Modifier.padding(horizontal = 20.dp, vertical = 14.dp), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary) }
private fun dateGroup(timestamp: Long): String {
    val date = Instant.ofEpochMilli(timestamp).atZone(ZoneId.systemDefault()).toLocalDate()
    val today = LocalDate.now()
    return when { date == today -> "Today"; date == today.minusDays(1) -> "Yesterday"; date >= today.minusDays(7) -> "Previous 7 days"; else -> "Earlier" }
}
private fun copyText(context: Context, text: String) {
    (context.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager).setPrimaryClip(ClipData.newPlainText("PocketMai", text))
}
private fun shareConversation(context: Context, title: String, messages: List<Message>) {
    val directory = context.cacheDir.resolve("exports").apply { mkdirs() }
    val file = directory.resolve("conversation.md")
    file.writeText("# $title\n\n" + messages.joinToString("\n\n") { "## ${it.role}\n\n${it.text}" })
    val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    context.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).apply {
        type = "text/markdown"; putExtra(Intent.EXTRA_STREAM, uri); addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
    }, "Share conversation"))
}
