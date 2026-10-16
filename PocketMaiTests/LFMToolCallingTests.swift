import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class LFMToolCallingTests: XCTestCase {
  private var store: AppStore!
  private var root: URL!

  override func setUp() async throws {
    try await super.setUp()
    StubChatEndpoint.install()
    root = FileManager.default.temporaryDirectory.appendingPathComponent("lfm-tools-\(UUID())")
    store = AppStore(persistence: PersistenceStore(localBaseURL: root))
    let deadline = Date().addingTimeInterval(20)
    while !store.hasLoadedPersistedSettings && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertTrue(store.hasLoadedPersistedSettings)
  }

  override func tearDown() async throws {
    StubChatEndpoint.uninstall()
    store = nil
    try? FileManager.default.removeItem(at: root)
    try await super.tearDown()
  }

  private func conversation(mode: ToolCallingMode = .text, stream: Bool = false) -> Conversation {
    let endpoint = OpenAIEndpoint(
      name: "LFM fixture", baseURL: "https://\(StubChatEndpoint.host)/v1", defaultModel: "lfm25")
    store.settings.openAIEndpoints = [endpoint]
    store.settings.toolCallingMode = mode
    store.settings.toolApprovalMode = .yolo
    store.settings.useToolProxy = true
    store.settings.toolPolicy = .init(automatic: false)
    store.settings.agents[0].canSpawnSubagents = false
    store.settings.toolSettings.webSearchProvider = .searXNG
    store.settings.toolSettings.webSearchSearXNGURL = "https://\(StubChatEndpoint.host)"
    var conversation = Conversation()
    conversation.provider = .openAICompatible
    conversation.endpointID = endpoint.id
    conversation.modelID = "lfm25"
    conversation.usesStreaming = stream
    conversation.toolsEnabled = true
    conversation.enabledTools = [.webSearch]
    conversation.enabledMCPServers = []
    conversation.messages = [ChatMessage(role: .user, text: "Websearch for the author of rizin")]
    return conversation
  }

  private func replyWithCall(_ call: String) {
    StubChatEndpoint.script = { _ in
      (StubChatEndpoint.completion(content: StubChatEndpoint.requests.count == 1
        ? call : "Search completed from fixture."), 0)
    }
  }

  func testExportedCallExecutesThroughProxyInEveryMode() async throws {
    for mode in [ToolCallingMode.text, .native, .xml, .json] {
      for stream in [false, true] {
        StubChatEndpoint.install()
        let conversation = conversation(mode: mode, stream: stream)
        // Exact first call from the exported failing chat, including the model's typo.
        replyWithCall("<|tool_call_start|>[web_search(query='author of rizen')]<|tool_call_end|>")
        let result = try await AssistantToolLoop.runIsolated(
          conversation: conversation, settings: store.settings, baseContext: "", store: store)
        XCTAssertEqual(StubChatEndpoint.searchQueries, ["author of rizen"], "\(mode), stream=\(stream)")
        XCTAssertEqual(result.toolRuns.map(\.name), ["web_search"], result.text)
        XCTAssertFalse(result.toolRuns.first?.isError ?? true, result.text)
        XCTAssertTrue(result.toolRuns.first?.result.contains("Rizin search fixture") ?? false)
        XCTAssertTrue(result.text.contains("Search completed from fixture."))
        XCTAssertEqual(StubChatEndpoint.requests.count, 2)
        let requests = StubChatEndpoint.requests
        let followup = try JSONSerialization.data(withJSONObject: requests[1])
        XCTAssertTrue(String(decoding: followup, as: UTF8.self).contains("Rizin search fixture"))
        XCTAssertFalse(result.text.contains("invalid_tool_call"))
        if mode == .native {
          let tools = requests[0]["tools"] as? [[String: Any]] ?? []
          let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
          XCTAssertFalse(names.contains("web_search"), "The proxy should still hide its schema")
          let messages = requests[1]["messages"] as? [[String: Any]] ?? []
          XCTAssertEqual(messages.filter { $0["role"] as? String == "tool" }.count, 1)
          XCTAssertFalse(String(decoding: followup, as: UTF8.self).contains("<|tool_call_start|>"))
        }
      }
    }
  }

  func testTextCallCanUseAnEnabledToolBehindProxy() async throws {
    let conversation = conversation()
    replyWithCall("TOOL_CALL\ntool: web_search\nquery: author of rizin\nEND_TOOL_CALL")
    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation, settings: store.settings, baseContext: "", store: store)
    XCTAssertEqual(StubChatEndpoint.searchQueries, ["author of rizin"])
    XCTAssertFalse(result.toolRuns.first?.isError ?? true, result.text)
  }

  func testChatToolCallingOverrideControlsRequestsAndCanReturnToDefault() async throws {
    for mode in ToolCallingMode.allCases {
      var chat = conversation(mode: mode == .native ? .xml : .native)
      let defaultMode = store.settings.toolCallingMode
      for override in [Optional(mode), nil] {
        StubChatEndpoint.install()
        chat.toolCallingMode = override
        StubChatEndpoint.script = { _ in
          (StubChatEndpoint.completion(content: "No tool needed."), 0)
        }
        _ = try await AssistantToolLoop.runIsolated(
          conversation: chat, settings: store.settings, baseContext: "", store: store)
        let request = try XCTUnwrap(StubChatEndpoint.requests.first)
        let effectiveMode = override ?? defaultMode
        let tools = request["tools"] as? [[String: Any]] ?? []
        XCTAssertEqual(!tools.isEmpty, effectiveMode == .native)
        let messages = try JSONSerialization.data(withJSONObject: request["messages"] ?? [])
        let prompt = String(decoding: messages, as: UTF8.self)
        switch effectiveMode {
        case .text: XCTAssertTrue(prompt.contains("TOOL_CALL"))
        case .xml: XCTAssertTrue(prompt.contains("<tool_call name="))
        case .json: XCTAssertTrue(prompt.contains("reply with exactly one JSON object"))
        case .native: break
        }
        XCTAssertEqual(store.settings.toolCallingMode, defaultMode)
      }
    }
  }

  func testNativeProxyAliasesCompleteDiscoveryAndSearch() async throws {
    let conversation = conversation(mode: .native)
    StubChatEndpoint.script = { _ in
      let turn = StubChatEndpoint.requests.count
      guard turn < 3 else {
        return (StubChatEndpoint.completion(content: "Search completed."), 0)
      }
      let name = turn == 1 ? "list_tools" : "call_tool"
      let arguments = turn == 1
        ? #"{"keywords":"web_search"}"#
        : #"{"name":"web_search","arguments":{"query":"author of rizin"}}"#
      return (["choices": [["index": 0, "finish_reason": "tool_calls", "message": [
        "role": "assistant", "content": "", "tool_calls": [[
          "id": "call_\(turn)", "type": "function",
          "function": ["name": name, "arguments": arguments],
        ]],
      ]]]], 0)
    }
    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation, settings: store.settings, baseContext: "", store: store)
    XCTAssertEqual(StubChatEndpoint.searchQueries, ["author of rizin"])
    XCTAssertEqual(result.toolRuns.map(\.name), [ToolProxy.listName, ToolProxy.callName])
    XCTAssertFalse(result.toolRuns.contains { $0.isError }, result.text)
    XCTAssertEqual(StubChatEndpoint.requests.count, 3)
    let tools = StubChatEndpoint.requests[0]["tools"] as? [[String: Any]] ?? []
    let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
    XCTAssertTrue(names.contains("list_tools") && names.contains("call_tool"))
    XCTAssertFalse(names.contains("list-tools") || names.contains("call-tool"))
  }

  func testHiddenToolStillRequiresApproval() async throws {
    let conversation = conversation()
    store.settings.toolPolicy.tools["web_search"] = .hidden
    store.settings.toolApprovalMode = .ask
    replyWithCall("<|tool_call_start|>[web_search(query='author of rizin')]<|tool_call_end|>")
    let task = Task {
      try await AssistantToolLoop.runIsolated(
        conversation: conversation, settings: store.settings, baseContext: "", store: store)
    }
    defer { task.cancel() }
    let deadline = Date().addingTimeInterval(10)
    while store.activeToolCallApprovalRequest == nil && Date() < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    let approval = try XCTUnwrap(store.activeToolCallApprovalRequest)
    XCTAssertEqual(approval.call.name, "web_search")
    XCTAssertTrue(StubChatEndpoint.searchQueries.isEmpty)
    store.cancelToolCallApproval(id: approval.id)
    let result = try await task.value
    XCTAssertTrue(StubChatEndpoint.searchQueries.isEmpty)
    XCTAssertTrue(result.toolRuns.first?.isError ?? false)
  }

  func testDisabledToolCannotExecuteThroughLFMEnvelope() async throws {
    var conversation = conversation()
    conversation.enabledTools.insert(.calculator)
    store.settings.toolPolicy.tools["web_search"] = .disabled
    replyWithCall("<|tool_call_start|>[web_search(query='author of rizin')]<|tool_call_end|>")
    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation, settings: store.settings, baseContext: "", store: store)
    XCTAssertTrue(StubChatEndpoint.searchQueries.isEmpty)
    XCTAssertTrue(result.toolRuns.first?.isError ?? false)
    XCTAssertTrue(result.toolRuns.first?.result.contains("not available") ?? false)
  }
}
