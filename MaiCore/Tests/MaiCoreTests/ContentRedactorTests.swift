import Foundation
import Testing

@testable import MaiCore
@testable import MaiTestSupport

@Test(
  "Redaction is case insensitive, reversible, non-cascading, and preserves distinct regex matches")
func redactionRules() throws {
  let rules = try ContentRedactor.parse(
    """
    # Private words
    alice=person
    /\\b(?:\\d{4}[- ]){3}\\d{4}\\b/=card
    /(?<=account=)[a-z]+/
    """)
  let redactor = ContentRedactor(rules: rules)
  let text = "Alice ALICE alice: 4111-1111-1111-1111 and 5555 5555 5555 4444; account=secret"
  let filtered = redactor.redact(text)
  #expect(!filtered.lowercased().contains("alice"))
  // Opaque UUID placeholders can contain four-digit fragments of a card number.
  #expect(!filtered.contains("4111-1111-1111-1111"))
  #expect(!filtered.contains("5555 5555 5555 4444") && !filtered.contains("secret"))
  #expect(redactor.unredact(filtered) == text)
  #expect(redactor.redact(text) == filtered)
  #expect(redactor.redact(filtered) == filtered)
  #expect(ContentRedactor(rules: rules).unredact(filtered) == filtered)
  #expect(redactor.unredact("<REDACT> person") == "<REDACT> person")
  let broad = ContentRedactor(rules: try ContentRedactor.parse("alice\n/private.*/"))
  let existing = broad.redact("Alice")
  let mixed = "private \(existing) fresh-secret"
  let masked = broad.redact(mixed)
  #expect(!masked.contains("fresh-secret"))
  #expect(broad.unredact(masked) == "private Alice fresh-secret")
  let overlapping = ContentRedactor(rules: try ContentRedactor.parse("abc\nbcde"))
  #expect(overlapping.unredact(overlapping.redact("abcde")) == "abcde")
  #expect(!overlapping.redact("abcde").hasSuffix("de"))
  #expect(throws: ContentRedactor.InvalidRule.self) {
    try ContentRedactor.parse("valid\n/[broken/")
  }
  #expect(try ContentRedactor.parse("# comments\n \n").isEmpty)
  let zero = ContentRedactor(rules: try ContentRedactor.parse("/^/"))
  #expect(zero.redact("unchanged") == "unchanged")
}

@Test("Redaction preserves structured tool results and redacts nested arguments and attachments")
func redactionStructuredMessages() throws {
  let redactor = ContentRedactor(rules: try ContentRedactor.parse("secret"))
  let image = ContentPart.image(.init(source: .data(Data([1, 2])), mimeType: "image/png"))
  let messages = [
    AgentMessage(
      role: .user,
      content: [
        .text("SECRET"), .reasoning("Secret"), image,
        .file(.init(name: "secret.txt", mimeType: "text/plain", text: "secret")),
        .resource(.init(uri: "file:///secret", text: "secret")),
        .toolCall(
          .init(id: "call", name: "read", arguments: .object(["path": .string("/secret/file")]))),
        .toolResult(
          .init(
            callID: "call", content: [.text("secret"), image],
            structuredContent: .object([
              "secret": .array([.object(["value": .string("SECRET")])])
            ]))),
      ])
  ]
  let filtered = redactor.redact(ProviderRequest(model: "test", messages: messages))
  #expect(filtered.count > 0)
  let output = try #require(filtered.request.messages.first?.toolResults.first)
  #expect(output.content.count == 2 && output.content[1] == image)
  #expect(output.structuredContent != nil)
  #expect(
    !String(decoding: try JSONEncoder().encode(filtered.request.messages), as: UTF8.self)
      .lowercased().contains("secret"))
  #expect(redactor.unredact(filtered.request.messages) == messages)
}

private actor RedactionApprovals: ApprovalHandler {
  let mode: ToolApprovalMode
  var calls: [ToolCall] = []
  init(_ mode: ToolApprovalMode) { self.mode = mode }
  func toolApprovalMode() -> ToolApprovalMode? { mode }
  func decide(_ request: ApprovalRequest) -> ApprovalDecision {
    calls.append(request.call)
    return .approve(arguments: request.call.arguments)
  }
}

private actor RedactionWarnings {
  var counts: [Int] = []
  func record(_ count: Int) { counts.append(count) }
}

private func redactionFile(_ contents: String) throws -> URL {
  let file = FileManager.default.temporaryDirectory.appendingPathComponent(
    "redaction-\(UUID()).txt")
  try contents.write(to: file, atomically: true, encoding: .utf8)
  return file
}

@Test(
  "Tool execution restores arguments before approvals, while every inference stays redacted",
  arguments: ["native", "json", "proxy"], [ToolApprovalMode.ask, .smart])
