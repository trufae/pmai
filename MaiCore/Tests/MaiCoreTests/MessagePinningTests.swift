import Foundation
import Testing

@testable import MaiCore

@Test("Any message role can be pinned idempotently and old files default to unpinned")
func messagePinningPersistence() throws {
  var messages = [
    AgentMessage.system("Instructions"), .developer("Guidance"), .user("Question"),
    .assistant("Answer"), AgentMessage(role: .tool, content: "Tool output"),
  ]
  for message in messages {
    let pinned = messages.setMessagePinned(true, id: message.id)
    let repeated = messages.setMessagePinned(true, id: message.id)
    #expect(pinned && repeated)
  }
  #expect(messages.pinnedMessages == messages)
  let missing = messages.setMessagePinned(true, id: "missing")
  #expect(!missing)
  let encoded = try JSONEncoder().encode(messages)
  #expect(try JSONDecoder().decode([AgentMessage].self, from: encoded) == messages)
  let unpinned = messages.setMessagePinned(false, id: messages[0].id)
  #expect(unpinned)
  #expect(messages.pinnedMessages.count == 4)
  let legacy = Data(#"{"id":"old","role":"user","content":[{"text":{"_0":"Old message"}}]}"#.utf8)
  #expect(try !JSONDecoder().decode(AgentMessage.self, from: legacy).isPinned)
  let chat = AgentChat(
    primaryAgent: .init(id: "fixture", provider: .hello, model: "hello"), messages: messages)
  #expect(chat.forked().messages == messages)
}

@Test("Compaction preserves pinned messages and their linked tool exchanges")
func messagePinningCompaction() {
  var messages = [
    AgentMessage.user("Old question"), .assistant("Keep this exact answer"),
    .user("Current question"),
  ]
  messages[1].isPinned = true
  let compacted = AgentTranscriptEditor.compactingConversation(messages, summary: "Summary")
  #expect(compacted.contains(messages[1]))
  #expect(compacted.contains(messages[2]))
  #expect(!compacted.contains(messages[0]))
  let attempted = AgentTranscriptEditor.apply(
    [
      .remove(messageIDs: [messages[1].id]),
      .rewrite(messageID: messages[1].id, text: "Changed"),
    ], to: messages)
  #expect(attempted.messages == messages)

  let call = ToolCall(id: "call", name: "files_read", arguments: .object([:]))
  var result = AgentMessage(
    role: .tool,
    content: [.toolResult(.init(callID: "call", text: String(repeating: "x", count: 800)))])
  result.isPinned = true
  let transaction = [
    AgentMessage.user("Read"), AgentMessage(role: .assistant, content: [.toolCall(call)]),
    result, .user("Next"),
  ]
  let edited = AgentTranscriptEditor.apply(
    [.remove(messageIDs: [transaction[1].id])], to: transaction)
  #expect(edited.messages == transaction)
  var pruned = transaction
  #expect(AgentContextPruning.pruneToolOutput(&pruned) == nil)
  #expect(pruned == transaction)
}

@Test("Pin and unpin changes during a run survive without duplicating the sent transcript")
func messagePinningDuringRun() {
  let sent = [AgentMessage.user("Question"), .assistant("Earlier answer"), .user("Continue")]
  let result = sent + [.assistant("New answer")]
  var current = sent
  current[0].isPinned = true
  let merged = AgentTranscriptEditor.mergeCompletedRun(current: current, sent: sent, result: result)
  #expect(merged.map(\.id) == result.map(\.id))
  #expect(merged[0].isPinned)
  let compacted = [AgentMessage.user("Summary"), sent[2], AgentMessage.assistant("New answer")]
  let restored = AgentTranscriptEditor.mergeCompletedRun(
    current: current, sent: sent, result: compacted)
  #expect(restored.prefix(current.count).elementsEqual(current))
  #expect(Set(restored.map(\.id)).count == restored.count)
  var unpinned = merged
  unpinned[0].isPinned = false
  let next = AgentTranscriptEditor.mergeCompletedRun(
    current: unpinned, sent: merged, result: merged + [.assistant("Done")])
  #expect(!next[0].isPinned)
  #expect(next.count == merged.count + 1)
}

@Test("Short transcript previews keep the first paragraph and normalize line endings")
func messageFirstParagraph() {
  #expect(
    TranscriptCopy.firstParagraph("\r\n First line\r\nsecond line\r\n \r\nHidden paragraph")
      == "First line second line")
  #expect(TranscriptCopy.firstParagraph("\n\n").isEmpty)
  #expect(TranscriptCopy.firstParagraph(String(repeating: "word ", count: 100)).count > 120)
}
