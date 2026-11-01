import AVFoundation
import Foundation
import MaiCore
import MaiACP
import MaiStandardTools
import UIKit

@MainActor
enum BuiltInToolCatalog {
  static func definitions(
    for conversation: Conversation,
    settings: AppSettings
  ) -> [ToolDefinition] {
    BuiltInToolID.allCases.flatMap { id -> [ToolDefinition] in
      guard conversation.enabledTools.contains(id) else { return [] }
      guard id.isCallableTool else { return [] }
      guard !(settings.isOffline && id.isDisabledInAirplaneMode) else {
        return []
      }
      return definitions(for: id, conversation: conversation, settings: settings)
    }
  }

  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    settings: AppSettings,
    store: AppStore
  ) async -> String? {
    switch call.name {
    case let name where RemoteWorkspaceTools.definitions.contains(where: { $0.name == name }):
      guard !store.settings.isOffline else { return "Error: remote hosts are unavailable while offline." }
      do {
        return try await PocketMaiRemoteTools.shared.call(name, arguments: .object(call.argumentValues),
          owner: conversation.id.uuidString).text
      } catch { return "Error: \(error.localizedDescription)" }
    case let name where TodoTool.toolNames.contains(name):
      return TodoTool.execute(name: name, arguments: call.argumentValues, store: store)
    case MaiCalculatorTool.name:
      return await PocketMaiPluginHost.shared.callStandardTool(
        name: call.name,
        arguments: call.argumentValues)
    case MaiVectorDatabaseTool.name:
      guard conversation.toolsEnabled, conversation.enabledTools.contains(.vdb),
        store.settings.toolSettings.filesWorkspaceAccessEnabled
      else {
        return "Error: enable Local documentation and Files workspace access to use vdb."
      }
      do {
        let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
        if let bookmark = resolved.refreshedBookmarkData {
          store.refreshWorkingFolderBookmark(
            conversationID: conversation.id, bookmarkData: bookmark)
        }
        let workspace = resolved.context
        return await PocketMaiPluginHost.shared.call(
          tool: MaiVectorDatabaseTool(
            configuration: MaiFileWorkspaceConfiguration(
              rootURL: workspace.rootURL, displayName: workspace.displayName,
              isSecurityScoped: workspace.isSecurityScoped,
              hiddenRootEntryNames: workspace.hidesModelsFolder ? ["Models"] : [])),
          arguments: call.argumentValues)
      } catch {
        return
          "Error: the working folder is no longer accessible. Select it again from the chat's + menu."
      }
    case MaiWebSearchTool.name:
      return await PocketMaiPluginHost.shared.call(
        tool: MaiWebSearchTool(configuration: store.settings.maiWebSearchConfiguration),
        arguments: call.argumentValues)
    case MaiWebFetchTool.name:
      return await PocketMaiPluginHost.shared.call(
        tool: MaiWebFetchTool(), arguments: call.argumentValues)
    case TextToSpeechTool.name:
      return TextToSpeechTool.speak(
        arguments: call.argumentValues,
        settings: store.effectiveToolSettings(for: conversation),
        skipTechnicalContent: store.effectiveConversationSettings(for: conversation)
          .skipTechnicalContentInTTS,
        openAIEndpoints: store.settings.isOffline ? [] : store.settings.openAIEndpoints)
    case MaiWeatherTool.name:
      let tool = await PocketMaiNetworkTools.weatherTool(
        arguments: call.argumentValues,
        settings: store.settings.toolSettings, locationService: { store.locationService })
      // Location lookup can yield while the user switches modes.
      guard store.settings.internetAccessPolicy.allows(tool.definition) else {
        return "Error: internet tools are disabled while offline."
      }
      return await PocketMaiPluginHost.shared.call(
        tool: tool, arguments: call.argumentValues)
    case let name where MaiFileWorkspaceTool.Operation(rawValue: name) != nil:
      return await executeFileWorkspaceTool(
        name: name,
        arguments: call.argumentValues,
        conversation: conversation,
        settings: settings,
        store: store)
    case CalendarTool.readName:
      return await CalendarTool.readEvents(arguments: call.argumentValues)
    case CalendarTool.createName:
      return await CalendarTool.createEvent(
        arguments: call.argumentValues,
        settings: store.settings.toolSettings)
    case ClipboardTool.getName:
      return ClipboardTool.getText()
    case ClipboardTool.setName:
      return ClipboardTool.setText(arguments: call.argumentValues)
    case AlarmTool.setName:
      return await AlarmTool.set(arguments: call.argumentValues)
    case AlarmTool.listName:
      return AlarmTool.list()
    case AlarmTool.cancelName:
      return AlarmTool.cancel(arguments: call.argumentValues)
    case let name where WebXDCTool.toolNames.contains(name):
      return WebXDCTool.execute(
        name: name, arguments: call.argumentValues, hub: store.webxdcHub)
    case let name where MaiGitHubTool.toolNames.contains(name):
      guard let tool = MaiGitHubTool(name: name, apiKey: store.settings.toolSettings.githubAPIKey)
      else {
        return "Error: GitHub tool '\(name)' is not registered."
      }
      return await PocketMaiPluginHost.shared.call(tool: tool, arguments: call.argumentValues)
    case MaiMastodonTool.name:
      return await PocketMaiPluginHost.shared.call(
        tool: MaiMastodonTool(configuration: store.settings.toolSettings.maiMastodonConfiguration),
        arguments: call.argumentValues)
    case let name where BrowserTool.toolNames.contains(name):
      return await BrowserTool.execute(name: name, arguments: call.argumentValues, store: store)
    case let name where ConversationSearchTool.toolNames.contains(name):
      return await ConversationSearchTool.execute(
        name: name,
        arguments: call.argumentValues,
        conversation: conversation,
        store: store)
    default:
      return nil
    }
  }

  private static func executeFileWorkspaceTool(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    conversation: Conversation,
    settings: AppSettings,
    store: AppStore
  ) async -> String {
    guard fileWorkspaceToolsEnabled(conversation: conversation, settings: settings) else {
      return "Error: Files tools are disabled in Files settings."
    }
    let context: FileWorkspaceContext
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: settings)
      if let refreshed = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(
          conversationID: conversation.id, bookmarkData: refreshed)
      }
      context = resolved.context
    } catch {
      let workspaceName = FileWorkspaceTool.workspaceName(
        for: conversation, settings: settings)
      return
        "Error: working folder '\(workspaceName)' is no longer accessible. Select it again from the chat's + menu."
    }
    if let operation = MaiFileWorkspaceTool.Operation(rawValue: name) {
      return await PocketMaiPluginHost.shared.call(
        tool: MaiFileWorkspaceTool(
          operation: operation,
          configuration: MaiFileWorkspaceConfiguration(
            rootURL: context.rootURL,
            displayName: context.displayName,
            isSecurityScoped: context.isSecurityScoped,
            hiddenRootEntryNames: context.hidesModelsFolder ? ["Models"] : [])),
        arguments: arguments)
    }
    return "Error: Unknown Files tool."
  }

  static func definitions(
    for id: BuiltInToolID,
    conversation: Conversation,
    settings: AppSettings,
    includeUnavailable: Bool = false
  ) -> [ToolDefinition] {
    switch id {
    case .datetime, .language, .location, .memory:
      return []
    case .weather:
      return [MaiWeatherTool.toolDefinition]
    case .webSearch:
      return [MaiWebSearchTool.toolDefinition]
        + (includeUnavailable || settings.toolSettings.webSearchFetchingEnabled
          ? [MaiWebFetchTool.toolDefinition] : [])
    case .todo:
      return TodoTool.definitions
    case .calculator:
      return [MaiCalculatorTool.toolDefinition]
    case .textToSpeech:
      return TextToSpeechTool.definitions
    case .files:
      guard includeUnavailable || settings.toolSettings.filesWorkspaceAccessEnabled else { return [] }
      return FileWorkspaceTool.definitions(
        workspaceName: FileWorkspaceTool.workspaceName(for: conversation, settings: settings),
        includeAdvancedTools: includeUnavailable || settings.toolSettings.filesAdvancedToolsEnabled)
    case .vdb:
      return settings.toolSettings.filesWorkspaceAccessEnabled
        ? [MaiVectorDatabaseTool.toolDefinition] : []
    case .remote:
      return RemoteWorkspaceTools.definitions
    case .calendar:
      var toolSettings = settings.toolSettings
      if includeUnavailable { toolSettings.calendarEventCreationEnabled = true }
      return CalendarTool.definitions(settings: toolSettings)
    case .clipboard:
      return ClipboardTool.definitions
    case .alarms:
      return AlarmTool.definitions
    case .webxdc:
      return WebXDCTool.definitions
    case .github:
      return MaiGitHubTool.definitions
    case .mastodon:
      return [MaiMastodonTool.toolDefinition]
    case .browser:
      return BrowserTool.definitions
    case .context:
      guard includeUnavailable || settings.toolSettings.conversationSearchScope != .none else { return [] }
      return ConversationSearchTool.definitions
    }
  }

  private static func fileWorkspaceToolsEnabled(
    conversation: Conversation,
    settings: AppSettings
  ) -> Bool {
    conversation.toolsEnabled
      && conversation.enabledTools.contains(.files)
      && settings.toolSettings.filesWorkspaceAccessEnabled
  }
}

