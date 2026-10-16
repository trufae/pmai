import Foundation
import Testing

@testable import MaiCore

@Test("Memory renders an envelope only when it has something to say")
func memoryPromptSection() {
  #expect(AgentMemory().promptSection == nil)
  #expect(AgentMemory(text: "   \n  ").promptSection == nil)

  var memory = AgentMemory(text: "Prefers Swift.")
  let section = memory.promptSection
  #expect(section?.contains("Prefers Swift.") == true)
  #expect(section?.contains("<user_preferences>") == true)
  // The envelope has to say the notes lose to the live conversation.
  #expect(section?.contains("the user's current messages and explicit instructions win") == true)

  // Learning is additive; forgetting is what replace is for.
  memory.append("Works on radare2.")
  #expect(memory.text == "Prefers Swift.\nWorks on radare2.")
  memory.append("   ")
  #expect(memory.lineCount == 2)
  memory.replace(with: "  Works on radare2.  ")
  #expect(memory.text == "Works on radare2.")
}

@Test("Memory round-trips through a file and leaves nothing behind when empty")
func memoryFileRoundTrip() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-memory-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent(AgentMemory.filename)

  #expect(try AgentMemory.load(from: url).isEmpty)
  try AgentMemory(text: "Lives in Barcelona.").save(to: url)
  #expect(try AgentMemory.load(from: url).text == "Lives in Barcelona.")
  #expect(try String(contentsOf: url, encoding: .utf8) == "Lives in Barcelona.\n")

  try AgentMemory(text: "").save(to: url)
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("A MaiCore chat projects into the shape the memory tools read")
func memoryChatProjection() {
  let chat = AgentChat(
    title: "Parser work",
    primaryAgent: AgentDefinition(id: "main", instructions: "Be terse.", provider: "p", model: "m"),
    messages: [
      .system("Be terse."),
      .user("where is the parser?"),
      AgentMessage(
        role: .assistant,
        content: [
          .toolCall(ToolCall(id: "c1", name: "files_grep", arguments: .object([:])))
        ]),
      AgentMessage(
        role: .tool,
        content: [.toolResult(ToolResult(callID: "c1", text: "Sources/Parser.swift"))]),
      AgentMessage(
        role: .assistant,
        content: [
          .text("In Sources/Parser.swift."),
          .file(FileContent(name: "notes.md", mimeType: "text/markdown", text: "keep it small")),
        ]),
    ])

  let projected = MemoryChat(chat, scope: "pocketmai")
  // Instructions and tool traffic are how the answer was reached, not what was
  // said, so they never become a source for memory.
  #expect(projected.entries.map(\.role) == ["user", "assistant"])
  #expect(projected.entries[1].text == "In Sources/Parser.swift.")
  #expect(projected.documents.map(\.name) == ["notes.md"])
  #expect(projected.scope == "pocketmai")
  #expect(projected.title == "Parser work")
  #expect(projected.shortID == String(chat.id.uuidString.prefix(8)).lowercased())
}

