import Foundation
import SwiftTUICLI
import SwiftTUIRuntime
import Testing

@testable import MaiCore
@testable import MaiStandardTools
@testable import MaiVisual

private let helloProfile = AgentDefinition(
  id: "main",
  instructions: "Be brief.",
  provider: .hello,
  model: "")

private actor AlwaysApprovalRecorder {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

@MainActor
private func makeWorkspace(
  seed: VisualConversationSeed,
  snapshot: VisualWorkspaceSnapshot? = nil
) async throws -> VisualWorkspace {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  return VisualWorkspace(
    launch: VisualLaunch(focusedConversation: seed, snapshot: snapshot),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: VisualApprovalHandler())
}

@Test("Pane layout splits, moves focus, closes panes, and keeps focus valid")
func paneLayoutOperations() {
  let a = UUID()
  let b = UUID()
  let c = UUID()
  var layout = PaneLayout(conversation: a)
  #expect(layout.panes == [PaneID(1)])
  #expect(!layout.canCloseFocusedPane)
  let closedSinglePane = layout.closeFocusedPane()
  #expect(!closedSinglePane)

  let second = layout.split(.horizontal, showing: b)
  #expect(layout.focusedPane == second)
  #expect(layout.focusedConversation == b)
  #expect(layout.panes == [PaneID(1), second])

  layout.focusPrevious()
  #expect(layout.focusedPane == PaneID(1))
  let third = layout.split(.vertical, showing: c)
  #expect(layout.panes == [PaneID(1), third, second])
  #expect(layout.conversation(in: third) == c)

  layout.focusNext()
  #expect(layout.focusedPane == second)
  layout.focusNext()
  #expect(layout.focusedPane == PaneID(1))

  let closedFirstPane = layout.closeFocusedPane()
  #expect(closedFirstPane)
  #expect(layout.panes == [third, second])
  #expect(layout.focusedPane == third)

  layout.show(a, in: second)
  #expect(layout.conversation(in: second) == a)
  layout.replaceConversation(a, with: b)
  #expect(layout.conversation(in: second) == b)

  layout.focus(PaneID(42))
  #expect(layout.focusedPane == third)
}

@Test("The workspace runs a conversation and reports its result")
@MainActor
func workspaceSendsMessages() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  let conversation = try #require(workspace.focusedConversation)
  #expect(conversation.visibleMessages.isEmpty)

  conversation.draft = "ping"
  workspace.send(conversation)
  #expect(conversation.isRunning)
  await conversation.runTask?.value

  #expect(!conversation.isRunning)
  #expect(conversation.visibleMessages.map(\.role) == [.user, .assistant])
  #expect(conversation.lastAssistantText == "Hello from MaiCore: ping")
  #expect(conversation.title == "repl")

  let scratch = workspace.makeConversation()
  #expect(scratch.title == AgentChat.placeholderTitle)
  scratch.draft = "rename me please"
  workspace.send(scratch)
  await scratch.runTask?.value
  #expect(scratch.title == "rename me please")
}

@Test("Snapshots resume every conversation and adopt the REPL's focused one")
@MainActor
func workspaceSnapshotRoundTrip() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(
      title: "repl",
      profile: helloProfile,
      messages: [.system("Be brief."), .user("hi")]))
  workspace.splitFocusedPane(.horizontal)
  #expect(workspace.conversations.count == 2)
  #expect(workspace.layout.panes.count == 2)
  let focused = try #require(workspace.focusedConversation)
  focused.title = "scratch"

  let outcome = workspace.shutdown()
  #expect(outcome.focusedConversation.title == "scratch")
  #expect(outcome.snapshot.conversations.count == 2)
  #expect(!outcome.configurationChanged)
  #expect(outcome.summary.contains("1 other conversation"))

  let replSeed = VisualConversationSeed(
    title: "repl",
    profile: helloProfile,
    messages: [.system("Be brief."), .user("hello again"), .assistant("hey")])
  let resumed = try await makeWorkspace(seed: replSeed, snapshot: outcome.snapshot)
  #expect(resumed.conversations.count == 2)
  #expect(resumed.layout == outcome.snapshot.layout)
  #expect(resumed.focusedConversation?.transcript.messages.last?.text == "hey")
  #expect(resumed.conversations[0].transcript.messages.map(\.text) == ["Be brief.", "hi"])

  let renamed = try #require(resumed.focusedConversation)
  resumed.requestRenameFocusedConversation()
  #expect(resumed.conversationRenameDraft == renamed.title)
  let rename = try #require(resumed.pendingConversationRename)
  resumed.conversationRenameDraft = "Renamed chat"
  resumed.confirmConversationRename(rename)
  #expect(renamed.title == "Renamed chat")
  #expect(resumed.pendingConversationRename == nil)

  let deletedID = resumed.focusedConversation?.id
  resumed.deleteFocusedConversation()
  #expect(resumed.conversations.count == 2)
  let deletion = try #require(resumed.pendingConversationDeletion)
  #expect(deletion.conversationID == deletedID)
  resumed.cancelConversationDeletion()
  #expect(resumed.conversations.count == 2)

  resumed.deleteFocusedConversation()
  resumed.confirmConversationDeletion(try #require(resumed.pendingConversationDeletion))
  #expect(resumed.conversations.count == 1)
  #expect(resumed.pendingConversationDeletion == nil)
  #expect(resumed.layout.panes.count == 2)
  #expect(resumed.focusedConversation?.id == resumed.conversations[0].id)
  resumed.deleteFocusedConversation()
  #expect(resumed.conversations.count == 1)
  #expect(resumed.pendingConversationDeletion == nil)
}

