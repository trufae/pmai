import FoundationModels
import MaiCore
import XCTest

@testable import PocketMai

final class AppleConversationTests: XCTestCase {
  private func request(_ messages: [ChatMessage]) -> ChatCompletionRequest {
    var conversation = Conversation()
    conversation.messages = messages
    return ChatCompletionRequest(
      conversation: conversation, settings: AppSettings(), context: "", assistantMessageID: UUID())
  }

  func testActiveAssistantExcludesProvisionalTextButKeepsCompletedTools() {
    let active = ChatMessage(
      role: .assistant,
      text: """
        <think>Private reasoning</think>
        <tool_run>lookup tool ({}):\nFound</tool_run>
        Provisional answer
        """)
    var request = request([ChatMessage(role: .user, text: "Find it"), active])
    request.assistantMessageID = active.id
    request.settings.includeReasoningContentInContext = true
    let input = PromptComposer.appleInput(request: request)
    XCTAssertTrue(input.history.isEmpty)
    XCTAssertTrue(input.prompt.contains("lookup tool ({}):\nFound"))
    XCTAssertFalse(input.prompt.contains("Provisional"))
    XCTAssertFalse(input.prompt.contains("Private"))
    XCTAssertEqual(input.prompt.components(separatedBy: "Find it").count, 2)
  }

  func testErrorsIncompleteToolsAndForeignReasoningAreExcluded() {
    var request = request([
      ChatMessage(role: .user, text: "One"),
      ChatMessage(
        role: .assistant, text: "<think>Secret</think>Visible<tool_run>pending</tool_run>"),
      ChatMessage(role: .error, text: "Failure"),
      ChatMessage(role: .user, text: "Two"),
      ChatMessage(role: .assistant, text: ""),
    ])
    request.settings.includeAssistantResponsesInContext = true
    request.settings.includeReasoningContentInContext = true
    let input = PromptComposer.appleInput(request: request)
    XCTAssertEqual(input.history.flatMap { $0 }.map(\.text), ["One", "Visible"])
    XCTAssertEqual(input.prompt, "Two")
  }

  func testContextIsPromptDataAndToolCatalogIsInstructions() {
    var request = request([ChatMessage(role: .user, text: "Question")])
    request.context = "File excerpt"
    request.hasToolCalling = true
    request.toolPrompt = "Tool catalog"
    request.settings.contextWindowMode = .none
    let input = PromptComposer.appleInput(request: request)
    XCTAssertTrue(input.instructions.contains("Tool catalog"))
    XCTAssertFalse(input.instructions.contains("File excerpt"))
    XCTAssertEqual(input.prompt, "Context:\nFile excerpt\n\nQuestion")
  }

  func testStreamingAndNonStreamingUseTheSameInput() {
    var request = request([ChatMessage(role: .user, text: "Question")])
    let input = PromptComposer.appleInput(request: request)
    request.conversation.usesStreaming.toggle()
    let other = PromptComposer.appleInput(request: request)
    XCTAssertEqual(input.messages.map(\.text), other.messages.map(\.text))
    XCTAssertEqual(input.messages.map(\.role), other.messages.map(\.role))
  }

  func testDisabledAssistantHistoryStillTrimsOldUserTurns() {
    var request = request([
      ChatMessage(role: .user, text: "Old"), ChatMessage(role: .assistant, text: "Answer"),
      ChatMessage(role: .user, text: "New"),
    ])
    request.settings.includeAssistantResponsesInContext = false
    request.settings.contextWindowMode = .none
    let input = PromptComposer.appleInput(request: request)
    XCTAssertTrue(input.history.isEmpty)
    XCTAssertEqual(input.prompt, "New")
  }

  func testFailedTurnsAndHostStatusAreNotReplayedAsAnswers() {
    var request = request([
      ChatMessage(role: .user, text: "Old"), ChatMessage(role: .error, text: "Failure"),
      ChatMessage(role: .user, text: "New"),
    ])
    request.settings.contextWindowMode = .none
    XCTAssertEqual(PromptComposer.appleInput(request: request).prompt, "New")
    for status in ["stopped", "operation failed: unavailable", "model response skipped by user after timeout"] {
      request.conversation.messages = [
        ChatMessage(role: .user, text: "Old"),
        ChatMessage(role: .assistant, text: "Partial answer\n\n[\(status)]"),
        ChatMessage(role: .user, text: "New"),
      ]
      request.settings.contextWindowMode = .full
      XCTAssertEqual(PromptComposer.appleInput(request: request).history.flatMap { $0 }.map(\.text),
        ["Old", "Partial answer"])
    }
  }

  func testNativeTranscriptRolesWithoutGenerating() throws {
    guard #available(iOS 26.0, *) else { throw XCTSkip("FoundationModels requires iOS 26") }
    let input = AppleConversationInput(
      instructions: "Rules", messages: [.user("One"), .assistant("Two"), .user("Three")])
    let entries = Array(AppleFoundationProvider.transcript(for: input))
    XCTAssertEqual(entries.count, 3)
    guard case .instructions(let instructions) = entries[0],
      case .prompt(let prompt) = entries[1], case .response(let response) = entries[2]
    else { return XCTFail("Incorrect native transcript roles") }
    let texts = (instructions.segments + prompt.segments + response.segments).compactMap {
      segment in
      if case .text(let text) = segment { return text.content }
      return nil
    }
    XCTAssertEqual(texts, ["Rules", "One", "Two"])
  }

  #if PMAI_FOUNDATION_MODELS_27
    func testApplePerResponseUsageMapping() throws {
      guard #available(iOS 27.0, *) else { throw XCTSkip("Native usage requires iOS 27") }
      let usage = AppleFoundationProvider.tokenUsage(
        .init(
          input: .init(totalTokenCount: 200, cachedTokenCount: 50),
          output: .init(totalTokenCount: 30, reasoningTokenCount: 10), metadata: [:]))
      XCTAssertEqual(usage.inputTokens, 200)
      XCTAssertEqual(usage.outputTokens, 30)
      XCTAssertEqual(usage.cachedTokens, 50)
      XCTAssertEqual(usage.reasoningTokens, 10)
      XCTAssertFalse(usage.isEstimated)
    }
  #endif
}
