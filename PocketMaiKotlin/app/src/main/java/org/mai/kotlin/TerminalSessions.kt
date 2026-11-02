package org.mai.kotlin

import android.app.Application
import android.os.Handler
import android.os.Looper
import android.util.AtomicFile
import android.util.Base64
import androidx.compose.runtime.*
import kotlinx.coroutines.*
import org.connectbot.terminal.TerminalEmulatorFactory
import org.connectbot.terminal.ModifierManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal class TerminalModifiers : ModifierManager {
    var control by mutableStateOf(false)
    var alt by mutableStateOf(false)
    override fun isCtrlActive() = control
    override fun isAltActive() = alt
    override fun isShiftActive() = false
    override fun clearTransients() { control = false; alt = false }
    fun mask() = (if (control) 4 else 0) or (if (alt) 2 else 0)
}

// Process-owned emulators survive Activity recreation, navigation and tab switches.
internal class TerminalSessions(private val app: Application, private val execute: (String, Array<out Pair<String, String>>) -> Unit) {
    private val root = app.filesDir.resolve("terminals").apply { mkdirs() }
    private val index = AtomicFile(root.resolve("tabs.json"))
    private val main = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val tabs = mutableStateListOf<ShellSession>()
    var visible by mutableStateOf(false)
    var selected by mutableStateOf("")
    var storageError by mutableStateOf("")
    private var restored = false
    private fun command(action: String, vararg fields: Pair<String, String>) = execute(action, fields)