@MainActor
enum ToolAgentRegistry {
  private struct CatalogSnapshot {
    var conversation: Conversation
    var settings: AppSettings
    var tools: [UUID: [MCPToolDescriptor]]
    var resources: [UUID: [MCPResourceDescriptor]]
    var statuses: [UUID: EndpointConnectionState]
    var catalog: AgentToolCatalog
  }
  private static var snapshots: [CatalogSnapshot] = []
  /// Restore values at the execution boundary, before proxy resolution,
  /// validation and approval. Provider requests mask them again on the way out.
  static func restoredCall(_ call: ParsedToolCall) -> ParsedToolCall {
    guard let redactor = ContentRedactor.current,
      let arguments = redactor.unredact(.object(call.argumentValues)).objectValue
    else { return call }
    return ParsedToolCall(
      name: call.name, arguments: [:], argumentValues: arguments,
      rawBlock: call.rawBlock, toolCallID: call.toolCallID, apiName: call.apiName)
  }

  static func visibleDefinitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    catalog(
      for: conversation, settings: settings, mcpTools: mcpTools,
      mcpResources: mcpResources, mcpStatuses: mcpStatuses
    ).visibleDefinitions
  }

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    catalog(
      for: conversation, settings: settings, mcpTools: mcpTools,
      mcpResources: mcpResources, mcpStatuses: mcpStatuses
    ).enabledDefinitions
  }

  /// Discovery also includes disabled members so Settings can restore them.
  /// Access settings, offline mode, and MCP server grants remain prerequisites.
  static func catalog(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> AgentToolCatalog {
    // Transcript and activity changes do not alter discovery. Keep only a
    // bounded set of metadata snapshots, shared by otherwise identical chats.
    var metadata = conversation
    metadata.messages = []
    metadata.subagents = []
    metadata.historyWindow = nil
    metadata.id = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    metadata.title = ""
    metadata.sessionID = ""
    metadata.createdAt = .distantPast
    metadata.updatedAt = .distantPast
    metadata.lastContextSignature = nil
    if let snapshot = snapshots.last(where: {
      $0.conversation == metadata && $0.settings == settings && $0.tools == mcpTools
        && $0.resources == mcpResources && $0.statuses == mcpStatuses
    }) { return snapshot.catalog }
    var groups: [ToolGroupDefinition] = []
    var definitions: [ToolDefinition] = []
    var enabledNames = Set<String>()
    var unavailableNames = Set<String>()
    var takenNames: Set<String> = [MCPResourceTool.readName]
    var activeNames = Set<String>()
    func append(
      _ tools: [ToolDefinition], group: ToolGroupDefinition, enabled: Set<String>,
      available: Bool = true, availableNames: Set<String>? = nil
    ) {
      var group = group
      let unique = tools.filter { tool in
        let active =
          available && (availableNames?.contains(tool.name) ?? true)
          && settings.toolPolicy.mode(
            for: tool.name, in: [group], enabled: enabled.contains(tool.name),
            useToolProxy: settings.useToolProxy && !settings.useSystemOne, exposedTools: [])
            != .disabled
        if takenNames.contains(tool.name) {
          // A disabled candidate must not shadow a later enabled server's
          // definition. Otherwise retain discovery/dispatch precedence.
          guard tool.name != MCPResourceTool.readName, active, !activeNames.contains(tool.name)
          else { return false }
          definitions.removeAll { $0.name == tool.name }
          for index in groups.indices { groups[index].toolNames.remove(tool.name) }
          enabledNames.remove(tool.name)
          unavailableNames.remove(tool.name)
        }
        takenNames.insert(tool.name)
        if active { activeNames.insert(tool.name) }
        return true
      }
      group.toolNames = Set(unique.map(\.name))
      groups.append(group)
      definitions += unique
      enabledNames.formUnion(group.toolNames.intersection(enabled))
      if !available { unavailableNames.formUnion(group.toolNames) }
      if let availableNames { unavailableNames.formUnion(group.toolNames.subtracting(availableNames)) }
    }
    for id in BuiltInToolID.allCases where id.isCallableTool {
      let tools = BuiltInToolCatalog.definitions(
        for: id, conversation: conversation, settings: settings, includeUnavailable: true)
      let availableNames = Set(BuiltInToolCatalog.definitions(
        for: id, conversation: conversation, settings: settings).map(\.name))
      append(
        tools,
        group: ToolGroupDefinition(
          id: id.rawValue, sourceID: "native", displayName: id.displayName,
          toolNames: Set(tools.map(\.name))),
        enabled: conversation.enabledTools.contains(id) ? Set(tools.map(\.name)) : [],
        availableNames: availableNames)
    }
    let skillDefinitions = SkillTools.catalog(for: conversation, settings: settings).modelInvocable
      .map(MaiSkillTools.definition)
    append(
      skillDefinitions, group: MaiSkillTools.group(toolNames: Set(skillDefinitions.map(\.name))),
      enabled: settings.enabledSkillTools)
    var resourceServers: [(server: MCPServer, resources: [MCPResourceDescriptor])] = []
    for server in settings.mcpServers {
      let available =
        server.isEnabled && server.hasValidEndpointURL
        && conversation.enabledMCPServers.contains(server.id)
        && mcpStatuses[server.id]?.isAvailable == true
      let tools = (mcpTools[server.id] ?? []).filter { !MaiSkillTools.isSkillTool($0.name) }.map {
        tool in
        var definition = tool
        definition.description = cleanedToolDescription(
          tool.description, fallback: "MCP tool from \(server.name).")
        return definition
      }
      append(
        tools,
        group: ToolGroupDefinition(
          id: server.portableID ?? server.id.uuidString.lowercased(), sourceID: "mcp",
          displayName: server.name, toolNames: Set(tools.map(\.name))),
        enabled: Set(
          tools.filter {
            conversation.enabledMCPTools.contains(
              MCPToolSelection.key(serverID: server.id, toolName: $0.name))
          }.map(\.name)), available: available)
      if available { resourceServers.append((server, mcpResources[server.id] ?? [])) }
    }
    if !resourceServers.isEmpty {
      takenNames.remove(MCPResourceTool.readName)
      let tool = MCPResourceTool.definition(for: resourceServers)
      append(
        [tool],
        group: ToolGroupDefinition(
          id: "resources", sourceID: "mcp", displayName: "MCP Resources",
          toolNames: [tool.name]), enabled: [tool.name])
    }
    let agents = SubagentTool.definitions(for: conversation, settings: settings)
    if !agents.isEmpty {
      append(
        agents,
        group: ToolGroupDefinition(
          id: "agents", sourceID: "native", displayName: "Agents",
          toolNames: Set(agents.map(\.name))), enabled: Set(agents.map(\.name)))
    }
    // Preserve the app's legacy pure-proxy default. Explicit Direct and Proxy
    // pins still work with either default and with System One routing.
    var modes = settings.toolPolicy.modes(
      for: Set(definitions.map(\.name)), in: groups, enabledNames: enabledNames,
      useToolProxy: settings.useToolProxy && !settings.useSystemOne, exposedTools: [])
    for name in unavailableNames { modes[name] = .disabled }
    if !conversation.toolsEnabled {
      modes = modes.mapValues { _ in .disabled }
    }
    let catalog = AgentToolCatalog(groups: groups, tools: definitions, modes: modes,
      internetAccess: settings.internetAccessPolicy)
    if snapshots.count >= 32 { snapshots.removeFirst() }
    snapshots.append(CatalogSnapshot(conversation: metadata, settings: settings,
      tools: mcpTools, resources: mcpResources, statuses: mcpStatuses, catalog: catalog))
    return catalog
  }

  private static func cleanedToolDescription(_ text: String, fallback: String) -> String {
    let cleaned = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return cleaned.isEmpty ? fallback : cleaned
  }

  static func execute(
    call: ParsedToolCall,
    conversationID: UUID,
    store: AppStore
  ) async -> String {
    guard let conversation = store.conversation(withID: conversationID) else {
      return "Error: conversation is no longer available."
    }
    return await execute(call: call, conversation: conversation, store: store)
  }

  /// Runs a call for a conversation the store owns, with the live settings.
  /// An isolated run — a child agent, the OpenAPI server — passes the
  /// settings it was started with instead, so a child sees the tools of the
  /// agent it runs as.
  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    settings: AppSettings? = nil,
    store: AppStore
  ) async -> String {
    let settings = settings ?? store.settings
    let call = restoredCall(call)
    let toolCatalog = catalog(
      for: conversation, settings: settings, mcpTools: store.mcpTools,
      mcpResources: store.mcpResources, mcpStatuses: store.mcpStatuses)
    let fullDefinitions = toolCatalog.enabledDefinitions
    let visibleDefinitions = toolCatalog.visibleDefinitions
    let callableDefinitions = toolCatalog.callableDefinitions
    let visibleCall = AgentTooling.normalized(call: call, tools: callableDefinitions)
    guard AgentTooling.containsDefinition(named: visibleCall.name, in: callableDefinitions) else {
      return AgentTooling.unavailableToolError(name: visibleCall.name)
    }

    if visibleDefinitions.contains(where: { $0.name == ToolProxy.callName }) {
      switch visibleCall.name {
      case ToolProxy.listName:
        return ToolProxy.listTools(
          arguments: visibleCall.argumentValues, definitions: toolCatalog.listedDefinitions)
      case ToolProxy.callName:
        let resolved = ToolProxy.resolveCall(
          arguments: visibleCall.argumentValues,
          definitions: fullDefinitions)
        guard let call = resolved.call else {
          return resolved.error ?? "Error: invalid proxied tool call."
        }
        return await executeConcrete(
          call: call,
          conversation: conversation,
          settings: settings,
          store: store,
          definitions: fullDefinitions)
      default:
        break
      }
    }

    return await executeConcrete(
      call: visibleCall,
      conversation: conversation,
      settings: settings,
      store: store,
      definitions: fullDefinitions)
  }

  fileprivate static func executeConcrete(
    call: ParsedToolCall,
    conversation: Conversation,
    settings: AppSettings,
    store: AppStore,
    definitions: [ToolDefinition]
  ) async -> String {
    let normalizedCall = AgentTooling.normalized(call: call, tools: definitions)
    guard let definition = definitions.first(where: { $0.name == normalizedCall.name }) else {
      return AgentTooling.unavailableToolError(name: normalizedCall.name)
    }
    let executionCatalog = catalog(
      for: conversation, settings: settings, mcpTools: store.mcpTools,
      mcpResources: store.mcpResources, mcpStatuses: store.mcpStatuses)
    guard store.settings.internetAccessPolicy.allows(definition, in: executionCatalog.groups) else {
      return "Error: internet tools are disabled while offline."
    }
    if MaiSkillTools.isSkillTool(normalizedCall.name) {
      return SkillTools.execute(
        call: normalizedCall, conversation: conversation, settings: settings)
    }
    if SubagentTool.isAgentTool(normalizedCall.name) {
      return await SubagentTool.execute(
        call: normalizedCall,
        conversation: conversation,
        settings: settings,
        store: store)
    }
    var executionConversation = conversation
    for id in BuiltInToolID.allCases where id.isCallableTool {
      if BuiltInToolCatalog.definitions(for: id, conversation: conversation, settings: settings)
        .contains(where: { $0.name == normalizedCall.name })
      {
        executionConversation.enabledTools.insert(id)
      }
    }
    if executionCatalog.groups.contains(where: {
      $0.sourceID == "native" && $0.toolNames.contains(normalizedCall.name)
    }),
      let result = await BuiltInToolCatalog.execute(
        call: normalizedCall,
        conversation: executionConversation,
        settings: settings,
        store: store)
    {
      return result
    }
    if normalizedCall.name == MCPResourceTool.readName {
      return await MCPResourceTool.read(
        arguments: normalizedCall.argumentValues,
        conversation: conversation,
        store: store)
    }
    return await dispatchMCP(
      call: normalizedCall, conversation: conversation, settings: settings,
      catalog: executionCatalog, store: store)
  }

  private static func dispatchMCP(
    call: ParsedToolCall,
    conversation: Conversation,
    settings: AppSettings,
    catalog: AgentToolCatalog,
    store: AppStore
  ) async -> String {
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
      && store.mcpStatuses[server.id]?.isAvailable == true
    {
      let tools = store.mcpTools[server.id] ?? []
      guard let definition = tools.first(where: { $0.name == call.name }) else { continue }
      let catalogID = "mcp/\(server.portableID ?? server.id.uuidString.lowercased())"
      guard
        catalog.groups.contains(where: {
          $0.catalogID == catalogID && $0.toolNames.contains(call.name)
        })
      else { continue }
      do {
        let server = try await store.authorizedMCPServer(server)
        guard store.settings.internetAccessPolicy.allows(
          definition, in: catalog.groups)
        else { return "Error: internet tools are disabled while offline." }
        return try await MCPHTTPClient.callTool(
          server: server,
          name: call.name,
          arguments: call.argumentValues,
          timeout: InteractiveOperationTimeout.extendedTransportTimeoutInterval)
      } catch {
        if MCPHTTPClient.isAvailabilityFailure(error) {
          store.markMCPUnavailable(serverID: server.id, message: error.localizedDescription)
        }
        return "Error calling MCP tool '\(call.name)': \(error.localizedDescription)"
      }
    }
    return "Error: unknown tool '\(call.name)'. Refresh MCP tools in Settings if you expect it."
  }

}

