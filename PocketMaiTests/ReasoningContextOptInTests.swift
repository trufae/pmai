import XCTest

@testable import PocketMai

final class ReasoningContextOptInTests: XCTestCase {
  private let assistantText = """
    <think>
    Hidden chain of thought.
    </think>

    Visible answer.
    """

  func testReasoningIsOptOutByDefault() {
    XCTAssertFalse(AppSettings().includeReasoningContentInContext)
  }

  func testStoredSettingsWithoutTheKeyDefaultToTrimmedReasoning() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    XCTAssertFalse(settings.includeReasoningContentInContext)
  }

  func testAssistantHistoryDropsReasoningByDefault() {
    let message = ChatMessage(role: .assistant, text: assistantText)
    let messages = PromptComposer.openAIHistoryMessages(
      from: message,
      includeAssistantResponses: true,
      echoReasoningContent: false)

    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.text, "Visible answer.")
    XCTAssertEqual(messages.first?.reasoning, "")
  }

  func testOmittedAssistantResponsesKeepTheirTurnBoundary() {
    let message = ChatMessage(role: .assistant, text: assistantText)
    let messages = PromptComposer.openAIHistoryMessages(
      from: message,
      includeAssistantResponses: false,
      echoReasoningContent: false)

    XCTAssertEqual(messages.map(\.role), [.assistant])
    XCTAssertEqual(messages.map(\.text), ["(redacted)"])

    var settings = AppSettings()
    settings.includeAssistantResponsesInContext = false
    let entries = PromptComposer.contextTranscriptEntries(from: message, settings: settings)
    XCTAssertEqual(entries.map(\.displayName), [ChatRole.assistant.displayName])
    XCTAssertEqual(entries.map(\.content), ["(redacted)"])
  }

  func testAssistantHistoryKeepsReasoningWhenOptedIn() {
    let message = ChatMessage(role: .assistant, text: assistantText)
    let messages = PromptComposer.openAIHistoryMessages(
      from: message,
      includeAssistantResponses: true,
      echoReasoningContent: false,
      includeReasoning: true)

    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      messages.first?.text,
      "<think>\nHidden chain of thought.\n</think>\n\nVisible answer.")
  }

  func testEndpointsTakingReasoningFieldDoNotInlineItTwice() {
    let message = ChatMessage(role: .assistant, text: assistantText)
    let messages = PromptComposer.openAIHistoryMessages(
      from: message,
      includeAssistantResponses: true,
      echoReasoningContent: true,
      includeReasoning: true)

    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages.first?.text, "Visible answer.")
    XCTAssertEqual(messages.first?.reasoning, "Hidden chain of thought.")
  }

  func testTranscriptContextFollowsTheSetting() {
    let message = ChatMessage(role: .assistant, text: assistantText)
    var settings = AppSettings()

    let trimmed = PromptComposer.contextTranscriptEntries(from: message, settings: settings)
    XCTAssertEqual(trimmed.map(\.content), ["Visible answer."])

    settings.includeReasoningContentInContext = true
    let kept = PromptComposer.contextTranscriptEntries(from: message, settings: settings)
    XCTAssertEqual(
      kept.map(\.content),
      ["<think>\nHidden chain of thought.\n</think>\n\nVisible answer."])
  }
}
