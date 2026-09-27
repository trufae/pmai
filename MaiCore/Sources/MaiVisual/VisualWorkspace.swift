import Foundation
import MaiCore
import Observation

#if os(macOS)
  let visualAlternateKeyName = "Option"
#else
  let visualAlternateKeyName = "Alt"
#endif

public struct ProviderForm: Equatable, Sendable {
  public var id = ""
  public var kind = ConfiguredProviderKind.openAICompatible.rawValue
  public var displayName = ""
  public var baseURL = ""
  public var apiKeyEnvironment = ""
  public var apiKey = ""

  public init() {}

  init(provider: ConfiguredProvider) {
    id = provider.id
    kind = provider.kind.rawValue
    displayName = provider.displayName ?? ""
    baseURL = provider.baseURL?.absoluteString ?? ""
    apiKeyEnvironment = provider.apiKeyEnvironment ?? ""
    // Never copy a saved secret into an editable UI field. An empty key keeps
    // the existing direct key when this form updates the provider.
    apiKey = ""
  }
}

public struct MCPServerForm: Equatable, Sendable {
  public var id = ""
  public var kind = "streamable-http"
  public var displayName = ""
  public var url = ""
  public var bearerTokenEnvironment = ""
  public var bearerToken = ""
  public var toolNamePrefix = ""
  public var approval = ToolApprovalRequirement.confirm

  public init() {}
}

public struct ToolSourceForm: Equatable, Sendable {
  public var id = ""
  public var kind = ""
  public var displayName = ""
  public var optionsJSON = "{}"

  public init() {}
}

public struct AgentForm: Equatable, Sendable {
  public var id = ""
  public var displayName = ""
  /// What the setup is for. People read it when picking; a delegating model
  /// reads it to choose an agent for a task.
  public var description = ""

  public init() {}
}

public enum VisualWorkspaceError: LocalizedError, Equatable, Sendable {
  case missingField(String)
  case invalidURL(String)
  case invalidOptions(String)
  case noFocusedConversation

  public var errorDescription: String? {
    switch self {
    case .missingField(let name): "\(name) is required."
    case .invalidURL(let value): "'\(value)' is not a valid URL."
    case .invalidOptions(let reason): "Options must be a JSON object: \(reason)"
    case .noFocusedConversation: "No conversation is focused."
    }
  }
}

public struct ConversationActionRequest: Identifiable, Equatable, Sendable {
  public let conversationID: UUID
  public let title: String

  public var id: UUID { conversationID }

  public init(conversationID: UUID, title: String) {
    self.conversationID = conversationID
    self.title = title
  }
}

/// The state behind the visual workspace: conversations, the pane layout, the
/// registries mirrored from the runtime, and the configuration draft edited by
/// the panels. Registration actions update the live runtime immediately and the
/// draft configuration for an explicit save.
@MainActor @Observable
public final class VisualWorkspace {
  @ObservationIgnored let runtime: AgentRuntime
  @ObservationIgnored let plugins: PluginRegistry
  @ObservationIgnored let approvals: VisualApprovalHandler
  @ObservationIgnored let commandHandler: VisualCommandHandler?
  public let environment: [String: String]
  public var configuration: MaiConfiguration
  public private(set) var configurationChanged = false
  public private(set) var configurationNeedsSave = false
  public var configurationPath: String
  public private(set) var catalogs: [MCPServerCatalog]
  public private(set) var conversations: [VisualConversation]
  public private(set) var layout: PaneLayout
  public var selectedTab: VisualTab
  public var showsSidebar = true
  /// Presents the searchable command menu; every pane and tab action is listed there.
  public var showsCommandMenu = false
  public var status: String?
  /// Set when a command such as `/exit` asks to hand the terminal back to the host.
  public private(set) var exitRequested = false
  public private(set) var providers: [ProviderDescriptor] = []
  public private(set) var tools: [ToolDefinition] = []
  public private(set) var toolGroups: [ToolGroupDefinition] = []
  /// The live agent process tree, refreshed when runs start and finish.
  public private(set) var agentTree = AgentProcessTree()
  public private(set) var agents: [AgentDefinition] = []
  /// Tokens/s and time in use per provider:model, mirrored from the runtime's
  /// usage store after every run and shown as bars on the Stats tab.
  public private(set) var usageLedger = ModelUsageLedger()
  public var pendingApproval: VisualApprovalHandler.Pending?
  public var pendingCompaction: VisualApprovalHandler.PendingCompaction?
  private var compactionQueue: [VisualApprovalHandler.PendingCompaction] = []
  private var presentedCompactionID: UUID?
  public var pendingConversationDeletion: ConversationActionRequest?
  public var pendingConversationRename: ConversationActionRequest?
  public var conversationRenameDraft = ""
  public private(set) var modelCatalog: [ModelDescriptor] = []
  public private(set) var modelCatalogProvider: ProviderID?
  public private(set) var isFetchingModels = false
  private var approvalQueue: [VisualApprovalHandler.Pending] = []
  private var presentedApprovalID: UUID?

