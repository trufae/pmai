package org.mai.kotlin

// Track the DEC modes used by full-screen applications. Parsing bytes across
// reads matters: escape sequences can be split anywhere by the transport.
internal class TerminalModes {
    private var state = 0
    private var number = 0
    private val parameters = mutableListOf<Int>()
    private val enabled = mutableSetOf<Int>()
    val application get() = enabled.isNotEmpty()

    fun feed(bytes: ByteArray) {
        for (byte in bytes) {
            val ch = byte.toInt() and 255
            if (ch == 27) { state = 1; continue }
            when (state) {
                1 -> {
                    if (ch == 'c'.code) enabled.clear()
                    state = if (ch == '['.code) 2 else 0
                }
                2 -> {
                    number = 0; parameters.clear()
                    state = if (ch == '?'.code) 3 else 0
                }
                3 -> when {
                    ch in '0'.code..'9'.code -> {
                        number = number * 10 + ch - '0'.code
                        if (number > 10000) state = 0
                    }
                    ch == ';'.code && parameters.size < 32 -> { parameters.add(number); number = 0 }
                    ch == 'h'.code || ch == 'l'.code -> {
                        parameters.add(number)
                        for (mode in parameters) if (mode in APPLICATION_MODES) {
                            if (ch == 'h'.code) enabled.add(mode) else enabled.remove(mode)
                        }
                        state = 0
                    }
                    else -> state = 0
                }
            }
        }
    }
    private companion object {
        val APPLICATION_MODES = setOf(1, 47, 1047, 1049, 1000, 1002, 1003)
    }
}
