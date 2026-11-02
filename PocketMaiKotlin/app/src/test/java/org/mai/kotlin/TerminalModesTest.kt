package org.mai.kotlin

import org.junit.Assert.*
import org.junit.Test

class TerminalModesTest {
    @Test fun fullScreenSwipesReturnToScrollbackAfterTheApplicationExits() {
        val modes = TerminalModes()
        assertFalse(modes.application)
        // radare2's mouse reporting and applications using an alternate screen
        // both need terminal input rather than moving local scrollback.
        "\u001b[?1000h".toByteArray().forEach { modes.feed(byteArrayOf(it)) }
        assertTrue(modes.application)
        modes.feed("\u001b[?1000l".toByteArray())
        assertFalse(modes.application)
        modes.feed("\u001b[?1;1049h".toByteArray())
        assertTrue(modes.application)
        modes.feed("\u001b[?1049l".toByteArray())
        assertTrue(modes.application)
        modes.feed("\u001b[?1l".toByteArray())
        assertFalse(modes.application)
        modes.feed("\u001b[?47h\u001bc".toByteArray())
        assertFalse(modes.application)
    }
}