@MainActor
enum MCPResourceTool {
  static let readName = "mcp_read_resource"

  static func definition(
    for servers: [(server: MCPServer, resources: [MCPResourceDescriptor])]
  ) -> ToolDefinition {
    let resourceLines = servers.flatMap { server, resources in
      resources.map { resource in
        let label = resource.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = label.isEmpty ? "" : " - \(label)"
        return "- \(resource.uri)\(suffix) (\(server.name))"
      }
    }
    let listed = resourceLines.prefix(60).joined(separator: "\n")
    let overflow = resourceLines.count > 60 ? "\n- ...and more resources." : ""
    let knownResources =
      listed.isEmpty
      ? "No cached resources are listed yet. Use a known MCP resource URI such as uapi://agent-guide when the matching server is enabled."
      : "Known enabled MCP resources:\n\(listed)\(overflow)"
    return ToolDefinition(
      name: readName,
      description:
        "Read an MCP resource by URI through the matching enabled MCP server. Use this for resource URIs such as uapi://agent-guide. \(knownResources)",
      parameters: [
        ToolParameterDef(
          name: "uri",
          type: "string",
          description: "Exact MCP resource URI, for example uapi://agent-guide.",
          required: true)
      ])
  }

  static func read(
    arguments: [String: AgentToolArgumentValue],
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    let uri =
      arguments["uri"]?.stringValue ?? arguments["url"]?.stringValue
      ?? arguments["resource"]?.stringValue ?? ""
    let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedURI.isEmpty else {
      return "Error: missing required argument 'uri' for tool '\(readName)'."
    }
    guard let server = resolveServer(for: trimmedURI, conversation: conversation, store: store)
    else {
      let available = availableResourceURIs(conversation: conversation, store: store)
      let suffix =
        available.isEmpty ? "" : " Available resources: \(available.joined(separator: ", "))"
      return "Error: no enabled MCP server can read resource '\(trimmedURI)'.\(suffix)"
    }
    do {
      let server = try await store.authorizedMCPServer(server)
      return try await MCPHTTPClient.readResource(
        server: server,
        uri: trimmedURI,
        timeout: InteractiveOperationTimeout.extendedTransportTimeoutInterval)
    } catch {
      if MCPHTTPClient.isAvailabilityFailure(error) {
        store.markMCPUnavailable(serverID: server.id, message: error.localizedDescription)
      }
      return "Error reading MCP resource '\(trimmedURI)': \(error.localizedDescription)"
    }
  }

