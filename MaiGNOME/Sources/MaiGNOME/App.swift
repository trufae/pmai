import CGNOME
import Foundation
import Glibc
import MaiACP
import MaiCore

@main
enum Main {
  static func main() {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
      print(LaunchOptions.usage)
      return
    }
    do {
      let options = try LaunchOptions(arguments)
      let app = adw_application_new("io.github.trufae.mai.GNOME", mai_instance_flags(arguments.isEmpty ? 0 : 1))!
      var window: GNOMEWindow?
      signal(app, "activate") {
        if let window { window.present() }
        else { window = GNOMEWindow(application: app, launch: options); window?.present() }
      }
      let status = g_application_run(castApplication(app), 0, nil)
      withExtendedLifetime(window) {}
      g_object_unref(UnsafeMutableRawPointer(app))
      exit(status)
    } catch {
      FileHandle.standardError.write(Data("pmai-gnome: \(error.localizedDescription)\n".utf8))
      exit(2)
    }
  }
}

func castApplication(_ app: UnsafeMutablePointer<AdwApplication>) -> UnsafeMutablePointer<GApplication> {
  UnsafeMutableRawPointer(app).assumingMemoryBound(to: GApplication.self)
}

/// Widget pointers and mutable state belong to GTK's main context. Worker tasks
/// capture immutable input and return through onGTK before touching the window.
final class GNOMEWindow: @unchecked Sendable {
  private let application: UnsafeMutablePointer<AdwApplication>
  private let launch: LaunchOptions
  private let window: Widget
  private let remoteSetup: Task<Void, any Error>
  private var split: Widget!
  private var contextMenu: ContextMenu!
  private let sidebarButton = gtk_toggle_button_new()!
  private let sidebar = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
  private let chatList = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
  private let hostMenu = gtk_menu_button_new()!
  private let hostsBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
  private let projectMenu = gtk_menu_button_new()!
  private let projects = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
  private let search = gtk_search_entry_new()!
  private let archived = gtk_toggle_button_new()!
  private let new = iconButton("list-add-symbolic", "New Chat")
  private let title = label("PocketMai", wrap: false)
  private let status = label("")
  private let transcript = TranscriptView()
  private let permissions = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
  private let composer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
  private let editor = gtk_text_view_new()!
  private lazy var completion = ComposerCompletion(editor: editor)
  private let send = gtk_button_new_with_label("Send")!
  private let stop = gtk_button_new_with_label("Stop")!
  private let connectButton = gtk_button_new_with_label("Reconnect")!
  private let attach = iconButton("mail-attachment-symbolic", "Attach File")
  private let attachmentsBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
  private let configurationMenu = gtk_menu_button_new()!
  private let configuration = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
  private let toolsMenu = gtk_menu_button_new()!
  private let toolsSearch = gtk_search_entry_new()!
  private let toolsBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
  private let agentsMenu = gtk_menu_button_new()!
  private let agentsBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
  private let terminal = iconButton("utilities-terminal-symbolic", "Open in Terminal")

  private struct Selection: Hashable {
    let cwd: String
    let sessionID: String?
    let hostID: UUID?
  }

  private struct Draft {
    let text: String
    let attachments: [Attachment]
  }

  private struct Permission {
    let request: JSONValue
    let answer: CheckedContinuation<String?, Never>
  }

  private enum MessageChange: Sendable {
    case rewind
    case replace(String?)
  }

  private var snapshot = ACPWorkspaceSnapshot()
  private var hosts: [ACPRemoteHost] = []
  private var host: ACPRemoteHost?
  private var settings: SettingsWindow?
  private var refreshID = UUID()
  private var project: String
  private var selection: Selection?
  private var recordedSelection = false
  private var generation = UUID()
  private var client: (any RemoteSessionClient)?
  private var disconnecting: Task<Void, Never>?
  private var operation: Task<Void, Never>?
  private var connected = false
  private var connecting = false
  private var canRewind = false
  private var canEditMessages = false
  private var sending = false
  private var closing = false
  private var importing = false
  private var renderPending = false
  private var messages: [ACPConversationMessage] = []
  private var loading: [ACPConversationMessage] = []
  private var options: [RemoteSessionOption] = []
  private var prompts = PromptCatalog(builtins: [])
  private var advertisedCommands: [PromptCatalog.Entry] = []
  private var agents: [AgentProcessRecord] = []
  private var pending: [Permission] = []
  private var attachments: [Attachment] = []
  private var drafts: [Selection: Draft] = [:]
  private var busy: Bool { operation != nil }
  private var savedSelection: Selection? {
    guard let selection, selection.sessionID != nil, recordedSelection || snapshot.sessions.contains(where: {
      $0.sessionID == selection.sessionID && $0.cwd == selection.cwd
    }) else { return nil }
    return selection
  }

  init(application: UnsafeMutablePointer<AdwApplication>, launch: LaunchOptions) {
    self.application = application
    self.launch = launch
    self.project = launch.directory.path
    remoteSetup = Task {
      try await ForwirohRemote.shared.configure(
        directory: launch.home.rootURL.appendingPathComponent("forwiroh-client"), name: "PocketMai for GNOME")
    }
    window = mai_window(application)!
    gtk_window_set_title(cast(window, GtkWindow.self), "PocketMai")
    gtk_window_set_default_size(cast(window, GtkWindow.self), 1050, 740)
    mai_style_transcript(window)
    buildSidebar()
    split = mai_split(window, sidebar, buildChat())
    mai_bind_sidebar_toggle(split, sidebarButton)
    contextMenu = ContextMenu(parent: gtk_widget_get_parent(split)!)
    transcript.onContextMenu = { [weak self] message, row, x, y in
      self?.showMessageMenu(message, from: row, x: x, y: y)
    }
    closeRequest(window) { [weak self] in self?.close() }
    updateControls()
    reloadHosts()
    refreshWorkspace()
  }

  func present() { gtk_window_present(cast(window, GtkWindow.self)) }

