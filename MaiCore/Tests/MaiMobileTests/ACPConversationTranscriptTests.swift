import Foundation
import MaiACP
import MaiCore
import Testing

@Test("OpenCode updates retain cached history and stable IDs until an explicit rewind")
func remoteTranscriptPreservesOpenCodeHistory() throws {
  let first = ACPConversationMessage(role: "user", text: "Earlier question", remoteID: "user-1")
  let answer = ACPConversationMessage(role: "assistant", text: "Earlier answer", remoteID: "answer-1:0")
  var messages = try JSONDecoder().decode(
    [ACPConversationMessage].self, from: JSONEncoder().encode([first, answer]))
  messages.append(.init(role: "user", text: "Next question"))
  let update = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionUpdate":"_pmai/message_snapshot","preserveHistory":true,"messages":[{"remoteID":"user-2","role":"user","text":"Next question"},{"remoteID":"answer-2:0","role":"assistant","text":"Partial answer"}]}"#.utf8))
  ACPConversationTranscript.apply(update, to: &messages)
  #expect(messages.map(\.text) == ["Earlier question", "Earlier answer", "Next question", "Partial answer"])
  #expect(messages.prefix(2).map(\.id) == [first.id, answer.id])
  let answerID = try #require(messages.last?.id)
  let completion = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionUpdate":"_pmai/message_snapshot","preserveHistory":true,"messages":[{"remoteID":"answer-2:0","role":"assistant","text":"Complete answer"}]}"#.utf8))
  ACPConversationTranscript.apply(completion, to: &messages)
  ACPConversationTranscript.apply(completion, to: &messages)
  #expect(messages.map(\.text) == ["Earlier question", "Earlier answer", "Next question", "Complete answer"])
  #expect(messages.last?.id == answerID)
  let rewind = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"sessionUpdate":"_pmai/message_snapshot","preserveHistory":false,"messages":[{"remoteID":"user-1","role":"user","text":"Earlier question"}]}"#.utf8))
  ACPConversationTranscript.apply(rewind, to: &messages)
  #expect(messages.map(\.text) == ["Earlier question"])
  #expect(messages.first?.id == first.id)
}

@Test("Remote transcripts retain tool output, status, plans and stable IDs across snapshots")
func remoteTranscriptUpdates() throws {
  var messages: [ACPConversationMessage] = []
  func apply(_ json: String) throws {
    ACPConversationTranscript.apply(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), to: &messages)
  }
  try apply(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello "}}"#)
  try apply(#"{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"world"}}"#)
  #expect(messages.map(\.text) == ["Hello world"])
  try apply(#"{"sessionUpdate":"tool_call","toolCallId":"call","title":"Read","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"first"}}]}"#)
  try apply(#"{"sessionUpdate":"tool_call_update","toolCallId":"call","content":[{"type":"content","content":{"type":"text","text":"second"}}]}"#)
  #expect(messages.last?.text == "Read\nfirst\nsecond")
  #expect(messages.last?.status == "in_progress")
  try apply(#"{"sessionUpdate":"plan","entries":[{"content":"Verify result"}]}"#)
  #expect(messages.last?.role == "plan")
  #expect(messages.last?.text == "Verify result")
  let snapshot = #"{"sessionUpdate":"_pmai/message_snapshot","messages":[{"remoteID":"host-1","role":"assistant","text":"Saved answer","created":1700000000250}]}"#
  try apply(snapshot)
  let id = try #require(messages.first?.id)
  try apply(snapshot)
  #expect(messages.count == 1)
  #expect(messages.first?.id == id)
  #expect(messages.first?.createdAt == Date(timeIntervalSince1970: 1_700_000_000.25))
  #expect(try JSONDecoder().decode([ACPConversationMessage].self, from: JSONEncoder().encode(messages)) == messages)
}

@Test("Remote message caches from iOS and early Kotlin builds remain readable")
func remoteTranscriptCacheCompatibility() throws {
  let id = UUID()
  let ios = ACPConversationMessage(id: id, role: "user", text: "Saved", createdAt: nil)
  #expect(try JSONDecoder().decode(ACPConversationMessage.self, from: JSONEncoder().encode(ios)).id == id)
  let android = Data(#"{"id":"host-message-1","role":"assistant","text":"Saved","remoteID":"host-message-1"}"#.utf8)
  let decoded = try JSONDecoder().decode(ACPConversationMessage.self, from: android)
  #expect(decoded.text == "Saved")
  #expect(decoded.remoteID == "host-message-1")
}