  private static func resolveServer(
    for uri: String,
    conversation: Conversation,
    store: AppStore
  ) -> MCPServer? {
    let enabledServers = store.settings.mcpServers.filter {
      $0.isEnabled && $0.hasValidEndpointURL && conversation.enabledMCPServers.contains($0.id)
        && store.mcpStatuses[$0.id]?.isAvailable == true
    }
    if let exact = enabledServers.first(where: { server in
      (store.mcpResources[server.id] ?? []).contains { $0.uri == uri }
    }) {
      return exact
    }
    if let scheme = URLComponents(string: uri)?.scheme?.lowercased(),
      let byScheme = enabledServers.first(where: { schemeMatches(scheme, serverName: $0.name) })
    {
      return byScheme
    }
    return enabledServers.count == 1 ? enabledServers.first : nil
  }

  private static func availableResourceURIs(
    conversation: Conversation,
    store: AppStore
  ) -> [String] {
    store.settings.mcpServers
      .filter {
        $0.isEnabled && conversation.enabledMCPServers.contains($0.id)
          && store.mcpStatuses[$0.id]?.isAvailable == true
      }
      .flatMap { store.mcpResources[$0.id] ?? [] }
      .map(\.uri)
      .sorted()
  }

  private static func normalizedScheme(_ name: String) -> String {
    name.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "." || $0 == "-" }
  }

  private static func schemeMatches(_ scheme: String, serverName: String) -> Bool {
    if normalizedScheme(serverName) == scheme {
      return true
    }
    return serverName.lowercased()
      .split { !$0.isLetter && !$0.isNumber && $0 != "+" && $0 != "." && $0 != "-" }
      .contains { $0 == scheme }
  }
}