@Test("Registering a provider updates the runtime and the configuration draft")
@MainActor
func workspaceRegistersProviders() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-visual-\(UUID().uuidString)/config.json").path
  workspace.configurationPath = path
  try await workspace.plugins.install(MaiCoreBuiltinsPlugin())
  await workspace.refreshRegistries()
  #expect(workspace.providers.map(\.id) == [.hello])

  var form = ProviderForm()
  form.id = "greeter"
  form.kind = ConfiguredProviderKind.hello.rawValue
  form.displayName = "Greeter"
  form.apiKey = "existing-secret"
  try await workspace.registerProvider(form)
  #expect(workspace.providers.map(\.id) == [ProviderID("greeter"), .hello])
  #expect(workspace.configuration.providers.map(\.id) == ["greeter"])
  #expect(workspace.configurationChanged)
  #expect(!workspace.configurationNeedsSave)
  let persisted = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
  #expect(persisted.providers.map(\.id) == ["greeter"])

  var edit = ProviderForm(provider: try #require(workspace.configuredProvider("greeter")))
  #expect(edit.apiKey.isEmpty)
  edit.baseURL = "http://127.0.0.1:11434/v1"
  try await workspace.registerProvider(edit)
  let updated = try #require(workspace.configuredProvider("greeter"))
  #expect(updated.baseURL?.absoluteString == "http://127.0.0.1:11434/v1")
  #expect(updated.apiKey == "existing-secret")
  let updatedPersisted = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
  #expect(
    updatedPersisted.providers.first?.baseURL?.absoluteString
      == "http://127.0.0.1:11434/v1")

  form.id = ""
  await #expect(throws: VisualWorkspaceError.missingField("Identifier")) {
    try await workspace.registerProvider(form)
  }

  var agent = AgentForm()
  agent.id = "saved"
  workspace.useProvider(ProviderID("greeter"))
  try await workspace.saveFocusedConversationAsAgent(agent)
  #expect(workspace.agents.map(\.id) == ["main", "saved"])
  #expect(
    workspace.configuration.agents.first(where: { $0.id == "saved" })?.provider
      == ProviderID("greeter"))
  #expect(workspace.focusedConversation?.profile.id == "saved")

  let saved = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
  #expect(saved.agents.map(\.id) == ["main", "saved"])
  #expect(saved.providers.map(\.id) == ["greeter"])
}

