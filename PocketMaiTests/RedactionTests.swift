import Foundation
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class RedactionTests: XCTestCase {
  func testSettingsPersistAndUseTheCLIRuleSyntaxAcrossAgents() throws {
    var settings = AppSettings()
    XCTAssertFalse(settings.redaction.enabled)
    XCTAssertFalse(
      try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).redaction.enabled)
    settings.redaction = .init(enabled: true, rules: "# Private\nJane=NAME\n/\\d{4}-\\d{4}/=CARD")
    let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.redaction, settings.redaction)
    let redactor = try XCTUnwrap(AppRedaction.context(settings: decoded))
    let masked = redactor.redact("JANE uses 1234-5678")
    XCTAssertFalse(masked.contains("JANE"))
    XCTAssertFalse(masked.contains("1234-5678"))
    XCTAssertEqual(redactor.unredact(masked), "JANE uses 1234-5678")
    settings.redaction.rules = "valid\n/[invalid/"
    XCTAssertThrowsError(try AppRedaction.context(settings: settings)) {
      XCTAssertEqual($0.localizedDescription, "Invalid redaction rule on line 2.")
    }
    settings.redaction.enabled = false
    XCTAssertNil(try AppRedaction.context(settings: settings))
    XCTAssertEqual(
      SkillTools.applyingLiveSettings(to: AppSettings(), from: decoded).redaction,
      decoded.redaction)
  }

  func testStreamingAndAppleInputRestoreDisplayWithoutExposingPartialTokens() async throws {
    let redactor = ContentRedactor(rules: try ContentRedactor.parse("Jane"))
    let token = redactor.redact("Jane")
    let input = AppleConversationInput(
      instructions: "Jane's instructions",
      messages: [.user("Jane"), .assistant("Hello Jane"), .user("Jane again")])
    let filtered = input.redacted(using: redactor)
    XCTAssertFalse(filtered.messages.contains { $0.text.contains("Jane") })
    XCTAssertEqual(filtered.history.count, input.history.count)
    XCTAssertEqual(redactor.unredact(filtered.prompt), input.prompt)
    var updates: [String] = []
    let accumulator = ContentRedactor.$current.withValue(redactor) {
      CoreProviderEventAccumulator(onUpdate: { updates.append($0) })
    }
    // The accumulator must retain the table even when callbacks arrive outside the turn's task.
    accumulator.consume(.textDelta("Hello " + String(token.prefix(12))))
    XCTAssertEqual(updates.last, "Hello ")
    accumulator.consume(.textDelta(String(token.dropFirst(12))))
    let result = try accumulator.finish(response: .init(message: .assistant("Hello " + token)))
    XCTAssertEqual(updates.last, "Hello Jane")
    XCTAssertEqual(result.0, "Hello " + token)
  }

  func testModelRequestsAndOneShotResultsAreRedactedAndRestored() async throws {
    StubChatEndpoint.install()
    defer { StubChatEndpoint.uninstall() }
    var settings = settingsForStub()
    settings.redaction = .init(enabled: true, rules: "Jane")
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let text = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      return (StubChatEndpoint.completion(content: text), 0)
    }
    let result = try await OneShotPromptRunner.run(
      .init(
        title: "Private", prompt: "Hello Jane", provider: .openAICompatible,
        modelID: "stub", endpointID: settings.selectedEndpointID), settings: settings)
    XCTAssertEqual(result, "Hello Jane")
    XCTAssertEqual(StubChatEndpoint.requests.count, 1)
    try assertNoSecretInRequests()
    settings.redaction.enabled = false
    _ = try await OneShotPromptRunner.run(
      .init(
        title: "Off", prompt: "Hello Jane", provider: .openAICompatible,
        modelID: "stub", endpointID: settings.selectedEndpointID), settings: settings)
    let last = try JSONSerialization.data(withJSONObject: XCTUnwrap(StubChatEndpoint.requests.last))
    XCTAssertTrue(String(decoding: last, as: UTF8.self).contains("Jane"))
  }

  func testToolArgumentsAreRestoredAndToolResultsAreMaskedForNativeAndTextCalls() async throws {
    for (native, approval) in [
      (true, ToolApprovalMode.yolo), (false, .yolo), (true, .smart), (true, .ask),
    ] {
      StubChatEndpoint.install()
      defer { StubChatEndpoint.uninstall() }
      let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      let store = AppStore(persistence: PersistenceStore(localBaseURL: base))
      for _ in 0..<1000 {
        if store.hasLoadedPersistedSettings { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertTrue(store.hasLoadedPersistedSettings)
      store.settings = settingsForStub()
      store.settings.redaction = .init(enabled: true, rules: "Jane")
      store.settings.toolCallingMode = native ? .native : .json
      store.settings.toolApprovalMode = approval
      if approval == .smart {
        let reviewer = store.settings.addAgent(named: "Reviewer")
        let index = try XCTUnwrap(store.settings.agents.firstIndex { $0.id == reviewer.id })
        store.settings.agents[index].settings.openAIModelID = "review"
        store.settings.taskAgents.approval = reviewer.id.uuidString.lowercased()
      }
      var conversation = Conversation()
      conversation.provider = .openAICompatible
      conversation.endpointID = store.settings.selectedEndpointID
      conversation.modelID = "stub"
      conversation.usesStreaming = false
      conversation.enabledTools = [.todo]
      conversation.enabledMCPServers = []
      conversation.messages = [.init(role: .user, text: "Jane")]
      StubChatEndpoint.script = { request in
        if request["model"] as? String == "review" {
          return (
            StubChatEndpoint.completion(content: #"{"decision":"allow","reason":"Within task"}"#), 0
          )
        }
        let messages = request["messages"] as? [[String: Any]] ?? []
        let text = messages.first { $0["role"] as? String == "user" }?["content"] as? String ?? ""
        let range = text.range(of: "__PMAI_[A-Za-z0-9_]+__", options: .regularExpression)
        let user = range.map { String(text[$0]) } ?? text
        if StubChatEndpoint.requests.filter({ $0["model"] as? String != "review" }).count > 1 {
          return (StubChatEndpoint.completion(content: "Saved " + user), 0)
        }
        let arguments = ["title": user]
        let json = String(
          decoding: try! JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        if !native {
          return (
            StubChatEndpoint.completion(content: "{\"tool\":\"todo_add\",\"args\":\(json)}"), 0
          )
        }
        return (
          [
            "choices": [
              [
                "finish_reason": "tool_calls",
                "message": [
                  "role": "assistant",
                  "tool_calls": [
                    [
                      "id": "private_call", "type": "function",
                      "function": ["name": "todo_add", "arguments": json],
                    ]
                  ],
                ],
              ]
            ]
          ], 0
        )
      }
      let run = Task {
        try await AssistantToolLoop.runIsolated(
          conversation: conversation, settings: store.settings, baseContext: "", store: store)
      }
      if approval == .ask {
        for _ in 0..<500 {
          if store.activeToolCallApprovalRequest != nil { break }
          try await Task.sleep(for: .milliseconds(10))
        }
        let pending = try XCTUnwrap(store.activeToolCallApprovalRequest)
        XCTAssertEqual(pending.call.argumentValues["title"]?.stringValue, "Jane")
        XCTAssertNil(store.approveToolCall(id: pending.id, editedText: pending.originalText))
      }
      let result = try await run.value
      XCTAssertEqual(store.settings.toolSettings.todos.last?.title, "Jane")
      XCTAssertTrue(result.text.contains("Jane"))
      XCTAssertFalse(result.conversation.messages.contains { $0.text.contains("__PMAI_") })
      XCTAssertFalse(result.toolRuns.contains { $0.argumentsJSON.contains("__PMAI_") })
      XCTAssertGreaterThanOrEqual(StubChatEndpoint.requests.count, 2)
      try assertNoSecretInRequests()
    }
  }

  private func settingsForStub() -> AppSettings {
    var settings = AppSettings()
    let endpoint = OpenAIEndpoint(
      name: "Stub", baseURL: "https://\(StubChatEndpoint.host)/v1", defaultModel: "stub")
    settings.openAIEndpoints = [endpoint]
    settings.selectedEndpointID = endpoint.id
    settings.defaultProvider = .openAICompatible
    return settings
  }

  private func assertNoSecretInRequests() throws {
    for request in StubChatEndpoint.requests {
      let data = try JSONSerialization.data(withJSONObject: request)
      XCTAssertFalse(String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("Jane"))
    }
  }
}
