import MaiACP
import MaiCore
import SwiftUI

struct HostPanelHeader: View {
  let title: String
  let backTitle: String?
  let action: () -> Void

  var body: some View {
    ZStack(alignment: .leading) {
      Text(title)
        .font(.headline)
        .lineLimit(1)
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, minHeight: 48)
        .accessibilityAddTraits(.isHeader)
      if let backTitle {
        FloatingActionIcon(
          systemImage: "chevron.left", accessibilityLabel: "Back to \(backTitle)",
          compact: true, action: action)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }
}

struct HostsView: View, Equatable {
  @EnvironmentObject private var appStore: AppStore
  let hosts: HostNavigationStore
  let onSelectHost: (UUID?) -> Void
  @State private var adding = false
  @State private var editing: RemoteAgentBookmark?
  @State private var renaming: RemoteAgentBookmark?

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hosts === rhs.hosts
  }

  var body: some View {
    SidebarPanel(title: "Hosts") {
      let pinned = hosts.remotes.connections.filter { hosts.isHostPinned($0.id) }
      let online = hosts.remotes.connections.filter {
        !hosts.isHostPinned($0.id) && connectionState($0.id) == .connected
      }
      let offline = hosts.remotes.connections.filter {
        !hosts.isHostPinned($0.id) && connectionState($0.id) != .connected
      }
      SidebarGroupedRows(items: pinned, groupTitle: { _ in "Pinned" }, row: remoteRow)
      SidebarGroupHeader(title: "Online")
      row(title: "Local", subtitle: "This PocketMai", image: "iphone", id: nil)
      if !online.isEmpty {
        ForEach(online) { host in remoteRow(host) }
      }
      SidebarGroupedRows(items: offline, groupTitle: { _ in "Offline" }, row: remoteRow)
    } actions: { _ in
      FloatingActionIcon(
        systemImage: "plus", accessibilityLabel: "Add Remote Host", compact: true
      ) {
        adding = true
      }
    }
    .sheet(isPresented: $adding) {
      RemoteAgentConnectionView(
        onAdded: { id in
          adding = false
          onSelectHost(id)
        })
    }
    .sheet(item: $editing) { host in RemoteAgentConnectionView(initialHost: host) }
    .modifier(RemoteHostRenameModifier(host: $renaming))
  }

  private func connectionState(_ id: UUID) -> HostConnectionState {
    hosts.connectionState(id, isOffline: appStore.settings.isOffline)
  }

  private func remoteRow(_ host: RemoteAgentBookmark) -> some View {
    row(
      title: host.name, subtitle: host.url.host ?? host.url.absoluteString,
      image: "network", id: host.id
    )
    .contextMenu {
      RemoteHostMenu(
        host: host, store: hosts.remotes, isOffline: appStore.settings.isOffline,
        rename: { renaming = host },
        connect: { hosts.reconnect(host.id, isOffline: appStore.settings.isOffline) },
        edit: { editing = host })
    }
  }

  private func row(title: String, subtitle: String, image: String, id: UUID?) -> some View {
    let selected = hosts.selectedHostID == id
    let state = id.map { connectionState($0) }
    let iconColor: Color = state == .connected ? .green : state == .failed ? .red : .primary
    return SidebarFolderRow(
      title: title, subtitle: subtitle, systemImage: image,
      iconColor: iconColor,
      isSelected: selected,
      connectionStatus: state?.rawValue,
      isPinned: id.map { hosts.isHostPinned($0) } ?? false
    ) {
      onSelectHost(id)
    }
    .listRowBackground(SidebarRowBackground(isSelected: selected)).listRowSeparator(.hidden)
  }
}