@MainActor
enum FileWorkspaceTool {
  static let listName = MaiFileWorkspaceTool.Operation.list.rawValue
  static let findName = MaiFileWorkspaceTool.Operation.find.rawValue
  static let grepName = MaiFileWorkspaceTool.Operation.grep.rawValue
  static let readName = MaiFileWorkspaceTool.Operation.read.rawValue
  static let readIndexName = MaiFileWorkspaceTool.Operation.readIndex.rawValue
  static let readRangeName = MaiFileWorkspaceTool.Operation.readRange.rawValue
  static let replaceRangeName = MaiFileWorkspaceTool.Operation.replaceRange.rawValue
  static let patchName = MaiFileWorkspaceTool.Operation.patch.rawValue
  static let writeName = MaiFileWorkspaceTool.Operation.write.rawValue
  static let renameName = MaiFileWorkspaceTool.Operation.rename.rawValue
  static let deleteName = MaiFileWorkspaceTool.Operation.delete.rawValue

  /// The working folder the Files tools operate in for this conversation:
  /// the chat's own selection, else the chat folder's default, else nil for
  /// the built-in FilesData workspace.
  static func workingFolderReference(
    for conversation: Conversation,
    settings: AppSettings
  ) -> WorkingFolderReference? {
    conversation.workingFolder
      ?? settings.conversationFolderDefaults[conversation.folderID]?.workingFolder
  }