@Test("Visual tool groups toggle whole capabilities and persist their options")
@MainActor
func workspaceConfiguresToolGroups() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let plugins = PluginRegistry()
  try await plugins.install(MaiStandardToolsPlugin())
  let source = ConfiguredToolSource(
    id: "standard-tools",
    kind: MaiStandardToolsPlugin.factoryKind)
  for tool in try await plugins.makeTools(
    kind: source.kind,
    context: source.context(environment: [:]))
  {
    try await runtime.register(tool: tool)
  }
  let path = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-tool-groups-\(UUID().uuidString)/config.json").path
  let configuration = MaiConfiguration(
    defaultAgent: "main",
    providers: [ConfiguredProvider(id: "hello", kind: .hello)],
    toolSources: [source],
    agents: [helloProfile])
  let workspace = VisualWorkspace(
    launch: VisualLaunch(
      focusedConversation: VisualConversationSeed(title: "repl", profile: helloProfile),
      configuration: configuration,
      configurationPath: path),
    runtime: runtime,
    plugins: plugins,
    approvals: VisualApprovalHandler())
  await workspace.refreshRegistries()

  let conversation = try #require(workspace.focusedConversation)
  let agents = try #require(workspace.toolGroups.first { $0.id == "agents" })
  #expect(agents.toolNames == AgentRuntime.agentToolNames)
  #expect(!workspace.isToolGroupEnabled(agents, for: conversation))

  let github = try #require(workspace.toolGroups.first { $0.id == "github" })
  workspace.setToolGroup(agents, allowed: true, for: conversation)
  #expect(conversation.profile.toolGroupNames.contains("agents"))
  #expect(AgentRuntime.agentToolNames.isSubset(of: conversation.profile.toolNames))
  workspace.setToolGroup(github, allowed: true, for: conversation)
  #expect(conversation.profile.toolGroupNames.contains("github"))
  #expect(Set(MaiGitHubTool.toolNames).isSubset(of: conversation.profile.toolNames))

  workspace.setToolGroupMode(.proxy, group: github, for: conversation)
  workspace.setToolMode(.direct, name: "github_pr", for: conversation)
  workspace.setToolMode(.disabled, name: "github_ci_log", for: conversation)
  workspace.setAutomaticToolExposure(false, for: conversation)
  #expect(workspace.toolMode("github_pr", for: conversation) == .direct)
  #expect(workspace.toolMode("github_issue", for: conversation) == .proxy)
  #expect(workspace.toolMode("github_ci_log", for: conversation) == .disabled)
  #expect(conversation.request().toolPolicy == conversation.profile.toolPolicy)
  #expect(conversation.request().proxyExposedTools == conversation.profile.proxyExposedTools)
  let mastodon = try #require(workspace.toolGroups.first { $0.id == "mastodon" })
  workspace.selectedTab = .tools
  let rendered = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 110),
    width: 150,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  #expect(rendered.contains("GitHub (12)"))
  #expect(rendered.contains("Mastodon (1)"))
  #expect(rendered.contains("Agents (4)"))
  #expect(rendered.contains("0 calls"))
  #expect(rendered.contains("Automatically expose frequently used tools"))
  #expect(rendered.contains("Allow posting and replying"))

  var options = workspace.configuredToolGroupOptions(mastodon)
  options["mastodonInstance"] = .string("social.example")
  options["mastodonAPIKeyEnvironment"] = .string("SOCIAL_TOKEN")
  options["mastodonWriteEnabled"] = .bool(true)
  try await workspace.configureToolGroup(mastodon, options: options)

  let persisted = try MaiConfiguration.load(from: URL(fileURLWithPath: path))
  let persistedSource = try #require(persisted.toolSources.first)
  #expect(persistedSource.options["mastodonInstance"] == .string("social.example"))
  #expect(persistedSource.options["mastodonAPIKeyEnvironment"] == .string("SOCIAL_TOKEN"))
  #expect(persistedSource.options["mastodonWriteEnabled"] == .bool(true))
  #expect(persisted.agents.first?.toolGroupNames.contains("agents") == true)
  #expect(persisted.agents.first?.toolGroupNames.contains("github") == true)
  #expect(persisted.agents.first?.toolPolicy.tools["github_pr"] == .direct)
  #expect(persisted.agents.first?.toolPolicy.tools["github_ci_log"] == .disabled)
  #expect(persisted.agents.first?.toolPolicy.automatic == false)
}

@Test("Approvals raised during a run surface in the workspace and resolve the runtime")
@MainActor
func workspaceApprovals() async throws {
  let recorder = AlwaysApprovalRecorder()
  let approvals = VisualApprovalHandler {
    await recorder.record()
  }
  let runtime = AgentRuntime(approvalHandler: approvals)
  let workspace = VisualWorkspace(
    launch: VisualLaunch(
      focusedConversation: VisualConversationSeed(title: "repl", profile: helloProfile)),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: approvals)
  await approvals.attach { pending in await workspace.present(pending) }

  let request = ApprovalRequest(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "main", depth: 0),
    tool: ToolDefinition(name: "echo", description: "Echo"),
    call: ToolCall(id: "call-1", name: "echo", arguments: .object(["text": .string("hi")])))
  let decision = Task { try await approvals.decide(request) }
  while workspace.pendingApproval == nil { await Task.yield() }
  #expect(workspace.pendingApproval?.request.tool.name == "echo")

  workspace.resolveApproval(.approve(arguments: request.call.arguments))
  #expect(workspace.pendingApproval == nil)
  #expect(try await decision.value == .approve(arguments: request.call.arguments))

  let second = Task { try await approvals.decide(request) }
  while workspace.pendingApproval == nil { await Task.yield() }
  await approvals.detach()
  #expect(try await second.value == .deny(reason: "Visual mode ended before the approval."))
  workspace.approvalSheetDismissed()
  #expect(workspace.pendingApproval == nil)

  await approvals.attach { pending in await workspace.present(pending) }
  let third = Task { try await approvals.decide(request) }
  let fourth = Task { try await approvals.decide(request) }
  while workspace.pendingApprovalCount < 2 { await Task.yield() }
  workspace.resolveApprovalAlways()
  #expect(try await third.value == .approve(arguments: request.call.arguments))
  #expect(try await fourth.value == .approve(arguments: request.call.arguments))
  #expect(await recorder.count == 1)

  let automatic = try await approvals.decide(request)
  #expect(automatic == .approve(arguments: request.call.arguments))
}