  private func popover(_ button: Widget, content: Widget, width: Int32, header: Widget? = nil) {
    let popover = gtk_popover_new()!
    dismissPopoverOnEscape(popover)
    let scroll = gtk_scrolled_window_new()!
    gtk_widget_set_size_request(scroll, width, -1)
    gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroll), 1)
    gtk_scrolled_window_set_max_content_height(OpaquePointer(scroll), 400)
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    margins(content, 8)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), content)
    if let header {
      let body = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4)!
      margins(header, 6)
      append(body, header)
      append(body, scroll)
      gtk_popover_set_child(cast(popover, GtkPopover.self), body)
    } else {
      gtk_popover_set_child(cast(popover, GtkPopover.self), scroll)
    }
    gtk_menu_button_set_popover(OpaquePointer(button), popover)
  }

  private func buildSidebar() {
    let header = adw_header_bar_new()!
    let folder = iconButton("folder-open-symbolic", "Open Project Folder")
    let refresh = iconButton("view-refresh-symbolic", "Refresh Conversations")
    adw_header_bar_pack_start(OpaquePointer(header), folder)
    adw_header_bar_pack_end(OpaquePointer(header), new)
    adw_header_bar_pack_end(OpaquePointer(header), refresh)
    adw_header_bar_set_show_end_title_buttons(OpaquePointer(header), 0)
    append(sidebar, header)

    let filters = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
    let tools = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
    popover(hostMenu, content: hostsBox, width: 260)
    append(filters, hostMenu)
    gtk_widget_set_hexpand(projectMenu, 1)
    gtk_button_set_icon_name(cast(archived, GtkButton.self), "folder-archive-symbolic")
    gtk_widget_set_tooltip_text(archived, "Include Archived Conversations")
    popover(projectMenu, content: projects, width: 260)
    append(tools, projectMenu)
    append(tools, archived)
    append(filters, tools)
    append(filters, search)
    margins(filters, 8)
    append(sidebar, filters)

    let scroll = gtk_scrolled_window_new()!
    gtk_widget_set_vexpand(scroll, 1)
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    margins(chatList, 6)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), chatList)
    append(sidebar, scroll)

    signal(folder, "clicked") { [weak self] in self?.pickProject() }
    signal(refresh, "clicked") { [weak self] in
      self?.reloadHosts()
      self?.refreshWorkspace()
    }
    signal(new, "clicked") { [weak self] in
      guard let self else { return }
      self.select(.init(cwd: self.project, sessionID: nil, hostID: self.host?.id), title: "New Chat")
    }
    signal(search, "search-changed") { [weak self] in self?.renderChatList() }
    signal(archived, "toggled") { [weak self] in self?.renderChatList() }
  }

  private func buildChat() -> Widget {
    let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
    let header = adw_header_bar_new()!
    gtk_button_set_icon_name(cast(sidebarButton, GtkButton.self), "sidebar-show-symbolic")
    gtk_widget_set_tooltip_text(sidebarButton, "Show or Hide Sidebar")
    let settingsButton = iconButton("emblem-system-symbolic", "Settings")
    signal(settingsButton, "clicked") { [weak self] in self?.openSettings() }
    adw_header_bar_pack_start(OpaquePointer(header), sidebarButton)
    adw_header_bar_pack_end(OpaquePointer(header), settingsButton)
    gtk_widget_add_css_class(title, "title")
    gtk_label_set_ellipsize(OpaquePointer(title), PANGO_ELLIPSIZE_END)
    adw_header_bar_set_title_widget(OpaquePointer(header), title)
    gtk_menu_button_set_icon_name(OpaquePointer(agentsMenu), "system-users-symbolic")
    gtk_widget_set_tooltip_text(agentsMenu, "Subagents")
    popover(agentsMenu, content: agentsBox, width: 360)
    gtk_menu_button_set_label(OpaquePointer(configurationMenu), "Chat Settings")
    popover(configurationMenu, content: configuration, width: 280)
    gtk_menu_button_set_label(OpaquePointer(toolsMenu), "Tools")
    gtk_widget_set_tooltip_text(toolsMenu, "Choose Tools for This Chat")
    popover(toolsMenu, content: toolsBox, width: 360, header: toolsSearch)
    signal(toolsSearch, "search-changed") { [weak self] in self?.renderTools() }
    adw_header_bar_pack_end(OpaquePointer(header), terminal)
    adw_header_bar_pack_end(OpaquePointer(header), agentsMenu)
    adw_header_bar_pack_end(OpaquePointer(header), toolsMenu)
    adw_header_bar_pack_end(OpaquePointer(header), configurationMenu)
    append(root, header)
    append(root, transcript.scroll)

    let clamp = adw_clamp_new()!
    let footer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
    adw_clamp_set_maximum_size(OpaquePointer(clamp), 840)
    adw_clamp_set_tightening_threshold(OpaquePointer(clamp), 600)
    adw_clamp_set_child(OpaquePointer(clamp), footer)
    margins(footer, 12)
    gtk_widget_add_css_class(status, "dim-label")
    gtk_label_set_selectable(OpaquePointer(status), 1)
    append(footer, status)
    append(footer, permissions)
    append(footer, composer)
    append(composer, attachmentsBox)

    let scroll = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_min_content_height(OpaquePointer(scroll), 72)
    gtk_scrolled_window_set_max_content_height(OpaquePointer(scroll), 180)
    gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroll), 1)
    gtk_widget_set_hexpand(scroll, 1)
    gtk_widget_add_css_class(scroll, "card")
    gtk_text_view_set_wrap_mode(cast(editor, GtkTextView.self), GTK_WRAP_WORD_CHAR)
    gtk_text_view_set_left_margin(cast(editor, GtkTextView.self), 10)
    gtk_text_view_set_right_margin(cast(editor, GtkTextView.self), 10)
    gtk_text_view_set_top_margin(cast(editor, GtkTextView.self), 8)
    gtk_text_view_set_bottom_margin(cast(editor, GtkTextView.self), 8)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), editor)

    let inputRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
    gtk_widget_add_css_class(send, "suggested-action")
    gtk_widget_set_tooltip_text(send, "Send (Enter)")
    gtk_widget_add_css_class(stop, "destructive-action")
    for button in [attach, connectButton, stop, send] {
      gtk_widget_set_valign(button, GTK_ALIGN_END)
    }
    append(inputRow, attach)
    append(inputRow, scroll)
    append(inputRow, connectButton)
    append(inputRow, stop)
    append(inputRow, send)
    append(composer, inputRow)
    append(root, clamp)

    signal(gtk_text_view_get_buffer(cast(editor, GtkTextView.self))!, "changed") { [weak self] in
      self?.updateControls()
      self?.updateCompletion()
    }
    signal(send, "clicked") { [weak self] in self?.submit() }
    signal(stop, "clicked") { [weak self] in self?.stopPrompt() }
    signal(attach, "clicked") { [weak self] in self?.pickAttachment() }
    signal(connectButton, "clicked") { [weak self] in self?.reconnect() }
    signal(terminal, "clicked") { [weak self] in self?.openTerminal() }
    mai_bind_send_key(editor, send)
    completion.onCaretChange = { [weak self] in self?.updateCompletion() }
    transcript.render([], showWelcome: true)
    return root
  }

  private func refreshWorkspace() {
    let launch = self.launch
    let host = self.host
    let remoteSetup = self.remoteSetup
    let id = UUID()
    refreshID = id
    Task { [weak self] in
      let result = await Result.async {
        if host != nil { try await remoteSetup.value }
        return try await launch.snapshot(for: host)
      }
      onGTK { [weak self] in
        guard let self, self.refreshID == id, !self.closing else { return }
        switch result {
        case .success(let snapshot):
          self.snapshot = snapshot
          if host != nil, self.selection == nil { self.setStatus("") }
          if self.selection == nil, host == nil, self.project == self.launch.directory.path,
            !snapshot.folders.contains(where: { $0.cwd == self.project }),
            !self.launch.explicitDirectory, self.launch.statePath == nil, let folder = snapshot.folders.first {
            self.project = folder.cwd
          }
          self.renderProjects()
          self.renderChatList()
          if let entry = snapshot.sessions.first(where: {
            $0.sessionID == self.selection?.sessionID && $0.cwd == self.selection?.cwd
          }) { setLabel(self.title, entry.title) }
          self.updateControls()
        case .failure(let error): self.setStatus(error.localizedDescription)
        }
      }
    }
  }

  private func reloadHosts() {
    do {
      hosts = try launch.hostStore.hosts()
      if let host, let updated = hosts.first(where: { $0.id == host.id }) {
        self.host = updated
        if project == host.cwd { project = updated.cwd }
      } else if host != nil, !busy {
        selectHost(nil)
      }
      renderHosts()
    } catch { setStatus(error.localizedDescription) }
  }

  private func renderHosts() {
    clear(hostsBox)
    gtk_menu_button_set_label(OpaquePointer(hostMenu), host?.name ?? "This Computer")
    let local = menuRow("This Computer")
    signal(local, "clicked") { [weak self] in self?.selectHost(nil) }
    append(hostsBox, local)
    for remote in hosts {
      let row = menuRow(remote.name, detail: remote.cwd)
      signal(row, "clicked") { [weak self] in self?.selectHost(remote) }
      append(hostsBox, row)
    }
  }

  private func selectHost(_ host: ACPRemoteHost?) {
    gtk_menu_button_popdown(OpaquePointer(hostMenu))
    guard self.host?.id != host?.id else { return }
    guard !busy else { setStatus("Wait for the current operation to finish before switching hosts."); return }
    select(nil, title: "PocketMai")
    self.host = host
    project = host?.cwd ?? launch.directory.path
    snapshot = .init()
    gtk_editable_set_text(OpaquePointer(search), "")
    gtk_toggle_button_set_active(cast(archived, GtkToggleButton.self), 0)
    renderHosts()
    renderProjects()
    renderChatList()
    setStatus(host == nil ? "" : "Loading remote conversations…")
    refreshWorkspace()
  }

  private func openSettings() {
    if let settings { settings.present(); return }
    let settings = SettingsWindow(parent: window, launch: launch,
      cwd: host == nil ? project : nil, remoteSetup: remoteSetup,
      onSaved: { [weak self] change in
        guard let self else { return }
        if let remote = change.pairedHost {
          self.reloadHosts()
          self.selectHost(remote)
        } else if change.hostsChanged {
          self.reloadHosts()
          self.refreshWorkspace()
        } else {
          // A running worker keeps its runtime, but the completion list can
          // pick up locally saved prompts and skills immediately.
          if self.host == nil, let selection = self.selection,
            let catalog = try? self.launch.localPrompts(cwd: selection.cwd) {
            self.prompts = catalog
            self.updateCompletion()
          }
        }
      }, onClose: { [weak self] in self?.settings = nil })
    self.settings = settings
    settings.present()
  }

  private func showConversation() {
    let view = OpaquePointer(split)
    if adw_overlay_split_view_get_collapsed(view) != 0 {
      adw_overlay_split_view_set_show_sidebar(view, 0)
    }
  }

  private func renderProjects() {
    clear(projects)
    let selected = snapshot.folders.first { $0.cwd == project }
    let name = ACPWorkspaceFolder.displayName(for: project, name: selected?.name)
    gtk_menu_button_set_label(OpaquePointer(projectMenu), name)
    gtk_widget_set_tooltip_text(projectMenu, project)
    for folder in snapshot.folders {
      let row = menuRow(folder.name, detail: folder.cwd)
      signal(row, "clicked") { [weak self] in
        guard let self else { return }
        self.project = folder.cwd
        gtk_editable_set_text(OpaquePointer(self.search), "")
        gtk_menu_button_popdown(OpaquePointer(self.projectMenu))
        self.renderProjects()
        self.renderChatList()
      }
      append(projects, row)
    }
    if host == nil {
      let open = menuRow("Open Project Folder…")
      signal(open, "clicked") { [weak self] in
        guard let self else { return }
        gtk_menu_button_popdown(OpaquePointer(self.projectMenu))
        self.pickProject()
      }
      append(projects, open)
    }
  }

  private func renderChatList() {
    clear(chatList)
    let query = gtk_editable_get_text(OpaquePointer(search)).map { String(cString: $0) } ?? ""
    let includeArchived = gtk_toggle_button_get_active(cast(archived, GtkToggleButton.self)) != 0
    let folders = Dictionary(snapshot.folders.map { ($0.cwd, $0.name) }, uniquingKeysWith: { first, _ in first })
    let sessions = snapshot.sessions.filter { session in
      guard includeArchived || session.isArchived != true else { return false }
      if query.isEmpty { return session.cwd == project }
      return [session.title, session.cwd, folders[session.cwd] ?? ""].contains {
        $0.localizedCaseInsensitiveContains(query)
      }
    }.sorted { lhs, rhs in
      if (lhs.isPinned == true) != (rhs.isPinned == true) { return lhs.isPinned == true }
      return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
    }
    for session in sessions {
      let item = Selection(cwd: session.cwd, sessionID: session.sessionID, hostID: host?.id)
      let isArchived = session.isArchived == true
      let name = (session.isPinned == true ? "★ " : "") + session.title
      let detail = query.isEmpty ? nil : folders[session.cwd]
      let row = menuRow(name, detail: isArchived ? "Archived" : detail)
      if selection == item { gtk_widget_add_css_class(row, "accent") }
      signal(row, "clicked") { [weak self] in self?.select(item, title: session.title) }
      contextClick(row) { [weak self] x, y in
        self?.showConversationMenu(session, item: item, from: row, x: x, y: y)
      }
      append(chatList, row)
    }
    if sessions.isEmpty {
      let empty = label(query.isEmpty ? "No saved conversations" : "No matching conversations")
      gtk_widget_add_css_class(empty, "dim-label")
      margins(empty, 10)
      append(chatList, empty)
    }
  }

  private func menuRow(_ title: String, detail: String? = nil) -> Widget {
    let button = gtk_button_new()!
    let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
    let primary = label(title, wrap: false)
    gtk_label_set_ellipsize(OpaquePointer(primary), PANGO_ELLIPSIZE_END)
    append(box, primary)
    if let detail {
      let secondary = label(detail, wrap: false)
      gtk_label_set_ellipsize(OpaquePointer(secondary), PANGO_ELLIPSIZE_START)
      gtk_widget_add_css_class(secondary, "dim-label")
      gtk_widget_add_css_class(secondary, "caption")
      append(box, secondary)
    }
    gtk_widget_add_css_class(button, "flat")
    gtk_button_set_child(cast(button, GtkButton.self), box)
    return button
  }

  private func pickProject() {
    guard !busy else { return }
    chooseFile(window: window, folder: true, directory: host == nil ? project : launch.directory.path) { [weak self] url in
      guard let self else { return }
      let home = self.launch.home
      Task {
        let result = Result { try home.openProject(atWorkingDirectory: url) }
        onGTK {
          guard !self.closing, !self.busy else { return }
          switch result {
          case .success(let project):
            if self.host != nil { self.selectHost(nil) }
            self.project = project.workingDirectory
            gtk_editable_set_text(OpaquePointer(self.search), "")
            self.refreshWorkspace()
          case .failure(let error): self.setStatus(error.localizedDescription)
          }
        }
      }
    }
  }

  private func select(_ item: Selection?, title name: String) {
    if busy {
      setStatus(sending ? "Stop the current reply before switching conversations." : "Wait for the current operation to finish.")
      return
    }
    if item == selection || (item != nil && item?.sessionID == nil && item?.cwd == selection?.cwd && savedSelection == nil) {
      if item != nil { showConversation() }
      return
    }
    if let selection {
      let key = savedSelection ?? Selection(cwd: selection.cwd, sessionID: nil, hostID: selection.hostID)
      drafts[key] = Draft(text: editorText(editor), attachments: attachments)
    }
    let previous = client
    finishPermissions()
    client = nil
    connected = false
    selection = item
    canRewind = false
    canEditMessages = false
    recordedSelection = item?.sessionID != nil
    generation = UUID()
    messages = []
    options = []
    prompts = PromptCatalog(builtins: [])
    advertisedCommands = []
    agents = []
    let draft = item.flatMap { drafts.removeValue(forKey: $0) }
    setEditorText(editor, draft?.text ?? "")
    attachments = draft?.attachments ?? []
    renderAttachments()
    renderOptions()
    renderAgents()
    transcript.reset()
    setLabel(title, name)
    renderChatList()
    if let item {
      showConversation()
      connect(item, after: previous)
    } else {
      if let previous { disconnecting = Task { await previous.disconnect() } }
      transcript.render([], showWelcome: true)
      updateControls()
    }
  }

  private func reconnect() {
    guard let selection, !busy else { return }
    let previous = client
    client = nil
    generation = UUID()
    connect(selection, after: previous)
  }

  private func connect(_ item: Selection, after previous: (any RemoteSessionClient)?) {
    let id = generation
    let workspace = launch.workspace
    let launch = self.launch
    let host = self.host
    let remoteSetup = self.remoteSetup
    let disconnecting = self.disconnecting
    self.disconnecting = nil
    connected = false
    connecting = true
    loading = []
    setStatus("Connecting…")
    operation = Task { [weak self] in
      await disconnecting?.value
      await previous?.disconnect()
      if host == nil, let session = item.sessionID {
        let saved = try? await workspace.load(sessionID: session, cwd: item.cwd)
        if let saved {
          let transcript = ACPConversationTranscript.saved(saved.transcript)
          onGTK { [weak self] in
            guard let self, self.generation == id, !self.closing else { return }
            self.messages = transcript
            self.agents = saved.subagents ?? []
            self.renderAgents()
            self.transcript.render(self.messages, showWelcome: false)
          }
        }
      }
      guard !Task.isCancelled else { return }
      let worker: any RemoteSessionClient
      do {
        let update: @Sendable (JSONValue) async -> Void = { [weak self] value in
          onGTK { [weak self] in self?.receive(value, session: id) }
        }
        let permission: @Sendable (JSONValue) async throws -> String? = { [weak self] request in
          await withCheckedContinuation { answer in
            onGTK { [weak self] in
              guard let self, self.generation == id, !self.closing else {
                answer.resume(returning: nil)
                return
              }
              self.pending.append(.init(request: request, answer: answer))
              self.renderPermission()
            }
          }
        }
        let disconnect: @Sendable () async -> Void = { [weak self] in
          onGTK { [weak self] in self?.disconnected(session: id) }
        }
        if let host {
          try await remoteSetup.value
          worker = try launch.hostStore.connection(for: host).makeSession(cwd: item.cwd, sessionID: item.sessionID,
            onUpdate: update, onPermission: permission, onDisconnect: disconnect, onConnectionFailure: { [weak self] error in
              let message = error.localizedDescription
              onGTK { [weak self] in self?.disconnected(session: id, message: message) }
            })
        } else {
          worker = ACPClient(configuration: try launch.worker(cwd: item.cwd, session: item.sessionID),
            onUpdate: update, onPermission: permission, onDisconnect: disconnect)
        }
      } catch {
        let message = error.localizedDescription
        onGTK { [weak self] in self?.connectionFailed(message, session: id) }
        return
      }
      onGTK { [weak self] in
        guard let self, self.generation == id else { return }
        self.client = worker
      }
      do {
        let session = try await worker.connect()
        try Task.checkCancellation()
        let canRewind = await worker.historyRewindSupported()
        let canEditMessages = await worker.messageEditingSupported()
        let options = (try? await worker.configurationOptions()) ?? []
        let prompts = (try? await worker.promptCatalog()) ?? PromptCatalog(builtins: [])
        onGTK { [weak self] in
          guard let self, self.generation == id, !self.closing else { return }
          self.selection = Selection(cwd: item.cwd, sessionID: session, hostID: item.hostID)
          self.connected = true
          self.connecting = false
          self.canRewind = canRewind
          self.canEditMessages = canEditMessages
          self.operation = nil
          if !self.loading.isEmpty || self.messages.isEmpty { self.messages = self.loading }
          self.loading = []
          self.options = options
          self.prompts = prompts
          self.updateCompletion()
          self.renderOptions()
          self.transcript.render(self.messages, showWelcome: false)
          self.setStatus("")
          self.refreshWorkspace()
          self.updateControls()
          _ = gtk_widget_grab_focus(self.editor)
        }
      } catch {
        await worker.disconnect()
        let message = error.localizedDescription
        onGTK { [weak self] in self?.connectionFailed(message, session: id) }
      }
    }
    updateControls()
  }

  private func connectionFailed(_ message: String, session: UUID) {
    guard generation == session, !closing else { return }
    connecting = false
    connected = false
    operation = nil
    finishPermissions()
    setStatus(message)
    updateControls()
  }

  private func disconnected(session: UUID, message: String = "Disconnected") {
    guard generation == session, !closing else { return }
    connected = false
    finishPermissions()
    if !busy { setStatus(message) }
    updateControls()
  }

  private func receive(_ update: JSONValue, session: UUID) {
    guard generation == session, !closing else { return }
    switch update.objectValue?["sessionUpdate"]?.stringValue {
    case "config_option_update":
      options = RemoteSessionOption.parse(update.objectValue?["configOptions"])
      renderOptions()
      return
    case "available_commands_update":
      advertisedCommands = (update.objectValue?["availableCommands"]?.arrayValue ?? []).compactMap { entry in
        guard let fields = entry.objectValue, let name = fields["name"]?.stringValue else { return nil }
        return .init(kind: .user, name: name, commandName: name, text: "",
          description: fields["description"]?.stringValue, invocation: name)
      }
      updateCompletion()
      return
    default: break
    }
    if connecting {
      ACPConversationTranscript.apply(update, to: &loading)
    } else {
      ACPConversationTranscript.apply(update, to: &messages)
      if !renderPending {
        renderPending = true
        onGTK(after: 40) { [weak self] in
          guard let self, !self.closing else { return }
          self.renderPending = false
          self.transcript.render(self.messages, showWelcome: self.selection == nil)
        }
      }
    }
  }

  private func updateCompletion() {
    guard !closing else { return }
    var catalog = prompts
    catalog.entries += advertisedCommands
    completion.update(catalog)
  }

  private func promptEntry(named name: String) -> PromptCatalog.Entry? {
    prompts.entry(named: name) ?? advertisedCommands.first {
      PromptSlashCommand.normalized($0.commandName) == PromptSlashCommand.normalized(name)
    }
  }

  private func localCommand(for text: String) -> (ComposerCommand, String)? {
    guard let parsed = PromptSlashCommand.parse(text),
      let command = ComposerCommand(rawValue: PromptSlashCommand.normalized(parsed.command)),
      text.hasPrefix("/") || promptEntry(named: parsed.command)?.kind == .system || promptEntry(named: parsed.command) == nil
    else { return nil }
    return (command, parsed.remainder)
  }

  private func canRun(_ command: ComposerCommand) -> Bool {
    switch command {
    case .help, .settings, .sidebar: true
    case .stop: sending
    case .agent, .provider, .model, .set: connected && !busy
    }
  }

  private func run(_ command: ComposerCommand, argument: String) {
    guard canRun(command) else { return }
    switch command {
    case .settings:
      openSettings()
    case .sidebar:
      let button = cast(sidebarButton, GtkToggleButton.self)
      gtk_toggle_button_set_active(button, gtk_toggle_button_get_active(button) == 0 ? 1 : 0)
    case .help:
      let text = ComposerCommand.allCases.map { "- `/\($0.rawValue)` — \($0.summary)" }.joined(separator: "\n")
      messages.append(.init(role: "assistant", text: text))
      transcript.render(messages, showWelcome: false)
    case .stop:
      stopPrompt()
    case .agent, .provider, .model, .set:
      if argument.isEmpty {
        if options.isEmpty { setStatus("This session offers no configurable chat options.") }
        else { gtk_menu_button_popup(OpaquePointer(configurationMenu)) }
        break
      }
      let fields = argument.split(maxSplits: 1, whereSeparator: \.isWhitespace)
      let option = command == .set ? options.first { $0.id == fields.first.map(String.init) }
        : options.first { $0.category == command.rawValue || $0.id == command.rawValue }
      let value = command == .set ? fields.dropFirst().first.map(String.init) ?? "" : argument
      guard let option else { setStatus("Use Chat Settings to see the options offered by this session."); return }
      let setting = option.isBoolean ? Bool(value.lowercased()).map(JSONValue.bool) ?? .null : .string(value)
      guard option.accepts(setting) else { setStatus("Choose a valid value for " + option.name + " in Chat Settings."); return }
      setOption(option.id, value: setting)
    }
    setEditorText(editor, "")
  }

  private func submit() {
    let text = editorText(editor).trimmingCharacters(in: .whitespacesAndNewlines)
    if let (command, argument) = localCommand(for: text) {
      run(command, argument: argument)
      return
    }
    guard connected, !busy, !importing, let client else { return }
    let submitted = attachments
    guard !text.isEmpty || !submitted.isEmpty else { return }
    var prompt = RemotePromptRequest(text: text, attachments: submitted.map(\.content))
    if let command = PromptSlashCommand.parse(text), let entry = promptEntry(named: command.command),
      entry.kind != .system
    {
      prompt.text = entry.invocation != nil || entry.skillID != nil ? command.remainder
        : entry.message(arguments: command.remainder) ?? text
      prompt.command = entry.invocation
      prompt.skillID = entry.skillID
    }
    let request = prompt
    let display = ([text] + submitted.map { "Attached: \($0.name)" }).filter { !$0.isEmpty }.joined(separator: "\n\n")
    let optimistic = ACPConversationMessage(role: "user", text: display)
    messages.append(optimistic)
    transcript.render(messages, showWelcome: false)
    attachments = []
    renderAttachments()
    setEditorText(editor, "")
    sending = true
    setStatus("Working…")
    operation = Task { [weak self] in
      let result = await Result.async { try await client.prompt(request) { _ in } }
      let active = await client.isConnected
      let acp = client as? ACPClient
      let agents = if let acp, await acp.agentManagementSupported() { try? await acp.sessionAgents() }
        else { nil as [AgentProcessRecord]? }
      onGTK { [weak self] in
        guard let self, !self.closing else { return }
        self.connected = active
        self.sending = false
        self.operation = nil
        self.finishPermissions()
        switch result {
        case .success(let reason):
          self.recordedSelection = true
          self.setStatus(reason == .cancelled ? "Reply stopped" : "")
        case .failure(let error):
          if self.messages.last?.id == optimistic.id { self.messages.removeLast() }
          let current = editorText(self.editor)
          setEditorText(self.editor, [text, current].filter { !$0.isEmpty }.joined(separator: "\n\n"))
          self.attachments.insert(contentsOf: submitted, at: 0)
          self.renderAttachments()
          self.setStatus(error.localizedDescription)
        }
        if let agents { self.agents = agents; self.renderAgents() }
        self.transcript.render(self.messages, showWelcome: false)
        self.updateControls()
        self.refreshWorkspace()
      }
    }
    updateControls()
  }

  private func stopPrompt() {
    guard sending, let client else { return }
    finishPermissions()
    setStatus("Stopping…")
    Task { await client.cancel() }
  }

  private func pickAttachment() {
    guard let selection else { return }
    let id = generation
    chooseFile(window: window, folder: false, directory: selection.hostID == nil ? selection.cwd : launch.directory.path) { [weak self] url in
      guard let self, self.generation == id, !self.closing, !self.importing else { return }
      self.importing = true
      self.updateControls()
      let type = g_content_type_guess(url.path, nil, 0, nil)
      let mime = type.flatMap { g_content_type_get_mime_type($0) }
      let mimeType = mime.map { String(cString: $0) }
      g_free(type)
      g_free(mime)
      Task {
        let result = await Result.async { try await Attachment.load(url, mimeType: mimeType) }
        onGTK {
          self.importing = false
          guard !self.closing else { return }
          if self.generation == id {
            switch result {
            case .success(let attachment):
              self.attachments.append(attachment)
              self.renderAttachments()
            case .failure(let error): self.setStatus(error.localizedDescription)
            }
          }
          self.updateControls()
        }
      }
    }
  }

  private func renderAttachments() {
    clear(attachmentsBox)
    for attachment in attachments {
      let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
      let name = label(attachment.name)
      let remove = iconButton("window-close-symbolic", "Remove \(attachment.name)")
      signal(remove, "clicked") { [weak self] in
        guard let self else { return }
        self.attachments.removeAll { $0.id == attachment.id }
        self.renderAttachments()
        self.updateControls()
      }
      gtk_widget_set_hexpand(name, 1)
      gtk_widget_add_css_class(remove, "flat")
      append(row, name)
      append(row, remove)
      append(attachmentsBox, row)
    }
    gtk_widget_set_visible(attachmentsBox, attachments.isEmpty ? 0 : 1)
  }

  private func renderOptions() {
    clear(configuration)
    let model = options.first { $0.category == "model" }
    let modelName = model?.choices.first { $0.id == model?.currentValue.stringValue }?.name
    let displayName = modelName.map { $0.count > 24 ? String($0.prefix(23)) + "…" : $0 }
    gtk_menu_button_set_label(OpaquePointer(configurationMenu), displayName ?? "Chat Settings")
    gtk_widget_set_tooltip_text(configurationMenu, modelName ?? "Chat Settings")
    let general = options.filter { !isToolOption($0) }
    let agentFirst = general.filter { $0.id == "agent" || $0.category == "agent" }
    for option in agentFirst + general.filter({ !agentFirst.contains($0) }) {
      let heading = label(option.name)
      gtk_widget_add_css_class(heading, "heading")
      append(configuration, heading)
      let choices: [(String, JSONValue, String?)] = option.isBoolean
        ? [("On", .bool(true), nil), ("Off", .bool(false), nil)]
        : option.choices.map { ($0.name, .string($0.id), $0.group) }
      var previousGroup: String?
      for (name, value, group) in choices {
        if let group, group != previousGroup, option.category == "agent" {
          let groupLabel = label(group)
          gtk_widget_add_css_class(groupLabel, "dim-label")
          gtk_widget_add_css_class(groupLabel, "caption")
          append(configuration, groupLabel)
        }
        previousGroup = group
        let button = menuRow(value == option.currentValue ? "✓  \(name)" : name)
        signal(button, "clicked") { [weak self] in self?.setOption(option.id, value: value) }
        append(configuration, button)
      }
    }
    renderTools()
    updateControls()
  }

  private func isToolOption(_ option: RemoteSessionOption) -> Bool {
    option.isBoolean && (option.id.hasPrefix("tools.") || option.category == "tools"
      || option.category?.hasPrefix("tools/") == true)
  }

  private func renderTools() {
    clear(toolsBox)
    let tools = options.filter(isToolOption)
    let enabled = tools.first { $0.id == "tools.enabled" }?.currentValue.boolValue != false
    let query = (gtk_editable_get_text(OpaquePointer(toolsSearch)).map(String.init(cString:)) ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let individual = tools.filter { $0.id.hasPrefix("tools.tool.") || $0.category?.hasPrefix("tools/") == true }
    for control in tools where !individual.contains(control) {
      appendToolSwitch(control, enabled: true)
    }
    let groups = Dictionary(grouping: individual) { option in
      option.category.flatMap { $0.hasPrefix("tools/") ? String($0.dropFirst("tools/".count)) : nil } ?? "Other"
    }
    var matched = false
    for group in groups.keys.sorted() {
      let matches = (groups[group] ?? []).filter { option in
        query.isEmpty || [group, option.name, option.description ?? ""].contains {
          $0.localizedCaseInsensitiveContains(query)
        }
      }
      guard !matches.isEmpty else { continue }
      matched = true
      let heading = label(group)
      gtk_widget_add_css_class(heading, "heading")
      append(toolsBox, heading)
      for option in matches { appendToolSwitch(option, enabled: enabled) }
    }
    if !matched, !query.isEmpty { append(toolsBox, label("No matching tools")) }
  }

  private func appendToolSwitch(_ option: RemoteSessionOption, enabled: Bool) {
    let toggle = gtk_check_button_new_with_label(option.name)!
    let button = cast(toggle, GtkCheckButton.self)
    gtk_check_button_set_active(button, option.currentValue.boolValue == true ? 1 : 0)
    gtk_widget_set_sensitive(toggle, enabled ? 1 : 0)
    if let description = option.description { gtk_widget_set_tooltip_text(toggle, description) }
    signal(toggle, "toggled") { [weak self] in
      self?.setOption(option.id, value: .bool(gtk_check_button_get_active(button) != 0))
    }
    append(toolsBox, toggle)
  }

  private func setOption(_ id: String, value: JSONValue) {
    guard connected, !busy, let client else { return }
    gtk_menu_button_popdown(OpaquePointer(configurationMenu))
    operation = Task { [weak self] in
      let result = await Result.async { try await client.setConfigurationOption(id: id, value: value) }
      onGTK { [weak self] in
        guard let self, !self.closing else { return }
        self.operation = nil
        switch result {
        case .success(let options):
          self.options = options
          self.renderOptions()
        case .failure(let error):
          self.setStatus(error.localizedDescription)
          self.renderTools()
        }
        self.updateControls()
      }
    }
    updateControls()
  }

  private func renderAgents() {
    clear(agentsBox)
    for agent in agents {
      let heading = agent.displayName + " · " + agent.state.rawValue.capitalized
      let expander = gtk_expander_new(heading)!
      let turns = agent.messages.filter { $0.role == .user || $0.role == .assistant }
      let content = label(([agent.task] + turns.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n"))
      gtk_label_set_selectable(OpaquePointer(content), 1)
      gtk_expander_set_child(OpaquePointer(expander), content)
      append(agentsBox, expander)
    }
    updateControls()
  }

  private func renderPermission() {
    clear(permissions)
    gtk_widget_set_visible(permissions, pending.isEmpty ? 0 : 1)
    guard let request = pending.first?.request.objectValue else { return }
    let tool = request["toolCall"]?.objectValue
    let heading = label(tool?["title"]?.stringValue ?? "The agent is requesting permission.")
    gtk_widget_add_css_class(heading, "heading")
    append(permissions, heading)
    if let input = tool?["rawInput"].flatMap(jsonText) {
      let content = label(input)
      gtk_widget_add_css_class(content, "monospace")
      gtk_label_set_selectable(OpaquePointer(content), 1)
      let scroll = gtk_scrolled_window_new()!
      gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      gtk_scrolled_window_set_max_content_height(OpaquePointer(scroll), 140)
      gtk_scrolled_window_set_propagate_natural_height(OpaquePointer(scroll), 1)
      gtk_scrolled_window_set_child(OpaquePointer(scroll), content)
      append(permissions, scroll)
    }
    let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
    let cancel = gtk_button_new_with_label("Cancel")!
    signal(cancel, "clicked") { [weak self] in self?.answerPermission(nil) }
    append(actions, cancel)
    for value in request["options"]?.arrayValue ?? [] {
      guard let fields = value.objectValue, let id = fields["optionId"]?.stringValue else { continue }
      let button = gtk_button_new_with_label(fields["name"]?.stringValue ?? id)!
      signal(button, "clicked") { [weak self] in self?.answerPermission(id) }
      append(actions, button)
    }
    append(permissions, actions)
  }

  private func answerPermission(_ option: String?) {
    guard !pending.isEmpty else { return }
    pending.removeFirst().answer.resume(returning: option)
    renderPermission()
  }

  private func finishPermissions() {
    for permission in pending { permission.answer.resume(returning: nil) }
    pending.removeAll()
    renderPermission()
  }

  private func showConversationMenu(_ session: ACPSessionInfo, item: Selection, from row: Widget, x: Double, y: Double) {
    var actions: [ContextMenu.Action] = []
    if snapshot.canManageSessions == true {
      actions.append(.init(title: "Rename…", enabled: !busy) { [weak self] in
        guard let self else { return }
        let form = SettingsForm(parent: self.window, title: "Rename Conversation", height: 210)
        let field = form.entry("Title", text: session.title)
        form.present(button: "Rename") { [weak self] in
          let title = entryText(field)
          guard !title.isEmpty else { throw AppError("Enter a conversation title.") }
          self?.manageConversation(item, action: .rename, title: title)
        }
      })
    }
    if snapshot.canOrganizeSessions == true {
      let pinned = session.isPinned == true
      actions.append(.init(title: pinned ? "Unpin" : "Pin", enabled: !busy) { [weak self] in
        self?.manageConversation(item, action: pinned ? .unpin : .pin)
      })
      let archived = session.isArchived == true
      actions.append(.init(title: archived ? "Restore from Archive" : "Archive", enabled: !busy) { [weak self] in
        self?.manageConversation(item, action: archived ? .restore : .archive)
      })
    }
    if item.hostID == nil {
      actions.append(.init(title: "Open in Terminal", enabled: !busy) { [weak self] in self?.openTerminal(item) })
    }
    actions.append(.init(title: "Copy Title") { [weak self] in
      guard let self else { return }
      gdk_clipboard_set_text(gtk_widget_get_clipboard(self.window), session.title)
    })
    if snapshot.canManageSessions == true {
      actions.append(.init(title: "Delete Conversation…", destructive: true, enabled: !busy) { [weak self] in
        self?.confirm("Delete Conversation", detail: "Permanently delete “\(session.title)” and its messages?",
          button: "Delete") { [weak self] in self?.manageConversation(item, action: .delete) }
      })
    }
    contextMenu.show(from: row, x: x, y: y, actions: actions)
  }

  private func manageConversation(_ item: Selection, action: ACPSessionAction, title name: String? = nil) {
    guard !busy, !closing, item.hostID == host?.id, let id = item.sessionID,
      snapshot.sessions.contains(where: { $0.sessionID == id && $0.cwd == item.cwd })
    else { return }
    let active = selection == item && connected ? client : nil
    let clearSelection = selection == item && (action == .delete || action == .archive)
    let launch = self.launch
    let host = self.host
    let remoteSetup = self.remoteSetup
    let disconnecting = self.disconnecting
    operation = Task { [weak self] in
      await disconnecting?.value
      var temporary: (any RemoteSessionClient)?
      let result: Result<Void, any Error>
      do {
        let worker: any RemoteSessionClient
        if let active {
          worker = active
        } else {
          if let host {
            try await remoteSetup.value
            worker = try launch.hostStore.connection(for: host).makeSession(cwd: item.cwd)
          } else {
            worker = ACPClient(configuration: try launch.worker(cwd: item.cwd, session: nil))
          }
          temporary = worker
        }
        _ = try await worker.manageSession(id, cwd: item.cwd, action: action, title: name)
        if clearSelection { await active?.disconnect() }
        result = .success(())
      } catch { result = .failure(error) }
      await temporary?.disconnect()
      onGTK { [weak self] in
        guard let self, !self.closing else { return }
        self.operation = nil
        switch result {
        case .success:
          if clearSelection {
            self.client = nil
            self.select(nil, title: "PocketMai")
          } else if self.selection == item, let name {
            setLabel(self.title, name)
          }
          if action == .delete { self.drafts.removeValue(forKey: item) }
          self.setStatus("")
          self.refreshWorkspace()
        case .failure(let error):
          self.setStatus(error.localizedDescription)
        }
        self.updateControls()
      }
    }
    updateControls()
  }

  private func showMessageMenu(_ message: ACPConversationMessage, from row: Widget, x: Double, y: Double) {
    let generation = self.generation
    var actions: [ContextMenu.Action] = [
      .init(title: "Copy Text") { [weak self] in
        guard let self else { return }
        gdk_clipboard_set_text(gtk_widget_get_clipboard(self.window), message.text)
      }
    ]
    if connected, message.remoteID != nil {
      if canEditMessages {
        actions.append(.init(title: "Edit Message…", enabled: !busy) { [weak self] in
          guard let self else { return }
          let form = SettingsForm(parent: self.window, title: "Edit Message", height: 340)
          let field = form.editor("Message", text: message.text)
          form.present { [weak self] in
            let text = editorText(field)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
              throw AppError("Enter a message.")
            }
            self?.changeMessage(message, in: generation, change: .replace(text))
          }
        })
      }
      if canRewind {
        actions.append(.init(title: "Rewind From Here…", enabled: !busy) { [weak self] in
          self?.confirm("Rewind Conversation", detail: "Remove this message and all later messages?",
            button: "Rewind") { [weak self] in self?.changeMessage(message, in: generation, change: .rewind) }
        })
      }
      if canEditMessages {
        actions.append(.init(title: "Delete Message…", destructive: true, enabled: !busy) { [weak self] in
          self?.confirm("Delete Message", detail: "Permanently remove this message and any linked tool activity?",
            button: "Delete") { [weak self] in self?.changeMessage(message, in: generation, change: .replace(nil)) }
        })
      }
    }
    contextMenu.show(from: row, x: x, y: y, actions: actions)
  }

  private func confirm(_ title: String, detail: String, button: String, action: @escaping () -> Void) {
    let form = SettingsForm(parent: window, title: title, height: 190)
    form.note(detail)
    form.present(button: button, destructive: true, work: action)
  }

  private func changeMessage(_ message: ACPConversationMessage, in generation: UUID, change: MessageChange) {
    guard self.generation == generation, !busy, !closing, connected, let client, let id = message.remoteID,
      messages.contains(where: { $0.id == message.id && $0.remoteID == id })
    else { return }
    operation = Task { [weak self] in
      let result = await Result.async {
        switch change {
        case .rewind: try await client.rewind(to: id)
        case .replace(let text): try await client.editMessage(id, text: text)
        }
      }
      onGTK { [weak self] in
        guard let self, !self.closing, self.generation == generation else { return }
        self.operation = nil
        switch result {
        case .success:
          self.setStatus("")
          self.refreshWorkspace()
        case .failure(let error):
          self.setStatus(error.localizedDescription)
        }
        self.updateControls()
      }
    }
    updateControls()
  }

  private func openTerminal() {
    guard let selection = savedSelection else { return }
    openTerminal(selection)
  }

  private func openTerminal(_ item: Selection) {
    guard host == nil, item.hostID == nil, let id = item.sessionID, !busy, !closing else { return }
    let handoff = selection == item
    let previous = handoff ? client : nil
    if handoff {
      client = nil
      connected = false
      generation = UUID()
    }
    let launch = self.launch
    let disconnecting = self.disconnecting
    operation = Task { [weak self] in
      await disconnecting?.value
      await previous?.disconnect()
      let result = Result { try launch.openInTerminal(cwd: item.cwd, session: id) }
      onGTK { [weak self] in
        guard let self, !self.closing else { return }
        self.operation = nil
        switch result {
        case .success: self.setStatus(handoff ? "Finish the terminal session before reconnecting here." : "")
        case .failure(let error): self.setStatus(error.localizedDescription)
        }
        self.updateControls()
      }
    }
    updateControls()
  }

  private func close() {
    guard !closing else { return }
    closing = true
    completion.detach()
    contextMenu.detach()
    finishPermissions()
    let client = self.client
    let operation = self.operation
    let disconnecting = self.disconnecting
    if connecting { operation?.cancel() }
    Task { [weak self] in
      let deadline = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        await client?.disconnect()
        onGTK { [weak self] in self?.quit() }
      }
      await client?.cancel()
      await operation?.value
      await disconnecting?.value
      await client?.disconnect()
      deadline.cancel()
      onGTK { [weak self] in self?.quit() }
    }
  }

  private func quit() { g_application_quit(castApplication(application)) }

  private func setStatus(_ message: String) {
    setLabel(status, message)
    gtk_widget_set_visible(status, message.isEmpty ? 0 : 1)
  }

  private func updateControls() {
    gtk_widget_set_visible(composer, selection == nil ? 0 : 1)
    gtk_widget_set_visible(agentsMenu, agents.isEmpty ? 0 : 1)
    gtk_widget_set_visible(configurationMenu, options.isEmpty ? 0 : 1)
    gtk_widget_set_visible(toolsMenu, options.contains(where: isToolOption) ? 1 : 0)
    gtk_widget_set_visible(terminal, savedSelection != nil && host == nil ? 1 : 0)
    gtk_widget_set_visible(stop, sending ? 1 : 0)
    gtk_widget_set_visible(connectButton, !connected && !busy && selection != nil ? 1 : 0)
    gtk_widget_set_sensitive(new, busy ? 0 : 1)
    gtk_widget_set_sensitive(terminal, busy ? 0 : 1)
    gtk_widget_set_sensitive(configurationMenu, connected && !busy ? 1 : 0)
    gtk_widget_set_sensitive(toolsBox, connected && !busy ? 1 : 0)
    gtk_widget_set_sensitive(attach, importing ? 0 : 1)
    let text = editorText(editor).trimmingCharacters(in: .whitespacesAndNewlines)
    let canSend = localCommand(for: text).map { canRun($0.0) }
      ?? (connected && !busy && !importing && (!attachments.isEmpty || !text.isEmpty))
    gtk_widget_set_sensitive(send, canSend ? 1 : 0)
  }
}

private extension Result where Success: Sendable, Failure == any Error {
  static func async(_ work: () async throws -> Success) async -> Self {
    do { return .success(try await work()) }
    catch { return .failure(error) }
  }
}