  static func workspaceName(for conversation: Conversation, settings: AppSettings) -> String {
    workingFolderReference(for: conversation, settings: settings)?.displayName
      ?? FileWorkspaceService.defaultWorkspaceName
  }

  static func context(
    for conversation: Conversation,
    settings: AppSettings
  ) throws -> (context: FileWorkspaceContext, refreshedBookmarkData: Data?) {
    guard let reference = workingFolderReference(for: conversation, settings: settings) else {
      return (try FileWorkspaceContext.filesData(), nil)
    }
    let resolved = try WorkingFolderAccess.resolve(reference)
    return (
      FileWorkspaceContext.custom(rootURL: resolved.url, displayName: reference.displayName),
      resolved.refreshedBookmarkData
    )
  }

  static func definitions(
    workspaceName name: String,
    includeAdvancedTools: Bool
  ) -> [ToolDefinition] {
    let definitions = MaiFileWorkspaceTool.makeTools(
      configuration: MaiFileWorkspaceConfiguration(
        rootURL: PocketMaiDirectories.filesWorkspaceURL,
        displayName: name),
      includeAdvancedTools: includeAdvancedTools
    )
    .map(\.definition)
    return definitions
  }
}

@MainActor
enum CalendarTool {
  static let readName = "calendar_read_events"
  static let createName = "calendar_create_event"

