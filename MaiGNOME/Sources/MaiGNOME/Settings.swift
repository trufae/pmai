import CGNOME
import Foundation
import MaiACP
import MaiCore

final class SettingsWindow: @unchecked Sendable {
  enum Change {
    case configuration, hosts, paired(ACPRemoteHost)

    var pairedHost: ACPRemoteHost? {
      if case .paired(let host) = self { return host }
      return nil
    }

    var hostsChanged: Bool {
      if case .configuration = self { return false }
      return true
    }
  }

  private let window: Widget
  private let launch: LaunchOptions
  private let cwd: String?
  private let remoteSetup: Task<Void, any Error>
  private let onSaved: (Change) -> Void
  private let onClose: () -> Void
  private let status = label("")
  private let providers = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)!
  private let servers = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)!
  private let skills = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)!
  private let prompts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)!
  private let hosts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 5)!
  private var document: ConfigurationDocument?

  init(parent: Widget, launch: LaunchOptions, cwd: String?, remoteSetup: Task<Void, any Error>,
    onSaved: @escaping (Change) -> Void, onClose: @escaping () -> Void
  ) {
    self.window = gtk_window_new()!
    self.launch = launch
    self.cwd = cwd
    self.remoteSetup = remoteSetup
    self.onSaved = onSaved
    self.onClose = onClose
    let native = cast(window, GtkWindow.self)
    gtk_window_set_title(native, "PocketMai Settings")
    gtk_window_set_transient_for(native, cast(parent, GtkWindow.self))
    gtk_window_set_modal(native, 1)
    gtk_window_set_destroy_with_parent(native, 1)
    gtk_window_set_default_size(native, 690, 510)

    let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    let stack = gtk_stack_new()!
    let switcher = gtk_stack_switcher_new()!
    gtk_stack_switcher_set_stack(OpaquePointer(switcher), OpaquePointer(stack))
    gtk_widget_set_halign(switcher, GTK_ALIGN_CENTER)
    margins(root, 12)
    append(root, switcher)
    gtk_widget_set_vexpand(stack, 1)
    for (name, box) in [
      ("Providers", providers), ("MCP Servers", servers), ("Skills", skills),
      ("Prompts", prompts), ("Remote Hosts", hosts),
    ] {
      let scroll = gtk_scrolled_window_new()!
      gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
      gtk_scrolled_window_set_child(OpaquePointer(scroll), box)
      margins(box, 6)
      gtk_stack_add_titled(OpaquePointer(stack), scroll, name, name)
    }
    append(root, stack)
    gtk_widget_add_css_class(status, "dim-label")
    gtk_label_set_selectable(OpaquePointer(status), 1)
    append(root, status)
    gtk_window_set_child(native, root)
    closeRequest(window, closeOnEscape: true) { [weak self] in
      guard let self else { return }
      gtk_window_destroy(cast(self.window, GtkWindow.self))
      self.onClose()
    }
    reloadConfiguration()
    renderSkills()
    renderHosts()
  }

  func present() { gtk_window_present(cast(window, GtkWindow.self)) }

  private func reloadConfiguration() {
    do {
      document = try launch.settingsDocument(cwd: cwd)
      setLabel(status, document?.url.path ?? "")
    } catch {
      document = nil
      setLabel(status, error.localizedDescription)
    }
    renderConfiguration()
  }

  private func action(_ title: String, in box: Widget, run: @escaping () -> Void) {
    let button = gtk_button_new_with_label(title)!
    gtk_widget_set_halign(button, GTK_ALIGN_START)
    signal(button, "clicked", run)
    append(box, button)
  }

  private func item(_ title: String, detail: String, in box: Widget, edit: @escaping () -> Void) {
    let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
    let texts = gtk_box_new(GTK_ORIENTATION_VERTICAL, 3)!
    gtk_widget_set_hexpand(texts, 1)
    let heading = label(title)
    gtk_widget_add_css_class(heading, "heading")
    append(texts, heading)
    if !detail.isEmpty {
      let subtitle = label(detail)
      gtk_widget_add_css_class(subtitle, "dim-label")
      append(texts, subtitle)
    }
    let button = gtk_button_new_with_label("Edit")!
    gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
    signal(button, "clicked", edit)
    append(row, texts)
    append(row, button)
    margins(row, 6)
    append(box, row)
  }

  private func renderConfiguration() {
    [providers, servers, prompts].forEach(clear)
    guard let configuration = document?.configuration else {
      for page in [providers, servers, prompts] {
        action("Reload Configuration", in: page) { [weak self] in self?.reloadConfiguration() }
      }
      return
    }
    action("Add Provider", in: providers) { [weak self] in self?.editProvider(nil) }
    for provider in configuration.providers {
      item(provider.displayName ?? provider.id, detail: provider.kind.rawValue, in: providers) { [weak self] in
        self?.editProvider(provider)
      }
    }
    action("Add MCP Server", in: servers) { [weak self] in self?.editServer(nil) }
    for server in configuration.mcpServers {
      item(server.displayName ?? server.id, detail: server.enabled ? server.kind : "Disabled", in: servers) { [weak self] in
        self?.editServer(server)
      }
    }
    action("Add Prompt", in: prompts) { [weak self] in self?.editPrompt(nil) }
    for prompt in configuration.userPrompts {
      item(prompt.name, detail: "$" + prompt.commandName, in: prompts) { [weak self] in self?.editPrompt(prompt) }
    }
  }

  private func saveConfiguration(_ edit: (inout MaiConfiguration) throws -> Void) throws {
    guard var document else { throw AppError("Reload the configuration before saving.") }
    var updated = document.configuration
    try edit(&updated)
    try document.save(updated)
    self.document = document
    renderConfiguration()
    setLabel(status, "Saved. New conversations and reconnected workers load the updated configuration.")
    onSaved(.configuration)
  }

  private func editProvider(_ original: ConfiguredProvider?) {
    let form = SettingsForm(parent: window, title: original == nil ? "Add Provider" : "Edit Provider")
    let id = form.entry("Identifier", text: original?.id, editable: original == nil)
    let name = form.entry("Display name", text: original?.displayName)
    let kind = form.entry("Provider type", text: original?.kind.rawValue ?? "openai")
    let url = form.entry("API endpoint", text: original?.baseURL?.absoluteString)
    let model = form.entry("Default model", text: original?.defaultModel)
    let secret = form.entry("API key", text: original?.apiKey, secret: true)
    let secretEnv = form.entry("API key environment variable", text: original?.apiKeyEnvironment)
    let secretFile = form.entry("API key file", text: original?.apiKeyFile)
    form.present { [self] in
      let identifier = try settingIdentifier(entryText(id))
      var provider = original ?? ConfiguredProvider(id: identifier, kind: .openAI)
      provider.kind = .init(try settingIdentifier(entryText(kind)))
      provider.displayName = entryText(name).nilIfEmpty
      provider.baseURL = try settingURL(entryText(url))
      provider.defaultModel = entryText(model).nilIfEmpty
      provider.apiKey = entryText(secret).nilIfEmpty
      provider.apiKeyEnvironment = entryText(secretEnv).nilIfEmpty
      provider.apiKeyFile = entryText(secretFile).nilIfEmpty
      try provider.validate()
      try saveConfiguration { configuration in
        if original != nil, let index = configuration.providers.firstIndex(where: { $0.id == identifier }) {
          configuration.providers[index] = provider
        } else {
          guard !configuration.providers.contains(where: { $0.id == identifier }) else {
            throw MaiConfigurationError.duplicateIdentifier(kind: "provider", id: identifier)
          }
          configuration.providers.append(provider)
        }
      }
    }
  }

  private func editServer(_ original: ConfiguredMCPServer?) {
    let form = SettingsForm(parent: window, title: original == nil ? "Add MCP Server" : "Edit MCP Server")
    let id = form.entry("Identifier", text: original?.id, editable: original == nil)
    let name = form.entry("Display name", text: original?.displayName)
    let transport = form.entry("Transport (streamable-http or stdio)", text: original?.kind ?? "streamable-http")
    let url = form.entry("HTTP endpoint", text: original?.url?.absoluteString)
    let token = form.entry("Bearer token", text: original?.bearerToken, secret: true)
    let command = form.entry("Executable", text: original?.command)
    let arguments = form.editor("Arguments, one per line", text: original?.args.joined(separator: "\n"), height: 68)
    let directory = form.entry("Working directory", text: original?.cwd)
    let enabled = form.toggle("Enabled", active: original?.enabled ?? true)
    form.present { [self] in
      let identifier = try settingIdentifier(entryText(id))
      var server = original ?? ConfiguredMCPServer(id: identifier)
      server.kind = try settingIdentifier(entryText(transport))
      server.enabled = gtk_check_button_get_active(cast(enabled, GtkCheckButton.self)) != 0
      server.displayName = entryText(name).nilIfEmpty
      server.url = try settingURL(entryText(url), schemes: ["http", "https"])
      server.bearerToken = entryText(token).nilIfEmpty
      server.command = entryText(command).nilIfEmpty
      let argumentText = editorText(arguments)
      if original?.args.joined(separator: "\n") != argumentText {
        server.args = argumentText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if argumentText.isEmpty { server.args = [] }
      }
      server.cwd = entryText(directory).nilIfEmpty
      if server.kind == "stdio", server.command == nil {
        throw MaiConfigurationError.mcpServerMissingCommand(identifier)
      }
      if server.kind == "streamable-http", server.url == nil {
        throw MaiConfigurationError.mcpServerMissingURL(identifier)
      }
      try saveConfiguration { configuration in
        if original != nil, let index = configuration.mcpServers.firstIndex(where: { $0.id == identifier }) {
          configuration.mcpServers[index] = server
        } else {
          guard !configuration.mcpServers.contains(where: { $0.id == identifier }) else {
            throw MaiConfigurationError.duplicateIdentifier(kind: "MCP server", id: identifier)
          }
          configuration.mcpServers.append(server)
        }
      }
    }
  }

  private func editPrompt(_ original: UserPrompt?) {
    let form = SettingsForm(parent: window, title: original == nil ? "Add Prompt" : "Edit Prompt")
    let name = form.entry("Name", text: original?.name, editable: original == nil)
    let body = form.editor("Prompt", text: original?.text)
    form.present { [self] in
      let title = entryText(name)
      let text = editorText(body)
      guard !title.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw AppError("Enter both a name and a prompt.")
      }
      try saveConfiguration { configuration in
        let command = PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: title))
        if original == nil, configuration.userPrompts.contains(where: {
          PromptSlashCommand.normalized($0.commandName) == command
        }) { throw AppError("A prompt with that command name already exists.") }
        configuration.setUserPrompt(title, text: text)
      }
    }
  }

  private func renderSkills() {
    clear(skills)
    var roots = [("Global Skills", launch.home.skillsDirectoryURL)]
    if let cwd, let project = try? launch.home.loadProject(atWorkingDirectory: URL(fileURLWithPath: cwd)) {
      roots.append(("Project Skills", launch.home.skillsURL(for: project)))
    }
    for (title, root) in roots {
      let heading = label(title)
      gtk_widget_add_css_class(heading, "title-4")
      append(skills, heading)
      let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
      action("New Skill", in: actions) { [weak self] in self?.editSkill(nil, in: root) }
      action("Import Skill Folder", in: actions) { [weak self] in self?.importSkill(in: root) }
      append(skills, actions)
      for skill in AgentSkillCatalog.load(directory: root) {
        item(skill.name, detail: skill.description, in: skills) { [weak self] in
          self?.editSkill(skill, in: root)
        }
      }
    }
  }

  private func editSkill(_ original: AgentSkill?, in root: URL) {
    let form = SettingsForm(parent: window, title: original == nil ? "New Skill" : "Edit Skill")
    let name = form.entry("Name", text: original?.name, editable: original == nil)
    let description = form.editor("Description", text: original?.description, height: 72)
    let body = form.editor("Instructions", text: original?.body)
    form.present { [self] in
      if let original {
        guard let current = AgentSkill.load(directory: original.directoryURL, rootURL: original.rootURL),
          current.body == original.body, current.description == original.description
        else { throw AppError("This skill changed on disk. Reopen Settings before editing it.") }
        try AgentSkillManager.update(original, description: editorText(description), prompt: editorText(body))
      } else {
        try AgentSkillManager.create(name: entryText(name), description: editorText(description),
          prompt: editorText(body), in: root)
      }
      renderSkills()
      onSaved(.configuration)
    }
  }

  private func importSkill(in root: URL) {
    chooseFile(window: window, folder: true, directory: cwd ?? launch.directory.path) { [weak self] folder in
      guard let self else { return }
      do {
        guard let skill = AgentSkill.load(directory: folder) else { throw AgentSkillManagerError.invalidSkill }
        try AgentSkillManager.install(MaiArchiveSkill(skill: skill), in: root)
        renderSkills()
        onSaved(.configuration)
      } catch { setLabel(status, error.localizedDescription) }
    }
  }

  private func renderHosts() {
    clear(hosts)
    let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
    action("Import Pairing Link", in: actions) { [weak self] in self?.pairHost() }
    action("Add Host Manually", in: actions) { [weak self] in self?.editHost(nil) }
    append(hosts, actions)
    do {
      for host in try launch.hostStore.hosts() {
        item(host.name, detail: host.url.host ?? host.cwd, in: hosts) { [weak self] in self?.editHost(host) }
      }
    } catch { setLabel(status, error.localizedDescription) }
  }

  private func editHost(_ host: ACPRemoteHost?) {
    let form = SettingsForm(parent: window, title: host == nil ? "Add Remote Host" : "Edit Remote Host")
    let name = form.entry("Name", text: host?.name)
    let url = form.entry("Endpoint URL", text: host?.url.absoluteString)
    let cwd = form.entry("Default working directory", text: host?.cwd)
    let backend = form.entry("Backend (acp or opencode)", text: (host?.backend ?? .acp).rawValue, editable: host == nil)
    let token = host == nil ? form.entry("Token", secret: true) : nil
    let access = host.map { form.toggle("Allow agents to use this host", active: $0.agentAccess == true) }
    if let host {
      form.extraAction("Forget Host…") { [weak self, weak form] in
        guard let self, let form else { return }
        let confirmation = SettingsForm(parent: form.window, title: "Forget " + host.name)
        confirmation.note("Remove this saved connection and its token from this computer?")
        confirmation.present(button: "Forget Host") { [weak form] in
          try self.launch.hostStore.remove(host)
          self.renderHosts()
          self.onSaved(.hosts)
          onGTK { [weak form] in form?.close() }
        }
      }
    }
    form.present { [self] in
      guard let endpoint = try settingURL(entryText(url)) else { throw AppError("Enter the host endpoint.") }
      let title = entryText(name)
      let directory = entryText(cwd)
      if let host, let access {
        try launch.hostStore.update(host, name: title, url: endpoint, cwd: directory,
          agentAccess: gtk_check_button_get_active(cast(access, GtkCheckButton.self)) != 0)
        onSaved(.hosts)
      } else {
        let secret = token.map(entryText) ?? ""
        let profile: RemoteHostConnection
        switch RemoteAgentBackend(rawValue: entryText(backend).lowercased()) {
        case .acp:
          profile = .init(try ACPRemoteConnection(name: title, url: endpoint, token: secret, cwd: directory))
        case .openCode:
          profile = .init(try OpenCodeConnection(name: title, url: endpoint, token: secret, cwd: directory))
        default: throw AppError("Enter acp or opencode as the backend.")
        }
        let paired = try launch.hostStore.pair(profile)
        onSaved(.paired(paired))
      }
      renderHosts()
    }
  }

  private func pairHost() {
    let form = SettingsForm(parent: window, title: "Import Remote Host")
    let invitation = form.entry("Pairing link", secret: true)
    let name = form.entry("Name override")
    form.presentAsync(button: "Pair", work: { [launch, remoteSetup] in
      try await remoteSetup.value
      return try await launch.pairHost(invitation: $0, name: $1)
    }, input: { (entryText(invitation), entryText(name)) }) { [weak self] host in
      self?.renderHosts()
      self?.onSaved(.paired(host))
    }
  }
}

