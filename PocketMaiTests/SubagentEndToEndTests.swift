import Foundation
import MaiCore
import XCTest

@testable import PocketMai

/// A stand-in for an OpenAI-compatible endpoint, answering from a script that
/// looks at what the app sent. The default script plays one delegation: the
/// parent's first turn gets a tool call, the child's brief gets an answer,
/// and the parent's follow-up gets the answer echoed back. A test can install
/// a script of its own, and have a reply held back for a while, so overlap
/// between calls can be observed. It intercepts `URLSession.shared`, which is
/// what the OpenAI plugin uses, so no socket is opened.
final class StubChatEndpoint: URLProtocol {
  static let host = "stub.local"

  /// One chat request as it came in, and when it was answered.
  struct Entry {
    var request: [String: Any]
    var arrived: Date
    var answered: Date?

    /// The newest user message of the request, which is what the scripts
    /// look at: a brief for a child, a delivery for a parent.
    var lastUserText: String {
      let messages = request["messages"] as? [[String: Any]] ?? []
      return messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
    }
  }

  typealias Script = @Sendable ([String: Any]) -> (payload: [String: Any], delay: TimeInterval)

  nonisolated(unsafe) static var log: [Entry] = []
  nonisolated(unsafe) static var script: Script?
  private static let lock = NSLock()

  static var requests: [[String: Any]] {
    lock.withLock { log.map(\.request) }
  }

  static func install() {
    lock.withLock {
      log = []
      script = nil
    }
    URLProtocol.registerClass(StubChatEndpoint.self)
  }

  static func uninstall() {
    URLProtocol.unregisterClass(StubChatEndpoint.self)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == host
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  private final class Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
  }

  override func startLoading() {
    if request.url?.path.hasSuffix("/models") == true {
      finish(with: ["object": "list", "data": [["id": "stub"]]])
      return
    }
    let body = Self.body(of: request)
    let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let index = Self.lock.withLock { () -> Int in
      Self.log.append(Entry(request: json, arrived: Date(), answered: nil))
      return Self.log.count - 1
    }
    let reply = Self.script?(json) ?? (payload: Self.reply(to: json), delay: 0)
    let boxed = Unchecked((loader: self, payload: reply.payload))
    let answer: @Sendable () -> Void = {
      Self.lock.withLock { Self.log[index].answered = Date() }
      boxed.value.loader.finish(with: boxed.value.payload)
    }
    if reply.delay > 0 {
      DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: answer)
    } else {
      answer()
    }
  }

  override func stopLoading() {}

  private func finish(with payload: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let response = HTTPURLResponse(
      url: request.url!,
      statusCode: 200,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    client?.urlProtocolDidFinishLoading(self)
  }

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }

  /// The default script: one waited delegation.
  private static func reply(to request: [String: Any]) -> [String: Any] {
    let messages = request["messages"] as? [[String: Any]] ?? []
    if let toolResult = messages.last(where: { $0["role"] as? String == "tool" }) {
      let content = toolResult["content"] as? String ?? ""
      return completion(content: "Parent got: \(content)")
    }
    let lastUser = messages.last { $0["role"] as? String == "user" }
    let prompt = lastUser?["content"] as? String ?? ""
    if prompt.contains("## Task") {
      return completion(content: "Child answer")
    }
    return toolCalls([("call_1", ["task": "Say hi", "output": "Two words"])])
  }

  static func completion(content: String) -> [String: Any] {
    [
      "id": "stub-final",
      "object": "chat.completion",
      "choices": [
        [
          "index": 0,
          "finish_reason": "stop",
          "message": ["role": "assistant", "content": content],
        ]
      ],
    ]
  }

  /// A reply that calls `agent_start` once per entry, all in the same message.
  static func toolCalls(_ starts: [(id: String, arguments: [String: Any])]) -> [String: Any] {
    let calls = starts.map { start -> [String: Any] in
      let arguments = try! JSONSerialization.data(
        withJSONObject: start.arguments, options: [.sortedKeys])
      return [
        "id": start.id,
        "type": "function",
        "function": [
          "name": AgentProcessTools.startToolName,
          "arguments": String(decoding: arguments, as: UTF8.self),
        ],
      ]
    }
    return [
      "id": "stub-call",
      "object": "chat.completion",
      "choices": [
        [
          "index": 0,
          "finish_reason": "tool_calls",
          "message": [
            "role": "assistant",
            "content": "",
            "tool_calls": calls,
          ],
        ]
      ],
    ]
  }
}

/// The whole path a chat takes when its agent delegates: the parent calls
/// agent_start, a child conversation runs in its own task against the same
/// endpoint, its answer comes back as the tool result, and the supervisor
/// shows the child as this chat's, finished and collected. Two children
/// started in one reply run at once, and a child started without waiting
/// delivers its answer as a message.
@MainActor
final class SubagentEndToEndTests: XCTestCase {
  private var store: AppStore!