  public var pendingApprovalCount: Int {
    (pendingApproval == nil ? 0 : 1) + approvalQueue.count
  }

  public init(
    launch: VisualLaunch,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    approvals: VisualApprovalHandler
  ) {
    self.runtime = runtime
    self.plugins = plugins
    self.approvals = approvals
    commandHandler = launch.commandHandler
    environment = launch.environment
    configuration = launch.configuration ?? MaiConfiguration()
    configurationPath =
      launch.configurationPath
      ?? NSString(string: "~/.config/pmai/config.json").expandingTildeInPath
    catalogs = launch.catalogs

    if let snapshot = launch.snapshot, !snapshot.conversations.isEmpty {
      let restored = snapshot.conversations.map { VisualConversation(seed: $0) }
      var layout = snapshot.layout
      let ids = Set(restored.map(\.id))
      if !layout.root.leaves.allSatisfy({ ids.contains($0.conversation) }) {
        layout = PaneLayout(conversation: restored[0].id)
      }
      conversations = restored
      self.layout = layout
      selectedTab = snapshot.selectedTab
      let focusedID = layout.focusedConversation
      restored.first { $0.id == focusedID }?.replace(with: launch.focusedConversation)
    } else {
      let conversation = VisualConversation(seed: launch.focusedConversation)
      conversations = [conversation]
      layout = PaneLayout(conversation: conversation.id)
      selectedTab = .chats
    }
  }

  // MARK: Conversations and panes

  public func conversation(_ id: UUID) -> VisualConversation? {
    conversations.first { $0.id == id }
  }

  public var focusedConversation: VisualConversation? {
    conversation(layout.focusedConversation)
  }

  public func isFocused(_ conversation: VisualConversation) -> Bool {
    layout.focusedConversation == conversation.id
  }

  public func isShown(_ conversation: VisualConversation) -> Bool {
    layout.root.leaves.contains { $0.conversation == conversation.id }
  }

  public var usageReport: ModelUsageReport { ModelUsageReport(usageLedger) }

  public func refreshRegistries() async {
    providers = await runtime.availableProviders()
    tools = await runtime.availableTools()
    agents = await runtime.availableAgents()
    await refreshAgentTree()
    await refreshUsageStats()
    var groups = AgentRuntime.builtInToolGroups(for: tools)
    for source in configuration.toolSources where source.enabled {
      do {
        groups.append(
          contentsOf: try await plugins.toolGroups(
            kind: source.kind,
            context: source.context(environment: environment)))
      } catch {
        status =
          "warning: tool groups for '\(source.id)' are unavailable: \(error.localizedDescription)"
      }
    }
    toolGroups = ToolGroupDefinition.catalog(known: groups, tools: tools)
  }

  @discardableResult
  public func makeConversation(profile: AgentDefinition? = nil) -> VisualConversation {
    let base =
      profile ?? focusedConversation?.profile ?? conversations.first?.profile
      ?? AgentDefinition(id: "main", instructions: "", provider: .hello, model: "")
    let seed = VisualConversationSeed(
      title: AgentChat.placeholderTitle,
      profile: base,
      messages: VisualConversation.initialHistory(for: base))
    let conversation = VisualConversation(seed: seed, hasCustomTitle: false)
    conversations.append(conversation)
    return conversation
  }

  public func newConversationInFocusedPane() {
    let conversation = makeConversation()
    layout.show(conversation.id, in: layout.focusedPane)
    selectedTab = .chats
  }

  public func show(_ conversation: VisualConversation, in pane: PaneID? = nil) {
    layout.show(conversation.id, in: pane ?? layout.focusedPane)
    selectedTab = .chats
  }

  public func focus(pane: PaneID) { layout.focus(pane) }
  public func focusNextPane() { layout.focusNext() }
  public func focusPreviousPane() { layout.focusPrevious() }

  public func splitFocusedPane(_ axis: SplitAxis) {
    let conversation = makeConversation()
    layout.split(axis, showing: conversation.id)
    selectedTab = .chats
  }

  public func closeFocusedPane() {
    if !layout.closeFocusedPane() { status = "The last pane cannot be closed." }
  }

