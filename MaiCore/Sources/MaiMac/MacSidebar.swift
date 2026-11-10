import AppKit
import MaiACP
import SwiftUI

struct MacSidebar: View {
  @Bindable var workspace: MacWorkspace
  @State private var rename: SidebarRename?
  @State private var confirmation: SidebarConfirmation?
  @State private var selectedSessionIDs = Set<String>()
  @FocusState private var searchFocused: Bool

  var body: some View {
    VStack(spacing: 0) {
      List(selection: conversationSelection) {
        section(.hosts, subtitle: workspace.hostName) { hosts.selectionDisabled() }
        section(.folders, subtitle: folderName) { folders.selectionDisabled() }
        section(.conversations, subtitle: workspace.showArchived ? "Archived" : nil) { conversations }
      }
      .listStyle(.sidebar)
      .buttonStyle(.plain)
      .disabled(workspace.busy)
      .contextMenu(forSelectionType: String.self) { ids in
        let sessions = workspace.sessions.filter { ids.contains($0.sessionID) }
        if sessions.count == 1, let session = sessions.first {
          sessionActions(session, chat: workspace.conversation(for: session))
        } else if !sessions.isEmpty {
          batchActions(sessions)
        }
      }
      if selectedSessions.count > 1 {
        HStack {
          Text("\(selectedSessions.count) selected").font(.caption)
          Spacer()
          Menu { batchActions(selectedSessions) } label: {
            Label("Actions", systemImage: "ellipsis.circle")
          }
          .menuStyle(.borderlessButton).fixedSize()
        }.padding(12)
          .disabled(workspace.busy)
      }
      Divider()
      HStack {
        Label(workspace.hostName, systemImage: workspace.hostID == nil ? "desktopcomputer" : "network")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if workspace.busy { ProgressView().controlSize(.small) }
        SettingsLink { Image(systemName: "gearshape") }.help("Settings (⌘,)")
      }.padding(12)
    }
    .sheet(item: $rename) { SidebarRenameSheet(edit: $0) }
    .alert(confirmation?.title ?? "", isPresented: Binding(
      get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
    )) {
      if let confirmation {
        Button(confirmation.button, role: .destructive, action: confirmation.action)
      }
      Button("Cancel", role: .cancel) { confirmation = nil }
    } message: { Text(confirmation?.message ?? "") }
    .onChange(of: workspace.selectedID) { _, _ in
      if !workspace.busy {
        if selectedSessionIDs.count > 1, let id = workspace.selected?.sessionID,
          selectedSessionIDs.contains(id) { return }
        syncSelection()
      }
    }
    .onChange(of: workspace.sessions.map(\.sessionID)) { _, ids in
      selectedSessionIDs.formIntersection(ids)
    }
    .onChange(of: selectionContext) { _, _ in syncSelection() }
    .onAppear { syncSelection() }
    .onChange(of: workspace.focusConversationSearch, initial: true) { _, requested in
      guard requested else { return }
      DispatchQueue.main.async {
        searchFocused = true
        workspace.focusConversationSearch = false
      }
    }
  }

  private var selectedSessions: [ACPSessionInfo] {
    workspace.sessions.filter { selectedSessionIDs.contains($0.sessionID) }
  }

  private var selectionContext: [String] {
    [workspace.hostID?.uuidString ?? "", workspace.cwd, workspace.search,
      String(workspace.showArchived), workspace.sidebarSection?.rawValue ?? ""]
  }

  private var conversationSelection: Binding<Set<String>> {
    Binding(get: { selectedSessionIDs }, set: { ids in
      selectedSessionIDs = ids
      if ids.count == 1, let session = workspace.sessions.first(where: { ids.contains($0.sessionID) }) {
        workspace.open(session)
      }
    })
  }

  private func syncSelection() {
    if workspace.sidebarSection == .conversations, let chat = workspace.selected,
      let session = workspace.sessions.first(where: {
        chat.hostID == workspace.hostID && chat.cwd == $0.cwd && chat.sessionID == $0.sessionID
      }) {
      selectedSessionIDs = [session.sessionID]
    } else { selectedSessionIDs = [] }
  }

  private var folderName: String? {
    workspace.snapshot.folders.first { $0.cwd == workspace.cwd }?.name
  }

  private func section<Content: View>(_ section: MacSidebarSection, subtitle: String?,
    @ViewBuilder content: () -> Content) -> some View {
    Section {
      if workspace.sidebarSection == section { content() }
    } header: {
      Button {
        workspace.sidebarSection = workspace.sidebarSection == section ? nil : section
      } label: {
        HStack(spacing: 6) {
          Image(systemName: workspace.sidebarSection == section ? "chevron.down" : "chevron.right")
            .font(.caption2)
          Text(section.rawValue)
          Spacer(minLength: 4)
          if let subtitle { Text(subtitle).fontWeight(.regular).lineLimit(1).truncationMode(.middle) }
        }
        .contentShape(Rectangle())
      }
      .accessibilityLabel(section.rawValue)
      .accessibilityValue(workspace.sidebarSection == section ? "Expanded" : "Collapsed")
      .selectionDisabled()
    }
  }