  override func setUp() async throws {
    try await super.setUp()
    StubChatEndpoint.install()
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("pocketmai-subagent-\(UUID().uuidString)", isDirectory: true)
    store = AppStore(persistence: PersistenceStore(localBaseURL: base))
    let deadline = Date().addingTimeInterval(20)
    while !store.hasLoadedPersistedSettings {
      XCTAssertLessThan(Date(), deadline, "settings never loaded")
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  override func tearDown() async throws {
    StubChatEndpoint.uninstall()
    store = nil
    try await super.tearDown()
  }

  /// What the stub recorded, one line per request — its roles and the start
  /// of its newest user message — for a failure message.
  private func requestShapes() -> String {
    StubChatEndpoint.log.enumerated().map { index, entry in
      let roles = (entry.request["messages"] as? [[String: Any]] ?? [])
        .compactMap { $0["role"] as? String }
        .joined(separator: ",")
      let user = entry.lastUserText.replacingOccurrences(of: "\n", with: " ").prefix(50)
      return "#\(index + 1) [\(roles)] user=\"\(user)\""
    }.joined(separator: "; ")
  }

  /// A chat on the stub endpoint whose agent may start children.
  private func makeDelegatingConversation() -> Conversation {
    let endpoint = OpenAIEndpoint(
      name: "Stub",
      baseURL: "https://\(StubChatEndpoint.host)/v1",
      apiKey: "stub",
      defaultModel: "stub",
      isEnabled: true)
    store.settings.openAIEndpoints = [endpoint]
    store.settings.defaultProvider = .openAICompatible
    store.settings.selectedEndpointID = endpoint.id
    store.settings.toolCallingMode = .native
    store.settings.yoloModeEnabled = true
    store.settings.agents[0].canSpawnSubagents = true
    XCTAssertTrue(store.settings.selectedAgent.canSpawnSubagents)

    var conversation = Conversation()
    conversation.provider = .openAICompatible
    conversation.endpointID = endpoint.id
    conversation.modelID = "stub"
    conversation.usesStreaming = false
    conversation.enabledTools = []
    conversation.enabledMCPServers = []
    conversation.messages = [ChatMessage(role: .user, text: "Delegate this")]
    return conversation
  }

  func testAgentStartRunsAChildAndHandsItsAnswerToTheParent() async throws {
    let conversation = makeDelegatingConversation()

    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation,
      settings: store.settings,
      baseContext: "",
      store: store)

    XCTAssertEqual(result.text, "Parent got: Child answer")
    XCTAssertEqual(result.toolRuns.map(\.name), [AgentProcessTools.startToolName])
    XCTAssertEqual(result.toolRuns.first?.result, "Child answer")
    XCTAssertFalse(result.toolRuns.first?.isError ?? true)

    // Three model calls: the parent's, the child's, and the parent's again.
    XCTAssertEqual(StubChatEndpoint.requests.count, 3)
    let childRequest = StubChatEndpoint.requests[1]
    let childMessages = childRequest["messages"] as? [[String: Any]] ?? []
    let childPrompt = childMessages.last { $0["role"] as? String == "user" }?["content"] as? String
    XCTAssertTrue(childPrompt?.contains("## Task\n\nSay hi") == true, childPrompt ?? "")
    XCTAssertTrue(childPrompt?.contains("running as agent 'Main.worker'") == true)
    let childSystem =
      childMessages.first { $0["role"] as? String == "system" }?["content"] as? String
    XCTAssertTrue(childSystem?.contains("focused worker agent") == true, childSystem ?? "")
    // The worker is a peer: it gets the parent's tools and may delegate in
    // turn, since one level down is still above the depth limit.
    let childTools = (childRequest["tools"] as? [[String: Any]] ?? []).compactMap {
      ($0["function"] as? [String: Any])?["name"] as? String
    }
    XCTAssertTrue(childTools.contains(AgentProcessTools.startToolName), "\(childTools)")

    // The supervisor lists the child under the chat's own process, done and taken.
    await store.refreshAgentProcesses()
    let children = store.agentChildren(of: conversation.id)
    XCTAssertEqual(children.count, 1)
    let child = try XCTUnwrap(children.first)
    XCTAssertEqual(child.agentID, "Main.worker")
    XCTAssertEqual(child.displayName, "Main worker")
    XCTAssertEqual(child.state, .completed)
    XCTAssertTrue(child.isCollected)
    XCTAssertEqual(child.depth, 1)
    XCTAssertEqual(child.task, "Say hi")
    XCTAssertEqual(child.modelTurns, 1)
    let transcript = await store.agentTranscript(child.pid)
    XCTAssertEqual(transcript.map(\.role), [.user, .assistant])
    XCTAssertEqual(transcript.last?.text, "Child answer")
    XCTAssertFalse(store.hasLiveAgentChildren(in: conversation.id))
  }

  func testChildrenStartedInOneReplyRunAtOnce() async throws {
    let conversation = makeDelegatingConversation()
    // Each child's reply is held back long enough for the other child's
    // request to arrive meanwhile — if the second start waited for the first
    // to finish, it could not.
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let toolResults = messages.filter { $0["role"] as? String == "tool" }
      if !toolResults.isEmpty {
        let answers = toolResults.compactMap { $0["content"] as? String }.joined(separator: " + ")
        return (StubChatEndpoint.completion(content: "Parent got: \(answers)"), 0)
      }
      let prompt = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      if let range = prompt.range(of: "## Task\n\n") {
        let task = prompt[range.upperBound...].prefix { !$0.isNewline }
        return (StubChatEndpoint.completion(content: "Done \(task)"), 0.4)
      }
      return (
        StubChatEndpoint.toolCalls([
          ("call_a", ["task": "A", "output": "One word"]),
          ("call_b", ["task": "B", "output": "One word"]),
        ]), 0
      )
    }

    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation,
      settings: store.settings,
      baseContext: "",
      store: store)

