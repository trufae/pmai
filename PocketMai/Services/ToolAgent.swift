import AVFoundation
import Foundation
import MaiCore
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
      // Memory is a context source, but it also carries the callable chats_*
      // tools when a conversation search scope is configured.
      guard id.isCallableTool || id == .memory else { return [] }
      guard !(settings.airplaneModeEnabled && id.isDisabledInAirplaneMode) else {
        return []
      }
      return definitions(for: id, conversation: conversation, settings: settings)
    }
  }

  static func execute(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore
  ) async -> String? {
    switch call.name {
    case let name where TodoTool.toolNames.contains(name):
      return TodoTool.execute(name: name, arguments: call.argumentValues, store: store)
    case MaiCalculatorTool.name:
      return await PocketMaiPluginHost.shared.callStandardTool(
        name: call.name,
        arguments: call.argumentValues)
    case MaiWebSearchTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: web search is disabled while Airplane Mode is enabled."
      }
      return await PocketMaiPluginHost.shared.call(
        tool: MaiWebSearchTool(configuration: store.settings.maiWebSearchConfiguration),
        arguments: call.argumentValues)
    case MaiWebFetchTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: web fetch is disabled while Airplane Mode is enabled."
      }
      return await PocketMaiPluginHost.shared.call(
        tool: MaiWebFetchTool(), arguments: call.argumentValues)
    case TextToSpeechTool.name:
      return TextToSpeechTool.speak(
        arguments: call.argumentValues,
        settings: store.effectiveToolSettings(for: conversation),
        skipTechnicalContent: store.effectiveConversationSettings(for: conversation)
          .skipTechnicalContentInTTS,
        openAIEndpoints: store.settings.airplaneModeEnabled ? [] : store.settings.openAIEndpoints)
    case MaiWeatherTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: weather is disabled while Airplane Mode is enabled."
      }
      let tool = await PocketMaiNetworkTools.weatherTool(
        arguments: call.argumentValues,
        settings: store.settings.toolSettings, locationService: { store.locationService })
      return await PocketMaiPluginHost.shared.call(
        tool: tool, arguments: call.argumentValues)
    case FileWorkspaceTool.listName, FileWorkspaceTool.findName, FileWorkspaceTool.grepName,
      FileWorkspaceTool.readName, FileWorkspaceTool.readIndexName,
      FileWorkspaceTool.readRangeName, FileWorkspaceTool.replaceRangeName,
      FileWorkspaceTool.patchName,
      FileWorkspaceTool.writeName, FileWorkspaceTool.renameName, FileWorkspaceTool.deleteName:
      return await executeFileWorkspaceTool(
        name: call.name,
        arguments: call.argumentValues,
        conversation: conversation,
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
      guard !store.settings.airplaneModeEnabled else {
        return "Error: GitHub tools are disabled while Airplane Mode is enabled."
      }
      guard let tool = MaiGitHubTool(name: name) else {
        return "Error: GitHub tool '\(name)' is not registered."
      }
      return await PocketMaiPluginHost.shared.call(tool: tool, arguments: call.argumentValues)
    case MaiMastodonTool.name:
      guard !store.settings.airplaneModeEnabled else {
        return "Error: Mastodon is disabled while Airplane Mode is enabled."
      }
      return await PocketMaiPluginHost.shared.call(
        tool: MaiMastodonTool(configuration: store.settings.toolSettings.maiMastodonConfiguration),
        arguments: call.argumentValues)
    case let name where BrowserTool.toolNames.contains(name):
      guard !store.settings.airplaneModeEnabled else {
        return "Error: the browser is disabled while Airplane Mode is enabled."
      }
      return await BrowserTool.execute(name: name, arguments: call.argumentValues, store: store)
    case let name where ConversationSearchTool.toolNames.contains(name):
      return ConversationSearchTool.execute(
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
    store: AppStore
  ) async -> String {
    guard fileWorkspaceToolsEnabled(conversation: conversation, settings: store.settings) else {
      return "Error: Files tools are disabled in Files settings."
    }
    let context: FileWorkspaceContext
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
      if let refreshed = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(
          conversationID: conversation.id, bookmarkData: refreshed)
      }
      context = resolved.context
    } catch {
      let workspaceName = FileWorkspaceTool.workspaceName(
        for: conversation, settings: store.settings)
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

  private static func definitions(
    for id: BuiltInToolID,
    conversation: Conversation,
    settings: AppSettings
  ) -> [ToolDefinition] {
    switch id {
    case .datetime, .language, .location:
      return []
    case .weather:
      return [MaiWeatherTool.toolDefinition]
    case .webSearch:
      return [MaiWebSearchTool.toolDefinition]
        + (settings.toolSettings.webSearchFetchingEnabled
          ? [MaiWebFetchTool.toolDefinition] : [])
    case .todo:
      return TodoTool.definitions
    case .calculator:
      return [MaiCalculatorTool.toolDefinition]
    case .textToSpeech:
      return TextToSpeechTool.definitions
    case .files:
      guard settings.toolSettings.filesWorkspaceAccessEnabled else { return [] }
      return FileWorkspaceTool.definitions(
        workspaceName: FileWorkspaceTool.workspaceName(for: conversation, settings: settings),
        includeAdvancedTools: settings.toolSettings.filesAdvancedToolsEnabled)
    case .calendar:
      return CalendarTool.definitions(settings: settings.toolSettings)
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
    case .memory:
      guard settings.toolSettings.conversationSearchScope != .none else { return [] }
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
  static func visibleDefinitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    let fullDefinitions = definitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    guard settings.useToolProxy && !settings.useSystemOne else { return fullDefinitions }
    return fullDefinitions.isEmpty ? [] : ToolProxy.definitions
  }

  static func definitions(
    for conversation: Conversation,
    settings: AppSettings,
    mcpTools: [UUID: [MCPToolDescriptor]] = [:],
    mcpResources: [UUID: [MCPResourceDescriptor]] = [:],
    mcpStatuses: [UUID: EndpointConnectionState] = [:]
  ) -> [ToolDefinition] {
    guard conversation.toolsEnabled else { return [] }
    var defs = BuiltInToolCatalog.definitions(
      for: conversation,
      settings: settings)
    // Tool names must stay unique: duplicates shadow each other at dispatch
    // and trap the by-name lookups. Keep the first definition — built-ins,
    // then servers in settings order — matching executeConcrete's resolution
    // order, which also routes mcp_read_resource before any MCP server.
    var takenNames = Set(defs.map(\.name))
    takenNames.insert(MCPResourceTool.readName)
    var enabledResourceServers: [(server: MCPServer, resources: [MCPResourceDescriptor])] = []
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
      && mcpStatuses[server.id]?.isAvailable == true
    {
      let tools = mcpTools[server.id] ?? []
      for tool in tools {
        let key = MCPToolSelection.key(serverID: server.id, toolName: tool.name)
        guard conversation.enabledMCPTools.contains(key) else { continue }
        guard takenNames.insert(tool.name).inserted else { continue }
        let description = cleanedToolDescription(
          tool.description,
          fallback: "MCP tool from \(server.name).")
        var definition = tool
        definition.description = description
        defs.append(definition)
      }
      enabledResourceServers.append((server, mcpResources[server.id] ?? []))
    }
    if !enabledResourceServers.isEmpty {
      defs.append(MCPResourceTool.definition(for: enabledResourceServers))
    }
    for definition in SubagentTool.definitions(for: conversation, settings: settings)
    where takenNames.insert(definition.name).inserted {
      defs.append(definition)
    }
    return defs
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
    let fullDefinitions = ToolAgentRegistry.definitions(
      for: conversation,
      settings: settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: store.mcpTools,
      mcpResources: store.mcpResources,
      mcpStatuses: store.mcpStatuses)
    let visibleCall = AgentTooling.normalized(call: call, tools: visibleDefinitions)
    guard AgentTooling.containsDefinition(named: visibleCall.name, in: visibleDefinitions) else {
      return AgentTooling.unavailableToolError(name: visibleCall.name)
    }

    if settings.useToolProxy && !fullDefinitions.isEmpty {
      switch visibleCall.name {
      case ToolProxy.listName:
        return ToolProxy.listTools(
          arguments: visibleCall.argumentValues, definitions: fullDefinitions)
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
        return
          "Error: proxy mode only exposes '\(ToolProxy.listName)' and '\(ToolProxy.callName)'. Use '\(ToolProxy.callName)' to call enabled tools."
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
    guard AgentTooling.containsDefinition(named: normalizedCall.name, in: definitions) else {
      return AgentTooling.unavailableToolError(name: normalizedCall.name)
    }
    if SubagentTool.isAgentTool(normalizedCall.name) {
      return await SubagentTool.execute(
        call: normalizedCall,
        conversation: conversation,
        settings: settings,
        store: store)
    }
    if let result = await BuiltInToolCatalog.execute(
      call: normalizedCall,
      conversation: conversation,
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
    return await dispatchMCP(call: normalizedCall, conversation: conversation, store: store)
  }

  private static func dispatchMCP(
    call: ParsedToolCall,
    conversation: Conversation,
    store: AppStore
  ) async -> String {
    for server in store.settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
      && store.mcpStatuses[server.id]?.isAvailable == true
    {
      let tools = store.mcpTools[server.id] ?? []
      guard tools.contains(where: { $0.name == call.name }) else { continue }
      let key = MCPToolSelection.key(serverID: server.id, toolName: call.name)
      if !conversation.enabledMCPTools.contains(key) {
        return "Error: tool '\(call.name)' is disabled for this conversation."
      }
      do {
        let server = try await store.authorizedMCPServer(server)
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
      includeAdvancedTools: includeAdvancedTools)
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
    messageID: UUID? = nil
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

    TTSPlayer.shared.speak(
      text: text,
      voice: selectedVoice,
      role: role,
      title: title,
      messageID: messageID,
      openAIEndpoints: openAIEndpoints,
      skipTechnicalContent: skipTechnicalContent,
      interrupt: interrupt)
    return "Speaking \(text.count) character\(text.count == 1 ? "" : "s")."
  }
}
