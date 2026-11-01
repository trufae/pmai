package org.mai.kotlin

import java.io.File
import java.nio.file.AtomicMoveNotSupportedException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Properties

data class TerminalLocation(val hostID: String, val name: String, val endpoint: String, val cwd: String) {
    fun file(directory: File): File {
        val key = listOf(hostID, endpoint, cwd).joinToString("\n")
        val digest = MessageDigest.getInstance("SHA-256").digest(key.toByteArray(Charsets.UTF_8))
        return directory.resolve(digest.joinToString("") { "%02x".format(it.toInt() and 255) } + ".properties")
    }
}

data class TerminalEntry(val id: String, val command: String, val output: String = "",
    val running: Boolean = true, val isError: Boolean = false)

data class TerminalBuffer(val entries: List<TerminalEntry> = emptyList(), val history: List<String> = emptyList()) {
    val running get() = entries.lastOrNull()?.running == true

    fun append(id: String, command: String) = copy(entries = entries + TerminalEntry(id, command),
        history = history.filter { it != command } + command).bounded()

    fun update(id: String, output: String, running: Boolean, isError: Boolean) = copy(entries = entries.map {
        if (it.id == id) it.copy(output = boundedOutput(output), running = running, isError = isError) else it
    }).bounded()

    fun interrupted() = copy(entries = entries.map {
        if (it.running) it.copy(output = it.output + "\n[connection closed; remote command may still be running]",
            running = false, isError = true) else it
    }).bounded()

    private fun bounded(): TerminalBuffer {
        val recent = entries.takeLast(ENTRY_LIMIT)
        var bytes = 0
        var first = recent.size
        for (index in recent.indices.reversed()) {
            val entry = recent[index]
            bytes += entry.command.toByteArray(Charsets.UTF_8).size + entry.output.toByteArray(Charsets.UTF_8).size
            if (bytes > BACKLOG_LIMIT && index < recent.lastIndex) break
            first = index
        }
        return copy(entries = recent.drop(first), history = history.takeLast(HISTORY_LIMIT))
    }

    fun save(file: File) {
        check(file.parentFile?.isDirectory == true || file.parentFile?.mkdirs() == true) { "Cannot create terminal history folder" }
        val properties = Properties()
        properties.setProperty("version", "1")
        properties.setProperty("history.count", history.size.toString())
        history.forEachIndexed { index, command -> properties.setProperty("history." + index, command) }
        properties.setProperty("entries.count", entries.size.toString())
        entries.forEachIndexed { index, entry ->
            val key = "entry." + index + "."
            properties.setProperty(key + "id", entry.id)
            properties.setProperty(key + "command", entry.command)
            properties.setProperty(key + "output", entry.output)
            properties.setProperty(key + "running", entry.running.toString())
            properties.setProperty(key + "error", entry.isError.toString())
        }
        val temporary = File(file.path + ".tmp")
        temporary.outputStream().use { properties.store(it, null) }
        try {
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (_: AtomicMoveNotSupportedException) {
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING)
        }
    }

    companion object {
        const val HISTORY_LIMIT = 500
        const val ENTRY_LIMIT = 200
        const val OUTPUT_LIMIT = 128_000
        const val BACKLOG_LIMIT = 1_000_000

        private fun boundedOutput(output: String): String {
            val bytes = output.toByteArray(Charsets.UTF_8)
            return if (bytes.size <= OUTPUT_LIMIT) output
                else "[earlier output trimmed]\n" + bytes.copyOfRange(bytes.size - OUTPUT_LIMIT, bytes.size).toString(Charsets.UTF_8)
        }

        fun load(file: File): TerminalBuffer {
            if (!file.exists()) return TerminalBuffer()
            val properties = Properties().apply { file.inputStream().use { load(it) } }
            require(properties.getProperty("version") == "1") { "Unsupported terminal history format" }
            fun value(key: String) = properties.getProperty(key).orEmpty()
            val history = List(value("history.count").toInt().coerceIn(0, HISTORY_LIMIT)) { value("history." + it) }
            val entries = List(value("entries.count").toInt().coerceIn(0, ENTRY_LIMIT)) { index ->
                val key = "entry." + index + "."
                TerminalEntry(value(key + "id"), value(key + "command"), value(key + "output"),
                    value(key + "running").toBoolean(), value(key + "error").toBoolean())
            }
            return TerminalBuffer(entries, history).interrupted()
        }
    }
}

class TerminalHistoryCursor {
    var index: Int? = null
        private set
    private var draft = ""

    fun move(direction: Int, command: String, history: List<String>): String {
        if (history.isEmpty()) return command
        if (index == null) {
            if (direction >= 0) return command
            draft = command
        }
        val next = ((index ?: history.size) + direction).coerceIn(0, history.size)
        index = next.takeIf { it < history.size }
        return index?.let { history[it] } ?: draft
    }

    fun reset() { index = null; draft = "" }
}

data class TerminalSession(val location: TerminalLocation, val buffer: TerminalBuffer,
    val draft: String = "", val historyIndex: Int? = null, val storageError: String = "")
