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

  var body: some View {
    List {
      row(title: "Local", subtitle: "This PocketMai", image: "iphone", id: nil)
      ForEach(hosts.remotes.connections) { host in
        row(
          title: host.name, subtitle: host.url.host ?? host.url.absoluteString,
          image: "network", id: host.id
        )
        .contextMenu {
          Button("Edit Host", systemImage: "pencil") { editing = host }
          Button("Reconnect", systemImage: "arrow.clockwise") {
            hosts.reconnect(host.id, isOffline: appStore.settings.isOffline)
            onSelectHost(host.id)
          }
          .disabled(appStore.settings.isOffline)
          Button("Remove Host", systemImage: "trash", role: .destructive) {
            hosts.remotes.remove(host.id)
          }
        }
      }
    }
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
        RemoteAgentsView(onSelectHost: { id in
          managing = false
          onSelectHost(id)
        })
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
  }

  private func row(title: String, subtitle: String, image: String, id: UUID?) -> some View {
    let selected = hosts.selectedHostID == id
    return SidebarFolderRow(
      title: title, subtitle: subtitle, systemImage: image,
      iconColor: (hosts.remotes.host(id)?.accentColor).flatMap {
        ConversationFolderTint(rawIdentifier: $0)
      }?.color,
      isSelected: selected
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

  var body: some View {
    List {
      ForEach(hosts.folders) { folder in
        let count =
          hosts.selectedHost.map { host in
            hosts.remotes.conversations(for: host).filter { $0.cwd == folder.cwd }.count
          } ?? 0
        let selected = hosts.selectedFolderID == folder.cwd
        SidebarFolderRow(
          title: folder.name,
          subtitle: "\(count) conversation\(count == 1 ? "" : "s") · \(folder.cwd)",
          systemImage: folder.icon ?? "folder", iconColor: folderColor(folder), isSelected: selected
        ) {
          onSelectFolder(folder.cwd)
        }
        .listRowBackground(SidebarRowBackground(isSelected: selected)).listRowSeparator(.hidden)
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
    .safeAreaInset(edge: .top) {
      HostPanelHeader(
        title: hosts.selectedHost?.name ?? "Folders", backTitle: "Hosts", action: onShowHosts)
    }
    .safeAreaInset(edge: .bottom) {
      FloatingActionPill(
        title: "Refresh", systemImage: "arrow.clockwise", prominent: false, compact: false
      ) {
        hosts.refresh(isOffline: isOffline)
      }.disabled(hosts.loading || isOffline).padding(.bottom, 24)
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
  let onNewChat: () -> Void
  let onShowSettings: () -> Void

  var body: some View {
    List {
      ForEach(hosts.conversations) { chat in
        let selected = hosts.selectedConversationID == chat.id
        SidebarFolderRow(
          title: chat.title,
          subtitle: chat.messages.last?.text
            ?? chat.updatedAt.formatted(date: .abbreviated, time: .shortened),
          systemImage: "bubble.left", isSelected: selected
        ) { onSelectConversation(chat.id) }
        .disabled(hosts.selectedHost?.requiresApproval == true || hosts.selectedFolderID == nil)
        .listRowBackground(SidebarRowBackground(isSelected: selected)).listRowSeparator(.hidden)
        .modifier(
          ConversationSummaryActionsModifier(
            store: appStore,
            conversation: ConversationSummary(conversation: chat.presentation),
            isEnabled: true, exportCoordinator: exportCoordinator,
            onSelectForBatch: nil, allowsLocalActions: false,
            canManage: hosts.selectedHost?.requiresApproval != true
              && (chat.sessionID == nil
                || (!appStore.settings.isOffline
                  && hosts.selectedHost?.workspace?.canManageSessions == true))
              && !(selected && hosts.activeChat?.busy == true),
            onRename: { await hosts.manageConversation(chat, title: $0) },
            onDelete: { _ in Task { await hosts.manageConversation(chat, title: nil) } }))
      }
      if hosts.conversations.isEmpty {
        Text(hosts.loading ? "Loading conversations…" : "No conversations in this folder yet.")
          .font(.callout).foregroundStyle(.secondary)
      }
      if let error = hosts.error { Text(error).foregroundStyle(.red).font(.callout) }
    }
    .listStyle(.plain).scrollContentBackground(.hidden)
    .contentMargins(.horizontal, 16, for: .scrollContent)
    .safeAreaInset(edge: .top) {
      HostPanelHeader(
        title: hosts.folders.first { $0.cwd == hosts.selectedFolderID }?.name ?? "Conversations",
        backTitle: "Folders", action: onShowFolders)
    }
    .safeAreaInset(edge: .bottom) {
      HStack {
        FloatingActionPill(
          title: "New Chat", systemImage: "plus", prominent: true, compact: false, action: onNewChat
        )
        .disabled(hosts.selectedHost?.requiresApproval == true || hosts.selectedFolderID == nil)
        FloatingActionIcon(
          systemImage: "gearshape", accessibilityLabel: "Settings", compact: false,
          action: onShowSettings)
      }.padding(.bottom, 24)
    }
  }
}
