@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
package org.mai.kotlin

import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalSoftwareKeyboardController
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import org.connectbot.terminal.Terminal
import org.connectbot.terminal.VTermKey

@Composable internal fun TerminalScreen(model: MaiViewModel) {
    val deck = model.terminals
    val session = deck.tabs.firstOrNull { it.id == deck.selected }
    val preferences = LocalContext.current.getSharedPreferences("appearance", 0)
    val keyboard = LocalSoftwareKeyboardController.current
    var history by rememberSaveable { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        if (it) session?.reconnect()
    }
    BackHandler(onBack = deck::dismiss)
    MaterialTheme(colorScheme = darkColorScheme(background = Color.Black, surface = Color.Black,
        primary = Color(0xFF81C784), onBackground = Color.White, onSurface = Color.White)) {
        Column(Modifier.fillMaxSize().background(Color.Black).safeDrawingPadding().imePadding()) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
                IconButton(onClick = deck::dismiss) { Icon(Icons.Outlined.Close, "Return to chat") }
                Column(Modifier.weight(1f)) {
                    Text(session?.location?.name ?: "Terminal", maxLines = 1, overflow = TextOverflow.Ellipsis)
                    session?.let { Text(it.location.cwd.ifEmpty { it.status }, style = MaterialTheme.typography.labelSmall,
                        maxLines = 1, overflow = TextOverflow.Ellipsis) }
                }
                IconButton(onClick = deck::newSession, enabled = session != null) { Icon(Icons.Outlined.Add, "New terminal session") }
                Box {
                    IconButton(onClick = { menu = true }) { Icon(Icons.Outlined.MoreVert, "Terminal options") }
                    DropdownMenu(menu, { menu = false }) {
                        DropdownMenuItem(text = { Text("Reconnect") }, onClick = { menu = false; session?.reconnect() })
                        DropdownMenuItem(text = { Text("Clear screen") }, onClick = { menu = false; session?.clear() })
                        DropdownMenuItem(text = { Text("Hide keyboard") }, onClick = { menu = false; keyboard?.hide() })
                        DropdownMenuItem(text = { Text("Close this session") }, onClick = { menu = false; session?.end() })
                    }
                }
            }
            LazyRow(Modifier.fillMaxWidth(), contentPadding = PaddingValues(horizontal = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(deck.tabs, key = { it.id }) { tab ->
                    FilterChip(selected = tab.id == deck.selected, onClick = { deck.select(tab.id) },
                        label = { Text("${deck.tabs.indexOf(tab) + 1} · ${tab.location.name}", maxLines = 1) })
                }
            }
            if (deck.storageError.isNotEmpty()) Text(deck.storageError, color = MaterialTheme.colorScheme.error)
            if (session == null) {
                Text("All terminal sessions are closed.", Modifier.padding(24.dp))
                TextButton(onClick = deck::dismiss) { Text("Return to chat") }
                Spacer(Modifier.weight(1f))
            } else key(session.id) {
                if (session.error.isNotEmpty()) {
                    Text(session.error, Modifier.padding(horizontal = 12.dp), color = MaterialTheme.colorScheme.error)
                    Row {
                        if (session.location.hostID.isEmpty() && TermuxShell.installed(LocalContext.current) && !TermuxShell.permitted(LocalContext.current)) {
                            TextButton(onClick = { permission.launch(TermuxShell.PERMISSION) }) { Text("Allow Termux") }
                        }
                        TextButton(onClick = session::reconnect) { Text("Reconnect") }
                    }
                }
                var font by remember { mutableFloatStateOf(preferences.getFloat("terminalFontSize", 14f).coerceIn(8f, 32f)) }
                // Keep the emulator outside composition; resizing only changes its cell grid.
                Terminal(session.emulator, modifier = Modifier.weight(1f).fillMaxWidth()
                    .pinchToResizeFont(onZoom = { font = (font * it).coerceIn(8f, 32f) },
                        onFinished = { preferences.edit().putFloat("terminalFontSize", font).apply() }),
                    initialFontSize = font.sp, minFontSize = font.sp, maxFontSize = font.sp,
                    keyboardEnabled = session.canInput, modifierManager = session.modifiers)
                if (!session.interactive) Text(session.status, Modifier.padding(horizontal = 12.dp), style = MaterialTheme.typography.labelSmall)
                TerminalKeyBar(session, onHistory = { history = true })
                if (history) TerminalHistorySheet(session, onDismiss = { history = false })
            }
        }
    }
}

@Composable private fun TerminalKeyBar(session: TerminalSessions.ShellSession, onHistory: () -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
        FilterChip(selected = session.modifiers.control, onClick = { session.modifiers.control = !session.modifiers.control }, label = { Text("Ctrl") })
        FilterChip(selected = session.modifiers.alt, onClick = { session.modifiers.alt = !session.modifiers.alt }, label = { Text("Alt") })
        listOf("Esc" to VTermKey.ESCAPE, "Tab" to VTermKey.TAB, "←" to VTermKey.LEFT,
            "↓" to VTermKey.DOWN, "↑" to VTermKey.UP, "→" to VTermKey.RIGHT,
            "PgUp" to VTermKey.PAGEUP, "PgDn" to VTermKey.PAGEDOWN).forEach { (title, code) ->
            TextButton(onClick = {
                session.emulator.dispatchKey(session.modifiers.mask(), code)
                session.modifiers.clearTransients()
            }, modifier = Modifier.defaultMinSize(minWidth = 44.dp, minHeight = 44.dp), contentPadding = PaddingValues(6.dp)) { Text(title) }
        }
        if (!session.interactive) IconButton(onClick = onHistory) { Icon(Icons.Outlined.History, "Command history") }
    }
}

@Composable private fun TerminalHistorySheet(session: TerminalSessions.ShellSession, onDismiss: () -> Unit) {
    var query by rememberSaveable { mutableStateOf("") }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 16.dp)) {
            Text("Command history", style = MaterialTheme.typography.titleLarge)
            OutlinedTextField(query, { query = it }, Modifier.fillMaxWidth().padding(vertical = 12.dp),
                placeholder = { Text("Search commands") }, singleLine = true)
            LazyColumn(Modifier.fillMaxWidth().weight(1f, fill = false), contentPadding = PaddingValues(bottom = 24.dp)) {
                items(session.buffer.history.asReversed().filter { it.contains(query, ignoreCase = true) }, key = { it }) { saved ->
                    Column(Modifier.fillMaxWidth().padding(vertical = 8.dp)) {
                        Text(saved, fontFamily = FontFamily.Monospace)
                        Row {
                            TextButton(onClick = { session.edit(saved); onDismiss() }) { Text("Edit") }
                            TextButton(onClick = { session.runSaved(saved); onDismiss() }, enabled = !session.buffer.running) { Text("Run") }
                        }
                    }
                }
            }
        }
    }
}