    // Both answers reach the parent, in the order the calls were made.
    XCTAssertEqual(result.text, "Parent got: Done A + Done B")
    XCTAssertEqual(result.toolRuns.map(\.result), ["Done A", "Done B"])

    let children = StubChatEndpoint.log.filter { $0.lastUserText.contains("## Task") }
    XCTAssertEqual(children.count, 2)
    let arrivals = children.map(\.arrived)
    let answers = children.compactMap(\.answered)
    XCTAssertEqual(answers.count, 2)
    let lastArrival = try XCTUnwrap(arrivals.max())
    let firstAnswer = try XCTUnwrap(answers.min())
    XCTAssertLessThan(
      lastArrival, firstAnswer,
      "the second child was asked only after the first had answered")

    // Both hang off the chat's one process. Pids go to whichever start
    // reached the supervisor first, so their order is not the call order.
    await store.refreshAgentProcesses()
    let processes = store.agentChildren(of: conversation.id)
    XCTAssertEqual(Set(processes.map(\.task)), ["A", "B"])
    XCTAssertEqual(processes.map(\.state), [.completed, .completed])
    XCTAssertTrue(processes.allSatisfy(\.isCollected))
  }

  func testAChildStartedWithoutWaitingDeliversItsAnswerAsAMessage() async throws {
    let conversation = makeDelegatingConversation()
    StubChatEndpoint.script = { request in
      let messages = request["messages"] as? [[String: Any]] ?? []
      let lastUser = messages.last { $0["role"] as? String == "user" }?["content"] as? String ?? ""
      if lastUser.contains("## Task") {
        return (StubChatEndpoint.completion(content: "Child answer"), 0.3)
      }
      if lastUser.contains("finished. Its answer:") {
        return (StubChatEndpoint.completion(content: "Parent read: \(lastUser)"), 0)
      }
      if messages.contains(where: { $0["role"] as? String == "tool" }) {
        return (StubChatEndpoint.completion(content: "Waiting for the child."), 0)
      }
      return (
        StubChatEndpoint.toolCalls([
          ("call_1", ["task": "Say hi", "output": "Two words", "wait": false])
        ]), 0
      )
    }

    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation,
      settings: store.settings,
      baseContext: "",
      store: store)

    // The start answered at once; the answer came later as a message, which
    // the parent read without ever calling agent_result. Nothing here indexes
    // into what was recorded: the child's and the parent's requests can come
    // in either order, and a run that ended early recorded fewer of them.
    let shapes = requestShapes()
    XCTAssertEqual(result.toolRuns.map(\.name), [AgentProcessTools.startToolName])
    let started = result.toolRuns.first?.result ?? ""
    XCTAssertTrue(started.hasPrefix("Started Main.worker as #"), started)
    // Four model calls: the parent's, the child's, the parent's "waiting",
    // and the parent's reading of the delivery.
    XCTAssertEqual(StubChatEndpoint.requests.count, 4, "requests: \(shapes)")
    let deliveryRequest = StubChatEndpoint.log.first {
      $0.lastUserText.contains("finished. Its answer:")
    }
    XCTAssertNotNil(deliveryRequest, "no request carried the delivery; requests: \(shapes)")
    if let deliveryRequest {
      XCTAssertTrue(deliveryRequest.lastUserText.hasPrefix("Agent #"), deliveryRequest.lastUserText)
      XCTAssertTrue(
        deliveryRequest.lastUserText.contains("Child answer"), deliveryRequest.lastUserText)
    }
    // The parent's follow-up — the last request made — carries the delivery
    // text as its newest user message, after the turn that started the child.
    let followUp = StubChatEndpoint.log.last
    XCTAssertTrue(followUp?.lastUserText.contains("finished. Its answer:") == true, shapes)
    let followUpTexts = (followUp?.request["messages"] as? [[String: Any]] ?? [])
      .compactMap { $0["content"] as? String }
    XCTAssertTrue(
      followUpTexts.contains { $0.contains("Started Main.worker as #") },
      "follow-up messages: \(followUpTexts.map { $0.prefix(60) })")
    XCTAssertTrue(result.text.hasPrefix("Parent read: Agent #"), result.text)
    XCTAssertTrue(
      result.text.contains("(Main.worker) finished. Its answer:\nChild answer"), result.text)
    let messages = result.conversation.messages
    XCTAssertEqual(
      messages.map(\.role), [.user, .assistant, .user, .assistant],
      "messages: \(messages.map { "\($0.role): \($0.text.prefix(60))" })")
    XCTAssertTrue(
      messages.contains { $0.role == .assistant && $0.text.contains("Waiting for the child.") },
      "no waiting turn; messages: \(messages.map(\.text))")
    XCTAssertTrue(
      messages.contains {
        $0.role == .user && $0.text.contains("finished. Its answer:\nChild answer")
      },
      "no delivery message; messages: \(messages.map(\.text))")

    await store.refreshAgentProcesses()
    let child = try XCTUnwrap(store.agentChildren(of: conversation.id).first)
    XCTAssertEqual(child.state, .completed)
    XCTAssertTrue(child.isCollected)
    XCTAssertNil(child.attention)
    let root = try XCTUnwrap(store.agentProcessIDs[conversation.id])
    let queued = await store.agentSupervisor.hasQueuedMessages(root)
    XCTAssertFalse(queued)
  }
  func testToolTaskAgentUsesItsModelAndEffortThenHandsOffToPrimary() async throws {
    var conversation = makeDelegatingConversation()
    store.settings.agents[0].canSpawnSubagents = false
    conversation.enabledTools = [.calculator]
    conversation.modelID = "large"
    conversation.reasoningLevel = .high
    store.settings.openAIModelID = "small"
    store.settings.defaultReasoningLevel = .low
    store.settings.streamByDefault = false
    let fast = store.settings.addAgent(named: "Fast")
    store.settings.taskAgents.tool = fast.id.uuidString.lowercased()
    StubChatEndpoint.script = { request in
      if request["model"] as? String == "large" {
        return (StubChatEndpoint.completion(content: "Main answer: 4"), 0)
      }
      let messages = request["messages"] as? [[String: Any]] ?? []
      if messages.contains(where: { $0["role"] as? String == "tool" }) {
        return (StubChatEndpoint.completion(content: "private specialist draft"), 0)
      }
      return (
        [
          "id": "calc", "object": "chat.completion",
          "choices": [
            [
              "index": 0, "finish_reason": "tool_calls",
              "message": [
                "role": "assistant", "content": "",
                "tool_calls": [
                  [
                    "id": "calc-1", "type": "function",
                    "function": [
                      "name": "calc", "arguments": "{\"expression\":\"2+2\"}",
                    ],
                  ]
                ],
              ],
            ]
          ],
        ], 0
      )
    }
    let result = try await AssistantToolLoop.runIsolated(
      conversation: conversation, settings: store.settings, baseContext: "", store: store)
    XCTAssertEqual(result.text, "Main answer: 4")
    XCTAssertEqual(result.toolRuns.count, 1)
    let requests = StubChatEndpoint.requests
    XCTAssertEqual(requests.compactMap { $0["model"] as? String }, ["small", "small", "large"])
    XCTAssertEqual(requests.first?["reasoning_effort"] as? String, "low")
    XCTAssertEqual(requests.last?["reasoning_effort"] as? String, "high")
    XCTAssertNil(requests.last?["tools"])
    let finalMessages = requests.last?["messages"] as? [[String: Any]] ?? []
    XCTAssertTrue(finalMessages.contains { ($0["content"] as? String)?.contains("4") == true })
    XCTAssertFalse(
      finalMessages.contains {
        ($0["content"] as? String)?.contains("private specialist draft") == true
      })
  }

  func testCreatingTaskProfilesDoesNotSwitchTheDefaultAgent() {
    let selected = store.settings.selectedAgentID
    let agent = store.addAgent(
      named: "Compactor", description: "Summarizes", canSpawnSubagents: false)
    XCTAssertNotEqual(agent.id, selected)
    XCTAssertEqual(store.settings.selectedAgentID, selected)
    XCTAssertTrue(store.settings.agents.contains { $0.id == agent.id })
  }

}
