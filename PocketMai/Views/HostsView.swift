import MaiACP
import MaiCore
import SwiftUI

struct HostPanelHeader: View {
  let title: String
  let backTitle: String
  let action: () -> Void

  var body: some View {
    HStack {
      Button(action: action) { Label(backTitle, systemImage: "chevron.left") }
      Spacer()
      Text(title).font(.headline).lineLimit(1)
    }
    .padding(.horizontal, 24).padding(.top, 64).padding(.bottom, 12)
  }
}

struct HostsView: View {
  @EnvironmentObject private var appStore: AppStore
  let hosts: HostNavigationStore
  let onSelectHost: (UUID?) -> Void
  @State private var managing = false
  @State private var adding = false
  @State private var scanning = false
  @State private var editing: RemoteAgentBookmark?
  @State private var renaming: RemoteAgentBookmark?

  var body: some View {
    List {
      row(title: "Local", subtitle: "This PocketMai", image: "iphone", id: nil)
      let pinned = hosts.remotes.connections.filter { hosts.isHostPinned($0.id) }
      let online = hosts.remotes.connections.filter {
        !hosts.isHostPinned($0.id) && connectionState($0.id) == .connected
      }
      let offline = hosts.remotes.connections.filter {
        !hosts.isHostPinned($0.id) && connectionState($0.id) != .connected
      }
      if !hosts.remotes.connections.isEmpty { groupSeparator }
      if !pinned.isEmpty {
        SidebarConversationGroupHeader(title: "Pinned")
        ForEach(pinned) { host in remoteRow(host) }
      }
      if !online.isEmpty {
        SidebarConversationGroupHeader(title: "Online")
        ForEach(online) { host in remoteRow(host) }
      }
      if !offline.isEmpty {
        SidebarConversationGroupHeader(title: "Offline")
        ForEach(offline) { host in remoteRow(host) }
      }
    }
    .environment(\.defaultMinListRowHeight, 0)
    .listStyle(.plain).scrollContentBackground(.hidden)
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .safeAreaInset(edge: .top) {
      HStack {
        Text("Hosts").font(.title2.bold())
        Spacer()
      }
      .padding(.horizontal, 24).padding(.top, 64).padding(.bottom, 12)
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 12) {
        FloatingActionPill(
          title: "Manage…", systemImage: "network", prominent: false, compact: true
        ) {
          managing = true
        }
        FloatingActionIcon(
          systemImage: "plus", accessibilityLabel: "Add Remote Host", compact: true
        ) {
          scanning = false
          adding = true
        }
        FloatingActionIcon(
          systemImage: "qrcode.viewfinder", accessibilityLabel: "Scan Host QR", compact: true
        ) {
          scanning = true
          adding = true
        }
      }.padding(.bottom, 24)
    }
    .sheet(isPresented: $managing) {
      NavigationStack {
        RemoteAgentsView(
          hosts: hosts,
          onSelectHost: { id in
            managing = false
            onSelectHost(id)
          }
        )
        .toolbar {
          ToolbarItem(placement: .confirmationAction) { Button("Done") { managing = false } }
        }
      }
    }
    .sheet(isPresented: $adding) {
      RemoteAgentConnectionView(
        onAdded: { id in
          adding = false
          onSelectHost(id)
        }, scanOnAppear: scanning)
    }
    .sheet(item: $editing) { host in RemoteAgentConnectionView(initialHost: host) }
    .sheet(item: $renaming) { host in RemoteHostRenameView(host: host) }
  }

  private var groupSeparator: some View {
    Divider()
      .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
      .listRowBackground(Color.clear)
      .listRowSeparator(.hidden)
      .accessibilityHidden(true)
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
      Button("Rename", systemImage: "character.cursor.ibeam") { renaming = host }
      Button("Edit Host", systemImage: "pencil") { editing = host }
      Button(
        hosts.isHostPinned(host.id) ? "Unpin Host" : "Pin to Top",
        systemImage: hosts.isHostPinned(host.id) ? "pin.slash" : "pin"
      ) { hosts.toggleHostPin(host.id) }
      Divider()
      if hosts.selectedHostID == host.id || hosts.isConnected(host.id) {
        Button("Disconnect", systemImage: "network.slash") { hosts.disconnect(host.id) }
      }
      Button("Reconnect", systemImage: "arrow.clockwise") {
        hosts.reconnect(host.id, isOffline: appStore.settings.isOffline)
      }
      .disabled(appStore.settings.isOffline)
      Divider()
      Button("Remove Host", systemImage: "trash", role: .destructive) {
        hosts.remotes.remove(host.id)
      }
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

struct RemoteFoldersView: View {
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

  var body: some View {
    List {
      ForEach(hosts.folders(matching: filter, sortedBy: sortOrder)) {
        folder in
        let count =
          hosts.selectedHost.map { host in
            hosts.remotes.conversations(for: host).filter { $0.cwd == folder.cwd }.count
          } ?? 0
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
              || hosts.selectedHost?.backend == .openCode || isOffline,
            openTerminal: { onOpenTerminal(folder.cwd) },
            terminalDisabled: hosts.selectedHost?.requiresApproval == true
              || hosts.selectedHost?.backend == .openCode || isOffline,
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
    }
    .listStyle(.plain).scrollContentBackground(.hidden)
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .onChange(of: isVisible) { _, visible in if !visible { filterFocused = false } }
    .safeAreaInset(edge: .top) {
      HostPanelHeader(
        title: hosts.selectedHost?.name ?? "Folders", backTitle: "Hosts", action: onShowHosts)
    }
    .safeAreaInset(edge: .bottom) {
      HStack(spacing: 10) {
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
      }.padding(.horizontal, 18).padding(.bottom, 22)
    }
  }

  private func folderColor(_ folder: ACPWorkspaceFolder) -> Color? {
    guard let raw = folder.tint, let tint = AgentProjectTint(rawValue: raw) else { return nil }
    let rgb = tint.rgb
    return Color(
      red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
  }
}

struct RemoteConversationsView: View {
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
    hosts.conversations.filter {
      SidebarSearch.matches(search, in: [$0.title] + $0.messages.map(\.text))
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

  var body: some View {
    ConversationSidebarPanel(
      title: hosts.folders.first { $0.cwd == hosts.selectedFolderID }?.name ?? "Conversations",
      onShowFolders: onShowFolders
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
    List {
      let chats = conversations
      ForEach(Array(chats.enumerated()), id: \.element.id) { index, chat in
        let title = groupTitle(for: chat)
        if index == 0 || groupTitle(for: chats[index - 1]) != title {
          SidebarConversationGroupHeader(title: title)
        }
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
      if conversations.isEmpty {
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
    .listStyle(.plain).scrollContentBackground(.hidden)
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .scrollIndicators(.hidden)
  }
}