func redactionToolBoundary(variant: String, approval: ToolApprovalMode) async throws {
  let strategy: ToolCallingStrategy = variant == "json" ? .json : .native
  let file = try redactionFile("alice\n/\\b(?:\\d{4}-){3}\\d{4}\\b/")
  defer { try? FileManager.default.removeItem(at: file) }
  let approvals = RedactionApprovals(approval)
  let runtime = AgentRuntime(approvalHandler: approvals)
  let warnings = RedactionWarnings()
  try await runtime.configureRedaction(.warn, file: file) { await warnings.record($0) }
  let redactor = await runtime.contentRedactor(sessionID: "chat")
  let token = redactor.redact("Alice")
  let original: JSONValue = .object(["path": .string("/Users/Alice/file")])
  var call = ToolCall(
    id: "read", name: "probe", arguments: .object(["path": .string("/Users/\(token)/file")]))
  let maskedArguments = call.arguments
  if variant == "proxy" {
    call.name = ToolProxy.callName
    call.arguments = .object(["name": .string("probe"), "arguments": call.arguments])
  }
  let first =
    strategy == .native
    ? AgentMessage(role: .assistant, content: [.toolCall(call)])
    : .assistant("{\"name\":\"probe\",\"arguments\":{\"path\":\"/Users/\(token)/file\"}}")
  var responses = [ProviderResponse(message: first, stopReason: .toolCall)]
  if approval == .smart {
    responses.append(.init(message: .assistant(#"{"decision":"allow","reason":"Approved"}"#)))
  }
  responses.append(.init(message: .assistant("Done"), stopReason: .stop))
  let provider = ScriptedProvider(responses: responses)
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: .init(
        name: "probe", description: "Read Alice's data",
        parameters: [
          .init(name: "path", type: "string", description: "Path", required: true)
        ])
    ) { arguments, _ in
      #expect(arguments == original)
      return ToolOutput(
        content: [.text("Alice: 4111-1111-1111-1111")],
        structuredContent: .object([
          "owner": .string("ALICE"), "card": .string("5555-5555-5555-4444"),
        ]))
    })
  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("Read /Users/Alice/file")],
      toolNames: ["probe"], toolCallingStrategy: strategy, useToolProxy: variant == "proxy",
      proxyExposedTools: [], retry: .init(attempts: 0),
      sessionID: "chat"))
  #expect(result.response.text == "Done")
  let requests = await provider.requests
  #expect(requests.count == (approval == .smart ? 3 : 2))
  for request in requests {
    let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    #expect(!wire.lowercased().contains("alice"))
    #expect(!wire.contains("4111-1111-1111-1111"))
    #expect(!wire.contains("5555-5555-5555-4444"))
  }
  #expect(result.transcript.flatMap(\.toolCalls).first?.arguments == call.arguments)
  #expect(result.transcript.flatMap(\.toolResults).first?.text.contains("Alice") == true)
  if approval == .ask {
    #expect(await approvals.calls.first?.arguments == original)
  } else {
    #expect(requests[1].approvalReview?.arguments == maskedArguments)
  }
  #expect(await warnings.counts.count == requests.count)
}

@Test("Redaction modes persist, rule reloads fail closed, and chat token tables stay isolated")
func redactionModesAndReload() async throws {
  #expect(try JSONDecoder().decode(MaiConfiguration.self, from: Data("{}".utf8)).redact == .off)
  for mode in RedactionMode.allCases {
    let encoded = try JSONEncoder().encode(MaiConfiguration(redact: mode))
    #expect(try JSONDecoder().decode(MaiConfiguration.self, from: encoded).redact == mode)
  }
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self, from: Data(#"{"redact":"/tmp/rules"}"#.utf8))
  #expect(legacy.redact == .off)
  let file = try redactionFile("alice")
  defer { try? FileManager.default.removeItem(at: file) }
  let runtime = AgentRuntime()
  let warnings = RedactionWarnings()
  let provider = ScriptedProvider(
    responses: Array(repeating: .init(message: .assistant("OK")), count: 4))
  try await runtime.register(provider)
  let request = AgentRequest(
    provider: "scripted", model: "fixture", messages: [.user("Alice")], sessionID: "one")
  try await runtime.configureRedaction(.on, file: file) { await warnings.record($0) }
  _ = try await runtime.run(request)
  let first = await runtime.contentRedactor(sessionID: "one")
  let token = first.redact("Alice")
  let second = await runtime.contentRedactor(sessionID: "two")
  #expect(second.unredact(token) == token)
  try await runtime.configureRedaction(.off)
  _ = try await runtime.run(request)
  try await runtime.configureRedaction(.warn)
  _ = try await runtime.run(request)
  try "/[invalid/".write(to: file, atomically: true, encoding: .utf8)
  await #expect(throws: ContentRedactor.InvalidRule.self) {
    try await runtime.configureRedaction(.on)
  }
  _ = try await runtime.run(request)
  let texts = await provider.requests.map { $0.messages.first { $0.role == .user }?.text }
  #expect(texts == [token, "Alice", token, token])
  #expect(await warnings.counts == [1, 1])
  try "bob".write(to: file, atomically: true, encoding: .utf8)
  try await runtime.configureRedaction(.on)
  #expect(first.redact("Alice") == "Alice")
  #expect(first.redact("Bob") != "Bob")
  #expect(first.unredact(token) == "Alice")
}

