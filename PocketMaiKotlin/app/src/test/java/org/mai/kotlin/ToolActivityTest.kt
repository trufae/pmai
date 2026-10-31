package org.mai.kotlin

import org.junit.Assert.*
import org.junit.Test

class ToolActivityTest {
    @Test fun preservesMessagesAndBreaksRunsAtProse() {
        val messages = listOf(
            Message("user", "user", "Read this"),
            Message("read", "tool", "Read file\nfull output", "completed", remoteID = "remote-read"),
            Message("thought", "thought", "Check the result"),
            Message("plan", "plan", "Try another command"),
            Message("fail", "tool", "Shell\npermission denied", "failed"),
            Message("reply", "assistant", "Trying another file"),
            Message("next", "tool", "Read next file", "in_progress"),
        )
        val runs = toolMessageRuns(messages)
        assertEquals(listOf(1, 4, 1, 1), runs.map { it.size })
        assertEquals(messages, runs.flatten())
        assertSame(messages[1], runs[1][0])
        assertTrue(runs[1][3].toolFailed)
        assertFalse(runs.last().first().toolFailed)
        assertTrue(toolMessageRuns(emptyList()).isEmpty())
    }
}
