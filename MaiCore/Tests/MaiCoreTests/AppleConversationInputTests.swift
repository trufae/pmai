import Testing

@testable import MaiCore

@Test func appleLatestPromptIsNotInHistory() {
  let single = AppleConversationInput(instructions: "Rules", messages: [.user("Hello")])
  #expect(single.history.isEmpty)
  #expect(single.prompt == "Hello")
  let input = AppleConversationInput(
    instructions: "Rules", messages: [.user("One"), .assistant("Two"), .user("Three")])
  #expect(input.history.flatMap { $0 }.map(\.text) == ["One", "Two"])
  #expect(input.prompt == "Three")
  #expect(input.messages.filter { $0.text == "Three" }.count == 1)
  #expect(input.messages.map(\.role) == [.system, .user, .assistant, .user])
}

@Test func appleEmptyConversationAndPendingPlaceholder() {
  let empty = AppleConversationInput(instructions: "Rules", messages: [])
  #expect(empty.prompt.isEmpty)
  #expect(empty.history.isEmpty)
  let pending = AppleConversationInput(
    instructions: "Rules", messages: [.user("Hello"), .assistant("")])
  #expect(pending.prompt == "Hello")
  #expect(pending.history.isEmpty)
}

@Test func appleTrimmingPreservesInstructionsAndCurrentContext() {
  for limit in [0, 1, 2, 3] {
    let input = AppleConversationInput(
      instructions: "Rules",
      messages: [.system("Memory"), .user("Old"), .assistant("Answer"), .user("New")],
      context: "Retrieved facts", messageLimit: limit)
    #expect(input.instructions == "Rules\n\nMemory")
    #expect(input.prompt == "Context:\nRetrieved facts\n\nNew")
    #expect(!input.instructions.contains("Retrieved facts"))
    #expect(input.history.count == (limit == 3 ? 1 : 0))
  }
}

@Test func appleToolRecordsStayWithTheirTurn() {
  let tool = AgentMessage(role: .tool, content: "<tool_run>\nlookup tool ({}):\nFound\n</tool_run>")
  let messages: [AgentMessage] = [.user("Look up"), tool, .assistant("Found it"), .user("Next")]
  let full = AppleConversationInput(instructions: "Rules", messages: messages)
  #expect(full.history.count == 1)
  #expect(full.messages[2].text == "Host tool results:\n\(tool.text)")
  let trimmed = AppleConversationInput(instructions: "Rules", messages: messages, messageLimit: 3)
  #expect(trimmed.history.isEmpty)
  let active = AppleConversationInput(
    instructions: "Rules", messages: [.user("Look up"), tool], messageLimit: 0)
  #expect(active.history.isEmpty)
  #expect(active.prompt == "Look up\n\nHost tool results:\n\(tool.text)")
}

@Test func appleRetriesStrictlyReduceHistory() {
  var input = AppleConversationInput(
    instructions: "Rules",
    messages: (0..<20).flatMap { [.user("Question \($0)"), .assistant("Answer \($0)")] } + [
      .user("Latest")
    ],
    context: "Current context")
  let prompt = input.prompt
  for attempt in 0..<3 {
    let count = input.characterCount
    let trimmed = input.trimForRetry(lastAttempt: attempt == 2)
    #expect(trimmed)
    #expect(input.characterCount < count)
    #expect(input.instructions == "Rules")
    #expect(input.prompt == prompt)
    #expect(input.history.allSatisfy { $0.first?.role == .user && $0.last?.role == .assistant })
  }
  #expect(input.history.isEmpty)
  let trimmed = input.trimForRetry()
  #expect(!trimmed)
}

@Test func appleQueuedUserMessagesSurviveNoHistorySetting() {
  let input = AppleConversationInput(
    instructions: "Rules",
    messages: [.user("Old"), .assistant("Answer"), .user("New"), .user("Extra")],
    messageLimit: 0)
  #expect(input.prompt == "New\n\nExtra")
  #expect(input.history.isEmpty)
}

@Test func appleOmittedAssistantStillMarksATurnBoundary() {
  let input = AppleConversationInput(
    instructions: "Rules", messages: [.user("Old"), .assistant(""), .user("New")], messageLimit: 0)
  #expect(input.prompt == "New")
  #expect(input.history.isEmpty)
}

@Test func appleCompletedResponseCanBeContinuedWithoutReplayingUserPrompt() {
  let input = AppleConversationInput(
    instructions: "Rules", messages: [.user("One"), .assistant("Two")])
  #expect(input.history.flatMap { $0 }.map(\.text) == ["One", "Two"])
  #expect(input.prompt == "Continue from the last response.")
}