struct RemoteFoldersView: View, Equatable {
  let hosts: HostNavigationStore
  let isOffline: Bool
  let onShowHosts: () -> Void
  let onSelectFolder: (String) -> Void
  var isVisible = true
  var onBrowseFiles: (String) -> Void = { _ in }
  var onOpenTerminal: (String) -> Void = { _ in }
  @State private var filter = ""
  @AppStorage("remoteFolderSortOrder") private var sortOrder: RemoteFolderSortOrder = .updated
  @State private var showingSortOptions = false
  @FocusState private var filterFocused: Bool

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hosts === rhs.hosts && lhs.isOffline == rhs.isOffline && lhs.isVisible == rhs.isVisible
  }

  var body: some View {
    let counts = (hosts.selectedHost?.conversations ?? []).reduce(into: [String: Int]()) {
      $0[$1.cwd, default: 0] += 1
    }
    SidebarPanel(
      title: hosts.selectedHost?.name ?? "Folders", backTitle: "Hosts", onBack: onShowHosts
    ) {
      SidebarGroupedRows(
        items: hosts.folders(matching: filter, sortedBy: sortOrder),
        groupTitle: { hosts.isFolderPinned($0.cwd) ? "Pinned" : "Folders" }
      ) {
        folder in
        let count = counts[folder.cwd, default: 0]
        let selected = hosts.selectedFolderID == folder.cwd
        let pinned = hosts.isFolderPinned(folder.cwd)
        SidebarFolderRow(
          title: folder.name,
          subtitle: "\(count) conversation\(count == 1 ? "" : "s") · \(folder.cwd)",
          systemImage: folder.icon ?? "folder", iconColor: folderColor(folder),
          isSelected: selected,
          isPinned: pinned, updatedAt: folder.updatedAt
        ) {
          filterFocused = false
          onSelectFolder(folder.cwd)
        }
        .listRowBackground(SidebarRowBackground(isSelected: selected)).listRowSeparator(.hidden)
        .contextMenu {
          SidebarFolderActions(
            isPinned: pinned,
            togglePin: { hosts.toggleFolderPin(folder.cwd) },
            browseFiles: { onBrowseFiles(folder.cwd) },
            browseFilesDisabled: hosts.selectedHost?.requiresApproval == true
              || isOffline,
            openTerminal: { onOpenTerminal(folder.cwd) },
            terminalDisabled: hosts.selectedHost?.requiresApproval == true
              || isOffline,
            path: folder.cwd)
        }
      }
      if hosts.loading {
        ProgressView(hosts.waitingApproval ? "Waiting for server approval…" : "Connecting…")
      }
      if hosts.waitingApproval {
        Text("Accept this PocketMai client in the serving REPL with /remote accept.")
          .font(.footnote).foregroundStyle(.secondary)
      }
      if let error = hosts.error { Text(error).foregroundStyle(.red).font(.callout) }
      if !hosts.supportsDiscovery {
        Text(
          "This agent shares its configured workspace. Update the remote pmai to browse all folders and chats."
        )
        .font(.footnote).foregroundStyle(.secondary)
      }
    } actions: { compact in
      HStack(spacing: compact ? 6 : 10) {
        FloatingSearchField(text: $filter, isFocused: $filterFocused, placeholder: "Filter folders")
        {
          filter = ""
          filterFocused = false
        }
        FloatingActionIcon(
          systemImage: "arrow.up.arrow.down", accessibilityLabel: "Sort folders", compact: true
        ) {
          filterFocused = false
          showingSortOptions = true
        }
        .accessibilityValue(sortOrder.title)
        .confirmationDialog(
          "Sort folders", isPresented: $showingSortOptions, titleVisibility: .visible
        ) {
          ForEach(RemoteFolderSortOrder.allCases) { order in
            Button(order.title) { sortOrder = order }
          }
        }
        FloatingActionIcon(
          systemImage: "arrow.clockwise", accessibilityLabel: "Refresh projects", compact: true
        ) {
          hosts.refresh(isOffline: isOffline)
        }.disabled(hosts.loading || isOffline)
      }
    }
    .onChange(of: isVisible) { _, visible in if !visible { filterFocused = false } }
  }

  private func folderColor(_ folder: ACPWorkspaceFolder) -> Color? {
    guard let raw = folder.tint, let tint = AgentProjectTint(rawValue: raw) else { return nil }
    let rgb = tint.rgb
    return Color(
      red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
  }
}