    fun restore() {
        if (restored) return
        restored = true
        try {
            if (index.baseFile.exists()) {
                val saved = JSONArray(index.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
                for (i in 0 until saved.length()) {
                    val tab = saved.getJSONObject(i)
                    val hostID = tab.getString("hostID")
                    require(UUID.fromString(tab.getString("id")).toString() == tab.getString("id"))
                    // Local processes cannot survive app death. Restore their scrollback on demand.
                    add(TerminalLocation(hostID, tab.getString("name"), tab.getString("endpoint"), tab.getString("cwd")),
                        tab.getString("id"), start = hostID.isNotEmpty())
                }
            }
        } catch (error: Exception) { storageError = "Could not restore terminals: ${error.localizedMessage}" }
    }

    fun open(state: AppState) {
        val host = state.remote.hosts.firstOrNull { it.id == state.remote.hostID }
        if (state.isRemote && (host == null || state.remote.folder.isBlank())) return
        val location = if (host == null) TerminalLocation("", "On this device", "", "")
            else TerminalLocation(host.id, host.name, host.address, state.remote.folder)
        selected = tabs.firstOrNull { it.location == location }?.id ?: add(location).id
        tabs.first { it.id == selected }.start()
        visible = true
    }

    fun add(location: TerminalLocation, id: String = UUID.randomUUID().toString(), start: Boolean = true): ShellSession {
        val tab = ShellSession(id, location)
        tabs.add(tab)
        selected = id
        if (start) tab.start()
        return tab
    }

    fun newSession() {
        val location = tabs.firstOrNull { it.id == selected }?.location ?: return
        add(location)
        saveIndex()
    }

    fun select(id: String) { selected = id; tabs.firstOrNull { it.id == id }?.start() }
    fun persist() { tabs.forEach { it.persist() }; saveIndex() }
    fun dismiss() { visible = false; persist() }
    private fun remove(tab: ShellSession) {
        tabs.remove(tab)
        if (selected == tab.id) selected = tabs.firstOrNull()?.id.orEmpty()
        saveIndex()
        tab.archive.baseFile.delete()
        tab.historyFile.delete()
        command("shellForget", "id" to tab.id)
    }

    fun receive(snapshot: JSONArray?) {
        if (snapshot == null) return
        for (i in 0 until snapshot.length()) {
            val value = snapshot.getJSONObject(i)
            tabs.firstOrNull { it.id == value.optString("id") }?.receive(value)
        }
    }

    fun termuxResult(id: String, message: String) {
        tabs.firstOrNull { it.id == id }?.let { if (message.isNotBlank()) it.error = message }
    }

    private fun saveIndex() {
        try {
            val data = JSONArray()
            tabs.forEach { tab -> data.put(JSONObject().put("id", tab.id).put("hostID", tab.location.hostID)
                .put("name", tab.location.name).put("endpoint", tab.location.endpoint).put("cwd", tab.location.cwd)) }
            index.writeBytes(data.toString().toByteArray())
            storageError = ""
        } catch (error: Exception) { storageError = "Could not save terminals: ${error.localizedMessage}" }
    }

    inner class ShellSession(val id: String, val location: TerminalLocation) {
        var status by mutableStateOf("Connecting…")
        var error by mutableStateOf("")
        var interactive by mutableStateOf(false)
        var applicationGestures by mutableStateOf(false)
            private set
        private val modes = TerminalModes()
        val modifiers = TerminalModifiers()
        val archive = AtomicFile(root.resolve("$id.session.json"))
        val historyFile = root.resolve("$id.properties")
        var buffer by mutableStateOf(TerminalBuffer())
            private set
        private var remoteID = ""
        private var offset = 0
        private var sequence = -1
        private var pendingAck: Int? = null
        private var commandMode = false
        private var output = ByteArray(0)
        private var resultID = ""
        private var resultOutput = ""
        private var started = false
        val canInput get() = started && status != "Disconnected" && status != "Connecting…" &&
            status != "Closing…" && !status.startsWith("Exited")
        private var termux: TermuxShell? = null
        private var line = ""
        private val history = TerminalHistoryCursor()
        private var storage: Job = Job().apply { complete() }
        private var checkpoint: Job? = null
        private var dirty = false
        private var removed = false
        private var columns = 80
        private var rows = 24
        val emulator = TerminalEmulatorFactory.create(
            onKeyboardInput = { bytes -> main.post { input(bytes) } },
            onResize = { size -> main.post {
                columns = size.columns; rows = size.rows
                termux?.resize(columns, rows)
                if (started && termux == null) command("shellResize", "id" to id, "columns" to columns.toString(), "rows" to rows.toString())
            } })
        init {
            try {
                buffer = TerminalBuffer.load(if (historyFile.exists()) historyFile else location.file(root))
                if (archive.baseFile.exists()) {
                    val saved = JSONObject(archive.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
                    remoteID = saved.optString("remoteID")
                    offset = saved.optInt("offset")
                    output = Base64.decode(saved.optString("data"), Base64.NO_WRAP)
                    emulator.writeInput(output)
                    modes.feed(output)
                    applicationGestures = modes.application
                }
            } catch (failure: Exception) { error = "Could not load terminal history: ${failure.localizedMessage}" }
        }
        fun start() {
            if (started) return
            if (location.hostID.isEmpty() && TermuxShell.installed(app)) {
                status = "Termux"
                if (!TermuxShell.permitted(app)) {
                    error = "Allow PocketMai to run commands in Termux, then reconnect."
                    return
                }
                interactive = true
                started = true
                termux = TermuxShell(app, id, columns, rows,
                    onData = { bytes -> withContext(Dispatchers.Main) { feed(bytes); schedulePersist() } },
                    onStatus = { message -> scope.launch { status = message } },
                    onError = { message -> scope.launch { error = message; started = false } })
                termux?.start()
            } else {
                started = true
                command("shellOpen", "id" to id, "hostID" to location.hostID, "cwd" to location.cwd,
                    "remoteID" to remoteID, "offset" to offset.toString())
                command("shellResize", "id" to id, "columns" to columns.toString(), "rows" to rows.toString())
            }
            saveIndex()
        }
        fun reconnect() {
            error = ""
            pendingAck?.let { persistAndAck(it); return }
            persist()
            if (termux != null) { termux?.close(); termux = null; started = false; start() }
            else if (!started) start()
            else command("shellReconnect", "id" to id)
        }
        fun end() {
            if (termux != null || !started) { termux?.close(); termux = null; forget() }
            else command("shellClose", "id" to id)
        }
        private fun forget() {
            removed = true
            checkpoint?.cancel(); checkpoint = null
            scope.launch { storage.join(); remove(this@ShellSession) }
        }
        fun receive(value: JSONObject) {
            if (removed) return
            status = value.optString("status")
            if (status == "Closed") { forget(); return }
            error = value.optString("error")
            interactive = value.optBoolean("interactive")
            if (!interactive && status == "Command mode" && !commandMode) {
                commandMode = true
                feedText("\nCommand mode: each command starts in ${location.cwd}.\n"); prompt()
            }
            val data = value.optString("data")
            val serial = value.optInt("sequence")
            if (data.isNotEmpty() && sequence != serial) {
                sequence = serial
                remoteID = value.optString("remoteID")
                offset = value.optInt("offset")
                feed(Base64.decode(data, Base64.NO_WRAP))
                if (location.hostID.isNotEmpty()) {
                    // The next remote read consumes these bytes on the host.
                    // Save data and its offset together before releasing it.
                    persistAndAck(serial)
                } else {
                    command("shellAck", "id" to id, "sequence" to serial.toString())
                    schedulePersist()
                }
            }
            val result = value.optJSONObject("command") ?: return
            if (result.optString("id") == resultID && resultID.isNotEmpty()) {
                val text = result.optString("output")
                if (text != resultOutput) {
                    feedText(if (text.startsWith(resultOutput)) text.substring(resultOutput.length) else "\n$text")
                    resultOutput = text
                }
                if (!result.optBoolean("running") && buffer.running) {
                    buffer = buffer.update(resultID, text, false, result.optBoolean("isError"))
                    saveHistory()
                    feedText("\n"); prompt()
                }
            }
        }
        private fun schedulePersist() {
            dirty = true
            if (checkpoint != null) return
            checkpoint = scope.launch {
                do {
                    delay(250)
                    dirty = false
                    saveHistory(includeHistory = false)
                    storage.join()
                } while (dirty)
                checkpoint = null
            }
        }
        private fun persistAndAck(serial: Int) {
            pendingAck = serial
            saveHistory(includeHistory = false) {
                pendingAck = null
                command("shellAck", "id" to id, "sequence" to serial.toString())
            }
        }
        private fun feed(data: ByteArray) {
            modes.feed(data)
            applicationGestures = modes.application
            emulator.writeInput(data)
            output += data
            if (output.size > 2 * 1024 * 1024) {
                output = output.takeLast(1024 * 1024).toByteArray()
                val newline = output.indexOf(10)
                if (newline >= 0) output = output.copyOfRange(newline + 1, output.size)
            }
        }
        private fun feedText(text: String) = feed(text.replace("\r\n", "\n").replace("\n", "\r\n").toByteArray())
        fun persist() { checkpoint?.cancel(); checkpoint = null; saveHistory() }
        private fun saveHistory(includeHistory: Boolean = true, onSaved: () -> Unit = {}) {
            val saved = buffer
            // feed() replaces the byte array, so these references form a
            // consistent data/offset checkpoint without encoding on the UI thread.
            val savedOutput = output
            val savedRemoteID = remoteID
            val savedOffset = offset
            val previous = storage
            storage = scope.launch {
                previous.join()
                try { withContext(Dispatchers.IO) {
                    if (includeHistory) saved.save(historyFile)
                    val data = JSONObject().put("remoteID", savedRemoteID).put("offset", savedOffset)
                        .put("data", Base64.encodeToString(savedOutput, Base64.NO_WRAP)).toString().toByteArray()
                    archive.writeBytes(data)
                }; onSaved() }
                catch (failure: Exception) { error = "Could not save history: ${failure.localizedMessage}" }
            }
        }
        fun clear() { emulator.clearScreen() }
        fun edit(command: String) { if (!interactive && !buffer.running) { line = command; redraw() } }
        fun runSaved(command: String) { if (!interactive && !buffer.running) { line = command; submit() } }
        private fun prompt() { feedText("$ ") }
        private fun redraw() { feedText("\r\u001b[2K$ $line") }
        private fun submit() {
            if (line.isBlank()) { feedText("\n"); prompt(); return }
            val script = line
            line = ""; history.reset()
            resultID = UUID.randomUUID().toString(); resultOutput = ""
            buffer = buffer.append(resultID, script)
            saveHistory()
            feedText("\n")
            command("shellRun", "id" to id, "commandID" to resultID, "script" to script)
        }
        fun input(data: ByteArray) {
            if (!canInput) return
            if (interactive) {
                termux?.let { it.send(data); return }
                data.asList().chunked(16 * 1024).forEach { part ->
                    command("shellInput", "id" to id, "data" to Base64.encodeToString(part.toByteArray(), Base64.NO_WRAP))
                }
                return
            }
            if (buffer.running) { if (data.contains(3)) command("shellStop", "id" to id); return }
            val text = data.toString(Charsets.UTF_8).replace("\u001b[200~", "").replace("\u001b[201~", "")
            if (text == "\u001b[A" || text == "\u001b[B" || text == "\u001bOA" || text == "\u001bOB") {
                line = history.move(if (text.endsWith("A")) -1 else 1, line, buffer.history); redraw(); return
            }
            if (text.startsWith("\u001b")) return
            if (text.length > 1 && (text.contains('\n') || text.contains('\r'))) {
                line += text.replace("\r\n", "\n").replace('\r', '\n'); feedText(text); return
            }
            text.forEach { ch -> when (ch) {
                '\r', '\n' -> submit()
                '\u007f', '\b' -> if (line.isNotEmpty()) { line = line.substring(0, line.offsetByCodePoints(line.length, -1)); redraw() }
                '\u0003' -> { line = ""; feedText("^C\n"); prompt() }
                '\u0015' -> { line = ""; redraw() }
                else -> if (!ch.isISOControl()) { line += ch; feedText(ch.toString()) }
            } }
        }
    }
}

private fun AtomicFile.writeBytes(data: ByteArray) {
    val stream = startWrite()
    try { stream.write(data); finishWrite(stream) }
    catch (error: Exception) { failWrite(stream); throw error }
}
