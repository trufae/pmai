import SwiftUI

struct ToolPickerPopover: View {
  @EnvironmentObject private var store: AppStore
  var remoteChat: RemoteAgentChat? = nil
  @State private var expandedServerIDs: Set<UUID> = []
  @State private var savedDefaults = false

  private var selection: ToolSelection { store.currentConversation?.toolSelection ?? ToolSelection() }

  var body: some View {
    ToolPickerContainer {
      if let remoteChat {
        RemoteToolPickerContent(chat: remoteChat)
      } else {
        Text("Tools for this chat")
          .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
        localTools.disabled(!toolsEnabled).opacity(toolsEnabled ? 1 : 0.5)
        Divider()
        Button(savedDefaults ? "Default tools saved" : "Use as default for \(store.settings.selectedAgent.name)") {
          store.saveChatToolsAsDefault()
          savedDefaults = true
        }
        .font(.caption).padding(12)
        .disabled(store.currentConversation == nil || savedDefaults)
        .onChange(of: selection) { _, _ in savedDefaults = false }
        .onChange(of: toolsEnabled) { _, _ in savedDefaults = false }
      }
    }
  }

  private var localTools: some View {
    Group {
      ForEach(
        BuiltInToolID.allCases.filter { $0 != .memory }.sorted { $0.displayName < $1.displayName }
      ) { tool in
        ToolSelectionRow(
          title: tool.displayName,
          systemImage: tool.systemImage,
          isEnabled: selection.native.contains(tool),
          isUnavailable: store.settings.isOffline && tool.isDisabledInAirplaneMode
        ) {
          store.setNativeTool(tool, enabled: !selection.native.contains(tool))
        }
      }

      if !store.settings.mcpServers.isEmpty {
        Divider().padding(.vertical, 4)
        Text("MCP Servers")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 12)

        ForEach(store.settings.mcpServers) { server in
          mcpServerRow(server)
        }
      }
    }
  }

  private var toolsEnabled: Bool {
    store.currentConversation?.toolsEnabled ?? false
  }

  @ViewBuilder
  private func mcpServerRow(_ server: MCPServer) -> some View {
    let tools = store.mcpTools[server.id] ?? []
    let resources = store.mcpResources[server.id] ?? []
    let status = store.mcpStatuses[server.id] ?? .unknown
    let expanded = expandedServerIDs.contains(server.id)
    let itemCount = tools.count + resources.count
    let enabled = selection.servers.contains(server.id)

    VStack(alignment: .leading, spacing: 0) {
      ToolPickerGroupRow(
        title: server.name.isEmpty ? "Untitled MCP" : server.name,
        detail: server.transport?.displayName,
        systemImage: serverStatusIcon(status), iconColor: status.statusColor,
        isEnabled: enabled,
        isPartiallyEnabled: enabled && !selection.containsAll(serverID: server.id, tools: tools),
        isExpanded: expanded, itemCount: itemCount, isLoading: status == .checking,
        toggle: { store.toggleChatMCPServer(server.id) },
        expand: {
          if itemCount == 0 {
            Task { await store.refreshMCP(server, force: true) }
          } else {
            withAnimation(.snappy) {
              if expanded {
                expandedServerIDs.remove(server.id)
              } else {
                expandedServerIDs.insert(server.id)
              }
            }
          }
        }
      )

      if expanded && itemCount > 0 {
        VStack(alignment: .leading, spacing: 2) {
          if !tools.isEmpty {
            Text("Tools")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.top, 4)
            ForEach(tools) { tool in
              ToolSelectionRow(
                title: tool.name,
                isEnabled: selection.contains(serverID: server.id, toolName: tool.name)
              ) {
                store.toggleChatMCPTool(serverID: server.id, toolName: tool.name)
              }
              .font(.callout).padding(.leading, 26)
            }
          }
          if !resources.isEmpty {
            Text("Resources")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.top, tools.isEmpty ? 4 : 8)
            ForEach(resources) { resource in
              HStack(spacing: 8) {
                Image(systemName: "doc.text")
                  .imageScale(.small)
                  .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                  Text(resource.uri)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  if !resource.name.isEmpty {
                    Text(resource.name)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
              }
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
          }
        }
      }
    }
  }

  private func serverStatusIcon(_ status: EndpointConnectionState) -> String {
    switch status {
    case .unknown: return "circle"
    case .checking: return "arrow.triangle.2.circlepath"
    case .available: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.circle.fill"
    }
  }
}