  private func deleteConversation(_ conversation: VisualConversation) {
    guard conversations.count > 1,
      let index = conversations.firstIndex(where: { $0.id == conversation.id })
    else {
      status = "The last conversation cannot be deleted."
      return
    }
    conversation.cancelRun()
    conversations.remove(at: index)
    let fallback = conversations[min(index, conversations.count - 1)]
    layout.replaceConversation(conversation.id, with: fallback.id)
    status = "Deleted '\(conversation.title)'."
  }

  public func deleteFocusedConversation() {
    guard conversations.count > 1, let focused = focusedConversation else {
      status = "The last conversation cannot be deleted."
      return
    }
    pendingConversationDeletion = ConversationActionRequest(
      conversationID: focused.id,
      title: focused.title)
  }

  public func confirmConversationDeletion(_ request: ConversationActionRequest) {
    guard pendingConversationDeletion?.id == request.id else { return }
    pendingConversationDeletion = nil
    guard let conversation = conversations.first(where: { $0.id == request.conversationID }) else {
      return
    }
    deleteConversation(conversation)
  }

  public func cancelConversationDeletion() {
    pendingConversationDeletion = nil
  }

  public func requestRenameFocusedConversation() {
    guard let focused = focusedConversation else { return }
    conversationRenameDraft = focused.title
    pendingConversationRename = ConversationActionRequest(
      conversationID: focused.id,
      title: focused.title)
  }