@Test("The chat tools list, search, and read other chats")
func memoryToolsReadOtherChats() {
  let chats = [
    MemoryChat(
      id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
      title: "Parser work",
      scope: "maicore",
      updatedAt: Date(timeIntervalSince1970: 2_000),
      entries: [
        .init(role: "user", text: "the parser lives in Sources/Parser.swift", date: .init())
      ],
      documents: [.init(name: "notes.md", text: "the parser is hand written")]),
    MemoryChat(
      id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
      title: "Release notes",
      scope: "maicore",
      updatedAt: Date(timeIntervalSince1970: 1_000),
      entries: [.init(role: "assistant", text: "shipped 1.6.0", date: .init())]),
  ]

  let listed = MaiMemoryTools.execute(name: "chats_list", arguments: [:], chats: chats)
  #expect(listed.contains("11111111 [maicore] Parser work"))
  #expect(listed.contains("Documents: notes.md"))
  #expect(
    MaiMemoryTools.execute(name: "chats_list", arguments: [:], chats: [])
      == "No other chats are available in this scope.")

  // Searching covers message text and attached documents alike.
  let found = MaiMemoryTools.execute(
    name: "chats_search", arguments: ["query": .string("parser")], chats: chats)
  #expect(found.contains("Sources/Parser.swift"))
  #expect(found.contains("[document notes.md]"))
  #expect(
    MaiMemoryTools.execute(
      name: "chats_search", arguments: ["query": .string("kubernetes")], chats: chats
    ).hasPrefix("No matches"))
  #expect(
    MaiMemoryTools.execute(name: "chats_search", arguments: [:], chats: chats)
      == "Error: query is required.")

  // A chat is addressable by id prefix or by title.
  let read = MaiMemoryTools.execute(
    name: "chats_read", arguments: ["chat": .string("1111")], chats: chats)
  #expect(read.contains("\"Parser work\""))
  #expect(read.contains("Sources/Parser.swift"))
  #expect(
    MaiMemoryTools.execute(
      name: "chats_read", arguments: ["chat": .string("Release")], chats: chats
    ).contains("shipped 1.6.0"))
  #expect(
    MaiMemoryTools.execute(
      name: "chats_read", arguments: ["chat": .string("nope")], chats: chats
    ).hasPrefix("Error: no chat matched"))

  let document = MaiMemoryTools.execute(
    name: "chats_read_document",
    arguments: ["chat": .string("1111"), "filename": .string("notes.md")],
    chats: chats)
  #expect(document.contains("the parser is hand written"))
  #expect(
    MaiMemoryTools.execute(
      name: "chats_read_document",
      arguments: ["chat": .string("2222"), "filename": .string("notes.md")],
      chats: chats
    ).contains("has no documents attached"))
  #expect(
    MaiMemoryTools.execute(name: "nope", arguments: [:], chats: chats)
      == "Error: unknown chats tool 'nope'.")
}

@Test("The learn prompt merges what is known with what was said")
func memoryLearnPrompt() throws {
  let chats = [
    MemoryChat(
      id: UUID(), title: "Old", updatedAt: Date(timeIntervalSince1970: 1_000),
      entries: [.init(role: "user", text: "older thing", date: .init())]),
    MemoryChat(
      id: UUID(), title: "New", updatedAt: Date(timeIntervalSince1970: 2_000),
      entries: [.init(role: "user", text: "newer thing", date: .init())]),
  ]

  // Newest first, so a token limit drops the stalest material, not the freshest.
  let transcript = AgentMemoryPrompt.transcript(of: chats)
  #expect(transcript == "user:\nnewer thing\n\nuser:\nolder thing")
  #expect(AgentMemoryPrompt.transcript(of: chats, limit: 20) == "user:\nnewer thing")

  let rendered = AgentMemoryPrompt.render(
    existing: AgentMemory(text: "Prefers Swift."),
    transcript: transcript,
    focus: "build tooling")
  #expect(rendered.contains("Prefers Swift."))
  #expect(rendered.contains("newer thing"))
  #expect(rendered.contains("Focus: build tooling"))
  #expect(!rendered.contains("{{"))

  let bare = AgentMemoryPrompt.render(existing: AgentMemory(), transcript: "x")
  #expect(bare.contains(AgentMemoryPrompt.emptyMemory))

  #expect(
    AgentMemoryPrompt.render(
      existing: AgentMemory(), transcript: "x", template: "Read: {{transcript}}")
      == "Read: x")
  #expect(AgentMemoryPrompt.missingPlaceholder(in: "Read: {{transcript}}") == nil)
  #expect(AgentMemoryPrompt.missingPlaceholder(in: "Read them") == "{{transcript}}")
  #expect(AgentMemoryPrompt.missingPlaceholder(in: " ") == nil)
}

