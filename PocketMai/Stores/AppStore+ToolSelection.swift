import Foundation

enum ToolSelectionScope { case conversation, agentDefaults }

extension AppStore {
  func updateToolSelection(in scope: ToolSelectionScope = .conversation,
    _ update: @escaping (inout ToolSelection) -> Void
  ) {
    switch scope {
    case .conversation:
      updateCurrentConversationSettings { update(&$0.toolSelection) }
    case .agentDefaults:
      update(&settings.toolSelection)
      saveSettings()
    }
  }

  func setNativeTool(_ tool: BuiltInToolID, enabled: Bool, in scope: ToolSelectionScope = .conversation) {
    guard !enabled || !(settings.isOffline && tool.isDisabledInAirplaneMode) else { return }
    updateToolSelection(in: scope) { selection in
      if enabled { selection.native.insert(tool) } else { selection.native.remove(tool) }
    }
    if enabled && tool == .location { prepareSelectedLocationTool() }
  }

  func toggleChatMCPServer(_ id: UUID) {
    let tools = mcpTools[id] ?? []
    updateToolSelection { selection in
      selection.setServer(id, enabled: !selection.containsAll(serverID: id, tools: tools), tools: tools)
    }
  }

  func toggleChatMCPTool(serverID: UUID, toolName: String) {
    updateToolSelection { selection in
      selection.setTool(serverID: serverID, toolName: toolName,
        enabled: !selection.contains(serverID: serverID, toolName: toolName))
    }
  }

  func saveChatToolsAsDefault() {
    guard let conversation = currentConversation else { return }
    settings.toolSelection = conversation.toolsEnabled ? conversation.toolSelection : ToolSelection()
    saveSettings()
  }

  func setChatToolsEnabled(_ enabled: Bool) {
    updateCurrentConversationSettings { conversation in
      conversation.toolsEnabled = enabled
      if enabled && conversation.enabledTools.contains(.location) { self.prepareSelectedLocationTool() }
    }
  }

  private func prepareSelectedLocationTool() {
    enableLocationAccessIfNeeded()
    saveSettings()
  }
}
