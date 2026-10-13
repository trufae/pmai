import MaiCore
import MaiStandardTools
import XCTest

@testable import PocketMai

/// Duplicate tool names used to crash the app: MCP tools are registered under
/// their raw names, so two servers exposing the same tool name (or a tool
/// named like a built-in) produced duplicate definitions, and the by-name
/// dictionary in AgentTooling.normalized trapped on the duplicate key.
/// The catalog now keeps the first definition per name — built-ins, then
/// servers in settings order — matching dispatch resolution order.
final class ToolCatalogDuplicateNameTests: XCTestCase {
  @MainActor
  func testHiddenToolsRemainCallableWithoutBeingListed() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "hidden-tools-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root))
    var settings = AppSettings()
    settings.useToolProxy = false
    settings.toolPolicy.groups[BuiltInToolID.calculator.rawValue] = .hidden
    var conversation = Conversation()
    conversation.enabledTools = [.calculator]
    let catalog = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    XCTAssertTrue(catalog.enabledDefinitions.contains { $0.name == MaiCalculatorTool.name })
    XCTAssertTrue(catalog.listedDefinitions.isEmpty)
    XCTAssertEqual(catalog.summary().hidden, 1)
    XCTAssertEqual(catalog.visibleDefinitions.map(\.name), [ToolProxy.listName, ToolProxy.callName])
    XCTAssertFalse(catalog.visibleDefinitions.map(\.description).joined().contains(MaiCalculatorTool.name))
    let listing = await ToolAgentRegistry.execute(
      call: ParsedToolCall(name: ToolProxy.listName,
        arguments: ["keywords": MaiCalculatorTool.name], rawBlock: ""),
      conversation: conversation, settings: settings, store: store)
    XCTAssertFalse(listing.contains("- \(MaiCalculatorTool.name):"))
    let direct = await ToolAgentRegistry.execute(
      call: ParsedToolCall(name: MaiCalculatorTool.name,
        arguments: ["expression": "2+3"], rawBlock: ""),
      conversation: conversation, settings: settings, store: store)
    XCTAssertEqual(direct, "5")
    let proxied = await ToolAgentRegistry.execute(
      call: ParsedToolCall(name: ToolProxy.callName, arguments: [:], argumentValues: [
        "name": .string(MaiCalculatorTool.name),
        "arguments": .object(["expression": .string("3*4")]),
      ], rawBlock: ""), conversation: conversation, settings: settings, store: store)
    XCTAssertEqual(proxied, "12")
    conversation.toolsEnabled = false
    let disabled = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    XCTAssertTrue(disabled.enabledDefinitions.isEmpty)
    XCTAssertTrue(disabled.visibleDefinitions.isEmpty)
  }

  @MainActor
  func testMixedExposureKeepsDisabledToolsOutOfBothCatalogs() {
    var settings = AppSettings()
    var conversation = Conversation()
    conversation.enabledTools = [.todo, .calculator]
    settings.toolPolicy.groups[BuiltInToolID.todo.rawValue] = .proxy
    settings.toolPolicy.tools[TodoTool.toolNames.first!] = .disabled
    settings.toolPolicy.tools[MaiCalculatorTool.name] = .direct
    let catalog = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    let todo = catalog.groups.first { $0.id == BuiltInToolID.todo.rawValue }!
    XCTAssertEqual(todo.toolNames, Set(TodoTool.toolNames))
    XCTAssertEqual(catalog.summary(for: todo).disabled, 1)
    XCTAssertEqual(catalog.summary(for: todo).proxy, TodoTool.toolNames.count - 1)
    XCTAssertFalse(catalog.enabledDefinitions.contains { $0.name == TodoTool.toolNames.first! })
    XCTAssertEqual(
      Set(catalog.visibleDefinitions.map(\.name)),
      [MaiCalculatorTool.name, ToolProxy.listName, ToolProxy.callName])
    settings.useToolProxy = true
    XCTAssertEqual(
      Set(ToolAgentRegistry.visibleDefinitions(for: conversation, settings: settings).map(\.name)),
      [MaiCalculatorTool.name, ToolProxy.listName, ToolProxy.callName])
    settings.toolPolicy.tools.removeAll()
    settings.toolPolicy.groups.removeAll()
    let inherited = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    XCTAssertEqual(inherited.summary().proxy, TodoTool.toolNames.count + 1)
    XCTAssertEqual(
      inherited.summary().disabled, inherited.summary().total - TodoTool.toolNames.count - 1)
  }

  @MainActor
  func testPinsCannotBypassOfflineWorkspaceOrMasterSwitch() {
    var settings = AppSettings()
    var conversation = Conversation()
    settings.toolPolicy.groups = ["files": .direct, "github": .direct, "calculator": .proxy]
    settings.airplaneModeEnabled = true
    var catalog = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    let files = catalog.groups.first { $0.id == "files" }!
    XCTAssertFalse(files.toolNames.isEmpty)
    XCTAssertEqual(catalog.summary(for: files).enabled, 0)
    XCTAssertFalse(
      catalog.enabledDefinitions.contains {
        $0.name.hasPrefix("files_") || $0.name.hasPrefix("github_")
      })
    XCTAssertTrue(catalog.enabledDefinitions.contains { $0.name == MaiCalculatorTool.name })
    conversation.toolsEnabled = false
    catalog = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    XCTAssertTrue(catalog.enabledDefinitions.isEmpty)
    XCTAssertTrue(catalog.visibleDefinitions.isEmpty)
  }

  @MainActor
  func testMixedDirectAndProxyExecuteAndDisabledTargetsAreRejected() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mixed-tools-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root))
    var settings = AppSettings()
    settings.toolPolicy.tools = [MaiCalculatorTool.name: .proxy]
    var conversation = Conversation()
    conversation.enabledTools = [.calculator]
    let proxied = ParsedToolCall(
      name: ToolProxy.callName, arguments: [:],
      argumentValues: [
        "name": .string(MaiCalculatorTool.name),
        "arguments": .object(["expression": .string("2+3")]),
      ],
      rawBlock: "")
    let proxyResult = await ToolAgentRegistry.execute(
      call: proxied, conversation: conversation, settings: settings, store: store)
    XCTAssertEqual(proxyResult, "5")
    settings.useToolProxy = true
    settings.toolPolicy.tools[MaiCalculatorTool.name] = .direct
    let direct = ParsedToolCall(
      name: MaiCalculatorTool.name, arguments: ["expression": "3*4"], rawBlock: "")
    let directResult = await ToolAgentRegistry.execute(
      call: direct, conversation: conversation, settings: settings, store: store)
    XCTAssertEqual(directResult, "12")
    settings.toolPolicy.tools[MaiCalculatorTool.name] = .disabled
    let deniedDirect = await ToolAgentRegistry.execute(
      call: direct, conversation: conversation, settings: settings, store: store)
    let deniedProxy = await ToolAgentRegistry.execute(
      call: proxied, conversation: conversation, settings: settings, store: store)
    XCTAssertTrue(deniedDirect.hasPrefix("Error:"))
    XCTAssertTrue(deniedProxy.hasPrefix("Error:"))
  }

  func testVectorDatabaseIndexesAndQueriesOnIOS() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "ios-vdb-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("func renewCredentials() { return refreshToken }\n".utf8).write(
      to: root.appendingPathComponent("Auth.swift"))
    let tool = MaiVectorDatabaseTool(configuration: MaiFileWorkspaceConfiguration(rootURL: root))
    let context = ToolExecutionContext(
      run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
      modelTurn: 0)
    let index = try await tool.call(
      arguments: .object(["action": .string("index")]), context: context)
    XCTAssertFalse(index.isError, index.text)
    let query = try await tool.call(
      arguments: .object(["query": .string("renew credentials")]), context: context)
    XCTAssertFalse(query.isError, query.text)
    XCTAssertTrue(query.text.contains("Auth.swift:1-1"))
  }

  @MainActor
  func testVectorDatabaseCatalogUsesWorkspaceAccessAndWorksOffline() {
    var settings = AppSettings()
    settings.airplaneModeEnabled = true
    var conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = [.vdb]
    XCTAssertFalse(
      BuiltInToolCatalog.definitions(for: conversation, settings: settings)
        .contains { $0.name == MaiVectorDatabaseTool.name })
    settings.toolSettings.filesWorkspaceAccessEnabled = true
    let definitions = BuiltInToolCatalog.definitions(for: conversation, settings: settings)
    XCTAssertEqual(definitions.map(\.name), [MaiVectorDatabaseTool.name])
    XCTAssertTrue(BuiltInToolID.vdb.isCallableTool)
    XCTAssertFalse(BuiltInToolID.vdb.isDisabledInAirplaneMode)
  }

  func testSharedCalculatorPluginExecutes() async {
    let result = await PocketMaiPluginHost.shared.callStandardTool(
      name: MaiCalculatorTool.name,
      arguments: ["expression": .string("(2 + 3) * 4")])
    XCTAssertEqual(result, "20")
  }

  private struct ServerFixture {
    let server: MCPServer
    let tools: [MCPToolDescriptor]
    let resources: [MCPResourceDescriptor]

    init(
      name: String,
      tools: [MCPToolDescriptor],
      resources: [MCPResourceDescriptor] = []
    ) {
      self.server = MCPServer(name: name, baseURL: "https://\(name.lowercased()).example/mcp")
      self.tools = tools
      self.resources = resources
    }
  }

  @MainActor
  private func catalogDefinitions(
    servers: [ServerFixture],
    enabledBuiltInTools: Set<BuiltInToolID> = []
  ) -> [ToolDefinition] {
    var settings = AppSettings()
    settings.mcpServers = servers.map(\.server)
    var conversation = Conversation()
    conversation.toolsEnabled = true
    conversation.enabledTools = enabledBuiltInTools
    conversation.enabledMCPServers = Set(servers.map(\.server.id))
    conversation.enabledMCPTools = Set(
      servers.flatMap { fixture in
        fixture.tools.map { MCPToolSelection.key(serverID: fixture.server.id, toolName: $0.name) }
      })
    return ToolAgentRegistry.definitions(
      for: conversation,
      settings: settings,
      mcpTools: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, $0.tools) }),
      mcpResources: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, $0.resources) }),
      mcpStatuses: Dictionary(
        uniqueKeysWithValues: servers.map { ($0.server.id, EndpointConnectionState.available) }))
  }

  @MainActor
  func testDuplicateToolNameAcrossServersKeepsFirstServer() {
    let definitions = catalogDefinitions(servers: [
      ServerFixture(
        name: "Alpha", tools: [MCPToolDescriptor(name: "search", description: "Alpha search.")]),
      ServerFixture(
        name: "Beta", tools: [MCPToolDescriptor(name: "search", description: "Beta search.")]),
    ])

    let searches = definitions.filter { $0.name == "search" }
    XCTAssertEqual(searches.count, 1)
    XCTAssertEqual(searches.first?.description, "Alpha search.")

    // This lookup trapped on the duplicate definition before deduplication.
    let call = ParsedToolCall(name: "search", arguments: ["query": "x"], rawBlock: "")
    XCTAssertEqual(
      AgentTooling.normalized(call: call, tools: definitions).name, "search")
  }

  @MainActor
  func testDisabledServerDoesNotShadowEnabledServerWithSameToolName() {
    let first = ServerFixture(name: "First", tools: [MCPToolDescriptor(name: "search", description: "Disabled.")])
    let second = ServerFixture(name: "Second", tools: [MCPToolDescriptor(name: "search", description: "Available.")])
    var settings = AppSettings()
    settings.mcpServers = [first.server, second.server]
    var conversation = Conversation()
    conversation.enabledMCPServers = [second.server.id]
    conversation.enabledMCPTools = [MCPToolSelection.key(serverID: second.server.id, toolName: "search")]
    let catalog = ToolAgentRegistry.catalog(for: conversation, settings: settings,
      mcpTools: [first.server.id: first.tools, second.server.id: second.tools],
      mcpStatuses: [first.server.id: .available, second.server.id: .available])
    XCTAssertEqual(catalog.enabledDefinitions.first { $0.name == "search" }?.description, "Available.")
    XCTAssertEqual(catalog.groups.first { $0.id == second.server.id.uuidString.lowercased() }?.toolNames, ["search"])
    XCTAssertEqual(catalog.groups.first { $0.id == first.server.id.uuidString.lowercased() }?.toolNames, [])
  }

  @MainActor
  func testMCPToolCollidingWithBuiltInKeepsBuiltIn() {
    let definitions = catalogDefinitions(
      servers: [
        ServerFixture(
          name: "Alpha",
          tools: [MCPToolDescriptor(name: MaiCalculatorTool.name, description: "Impostor.")])
      ],
      enabledBuiltInTools: [.calculator])

    let calculators = definitions.filter { $0.name == MaiCalculatorTool.name }
    XCTAssertEqual(calculators.count, 1)
    XCTAssertNotEqual(calculators.first?.description, "Impostor.")
  }

  @MainActor
  func testMCPToolNamedLikeResourceReaderIsExcluded() {
    let definitions = catalogDefinitions(servers: [
      ServerFixture(
        name: "Alpha",
        tools: [MCPToolDescriptor(name: MCPResourceTool.readName, description: "Impostor.")],
        resources: [MCPResourceDescriptor(uri: "alpha://guide")])
    ])

    // executeConcrete always routes mcp_read_resource to the host resource
    // reader, so an MCP tool with that name must not appear in the catalog.
    let readers = definitions.filter { $0.name == MCPResourceTool.readName }
    XCTAssertEqual(readers.count, 1)
    XCTAssertTrue(readers.first?.parameters.contains { $0.name == "uri" } ?? false)
  }

  @MainActor
  func testNormalizedDoesNotTrapOnDuplicateDefinitions() {
    // Definition lists snapshotted outside the catalog builder (e.g. approval
    // requests) may still carry duplicates; the lookup must not crash.
    let duplicates = [
      ToolDefinition(
        name: "search", description: "First.",
        parameters: [
          ToolParameterDef(
            name: "query", type: "string", description: "Search query.", required: true)
        ]),
      ToolDefinition(name: "search", description: "Second.", parameters: []),
    ]
    let call = ParsedToolCall(name: "search", arguments: ["query": "x"], rawBlock: "")

    let normalized = AgentTooling.normalized(call: call, tools: duplicates)
    XCTAssertEqual(normalized.name, "search")
    XCTAssertEqual(normalized.argumentValues["query"]?.stringValue, "x")
  }
}
