import Foundation

/// Selection is shared by chats and agent defaults; persistence keeps the existing keys.
struct ToolSelection: Equatable {
  var native: Set<BuiltInToolID> = []
  var servers: Set<UUID> = []
  var tools: Set<String> = []
  var disabled: Set<String> = []

  func contains(serverID: UUID, toolName: String) -> Bool {
    let key = MCPToolSelection.key(serverID: serverID, toolName: toolName)
    return servers.contains(serverID) && tools.contains(key) && !disabled.contains(key)
  }

  func containsAll(serverID: UUID, tools: [MCPToolDescriptor]) -> Bool {
    servers.contains(serverID) && tools.allSatisfy { contains(serverID: serverID, toolName: $0.name) }
  }

  mutating func setServer(_ id: UUID, enabled: Bool, tools knownTools: [MCPToolDescriptor] = []) {
    let prefix = MCPToolSelection.prefix(serverID: id)
    if enabled {
      servers.insert(id)
      let keys = knownTools.map { MCPToolSelection.key(serverID: id, toolName: $0.name) }
      tools.formUnion(keys)
      disabled.subtract(keys)
    } else {
      servers.remove(id)
      tools = tools.filter { !$0.hasPrefix(prefix) }
      disabled = disabled.filter { !$0.hasPrefix(prefix) }
    }
  }

  mutating func setTool(serverID: UUID, toolName: String, enabled: Bool) {
    let key = MCPToolSelection.key(serverID: serverID, toolName: toolName)
    if enabled {
      servers.insert(serverID)
      tools.insert(key)
      disabled.remove(key)
    } else {
      tools.remove(key)
      let prefix = MCPToolSelection.prefix(serverID: serverID)
      if !tools.contains(where: { $0.hasPrefix(prefix) && !disabled.contains($0) }) {
        servers.remove(serverID)
      }
    }
  }

  /// Only seed a server awaiting its first discovery, preserving individual choices.
  mutating func seed(serverID: UUID, tools knownTools: [MCPToolDescriptor]) -> Bool {
    guard !knownTools.isEmpty, servers.contains(serverID),
      !tools.contains(where: { $0.hasPrefix(MCPToolSelection.prefix(serverID: serverID)) })
    else { return false }
    tools.formUnion(knownTools.map { MCPToolSelection.key(serverID: serverID, toolName: $0.name) })
    return true
  }
}

extension Conversation {
  var toolSelection: ToolSelection {
    get { .init(native: enabledTools, servers: enabledMCPServers, tools: enabledMCPTools, disabled: disabledMCPTools) }
    set {
      enabledTools = newValue.native
      enabledMCPServers = newValue.servers
      enabledMCPTools = newValue.tools
      disabledMCPTools = newValue.disabled
    }
  }
}

extension AgentSettings {
  var toolSelection: ToolSelection {
    get { .init(native: defaultEnabledTools, servers: defaultEnabledMCPServers, tools: defaultEnabledMCPTools) }
    set {
      defaultEnabledTools = newValue.native
      defaultEnabledMCPServers = newValue.servers
      defaultEnabledMCPTools = newValue.tools.subtracting(newValue.disabled)
    }
  }
}

extension AppSettings {
  var toolSelection: ToolSelection {
    get { agentSettings.toolSelection }
    set { agentSettings.toolSelection = newValue }
  }
}