  public func confirmConversationRename(_ request: ConversationActionRequest) {
    guard pendingConversationRename?.id == request.id else { return }
    let title = conversationRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      status = "A chat name is required."
      return
    }
    guard let conversation = conversations.first(where: { $0.id == request.conversationID }) else {
      pendingConversationRename = nil
      return
    }
    conversation.rename(to: title)
    pendingConversationRename = nil
    conversationRenameDraft = ""
    status = "Renamed chat to '\(title)'."
  }

  public func cancelConversationRename() {
    pendingConversationRename = nil
    conversationRenameDraft = ""
  }

  public func clearFocusedConversation() {
    focusedConversation?.resetTranscript()
  }

  public func cancelFocusedRun() {
    guard let focused = focusedConversation, focused.isRunning else { return }
    focused.cancelRun()
    status = "Cancelled the reply in '\(focused.title)'."
  }

  public func send(_ conversation: VisualConversation) {
    let text = conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    if text.hasPrefix("/") {
      runCommand(text, in: conversation)
      return
    }
    guard !conversation.isRunning else {
      status = "'\(conversation.title)' is still replying; \(visualAlternateKeyName)+K cancels it."
      return
    }
    conversation.draft = ""
    conversation.appendUserMessage(text)
    conversation.beginRun()
    let request = conversation.request()
    let runtime = runtime
    let process = conversation.processID
    conversation.runTask = Task { [weak self] in
      do {
        let result = try await runtime.run(request, process: process) { event in
          await conversation.consume(event)
        }
        conversation.processID =
          await runtime.supervisor.tree().processes.first { $0.runID == result.runID }?.pid
        conversation.finishRun(with: result)
      } catch is CancellationError {
        conversation.failRun("Cancelled.")
      } catch {
        conversation.failRun(error.localizedDescription)
      }
      await self?.refreshAgentTree()
      await self?.refreshUsageStats()
    }
    Task { await refreshAgentTree() }
  }

  /// Runs a slash command through the host's REPL handler and shows what it
  /// printed above the pane's input. The command never reaches the model.
  public func runCommand(_ input: String, in conversation: VisualConversation) {
    conversation.draft = ""
    if let output = runVisualCommand(input) {
      conversation.commandOutput = VisualCommandOutput(command: input, text: output)
      return
    }
    guard let commandHandler else {
      conversation.commandOutput = VisualCommandOutput(
        command: input,
        text: "Slash commands are not available in this session.")
      return
    }
    guard !conversation.isRunning else {
      status = "'\(conversation.title)' is still replying; wait for it or cancel it first."
      return
    }
    let request = VisualCommandRequest(
      input: input,
      conversation: conversation.seed,
      configuration: configuration,
      catalogs: catalogs)
    conversation.commandOutput = VisualCommandOutput(command: input, text: "…")
    conversation.commandTask = Task { [weak self] in
      let outcome = await commandHandler(request)
      conversation.applyCommandResult(outcome.conversation)
      var output = outcome.output.trimmingCharacters(in: .newlines)
      if input.hasPrefix("/help") { output += "\n\n" + VisualWorkspace.visualCommandsHelp }
      conversation.commandOutput = VisualCommandOutput(command: input, text: output)
      conversation.commandTask = nil
      if input.hasPrefix("/stats") { await self?.refreshUsageStats() }
      if outcome.leavesVisualMode { self?.exitRequested = true }
    }
  }

  public func dismissCommandOutput(in conversation: VisualConversation) {
    conversation.commandOutput = nil
  }

  /// Asks the host to take the terminal back, like `/exit` or Ctrl+C.
  public func requestExit() {
    exitRequested = true
  }

  /// Copies the focused chat's last reply through the terminal clipboard action.
  public func copyLastReply(using write: (String) -> Bool) {
    guard let focused = focusedConversation else { return }
    guard let text = focused.lastAssistantText else {
      status = "No assistant reply to copy in '\(focused.title)'."
      return
    }
    status =
      write(text)
      ? "Copied the last reply of '\(focused.title)' to the clipboard."
      : "The terminal does not expose a clipboard; use /copy in the REPL."
  }

  public static let visualCommandsHelp = """
    Visual mode commands:
      /pane new            Start a conversation in the focused pane
      /pane split          Split the focused pane to the right
      /pane down           Split the focused pane downwards
      /pane close          Close the focused pane
      /pane next|prev      Move focus between panes
      /tab NAME            Show chats, providers, mcp, tools, agents, or stats
      /menu                Open the command menu (also Ctrl+K or F2)
      /sidebar             Show or hide the conversation list
      /cancel              Cancel the focused chat's reply
      /exit                Return to the REPL (also Ctrl+C)
    """

  /// Commands that only exist inside the workspace. Returns nil for REPL commands.
  func runVisualCommand(_ input: String) -> String? {
    let parts = input.split(whereSeparator: \Character.isWhitespace).map(String.init)
    guard let command = parts.first?.lowercased() else { return nil }
    let argument = parts.dropFirst().first?.lowercased() ?? ""
    switch command {
    case "/pane":
      switch argument {
      case "new":
        newConversationInFocusedPane()
        return "Started a new conversation in the focused pane."
      case "split", "right":
        splitFocusedPane(.horizontal)
        return "Split the pane to the right."
      case "down", "vsplit":
        splitFocusedPane(.vertical)
        return "Split the pane downwards."
      case "close":
        guard layout.canCloseFocusedPane else { return "The last pane cannot be closed." }
        closeFocusedPane()
        return "Closed the pane."
      case "next":
        focusNextPane()
        return "Focused the next pane."
      case "prev", "previous":
        focusPreviousPane()
        return "Focused the previous pane."
      default:
        return "Usage: /pane new|split|down|close|next|prev"
      }
    case "/tab":
      guard let tab = VisualTab(rawValue: argument) else {
        return "Usage: /tab " + VisualTab.allCases.map(\.rawValue).joined(separator: "|")
      }
      selectedTab = tab
      return "Showing the \(tab.title) tab."
    case "/menu":
      showsCommandMenu = true
      return "Command menu opened."
    case "/sidebar":
      showsSidebar.toggle()
      return showsSidebar ? "Sidebar shown." : "Sidebar hidden."
    case "/cancel":
      guard let focused = focusedConversation, focused.isRunning else {
        return "No reply is running in the focused chat."
      }
      cancelFocusedRun()
      return "Cancelled the reply."
    default:
      return nil
    }
  }

  // MARK: Session settings

  public func useProvider(_ id: ProviderID) {
    guard let focused = focusedConversation else { return }
    useProvider(id, for: focused)
  }

  public func useProvider(_ id: ProviderID, for conversation: VisualConversation) {
    conversation.profile.provider = id
    if modelCatalogProvider != id { modelCatalog = [] }
    persistAgentProfile(for: conversation)
    status = "'\(conversation.title)' now uses provider '\(id)'."
  }

  public func useModel(_ id: String) {
    guard let focused = focusedConversation else { return }
    useModel(id, for: focused)
  }

  public func useModel(_ id: String, for conversation: VisualConversation) {
    conversation.profile.model = id
    persistAgentProfile(for: conversation)
  }

  public func updateInstructions(_ instructions: String, for conversation: VisualConversation) {
    conversation.profile.instructions = instructions
    conversation.applyInstructions()
    persistAgentProfile(for: conversation)
  }

  public func setStreaming(_ enabled: Bool, for conversation: VisualConversation) {
    conversation.profile.stream = enabled
    persistAgentProfile(for: conversation)
  }

  public func setToolProxy(_ enabled: Bool, for conversation: VisualConversation) {
    conversation.profile.useToolProxy = enabled
    persistAgentProfile(for: conversation)
  }

  public func useAgent(_ definition: AgentDefinition) {
    guard definition.isEnabled else {
      status = "Agent '\(definition.id)' is disabled. Enable it before using it."
      return
    }
    guard let focused = focusedConversation else { return }
    focused.adopt(profile: definition, title: definition.displayName)
    status = "'\(focused.title)' restarted with agent '\(definition.id)'."
    selectedTab = .chats
  }

  /// Parks or restores a setup. A disabled agent stays in the file, stays
  /// listed, and is never offered to a model choosing a subagent.
  public func setAgentEnabled(_ enabled: Bool, for definition: AgentDefinition) {
    guard let index = configuration.agents.firstIndex(where: { $0.id == definition.id }) else {
      return
    }
    if !enabled, focusedConversation?.profile.id == definition.id {
      status = "Agent '\(definition.id)' is in use by the focused chat."
      return
    }
    configuration.agents[index].isEnabled = enabled
    agents = configuration.agents
    markConfigurationChanged()
    registerAgent(configuration.agents[index])
    status = "Agent '\(definition.id)' \(enabled ? "enabled" : "disabled")."
  }

  public func setAgentDescription(_ text: String, for definition: AgentDefinition) {
    guard let index = configuration.agents.firstIndex(where: { $0.id == definition.id }) else {
      return
    }
    configuration.agents[index].description = text.trimmingCharacters(
      in: .whitespacesAndNewlines)
    agents = configuration.agents
    markConfigurationChanged()
    registerAgent(configuration.agents[index])
    status = "Described agent '\(definition.id)'."
  }

  /// Lets a chat's agent hand tool work to a child, or not. Turning
  /// delegation on with no subagent budget would silently do nothing, so it
  /// raises the budget too.
  public func setToolDelegation(
    _ mode: AgentToolDelegation,
    for conversation: VisualConversation
  ) {
    conversation.profile.toolDelegation = mode
    if mode == .subagent, conversation.profile.limits.maxSubagents < 1 {
      conversation.profile.limits.maxSubagents = 1
    }
    persistAgentProfile(for: conversation)
    status =
      mode == .subagent
      ? "Tool calls for '\(conversation.title)' now run in a child agent."
      : "Tool calls for '\(conversation.title)' now run in the chat."
  }

  public func refreshAgentTree() async {
    agentTree = await runtime.supervisor.tree()
  }

  // MARK: Usage statistics

  public func refreshUsageStats() async {
    guard let store = await runtime.usageStatsStore() else {
      usageLedger = ModelUsageLedger()
      return
    }
    usageLedger = await store.ledger
  }

  public func resetUsageStats() {
    let runtime = runtime
    Task { [weak self] in
      guard let store = await runtime.usageStatsStore() else {
        self?.status = "No usage statistics are recorded in this session."
        return
      }
      await store.reset()
      await self?.refreshUsageStats()
      self?.status = "Usage statistics reset."
    }
  }

  public func removeUsageStats(id: String) {
    let runtime = runtime
    Task { [weak self] in
      guard let store = await runtime.usageStatsStore(), await store.remove(matching: id) > 0
      else {
        return
      }
      await self?.refreshUsageStats()
      self?.status = "Removed the statistics of '\(id)'."
    }
  }

  public func stopAgentProcess(_ pid: AgentPID) {
    let runtime = runtime
    Task { [weak self] in
      let stopped = await runtime.supervisor.stop(pid, reason: "Stopped from visual mode")
      self?.status = "Stopped \(stopped.map(\.description).joined(separator: ", "))."
      await self?.refreshAgentTree()
    }
  }

  private func registerAgent(_ definition: AgentDefinition) {
    let runtime = runtime
    Task { try? await runtime.register(agent: definition, replacingExisting: true) }
  }

  public func setTool(_ name: String, allowed: Bool, for conversation: VisualConversation) {
    if allowed {
      conversation.profile.toolNames.insert(name)
    } else {
      conversation.profile.toolNames.remove(name)
    }
    persistAgentProfile(for: conversation)
  }

  public func isToolGroupEnabled(
    _ group: ToolGroupDefinition,
    for conversation: VisualConversation
  ) -> Bool {
    conversation.profile.toolGroupNames.contains(group.id)
      || group.toolNames.isSubset(of: conversation.profile.toolNames)
  }

  public func setToolGroup(
    _ group: ToolGroupDefinition,
    allowed: Bool,
    for conversation: VisualConversation
  ) {
    if allowed {
      conversation.profile.toolGroupNames.insert(group.id)
      conversation.profile.toolNames.formUnion(group.toolNames)
    } else {
      conversation.profile.toolGroupNames.remove(group.id)
      conversation.profile.toolNames.subtract(group.toolNames)
    }
    persistAgentProfile(for: conversation)
  }

  public func configuredToolGroupOptions(_ group: ToolGroupDefinition) -> [String: JSONValue] {
    guard let source = configuration.toolSources.first(where: { $0.id == group.sourceID }) else {
      return Dictionary(
        uniqueKeysWithValues: group.options.compactMap { option in
          option.defaultValue.map { (option.id, $0) }
        })
    }
    return Dictionary(
      uniqueKeysWithValues: group.options.compactMap { option in
        source.options[option.id].map { (option.id, $0) }
          ?? option.defaultValue.map { (option.id, $0) }
      })
  }

  public func configureToolGroup(
    _ group: ToolGroupDefinition,
    options: [String: JSONValue]
  ) async throws {
    guard let index = configuration.toolSources.firstIndex(where: { $0.id == group.sourceID })
    else {
      throw VisualWorkspaceError.missingField("tool source for \(group.displayName)")
    }
    var source = configuration.toolSources[index]
    for option in group.options {
      if let value = options[option.id] {
        source.options[option.id] = value
      } else {
        source.options.removeValue(forKey: option.id)
      }
    }
    let context = source.context(environment: environment)
    let replacementTools = try await plugins.makeTools(kind: source.kind, context: context)
    let replacementGroups = try await plugins.toolGroups(kind: source.kind, context: context)
    for tool in replacementTools {
      try await runtime.register(tool: tool, replacingExisting: true)
    }
    let replacement = replacementGroups.first { $0.id == group.id }
    for index in configuration.agents.indices
    where configuration.agents[index].toolGroupNames.contains(group.id)
      || group.toolNames.isSubset(of: configuration.agents[index].toolNames)
    {
      configuration.agents[index].toolGroupNames.insert(group.id)
      configuration.agents[index].toolNames.subtract(group.toolNames)
      if let replacement {
        configuration.agents[index].toolNames.formUnion(replacement.toolNames)
      }
    }
    for conversation in conversations where isToolGroupEnabled(group, for: conversation) {
      conversation.profile.toolGroupNames.insert(group.id)
      conversation.profile.toolNames.subtract(group.toolNames)
      if let replacement {
        conversation.profile.toolNames.formUnion(replacement.toolNames)
      }
      upsert(conversation.profile, into: &configuration.agents)
    }
    for agent in configuration.agents {
      try await runtime.register(agent: agent, replacingExisting: true)
    }
    configuration.toolSources[index] = source
    markConfigurationChanged()
    try saveConfiguration()
    await refreshRegistries()
    status = "Updated \(group.displayName) settings."
  }

  public func fetchModels(for provider: ProviderID) async {
    isFetchingModels = true
    defer { isFetchingModels = false }
    do {
      modelCatalog = try await runtime.availableModels(provider: provider)
      modelCatalogProvider = provider
      status =
        modelCatalog.isEmpty
        ? "Provider '\(provider)' returned no models."
        : "Loaded \(modelCatalog.count) models from '\(provider)'."
    } catch {
      modelCatalog = []
      modelCatalogProvider = provider
      status = "error: \(error.localizedDescription)"
    }
  }

  // MARK: Registration

  public func registerProvider(_ form: ProviderForm) async throws {
    let id = try required(form.id, "Identifier")
    let kind = try required(form.kind, "Kind")
    var baseURL: URL?
    let rawURL = form.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    if !rawURL.isEmpty {
      guard let url = URL(string: rawURL), url.scheme != nil else {
        throw VisualWorkspaceError.invalidURL(rawURL)
      }
      baseURL = url
    }
    let apiKeyEnvironment = optional(form.apiKeyEnvironment)
    let existing = configuration.providers.first { $0.id == id }
    var configured = existing ?? ConfiguredProvider(id: id, kind: ConfiguredProviderKind(kind))
    configured.kind = ConfiguredProviderKind(kind)
    configured.displayName = optional(form.displayName)
    configured.baseURL = baseURL
    if let apiKeyEnvironment {
      configured.apiKey = nil
      configured.apiKeyEnvironment = apiKeyEnvironment
    } else if let apiKey = optional(form.apiKey) {
      configured.apiKey = apiKey
      configured.apiKeyEnvironment = nil
    } else {
      configured.apiKeyEnvironment = nil
    }
    let provider = try await plugins.makeProvider(from: configured, environment: environment)
    try await runtime.register(provider, replacingExisting: true)
    upsert(configured, into: &configuration.providers)
    try saveConfiguration()
    await refreshRegistries()
    status = "Registered provider '\(id)'."
  }

  public func connectMCPServer(_ form: MCPServerForm) async throws {
    let id = try required(form.id, "Identifier")
    let rawURL = try required(form.url, "URL")
    guard let url = URL(string: rawURL), url.scheme != nil else {
      throw VisualWorkspaceError.invalidURL(rawURL)
    }
    let tokenEnvironment = optional(form.bearerTokenEnvironment)
    let configured = ConfiguredMCPServer(
      id: id,
      kind: optional(form.kind) ?? "streamable-http",
      enabled: true,
      displayName: optional(form.displayName),
      url: url,
      bearerToken: tokenEnvironment == nil ? optional(form.bearerToken) : nil,
      bearerTokenEnvironment: tokenEnvironment,
      toolNamePrefix: optional(form.toolNamePrefix),
      defaultApproval: form.approval)
    status = "Connecting to MCP server '\(id)'…"
    let source = try await plugins.makeMCPToolSource(
      kind: configured.kind,
      configuration: configured,
      environment: environment)
    let catalog: MCPServerCatalog
    do {
      catalog = try await runtime.register(mcp: source, replacingExistingTools: true)
    } catch {
      status = nil
      throw error
    }
    catalogs.removeAll { $0.serverID == catalog.serverID }
    catalogs.append(catalog)
    upsert(configured, into: &configuration.mcpServers)
    try saveConfiguration()
    await refreshRegistries()
    status = "Connected MCP server '\(id)' with \(catalog.tools.count) tools."
  }

  public func registerToolSource(_ form: ToolSourceForm) async throws {
    let id = try required(form.id, "Identifier")
    let kind = try required(form.kind, "Kind")
    let options = try parseOptions(form.optionsJSON)
    let configured = ConfiguredToolSource(
      id: id,
      kind: kind,
      enabled: true,
      displayName: optional(form.displayName),
      options: options)
    let tools = try await plugins.makeTools(
      kind: kind,
      context: configured.context(environment: environment))
    for tool in tools {
      try await runtime.register(tool: tool, replacingExisting: true)
    }
    upsert(configured, into: &configuration.toolSources)
    try saveConfiguration()
    await refreshRegistries()
    status = "Registered \(tools.count) tools from '\(id)'."
  }

  public func saveFocusedConversationAsAgent(_ form: AgentForm) async throws {
    guard let focused = focusedConversation else {
      throw VisualWorkspaceError.noFocusedConversation
    }
    let id = try required(form.id, "Identifier")
    var definition = focused.profile
    definition.id = id
    definition.displayName = optional(form.displayName) ?? id
    definition.description = optional(form.description) ?? definition.description
    try await runtime.register(agent: definition, replacingExisting: true)
    upsert(definition, into: &configuration.agents)
    if configuration.defaultAgent == nil {
      configuration.defaultAgent = id
      markConfigurationChanged()
    }
    focused.profile.id = id
    try saveConfiguration()
    await refreshRegistries()
    status = "Saved agent '\(id)'."
  }

  /// Validates the draft and writes it to `configurationPath`.
  public func saveConfiguration() throws {
    let url = URL(fileURLWithPath: configurationPath)
    try configuration.save(to: url)
    configurationNeedsSave = false
    status = "Saved configuration to \(configurationPath)."
  }

  public func configuredProvider(_ id: ProviderID) -> ConfiguredProvider? {
    configuration.providers.first { $0.id == id.rawValue }
  }

  public var disabledMCPServers: [ConfiguredMCPServer] {
    configuration.mcpServers.filter { server in
      !catalogs.contains { $0.serverID == server.id }
    }
  }

  // MARK: Approvals

  func presentCompaction(_ pending: VisualApprovalHandler.PendingCompaction) async {
    if let pid = pending.request.run.pid,
      let conversation = conversations.first(where: { $0.processID == pid })
    {
      let transcript = await runtime.supervisor.transcript(pid)
      conversation.transcript.replaceAll(with: transcript)
    }
    if pendingCompaction == nil {
      pendingCompaction = pending
      presentedCompactionID = pending.id
    } else {
      compactionQueue.append(pending)
    }
  }

  func dismissCompaction(_ id: UUID) {
    compactionQueue.removeAll { $0.id == id }
    guard presentedCompactionID == id else { return }
    pendingCompaction = compactionQueue.isEmpty ? nil : compactionQueue.removeFirst()
    presentedCompactionID = pendingCompaction?.id
  }

  public func resolveCompaction(_ decision: AutocompactionDecision, clearChat: Bool = false) {
    guard let id = presentedCompactionID else { return }
    if clearChat, let pid = pendingCompaction?.request.run.pid,
      let conversation = conversations.first(where: { $0.processID == pid })
    {
      conversation.cancelRun()
      conversation.resetTranscript()
    }
    dismissCompaction(id)
    Task { await approvals.resolveCompaction(id, with: decision) }
  }

  public func compactionSheetDismissed() {
    // A programmatic resolution may already have presented the next request.
    guard pendingCompaction == nil else { return }
    resolveCompaction(.cancelRun)
  }

  public var canClearCompactionChat: Bool {
    guard let pid = pendingCompaction?.request.run.pid else { return false }
    return conversations.contains { $0.processID == pid }
  }

  public func stopCompactionToChangeModel() {
    resolveCompaction(.cancelRun)
    status = "Response stopped with its messages kept. Change the chat model or use /model -compact NAME, then send continue."
  }

  func present(_ pending: VisualApprovalHandler.Pending) {
    if pendingApproval == nil {
      pendingApproval = pending
      presentedApprovalID = pending.id
    } else {
      approvalQueue.append(pending)
    }
    status = "Approval requested for tool '\(pending.request.tool.name)'."
  }

  public func resolveApproval(_ decision: ApprovalDecision) {
    guard let id = presentedApprovalID else { return }
    presentedApprovalID = nil
    pendingApproval = nil
    let approvals = approvals
    Task { await approvals.resolve(id, with: decision) }
    status = nil
    presentNextApproval()
  }

  public func resolveApprovalAlways() {
    let pending = [pendingApproval].compactMap { $0 } + approvalQueue
    guard !pending.isEmpty else { return }
    presentedApprovalID = nil
    pendingApproval = nil
    approvalQueue.removeAll()
    let approvals = approvals
    Task { await approvals.resolveAlways(pending) }
    status = "YOLO mode enabled; all tool calls are permitted for this session."
  }

  /// Called when the approval sheet closes without a decision, for example on Escape.
  public func approvalSheetDismissed() {
    guard presentedApprovalID != nil else {
      presentNextApproval()
      return
    }
    resolveApproval(.deny(reason: "Dismissed without approval."))
  }

  private func presentNextApproval() {
    guard pendingApproval == nil, !approvalQueue.isEmpty else { return }
    let next = approvalQueue.removeFirst()
    pendingApproval = next
    presentedApprovalID = next.id
  }

  // MARK: Exit

  public func shutdown() -> VisualOutcome {
    for conversation in conversations { conversation.cancelRun() }
    let focused = focusedConversation ?? conversations[0]
    let others = conversations.count - 1
    var summary = "Back in the REPL with '\(focused.title)'"
    if others > 0 {
      summary += "; \(others) other conversation\(others == 1 ? "" : "s") kept for the next /visual"
    }
    summary += "."
    return VisualOutcome(
      focusedConversation: focused.seed,
      snapshot: VisualWorkspaceSnapshot(
        conversations: conversations.map(\.seed),
        layout: layout,
        selectedTab: selectedTab),
      configuration: configuration,
      configurationChanged: configurationChanged,
      catalogs: catalogs,
      summary: summary)
  }

  // MARK: Helpers

  private func required(_ value: String, _ name: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VisualWorkspaceError.missingField(name) }
    return trimmed
  }

  private func optional(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private func parseOptions(_ json: String) throws -> [String: JSONValue] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [:] }
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
      guard let object = value.objectValue else {
        throw VisualWorkspaceError.invalidOptions("the top-level value is not an object")
      }
      return object
    } catch let error as VisualWorkspaceError {
      throw error
    } catch {
      throw VisualWorkspaceError.invalidOptions(error.localizedDescription)
    }
  }

  private func upsert<Item: Identifiable>(_ item: Item, into items: inout [Item]) {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
    }
    markConfigurationChanged()
  }

  private func markConfigurationChanged() {
    configurationChanged = true
    configurationNeedsSave = true
  }

  private func persistAgentProfile(for conversation: VisualConversation) {
    let definition = conversation.profile
    if let promptName = definition.systemPrompt {
      var prompts = configuration.prompts ?? ConfiguredPrompts()
      prompts.system[promptName] = definition.instructions
      configuration.prompts = prompts
      for index in configuration.agents.indices
      where configuration.agents[index].systemPrompt == promptName {
        configuration.agents[index].instructions = definition.instructions
      }
    }
    upsert(definition, into: &configuration.agents)
    if configuration.defaultAgent == nil {
      configuration.defaultAgent = definition.id
      markConfigurationChanged()
    }
    do {
      try saveConfiguration()
      let runtime = runtime
      let affectedAgents =
        definition.systemPrompt.map { promptName in
          configuration.agents.filter { $0.systemPrompt == promptName }
        } ?? [definition]
      Task {
        for agent in affectedAgents {
          try? await runtime.register(agent: agent, replacingExisting: true)
        }
      }
    } catch {
      status = "error: \(error.localizedDescription)"
    }
  }
}