@Test("The root view renders the focused conversation without a terminal")
@MainActor
func rootViewRenders() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(
      title: "planning",
      profile: helloProfile,
      messages: [.system("Be brief."), .user("hi"), .assistant("Hello from MaiCore: hi")]))
  let output = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 30),
    width: 120,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  #expect(output.contains("pmai visual"))
  #expect(output.contains("planning"))
  #expect(output.contains("Hello from MaiCore: hi"))
  #expect(output.contains("Conversations"))
  #expect(output.contains("Rename chat"))
  #expect(output.contains("Delete chat"))
  #expect(output.contains("Menu ^K"))
  #expect(output.contains("Message, or /help (Return sends)"))
}

@Test("Transcript text wraps to the pane width and hides control characters")
@MainActor
func transcriptWrapsAndSanitizes() async throws {
  let longReply = Array(repeating: "wrapped words keep flowing", count: 12).joined(separator: " ")
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(
      title: "wrap",
      profile: helloProfile,
      messages: [.user("col\ta\tb"), .assistant(longReply)]))
  let output = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 40),
    width: 100,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  try? output.write(
    to: URL(fileURLWithPath: "/tmp/mai-visual-wrap-render.txt"), atomically: true, encoding: .utf8)
  let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
  #expect(lines.allSatisfy { $0.count <= 100 })
  #expect(output.contains("col    a    b"))
  #expect(!output.contains("\t"))
  // Word wrapping never splits a word, so every repetition still shows its last word.
  let occurrences = output.components(separatedBy: "flowing").count - 1
  #expect(occurrences == 12)
  #expect(MessageBlock.displayText("a\tb\u{07}c\r\nd") == "a    bc\nd")
}

@Test("Slash commands typed into a pane run through the host handler, not the model")
@MainActor
func workspaceRunsSlashCommands() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let handler: VisualCommandHandler = { request in
    var conversation = request.conversation
    if request.input == "/clear" { conversation.messages = [] }
    return VisualCommandOutcome(
      output: "ran \(request.input) over \(request.conversation.messages.count) messages\n",
      conversation: conversation,
      leavesVisualMode: request.input == "/exit")
  }
  let workspace = VisualWorkspace(
    launch: VisualLaunch(
      focusedConversation: VisualConversationSeed(
        title: "repl",
        profile: helloProfile,
        messages: [.system("Be brief."), .user("hi")]),
      commandHandler: handler),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: VisualApprovalHandler())
  let conversation = try #require(workspace.focusedConversation)

  conversation.draft = "/chat list"
  workspace.send(conversation)
  #expect(conversation.draft.isEmpty)
  #expect(!conversation.isRunning)
  await conversation.commandTask?.value
  #expect(
    conversation.commandOutput
      == VisualCommandOutput(command: "/chat list", text: "ran /chat list over 2 messages"))
  #expect(conversation.transcript.count == 2)
  #expect(!workspace.exitRequested)

  conversation.draft = "/clear"
  workspace.send(conversation)
  await conversation.commandTask?.value
  #expect(conversation.transcript.isEmpty)

  conversation.draft = "/help"
  workspace.send(conversation)
  await conversation.commandTask?.value
  #expect(conversation.commandOutput?.text.contains("/pane split") == true)

  workspace.dismissCommandOutput(in: conversation)
  #expect(conversation.commandOutput == nil)

  conversation.draft = "/exit"
  workspace.send(conversation)
  await conversation.commandTask?.value
  #expect(workspace.exitRequested)

  let plain = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  let unsupported = try #require(plain.focusedConversation)
  unsupported.draft = "/models"
  plain.send(unsupported)
  #expect(unsupported.commandOutput?.text.contains("not available") == true)
  #expect(unsupported.visibleMessages.isEmpty)
}

