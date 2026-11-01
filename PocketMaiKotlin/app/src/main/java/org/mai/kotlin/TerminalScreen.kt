@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import android.content.Context
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.collectIsDraggedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.KeyboardReturn
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.key.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

@Composable internal fun TerminalScreen(session: TerminalSession, model: MaiViewModel) {
    val preferences = LocalContext.current.getSharedPreferences("appearance", Context.MODE_PRIVATE)
    var fontSize by remember { mutableFloatStateOf(preferences.getFloat("terminalFontSize", 14f).coerceIn(6f, 43f)) }
    var pinching by remember { mutableStateOf(false) }
    var history by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    var followsOutput by remember { mutableStateOf(true) }
    val list = rememberLazyListState()
    val dragging by list.interactionSource.collectIsDraggedAsState()
    val scope = rememberCoroutineScope()
    val focus = remember { FocusRequester() }
    var input by remember { mutableStateOf(TextFieldValue(session.draft, TextRange(session.draft.length))) }
    LaunchedEffect(session.draft) {
        if (input.text != session.draft) input = TextFieldValue(session.draft, TextRange(session.draft.length))
    }
    val atBottom by remember { derivedStateOf {
        val last = list.layoutInfo.visibleItemsInfo.lastOrNull()
        last == null || (last.index == list.layoutInfo.totalItemsCount - 1 &&
            last.offset + last.size <= list.layoutInfo.viewportEndOffset + 40)
    } }
    LaunchedEffect(list) {
        var manual = false
        snapshotFlow { Triple(dragging, list.isScrollInProgress, atBottom) }.collect { (dragged, scrolling, bottom) ->
            if (dragged) manual = true
            if (manual) {
                followsOutput = bottom
                if (!dragged && !scrolling) manual = false
            }
        }
    }
    val last = session.buffer.entries.lastOrNull()
    LaunchedEffect(last?.id, last?.output, last?.running) {
        if (followsOutput && !pinching) list.scrollToItem(session.buffer.entries.size + 1)
    }
    LaunchedEffect(session.location) { focus.requestFocus() }
    BackHandler(onBack = model::closeTerminal)
    val run: (String?) -> Unit = { saved ->
        if (!session.buffer.running && !(saved ?: session.draft).isBlank()) {
            followsOutput = true
            model.runTerminal(saved)
        }
    }
    MaterialTheme(colorScheme = darkColorScheme(background = Color.Black, surface = Color.Black,
        primary = Color(0xFF81C784), onBackground = Color(0xFFE6E6E6), onSurface = Color(0xFFE6E6E6))) {
        Scaffold(containerColor = Color.Black, topBar = {
            TopAppBar(title = { Column {
                Text(session.location.name + " · Terminal", maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(session.location.cwd, style = MaterialTheme.typography.labelMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            } }, navigationIcon = {
                IconButton(onClick = model::closeTerminal) { Icon(Icons.Outlined.Close, "Close terminal") }
            }, actions = { Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Terminal options") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("Clear scrollback") }, enabled = !session.buffer.running && session.buffer.entries.isNotEmpty(),
                        onClick = { menu = false; model.clearTerminal(false) })
                    DropdownMenuItem(text = { Text("Clear history") }, enabled = session.buffer.history.isNotEmpty(),
                        onClick = { menu = false; model.clearTerminal(true) })
                }
            } })
        }, bottomBar = {
            Column(Modifier.imePadding().navigationBarsPadding().padding(12.dp)) {
                if (session.storageError.isNotEmpty()) Text(session.storageError, color = MaterialTheme.colorScheme.error)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = { model.terminalRecall(-1) },
                        enabled = session.buffer.history.isNotEmpty() && session.historyIndex != 0) {
                        Icon(Icons.Outlined.ArrowUpward, "Previous command")
                    }
                    IconButton(onClick = { model.terminalRecall(1) }, enabled = session.historyIndex != null) {
                        Icon(Icons.Outlined.ArrowDownward, "Next command")
                    }
                    IconButton(onClick = { history = true }, enabled = session.buffer.history.isNotEmpty()) {
                        Icon(Icons.Outlined.History, "Command history")
                    }
                    Spacer(Modifier.weight(1f))
                    if (session.buffer.running) TextButton(onClick = model::stopTerminal) { Text("Stop") }
                    else Text("Ready", style = MaterialTheme.typography.labelSmall)
                }
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("$", color = MaterialTheme.colorScheme.primary, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                    OutlinedTextField(input, { input = it; model.terminalDraft(it.text) },
                        Modifier.weight(1f).padding(horizontal = 8.dp).focusRequester(focus).onPreviewKeyEvent {
                            if (it.type != KeyEventType.KeyDown) false else when {
                                it.key == Key.DirectionUp -> { model.terminalRecall(-1); true }
                                it.key == Key.DirectionDown -> { model.terminalRecall(1); true }
                                it.key == Key.Enter && !it.isShiftPressed -> { run(null); true }
                                else -> false
                            }
                        }, placeholder = { Text("Command") }, maxLines = 6,
                        textStyle = TextStyle(fontFamily = FontFamily.Monospace, fontSize = fontSize.sp),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go, autoCorrectEnabled = false),
                        keyboardActions = KeyboardActions(onGo = { run(null) }))
                    IconButton(onClick = { run(null) }, enabled = !session.buffer.running && session.draft.isNotBlank()) {
                        Icon(Icons.AutoMirrored.Outlined.KeyboardReturn, "Run command")
                    }
                }
            }
        }) { padding ->
            Box(Modifier.fillMaxSize().padding(padding)) {
                LazyColumn(Modifier.fillMaxSize().pinchToResizeFont(onZoom = {
                    pinching = true
                    fontSize = (fontSize * it).coerceIn(6f, 43f)
                }, onFinished = {
                    pinching = false
                    preferences.edit().putFloat("terminalFontSize", fontSize).apply()
                }), state = list, contentPadding = PaddingValues(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    item("location") {
                        SelectionContainer { Column {
                            Text(session.location.name + ":" + session.location.cwd, color = MaterialTheme.colorScheme.primary,
                                fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                            Text("Each command starts in this project directory.", color = Color.Gray,
                                fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                        } }
                    }
                    items(session.buffer.entries, key = { it.id }) { entry ->
                        SelectionContainer { Column {
                            Text("$ " + entry.command, color = MaterialTheme.colorScheme.primary,
                                fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                            if (entry.output.isNotEmpty()) Text(entry.output,
                                Modifier.horizontalScroll(rememberScrollState()), softWrap = false,
                                color = if (entry.isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface,
                                fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                            if (entry.running) Text("Running…", color = Color.Gray, fontFamily = FontFamily.Monospace, fontSize = fontSize.sp)
                        } }
                    }
                    item("terminal-bottom") { Spacer(Modifier.height(1.dp)) }
                }
                if (!followsOutput) FilledTonalButton(onClick = {
                    followsOutput = true
                    scope.launch { list.animateScrollToItem(session.buffer.entries.size + 1) }
                }, modifier = Modifier.align(Alignment.BottomEnd).padding(8.dp)) {
                    Icon(Icons.Outlined.ArrowDownward, null)
                    Text("Latest output")
                }
            }
        }
        if (history) TerminalHistorySheet(session, onDismiss = { history = false }, onEdit = {
            model.terminalEdit(it); history = false; focus.requestFocus()
        }, onRun = { run(it); history = false })
    }
}

@Composable private fun TerminalHistorySheet(session: TerminalSession, onDismiss: () -> Unit,
    onEdit: (String) -> Unit, onRun: (String) -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Text("Command history", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(vertical = 12.dp),
                placeholder = { Text("Search commands") }, singleLine = true)
            LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(bottom = 24.dp)) {
                items(session.buffer.history.asReversed().filter { it.contains(query, ignoreCase = true) }, key = { it }) { saved ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        SelectionContainer { Text(saved, fontFamily = FontFamily.Monospace) }
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { onEdit(saved) }) { Text("Edit") }
                            OutlinedButton(onClick = { onRun(saved) }, enabled = !session.buffer.running) { Text("Run") }
                        }
                    }
                }
            }
        }
    }
}