  static func definitions(settings: NativeToolSettings) -> [ToolDefinition] {
    var definitions = [
      ToolDefinition(
        name: readName,
        description:
          "Read calendar events for a handy date phrase, one date, or an explicit date range. Returns limited event details only.",
        parameters: [
          ToolParameterDef(
            name: "range",
            type: "string",
            description:
              "Handy range phrase: today, tomorrow, yesterday, week, week ahead, this week, next week, this month, next month. The host converts this to local YYYY-MM-DD boundaries. Default: today.",
            required: false),
          ToolParameterDef(
            name: "date",
            type: "string",
            description:
              "One local date to read: YYYY-MM-DD, today, tomorrow, or yesterday. Omit when using range or start_date/end_date.",
            required: false),
          ToolParameterDef(
            name: "start_date",
            type: "string",
            description:
              "Range start as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday. Required with end_date for a custom range.",
            required: false),
          ToolParameterDef(
            name: "end_date",
            type: "string",
            description:
              "Range end as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday. Required with start_date for a custom range.",
            required: false),
        ])
    ]
    if settings.calendarEventCreationEnabled {
      definitions.append(
        ToolDefinition(
          name: createName,
          description:
            "Create one calendar event. Only available when Calendar event creation is enabled in Settings.",
          parameters: [
            ToolParameterDef(
              name: "title",
              type: "string",
              description: "Event title.",
              required: true),
            ToolParameterDef(
              name: "start_date",
              type: "string",
              description:
                "Event start as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday.",
              required: true),
            ToolParameterDef(
              name: "end_date",
              type: "string",
              description:
                "Event end as YYYY-MM-DD, ISO 8601 date-time, today, tomorrow, or yesterday.",
              required: true),
            ToolParameterDef(
              name: "all_day",
              type: "boolean",
              description: "Create an all-day event. Default: false.",
              required: false),
            ToolParameterDef(
              name: "location",
              type: "string",
              description: "Event location. Omit unless the user specified one.",
              required: false),
            ToolParameterDef(
              name: "notes",
              type: "string",
              description: "Short event notes. Omit unless the user specified notes.",
              required: false),
          ]))
    }
    return definitions
  }

  static func readEvents(arguments: [String: AgentToolArgumentValue]) async -> String {
    await CalendarEventService.readEvents(arguments: arguments)
  }

  static func createEvent(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings
  ) async -> String {
    await CalendarEventService.createEvent(arguments: arguments, settings: settings)
  }
}