final class SettingsForm: @unchecked Sendable {
  let window = gtk_window_new()!
  private let fields = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6)!
  private let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6)!
  private let save = gtk_button_new()!
  private let status = label("")
  private var task: Task<Void, Never>?
  private var closed = false

  init(parent: Widget, title: String, height: Int32 = 470) {
    let native = cast(window, GtkWindow.self)
    gtk_window_set_title(native, title)
    gtk_window_set_default_size(native, 500, height)
    gtk_window_set_transient_for(native, cast(parent, GtkWindow.self))
    gtk_window_set_modal(native, 1)
    gtk_window_set_destroy_with_parent(native, 1)
    let root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
    let scroll = gtk_scrolled_window_new()!
    gtk_widget_set_vexpand(scroll, 1)
    gtk_scrolled_window_set_policy(OpaquePointer(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), fields)
    margins(fields, 4)
    margins(root, 12)
    append(root, scroll)
    gtk_widget_add_css_class(status, "dim-label")
    append(root, status)
    append(root, actions)
    gtk_window_set_child(native, root)
    closeRequest(window, closeOnEscape: true) { [weak self] in self?.close() }
  }

  func note(_ text: String) { append(fields, label(text)) }

  func entry(_ title: String, text: String? = nil, editable: Bool = true, secret: Bool = false) -> Widget {
    note(title)
    let field = gtk_entry_new()!
    gtk_editable_set_text(OpaquePointer(field), text ?? "")
    gtk_editable_set_editable(OpaquePointer(field), editable ? 1 : 0)
    gtk_entry_set_visibility(cast(field, GtkEntry.self), secret ? 0 : 1)
    append(fields, field)
    return field
  }

  func editor(_ title: String, text: String?, height: Int32 = 150) -> Widget {
    note(title)
    let field = gtk_text_view_new()!
    gtk_text_view_set_wrap_mode(cast(field, GtkTextView.self), GTK_WRAP_WORD_CHAR)
    setEditorText(field, text ?? "")
    let scroll = gtk_scrolled_window_new()!
    gtk_scrolled_window_set_min_content_height(OpaquePointer(scroll), height)
    gtk_scrolled_window_set_child(OpaquePointer(scroll), field)
    gtk_widget_add_css_class(scroll, "card")
    append(fields, scroll)
    return field
  }

  func toggle(_ title: String, active: Bool) -> Widget {
    let button = gtk_check_button_new_with_label(title)!
    gtk_check_button_set_active(cast(button, GtkCheckButton.self), active ? 1 : 0)
    append(fields, button)
    return button
  }

  func extraAction(_ title: String, run: @escaping () -> Void) {
    let button = gtk_button_new_with_label(title)!
    signal(button, "clicked", run)
    append(actions, button)
  }

  private func show(button: String, destructive: Bool = false, run: @escaping () -> Void) {
    let spacer = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
    gtk_widget_set_hexpand(spacer, 1)
    append(actions, spacer)
    extraAction("Cancel") { [weak self] in self?.close() }
    gtk_button_set_label(cast(save, GtkButton.self), button)
    gtk_widget_add_css_class(save, destructive ? "destructive-action" : "suggested-action")
    signal(save, "clicked", run)
    append(actions, save)
    gtk_window_present(cast(window, GtkWindow.self))
  }

  func close() {
    guard !closed else { return }
    closed = true
    task?.cancel()
    gtk_window_destroy(cast(window, GtkWindow.self))
  }

  func present(button: String = "Save", destructive: Bool = false, work: @escaping () throws -> Void) {
    show(button: button, destructive: destructive) { [self] in
      do { try work(); close() }
      catch { setLabel(status, error.localizedDescription) }
    }
  }

  func presentAsync<Value: Sendable>(button: String,
    work: @escaping @Sendable (String, String) async throws -> Value,
    input: @escaping () -> (String, String), completed: @escaping @Sendable (Value) -> Void
  ) {
    show(button: button) { [self] in
      guard task == nil else { return }
      let (first, second) = input()
      gtk_widget_set_sensitive(save, 0)
      setLabel(status, "Waiting for pairing…")
      task = Task { [weak self] in
        let result: Result<Value, any Error>
        do { result = .success(try await work(first, second)) }
        catch { result = .failure(error) }
        onGTK { [weak self] in
          guard let self, !self.closed else { return }
          self.task = nil
          switch result {
          case .success(let value): completed(value); self.close()
          case .failure(let error):
            gtk_widget_set_sensitive(self.save, 1)
            setLabel(self.status, error.localizedDescription)
          }
        }
      }
    }
  }
}

func entryText(_ widget: Widget) -> String {
  let text = gtk_editable_get_text(OpaquePointer(widget)).map(String.init(cString:)) ?? ""
  return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func settingIdentifier(_ text: String) throws -> String {
  guard !text.isEmpty, !text.contains(where: \.isWhitespace), !text.contains("::"),
    !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  else { throw AppError("Enter an identifier without spaces, control characters, or '::'.") }
  return text
}

private func settingURL(_ text: String, schemes: Set<String>? = nil) throws -> URL? {
  guard !text.isEmpty else { return nil }
  guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), url.host?.isEmpty == false,
    schemes?.contains(scheme) != false
  else { throw AppError("Enter a valid endpoint URL, including its scheme and host.") }
  return url
}

private extension String {
  var nilIfEmpty: String? { isEmpty ? nil : self }
}
