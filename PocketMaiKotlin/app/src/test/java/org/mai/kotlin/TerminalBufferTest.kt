package org.mai.kotlin

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class TerminalBufferTest {
    @Test fun savedHistoryAndScrollbackRestoreWithoutReplayingAnInterruptedCommand() {
        val directory = Files.createTempDirectory("terminal-history").toFile()
        try {
            val location = TerminalLocation("host", "Worker", "wss://worker.example/acp", "/work")
            val buffer = TerminalBuffer().append("one", "printf 'hello\\n'")
                .update("one", "hello\n世界", running = false, isError = false).append("two", "build")
            buffer.save(location.file(directory))
            val restored = TerminalBuffer.load(location.file(directory))
            assertEquals(listOf("printf 'hello\\n'", "build"), restored.history)
            assertEquals("hello\n世界", restored.entries.first().output)
            assertFalse(restored.running)
            assertTrue(restored.entries.last().isError)
            assertTrue(restored.entries.last().output.contains("may still be running"))
            for (other in listOf(location.copy(cwd = "/other"), location.copy(hostID = "other"),
                location.copy(endpoint = "wss://other.example/acp"))) {
                assertTrue(TerminalBuffer.load(other.file(directory)).entries.isEmpty())
            }
        } finally { directory.deleteRecursively() }
    }

    @Test fun boundedBacklogKeepsRecentCommandsAndTheEndOfLargeOutput() {
        var buffer = TerminalBuffer()
        for (index in 0..TerminalBuffer.HISTORY_LIMIT) buffer = buffer.append(index.toString(), "echo " + index)
        assertEquals(TerminalBuffer.HISTORY_LIMIT, buffer.history.size)
        assertEquals("echo " + TerminalBuffer.HISTORY_LIMIT, buffer.history.last())
        assertEquals(TerminalBuffer.ENTRY_LIMIT, buffer.entries.size)
        val output = "x".repeat(TerminalBuffer.OUTPUT_LIMIT + 1) + "tail"
        repeat(10) {
            val id = "large-" + it
            buffer = buffer.append(id, id).update(id, output, running = false, isError = false)
        }
        assertTrue(buffer.entries.sumOf { it.command.toByteArray().size + it.output.toByteArray().size } <= TerminalBuffer.BACKLOG_LIMIT)
        assertTrue(buffer.entries.last().output.endsWith("tail"))
        assertTrue(buffer.entries.last().output.contains("earlier output trimmed"))
    }

    @Test fun historyDeduplicatesAndCanBeClearedIndependentlyOfScrollback() {
        val buffer = TerminalBuffer().append("one", "pwd").append("two", "ls").append("three", "pwd")
        assertEquals(listOf("ls", "pwd"), buffer.history)
        assertEquals(buffer.history, buffer.copy(entries = emptyList()).history)
        assertEquals(buffer.entries, buffer.copy(history = emptyList()).entries)
    }

    @Test fun navigatingHistoryRestoresAnUnfinishedDraft() {
        val cursor = TerminalHistoryCursor()
        val history = listOf("pwd", "ls")
        assertEquals("ls", cursor.move(-1, "unfinished", history))
        assertEquals("pwd", cursor.move(-1, "ls -l", history))
        assertEquals("pwd", cursor.move(-1, "pwd", history))
        assertEquals("ls", cursor.move(1, "pwd", history))
        assertEquals("unfinished", cursor.move(1, "ls", history))
        assertNull(cursor.index)
        assertEquals("new", cursor.move(1, "new", history))
        assertEquals("new", cursor.move(-1, "new", emptyList()))
    }
}
