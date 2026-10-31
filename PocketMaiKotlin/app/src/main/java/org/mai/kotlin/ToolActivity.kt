package org.mai.kotlin

internal val Message.toolFailed: Boolean
    get() = status.equals("failed", ignoreCase = true) || status.equals("error", ignoreCase = true)

// Group only adjacent tool updates; keep every original message for its actions.
internal fun toolMessageRuns(messages: List<Message>): List<List<Message>> {
    val runs = mutableListOf<MutableList<Message>>()
    messages.forEach { message ->
        if (message.role == "tool" && runs.lastOrNull()?.lastOrNull()?.role == "tool") runs.last().add(message)
        else runs.add(mutableListOf(message))
    }
    return runs
}