@Test("Sensitive numeric JSON values restore as numbers without confusing identical text")
func redactionNumericValues() throws {
  let redactor = ContentRedactor(rules: try ContentRedactor.parse("/\\b\\d{16}\\b/"))
  let arguments: JSONValue = .object([
    "numeric": .integer(4_111_111_111_111_111), "text": .string("4111111111111111"),
    "limit": .integer(10),
  ])
  let messages = [
    AgentMessage(
      role: .assistant,
      content: [
        .toolCall(.init(id: "call", name: "probe", arguments: arguments))
      ])
  ]
  let filtered = redactor.redact(ProviderRequest(model: "fixture", messages: messages))
  let call = try #require(filtered.request.messages.first?.toolCalls.first)
  #expect(!call.arguments.compactJSONString.contains("4111111111111111"))
  #expect(redactor.unredact(call.arguments) == arguments)
  #expect(redactor.unredact(filtered.request.messages) == messages)
}

@Test("Streaming restores placeholders split anywhere across text and reasoning deltas")
func redactionStreaming() async throws {
  let redactor = ContentRedactor(rules: try ContentRedactor.parse("alice"))
  let hidden = redactor.redact("Hello Alice!")
  let stream = RedactionStream(redactor)
  var visible = ""
  var thought = ""
  for character in hidden {
    if case .textDelta(let text) = await stream.feed(.textDelta(String(character))) {
      visible += text
    }
    if case .reasoningDelta(let text) = await stream.feed(.reasoningDelta(String(character))) {
      thought += text
    }
  }
  for event in await stream.finish() {
    if case .textDelta(let text) = event { visible += text }
    if case .reasoningDelta(let text) = event { thought += text }
  }
  #expect(visible == "Hello Alice!")
  #expect(thought == visible)
}

@Test("Child agents inherit redaction without sharing token tables with unrelated chats")
func redactionChildren() async throws {
  let file = try redactionFile("alice")
  defer { try? FileManager.default.removeItem(at: file) }
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.configureRedaction(.on, file: file)
  let redactor = await runtime.contentRedactor(sessionID: "parent")
  let token = redactor.redact("Alice")
  let provider = ScriptedProvider(responses: [
    .init(
      message: AgentMessage(
        role: .assistant,
        content: [
          .toolCall(
            .init(
              id: "child", name: AgentProcessTools.startToolName,
              arguments: .object([
                "agent": .string("worker"), "task": .string("Help \(token)"), "wait": .bool(true),
                "output": .string("One line"),
              ])))
        ]), stopReason: .toolCall),
    .init(message: .assistant("Helped \(token)"), stopReason: .stop),
    .init(message: .assistant("Done"), stopReason: .stop),
  ])
  try await runtime.register(provider)
  try await runtime.register(
    agent: .init(id: "worker", instructions: "Help Alice", provider: "scripted", model: "fixture"))
  let result = try await runtime.run(
    AgentRequest(
      provider: "scripted", model: "fixture", messages: [.user("Help Alice")],
      toolNames: [AgentProcessTools.startToolName], subagentNames: ["worker"], sessionID: "parent"))
  #expect(result.response.text == "Done")
  let requests = await provider.requests
  #expect(requests.count == 3)
  for request in requests {
    let wire = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    #expect(!wire.lowercased().contains("alice"))
    #expect(wire.contains(token))
  }
  let root = try #require(await runtime.supervisor.tree().processes.first { $0.depth == 0 })
  let records = redactor.unredact(await runtime.supervisor.records(under: root.pid))
  #expect(!records.isEmpty)
  #expect(!String(decoding: try JSONEncoder().encode(records), as: UTF8.self).contains(token))
}

@Test("Approval request serialization cannot hide escaped secrets from the filter")
func redactionEscapedApproval() throws {
  let secret = "private\"name"
  let redactor = ContentRedactor(rules: try ContentRedactor.parse(secret))
  let review = ToolApprovalReview(
    tool: .init(name: "probe", description: "Read"), arguments: .object(["path": .string(secret)]),
    task: secret, environment: .init(workingDirectory: "/work", allowedPaths: [], sandbox: ""))
  let filtered = redactor.redact(SmartToolApproval.request(review: review, model: "fixture"))
  let user = try #require(filtered.request.messages.first { $0.role == .user })
  let state = try JSONDecoder().decode(JSONValue.self, from: Data(user.text.utf8))
  #expect(state == filtered.request.approvalReview?.state)
  #expect(redactor.unredact(state) == review.state)
  #expect(!user.text.contains("private"))
}