@Test("Visual-only commands drive panes, tabs, the menu, and the sidebar")
@MainActor
func workspaceVisualCommands() async throws {
  let workspace = try await makeWorkspace(
    seed: VisualConversationSeed(title: "repl", profile: helloProfile))
  let conversation = try #require(workspace.focusedConversation)

  conversation.draft = "/pane split"
  workspace.send(conversation)
  #expect(workspace.layout.panes.count == 2)
  #expect(workspace.conversations.count == 2)
  #expect(conversation.commandOutput?.text == "Split the pane to the right.")

  conversation.draft = "/pane close"
  workspace.send(conversation)
  #expect(workspace.layout.panes.count == 1)

  conversation.draft = "/pane close"
  workspace.send(conversation)
  #expect(conversation.commandOutput?.text == "The last pane cannot be closed.")

  conversation.draft = "/tab tools"
  workspace.send(conversation)
  #expect(workspace.selectedTab == .tools)

  conversation.draft = "/tab nowhere"
  workspace.send(conversation)
  #expect(conversation.commandOutput?.text.hasPrefix("Usage: /tab") == true)

  conversation.draft = "/menu"
  workspace.send(conversation)
  #expect(workspace.showsCommandMenu)

  conversation.draft = "/sidebar"
  workspace.send(conversation)
  #expect(!workspace.showsSidebar)

  conversation.draft = "/cancel"
  workspace.send(conversation)
  #expect(conversation.commandOutput?.text == "No reply is running in the focused chat.")
}

@Test("The Stats tab draws a colored bar per model from the runtime's usage store")
@MainActor
func statsTabRendersUsageBars() async throws {
  let runtime = AgentRuntime()
  try await runtime.register(HelloProvider())
  let store = ModelUsageStore()
  await store.record(
    ModelCallStats(
      providerLabel: "thor", modelID: "qwen3.8:27b", inputTokens: 1_000, outputTokens: 4_000,
      promptSeconds: 4, generationSeconds: 100))
  await store.record(
    ModelCallStats(
      providerLabel: "openai", modelID: "big-pickle", inputTokens: 500, outputTokens: 400,
      generationSeconds: 20, tokensEstimated: true))
  await runtime.configureUsageStats(store)
  let workspace = VisualWorkspace(
    launch: VisualLaunch(
      focusedConversation: VisualConversationSeed(title: "repl", profile: helloProfile)),
    runtime: runtime,
    plugins: PluginRegistry(),
    approvals: VisualApprovalHandler())
  await workspace.refreshRegistries()
  #expect(workspace.usageLedger.totals.count == 2)
  #expect(workspace.runVisualCommand("/tab stats") == "Showing the Stats tab.")
  #expect(workspace.selectedTab == .stats)

  let output = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 30),
    width: 120,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  #expect(output.contains("Stats"))
  #expect(output.contains("Average output speed"))
  #expect(output.contains("Time in use"))
  #expect(output.contains("Efficiency"))
  // RenderOnce swaps non-ASCII glyphs (the em dash, the bars) for ASCII.
  #expect(output.contains("qwen3.8:27b"))
  #expect(output.contains("40.0 tok/s"))
  #expect(output.contains("big-pickle"))
  #expect(output.contains("20.0 tok/s"))
  #expect(output.contains("1m44s"))
  // 5,000 tokens over 104 s in use and one request.
  #expect(output.contains("48.1 tok/s/req"))
  #expect(output.contains("Reset statistics"))
  #expect(output.contains("~ marks"))

  // A reply recorded by the runtime shows up without leaving the tab.
  let conversation = try #require(workspace.focusedConversation)
  conversation.draft = "ping"
  workspace.send(conversation)
  await conversation.runTask?.value
  try await Task.sleep(for: .milliseconds(50))
  #expect(workspace.usageLedger.totals.contains { $0.providerLabel == "hello" })

  workspace.resetUsageStats()
  try await Task.sleep(for: .milliseconds(50))
  #expect(workspace.usageLedger.isEmpty)
  let empty = RenderOnce.render(
    VisualRootView(workspace: workspace).frame(height: 20),
    width: 100,
    environment: ["NO_COLOR": "1"],
    isStdoutTTY: false)
  #expect(empty.contains("No model usage recorded yet"))
}