struct RemoteConversationsView: View, Equatable {
  @EnvironmentObject private var appStore: AppStore
  @StateObject private var exportCoordinator = ConversationExportCoordinator()
  let hosts: HostNavigationStore
  let onShowFolders: () -> Void
  let onSelectConversation: (UUID) -> Void
  let onShowSettings: () -> Void
  var isVisible = true
  @State private var search = ""
  @FocusState private var searchFocused: Bool

  private var conversations: [RemoteAgentConversation] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return hosts.conversations.filter {
      query.isEmpty || SidebarSearch.matches(query, in: [$0.title] + $0.messages.map(\.text))
    }
  }

  private func groupTitle(for chat: RemoteAgentConversation) -> String {
    hosts.isConversationPinned(chat.id)
      ? "Pinned" : ConversationDatePresentation.sidebarGroupTitle(for: chat.updatedAt)
  }

  private func summary(for chat: RemoteAgentConversation) -> ConversationSummary {
    var summary = ConversationSummary(conversation: chat.presentation)
    summary.isPinned = hosts.isConversationPinned(chat.id)
    return summary
  }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.hosts === rhs.hosts && lhs.isVisible == rhs.isVisible
  }

  var body: some View {
    SidebarPanel(
      title: hosts.folders.first { $0.cwd == hosts.selectedFolderID }?.name ?? "Conversations",
      backTitle: "Folders", onBack: onShowFolders
    ) {
      conversationList
    } actions: { compact in
      HStack(spacing: compact ? 6 : 10) {
        ConversationSearchControls(
          text: $search, isFocused: $searchFocused, compact: compact,
          onShowSettings: onShowSettings)
      }
    }
    .onChange(of: isVisible) { _, visible in if !visible { searchFocused = false } }
  }

  private var conversationList: some View {
    let chats = conversations
    return Group {
      SidebarGroupedRows(items: chats, groupTitle: groupTitle) { chat in
        let selected = hosts.selectedConversationID == chat.id
        let summary = summary(for: chat)
        ConversationRow(
          conversation: summary, isSelected: selected,
          isResponding: selected && hosts.activeChat?.busy == true
        ) {
          searchFocused = false
          onSelectConversation(chat.id)
        }
        .disabled(hosts.selectedHost?.requiresApproval == true || hosts.selectedFolderID == nil)
        .listRowBackground(SidebarRowBackground(isSelected: selected)).listRowSeparator(.hidden)
        .modifier(
          ConversationSummaryActionsModifier(
            store: appStore,
            conversation: summary,
            isEnabled: true, exportCoordinator: exportCoordinator,
            onSelectForBatch: nil, allowsLocalActions: false,
            exportConversation: selected
              ? hosts.activeChat?.presentation ?? chat.presentation : chat.presentation,
            canManage: hosts.selectedHost?.requiresApproval != true
              && (chat.sessionID == nil
                || (!appStore.settings.isOffline
                  && hosts.selectedHost?.workspace?.canManageSessions == true))
              && !(selected && hosts.activeChat?.busy == true),
            onRename: {
              await hosts.manageConversation(
                chat, title: $0, isOffline: { appStore.settings.isOffline })
            },
            onDelete: { _ in
              Task {
                await hosts.manageConversation(
                  chat, title: nil, isOffline: { appStore.settings.isOffline })
              }
            },
            onTogglePin: { hosts.toggleConversationPin(chat.id) }))
      }
      if chats.isEmpty {
        Text(
          hosts.loading
            ? "Loading conversations…"
            : (search.isEmpty
              ? "No conversations in this folder yet." : "No matching conversations.")
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      if let error = hosts.error { Text(error).foregroundStyle(.red).font(.callout) }
    }
  }
}
