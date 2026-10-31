package org.mai.kotlin

internal val Message.toolFailed: Boolean
    get() = status.equals("failed", ignoreCase = true) || status.equals("error", ignoreCase = true)

internal val Message.isActivity: Boolean
    get() = role == "tool" || role == "thought" || role == "plan"

// Keep every original update and its actions, including interlaced reasoning.
internal fun toolMessageRuns(messages: List<Message>): List<List<Message>> {
    val runs = mutableListOf<MutableList<Message>>()
    messages.forEach { message ->
        if (message.isActivity && runs.lastOrNull()?.lastOrNull()?.isActivity == true) runs.last().add(message)
        else runs.add(mutableListOf(message))
    }
    return runs
}