@Test("Memory configuration defaults to on, this project only, and validates its prompt")
func memoryConfiguration() throws {
  var configuration = MaiConfiguration(providers: [ConfiguredProvider(id: "p", kind: .hello)])
  #expect(configuration.memory.enabled)
  #expect(configuration.memory.scope == .project)

  configuration.prompts = ConfiguredPrompts(memory: "Just remember it")
  #expect(
    throws: MaiConfigurationError.missingPromptPlaceholder(
      prompt: "memory", placeholder: "{{transcript}}")
  ) { try configuration.validate() }

  configuration.prompts = ConfiguredPrompts(memory: "Remember {{transcript}}")
  configuration.memory = ConfiguredMemory(enabled: false, scope: .all)
  try configuration.validate()
  let decoded = try JSONDecoder().decode(MaiConfiguration.self, from: try configuration.encoded())
  #expect(decoded.memory == ConfiguredMemory(enabled: false, scope: .all))
  #expect(decoded.prompts?.memory == "Remember {{transcript}}")

  // Files written before memory existed keep working.
  let legacy = try JSONDecoder().decode(
    MaiConfiguration.self,
    from: Data(#"{"version":1,"providers":[{"id":"p","kind":"hello"}]}"#.utf8))
  #expect(legacy.memory == ConfiguredMemory())
}

@Test("Memory reaches top-level runs and never a child agent")
func memoryReachesTopLevelRunsOnly() async throws {
  let provider = MemoryFixtureProvider()
  let runtime = AgentRuntime(approvalHandler: AllowAllApprovals())
  try await runtime.register(provider)
  try await runtime.register(
    tool: ClosureTool(
      definition: ToolDefinition(
        name: "read_file",
        description: "Read a file",
        annotations: ToolAnnotations(approval: .automatic))
    ) { _, _ in ToolOutput(text: "contents") })
  await runtime.configureMemory(AgentMemory(text: "Prefers Swift.").promptSection)

  _ = try await runtime.run(
    AgentRequest(
      agentID: "main",
      provider: "memory-fixture",
      model: "fixture",
      messages: [.system("Be terse."), .user("read it")],
      toolNames: AgentRuntime.agentToolNames.union(["read_file"]),
      toolGroupNames: [AgentRuntime.agentToolGroup.id],
      limits: AgentRunLimits(maxModelTurns: 4, maxToolCalls: 4, maxSubagents: 1),
      toolDelegation: .subagent))

  let requests = await provider.requests
  let parent = try #require(requests.first)
  #expect(parent.messages.map(\.role) == [.system, .system, .system, .user])
  #expect(parent.messages[1].text.contains("Prefers Swift."))
  // The stored transcript is untouched: memory is run-scoped context.
  #expect(parent.messages[0].text == "Be terse.")
  // Both sides carry the file tool, and the agent family too: the worker is
  // a peer, so its brief is what tells its request apart.
  let worker = try #require(
    requests.first { $0.messages.contains { $0.text.contains("running as agent '") } })
  #expect(!worker.messages.contains { $0.text.contains("Prefers Swift.") })

  // Clearing it costs the next run nothing.
  await runtime.configureMemory(nil)
  _ = try await runtime.run(
    AgentRequest(
      provider: "memory-fixture",
      model: "fixture",
      messages: [.system("Be terse."), .user("done")]))
  #expect(await provider.requests.last?.messages.map(\.role) == [.system, .user])
}

private actor MemoryFixtureProvider: ChatProvider {
  nonisolated let descriptor = ProviderDescriptor(
    id: "memory-fixture",
    displayName: "Memory fixture",
    capabilities: [.nativeToolCalling])
  private(set) var requests: [ProviderRequest] = []

  func complete(
    _ request: ProviderRequest,
    emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    requests.append(request)
    let results = request.messages.flatMap(\.toolResults)
    guard results.isEmpty else { return ProviderResponse(message: .assistant("done")) }
    // The parent has its own tools as well; it delegates whenever it can.
    guard
      let tool = request.tools.first(where: { $0.name == AgentRuntime.agentStartToolName })
        ?? request.tools.first
    else {
      return ProviderResponse(message: .assistant("done"))
    }
    let arguments: JSONValue =
      tool.name == AgentRuntime.agentStartToolName
      ? .object(["task": .string("read it"), "output": .string("the contents")])
      : .object([:])
    return ProviderResponse(
      message: AgentMessage(
        role: .assistant,
        content: [.toolCall(ToolCall(id: "c1", name: tool.name, arguments: arguments))]),
      stopReason: .toolCall)
  }
}