  private var hosts: some View {
    Group {
      Button { workspace.selectHost(nil) } label: {
        row("This Mac", icon: "desktopcomputer", selected: workspace.hostID == nil)
      }
      .contextMenu {
        Button("Show Folders", systemImage: "folder") { workspace.selectHost(nil) }
        Button("Open Folder…", systemImage: "folder.badge.plus", action: workspace.chooseFolder)
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await workspace.refresh() } }
      }
      ForEach(workspace.hosts) { host in
        Button { workspace.selectHost(host.id) } label: {
          row(host.name, icon: "network", selected: workspace.hostID == host.id)
        }
        .contextMenu {
          Button("Show Folders", systemImage: "folder") { workspace.selectHost(host.id) }
          Button("Rename…", systemImage: "pencil") {
            rename = .init(title: "Rename Host", name: host.name) { workspace.renameHost(host, to: $0) }
          }
          Button("Copy Address", systemImage: "doc.on.doc") { copy(host.url.absoluteString) }
          Divider()
          Button("Remove Host…", systemImage: "trash", role: .destructive) {
            confirmation = .init(title: "Remove \(host.name)?", button: "Remove Host",
              message: "Disconnect open conversations and remove this Mac’s saved connection. Remote conversations and files are kept.") {
                workspace.removeHost(host)
              }
          }
        }
      }
      Button { workspace.showConnection = true } label: { Label("Connect Host…", systemImage: "plus") }
    }
  }

  private var folders: some View {
    Group {
      ForEach(workspace.snapshot.folders) { folder in
        Button { workspace.selectFolder(folder.cwd) } label: {
          row(folder.name, icon: folder.icon ?? "folder", selected: workspace.cwd == folder.cwd)
        }
        .help(folder.cwd)
        .contextMenu {
          Button("Show Conversations", systemImage: "bubble.left.and.bubble.right") { workspace.selectFolder(folder.cwd) }
          Button("New Chat", systemImage: "square.and.pencil") {
            workspace.selectFolder(folder.cwd)
            workspace.newChat()
          }
          if workspace.hostID == nil {
            Button("Rename…", systemImage: "pencil") {
              rename = .init(title: "Rename Folder", name: folder.name) { workspace.renameFolder(folder, to: $0) }
            }
            Button("Show in Finder", systemImage: "folder") {
              NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.cwd)
            }
            Button("Open in Terminal", systemImage: "terminal") { workspace.openTerminal(in: folder) }
          }
          Button("Copy Path", systemImage: "doc.on.doc") { copy(folder.cwd) }
          if workspace.hostID == nil {
            Divider()
            Button("Remove from Sidebar…", systemImage: "minus.circle", role: .destructive) {
              confirmation = .init(title: "Remove \(folder.name) from the sidebar?", button: "Remove Folder",
                message: "Open conversations in this folder will close. Files and saved chats are kept; open the folder again to restore it.") {
                  workspace.forgetFolder(folder)
                }
            }
          }
        }
      }
      if workspace.hostID == nil {
        Button(action: workspace.chooseFolder) { Label("Open Folder…", systemImage: "folder.badge.plus") }
      } else if workspace.snapshot.folders.isEmpty {
        Text("No folders available on this host.").foregroundStyle(.secondary)
      }
    }
  }

  private var conversations: some View {
    Group {
      if workspace.cwd.isEmpty {
        Button("Choose a Folder…") { workspace.sidebarSection = .folders }.selectionDisabled()
      } else {
        HStack(spacing: 8) {
          TextField("Find a conversation", text: $workspace.search)
            .textFieldStyle(.roundedBorder).frame(maxWidth: .infinity)
            .focused($searchFocused)
          if workspace.snapshot.canOrganizeSessions == true {
            Toggle("Show archived conversations", isOn: $workspace.showArchived)
              .toggleStyle(.switch).controlSize(.mini).labelsHidden().fixedSize()
              .accessibilityValue(workspace.showArchived ? "Archived" : "Active")
              .help(workspace.showArchived ? "Showing archived conversations. Switch to active." : "Showing active conversations. Switch to archived.")
          }
        }.selectionDisabled()
        ForEach(workspace.unlistedConversations) { chat in
          Button { selectedSessionIDs = []; workspace.select(chat) } label: {
            chatRow(title: chat.title, chat: chat)
          }
          .contextMenu { openChatActions(chat) }
          .selectionDisabled()
        }
        ForEach(workspace.sessions) { session in
          let chat = workspace.conversation(for: session)
          chatRow(title: session.title, chat: chat, pinned: session.isPinned == true, date: session.updatedAt)
            .tag(session.sessionID)
        }
        if workspace.sessions.isEmpty && workspace.unlistedConversations.isEmpty {
          Text(workspace.search.isEmpty ? "No \(workspace.showArchived ? "archived" : "active") conversations." : "No matching conversations.")
            .foregroundStyle(.secondary)
            .selectionDisabled()
        }
      }
    }
  }

  private func row(_ title: String, icon: String, selected: Bool) -> some View {
    HStack {
      Label(title, systemImage: icon).lineLimit(1)
      Spacer()
      if selected { Image(systemName: "checkmark").accessibilityLabel("Selected") }
    }.contentShape(Rectangle())
  }

  private func chatRow(title: String, chat: MacConversation?, pinned: Bool = false, date: Date? = nil) -> some View {
    HStack {
      Image(systemName: chat?.permission != nil ? "hand.raised" : pinned ? "pin.fill" : "bubble.left")
      VStack(alignment: .leading, spacing: 3) {
        Text(title).lineLimit(2)
        if let date { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer()
      if chat?.busy == true { ProgressView().controlSize(.mini).accessibilityLabel("Working") }
      if let chat, workspace.selectedID == chat.id { Image(systemName: "checkmark").accessibilityLabel("Selected") }
    }.contentShape(Rectangle())
  }

  @ViewBuilder
  private func sessionActions(_ session: ACPSessionInfo, chat: MacConversation?) -> some View {
    Button("Open", systemImage: "bubble.left") { workspace.open(session) }
    if workspace.snapshot.canManageSessions == true {
      Group {
        Button("Rename…", systemImage: "pencil") {
          rename = .init(title: "Rename Conversation", name: session.title) { workspace.manage(session, action: .rename, title: $0) }
        }
        if workspace.snapshot.canOrganizeSessions == true {
          Button("Fork", systemImage: "arrow.triangle.branch") { workspace.manage(session, action: .fork) }
          Button(session.isPinned == true ? "Unpin" : "Pin to Top", systemImage: session.isPinned == true ? "pin.slash" : "pin") {
            workspace.manage(session, action: session.isPinned == true ? .unpin : .pin)
          }
          Button(session.isArchived == true ? "Restore" : "Archive", systemImage: "archivebox") {
            workspace.manage(session, action: session.isArchived == true ? .restore : .archive)
          }
        }
        Divider()
        moveMenu([session])
        Button("Delete…", systemImage: "trash", role: .destructive) {
          confirmDelete([session])
        }
      }.disabled(chat?.busy == true)
    }
    Divider()
    if workspace.hostID == nil {
      Button("Open in Terminal", systemImage: "terminal") { workspace.openTerminal(session) }
    }
    Button("Copy Conversation ID", systemImage: "doc.on.doc") { copy(session.sessionID) }
    if let chat { openChatActions(chat) }
  }

  private func batchActions(_ sessions: [ACPSessionInfo]) -> some View {
    Group {
      moveMenu(sessions)
      Button("Delete \(sessions.count) Conversations…", systemImage: "trash", role: .destructive) {
        confirmDelete(sessions)
      }
    }
    .disabled(workspace.busy || workspace.snapshot.canManageSessions != true
      || sessions.contains { workspace.conversation(for: $0)?.busy == true })
  }

  @ViewBuilder
  private func moveMenu(_ sessions: [ACPSessionInfo]) -> some View {
    if workspace.snapshot.canMoveSessions == true {
      Menu("Move to Folder", systemImage: "folder") {
        ForEach(workspace.snapshot.folders.filter { $0.cwd != workspace.cwd }) { folder in
          Button(folder.name, systemImage: folder.icon ?? "folder") {
            workspace.manage(sessions, action: .move, destinationCwd: folder.cwd)
          }
          .help(folder.cwd)
        }
      }
      .disabled(!workspace.snapshot.folders.contains { $0.cwd != workspace.cwd })
    }
  }

  private func confirmDelete(_ sessions: [ACPSessionInfo]) {
    let hostID = workspace.hostID
    let title = sessions.count == 1 ? "Delete \(sessions[0].title)?" : "Delete \(sessions.count) conversations?"
    confirmation = .init(title: title,
      button: sessions.count == 1 ? "Delete Conversation" : "Delete Conversations",
      message: "This permanently deletes the selected saved conversations.") {
        guard workspace.hostID == hostID else { return }
        workspace.manage(sessions, action: .delete)
      }
  }

  @ViewBuilder
  private func openChatActions(_ chat: MacConversation) -> some View {
    if chat.busy { Button("Stop Response", systemImage: "stop", action: chat.stop) }
    Button("Close Conversation", systemImage: "xmark") { workspace.closeConversation(chat) }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

private struct SidebarConfirmation {
  var title: String
  var button: String
  var message: String
  var action: () -> Void
}

private struct SidebarRename: Identifiable {
  let id = UUID()
  var title: String
  var name: String
  var save: (String) -> Void
}

private struct SidebarRenameSheet: View {
  let edit: SidebarRename
  @State private var name = ""
  @Environment(\.dismiss) private var dismiss
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(edit.title).font(.headline)
      TextField("Name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
      HStack {
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save") { edit.save(name.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
          .keyboardShortcut(.defaultAction)
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 400)
      .onAppear { name = edit.name; focused = true }
  }
}