@MainActor
enum ClipboardTool {
  static let getName = "clipboard_get_text"
  static let setName = "clipboard_set_text"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: getName,
      description: "Read the current text content of the system clipboard.",
      parameters: []
    ),
    ToolDefinition(
      name: setName,
      description: "Replace the system clipboard content with the given text.",
      parameters: [
        ToolParameterDef(
          name: "text", type: "string",
          description: "Text to place on the clipboard.",
          required: true)
      ]
    ),
  ]

  static func getText() -> String {
    guard UIPasteboard.general.hasStrings else {
      return "The clipboard has no text content."
    }
    guard let text = UIPasteboard.general.string, !text.isEmpty else {
      return "The clipboard has no text content."
    }
    return text
  }

  static func setText(arguments: [String: AgentToolArgumentValue]) -> String {
    let text =
      arguments["text"]?.stringValue ?? arguments["content"]?.stringValue
      ?? arguments["value"]?.stringValue ?? ""
    guard !text.isEmpty else { return "Error: text is required." }
    UIPasteboard.general.string = text
    return "Copied \(text.count) characters to the clipboard."
  }
}

/// The todo tools live in MaiCore and are shared with pmai; here the list
/// they drive is the one in tool settings, which the Todo settings screen
/// edits as well.
@MainActor
enum TodoTool {
  static let toolNames = MaiTodoTools.toolNames
  static let definitions = MaiTodoTools.definitions

  static func execute(
    name: String,
    arguments: [String: AgentToolArgumentValue],
    store: AppStore
  ) -> String {
    var list = AgentTodoList(items: store.settings.toolSettings.todos)
    let result = MaiTodoTools.execute(name: name, arguments: arguments, list: &list)
    if list.items != store.settings.toolSettings.todos {
      store.settings.toolSettings.todos = list.items
      store.saveSettings()
    }
    return result
  }
}

@MainActor
enum TextToSpeechTool {
  static let name = "text-to-speech"

  static let definitions: [ToolDefinition] = [
    ToolDefinition(
      name: name,
      description:
        "Speak text aloud on this device.",
      parameters: [
        ToolParameterDef(
          name: "text", type: "string",
          description: "Text to speak.",
          required: true),
        ToolParameterDef(
          name: "language", type: "string",
          description: "BCP-47 language, such as en-US or es-ES.",
          required: false),
        ToolParameterDef(
          name: "voice", type: "string",
          description: "Voice identifier.",
          required: false),
        ToolParameterDef(
          name: "rate", type: "number",
          description: "Speaking rate from 0.0 to 1.0.",
          required: false),
        ToolParameterDef(
          name: "pitch", type: "number",
          description: "Pitch multiplier from 0.5 to 2.0.",
          required: false),
        ToolParameterDef(
          name: "interrupt", type: "boolean",
          description: "Stop current speech first. Default: true.",
          required: false),
      ])
  ]

  static func speak(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings,
    skipTechnicalContent: Bool = true,
    openAIEndpoints: [OpenAIEndpoint] = [],
    role: VoiceRole = .assistant,
    title: String? = nil,
    messageID: UUID? = nil,
    player: TTSPlayer = .shared
  ) -> String {
    let text = TTSSpeechTextSanitizer.sanitized(
      arguments["text"]?.stringValue ?? "",
      skipTechnicalContent: skipTechnicalContent)
    guard !text.isEmpty else { return "Error: text is required." }

    let interrupt = arguments["interrupt"]?.boolValue ?? true
    let roleDefaults = settings.voices.settings(for: role)
    let voiceOverride =
      AgentTooling.firstNonEmpty(
        arguments["voice"]?.stringValue,
        arguments["voice_identifier"]?.stringValue)
    let languageOverride = arguments["language"]?.stringValue
    var voice = roleDefaults
    voice.language = languageOverride ?? roleDefaults.language
    voice.rate = arguments["rate"]?.numberValue ?? roleDefaults.rate
    voice.pitch = arguments["pitch"]?.numberValue ?? roleDefaults.pitch
    if let voiceOverride {
      if roleDefaults.provider == .openAICompatible {
        voice.openAIVoice = voiceOverride
      } else {
        voice.voiceIdentifier = voiceOverride
      }
    }
    let selectedVoice = RoleVoiceSettings(
      provider: voice.provider,
      language: languageOverride ?? roleDefaults.language,
      voiceIdentifier: voice.voiceIdentifier,
      openAIEndpointID: voice.openAIEndpointID,
      openAIVoice: voice.openAIVoice,
      rate: arguments["rate"]?.numberValue ?? roleDefaults.rate,
      pitch: arguments["pitch"]?.numberValue ?? roleDefaults.pitch)

    player.speak(
      text: text,
      voice: selectedVoice,
      role: role,
      title: title,
      messageID: messageID,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContent: skipTechnicalContent,
      interrupt: interrupt)
    if let error = player.errorMessage { return "Error: \(error)" }
    return "Speaking \(text.count) character\(text.count == 1 ? "" : "s")."
  }
}
