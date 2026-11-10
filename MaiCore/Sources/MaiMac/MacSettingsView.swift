import AppKit
import MaiACP
import MaiCore
import SwiftUI

private enum MacSettingsEditor: Identifiable {
  case provider(ConfiguredProvider?), mcp(ConfiguredMCPServer?), prompt(PromptCatalog.Entry?), skill(AgentSkill?)
  case host(ACPRemoteHost), connection
  var id: String {
    switch self {
    case .provider(let value): "provider:" + (value?.id ?? "new")
    case .mcp(let value): "mcp:" + (value?.id ?? "new")
    case .prompt(let value): "prompt:" + (value?.id ?? "new")
    case .skill(let value): "skill:" + (value?.id ?? "new")
    case .host(let value): "host:" + value.id.uuidString
    case .connection: "connection"
    }
  }
}

private struct MacSettingsRemoval {
  let title: String
  let message: String
  let action: () -> Void
}

struct MacSettingsView: View {
  @Bindable var workspace: MacWorkspace
  @State private var store: MacSettingsStore
  @AppStorage("mac.settings.pane") private var pane = "general"
  @State private var editor: MacSettingsEditor?
  @State private var removal: MacSettingsRemoval?
  private var appearance = MacAppearance()

  init(workspace: MacWorkspace) {
    self.workspace = workspace
    _store = State(initialValue: MacSettingsStore(home: workspace.home))
  }

  var body: some View {
    VStack(spacing: 0) {
      TabView(selection: $pane) {
        general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
        hosts.tabItem { Label("Hosts", systemImage: "network") }.tag("hosts")
        providers.tabItem { Label("Providers", systemImage: "cpu") }.tag("providers")
        mcps.tabItem { Label("MCP Servers", systemImage: "puzzlepiece.extension") }.tag("mcps")
        prompts.tabItem { Label("Prompts", systemImage: "text.bubble") }.tag("prompts")
        skills.tabItem { Label("Skills", systemImage: "sparkles") }.tag("skills")
      }
      if let error = store.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
          Text(error).textSelection(.enabled)
          Spacer()
          Button("Dismiss") { store.error = nil }
        }.font(.callout).padding()
      }
    }
    .frame(width: 760, height: 620)
    .task {
      store.prepare(cwd: workspace.hostID == nil ? workspace.cwd : nil)
      do { workspace.hosts = try workspace.hostStore.hosts() }
      catch { store.error = error.localizedDescription }
    }
    .sheet(item: $editor) { selection in
      switch selection {
      case .provider(let value): MacProviderEditor(store: store, provider: value)
      case .mcp(let value): MacMCPEditor(store: store, server: value)
      case .prompt(let value): MacPromptEditor(store: store, entry: value)
      case .skill(let value): MacSkillEditor(store: store, skill: value)
      case .host(let value): MacHostEditor(workspace: workspace, host: value)
      case .connection: MacConnectionSheet(workspace: workspace)
      }
    }
    .alert(removal?.title ?? "Remove Item", isPresented: Binding(
      get: { removal != nil }, set: { if !$0 { removal = nil } }
    )) {
      if let removal { Button("Remove", role: .destructive, action: removal.action) }
      Button("Cancel", role: .cancel) {}
    } message: { Text(removal?.message ?? "") }
  }

  private var general: some View {
    Form {
      Section("Appearance") {
        ColorPicker("Accent color", selection: appearance.accentBinding, supportsOpacity: false)
        Button("Use System Accent") { appearance.accentHex = "" }
          .disabled(appearance.accentHex.isEmpty)
        Text("Colors controls, your messages, bold text, and quotes. Pinch the trackpad over a conversation to resize its text.")
          .foregroundStyle(.secondary)
      }
      Section("Chat Fonts") {
        MacChatFontSettings()
      }
      Section("pmai for Mac") {
        Text("Settings share the CLI’s configuration, saved hosts, and skills. Global settings apply unless a workspace has its own pmai.json.")
        LabeledContent("Data", value: workspace.home.rootURL.path)
        Button("Show pmai Data in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: workspace.home.rootURL.path) }
      }
      Section("Configuration") {
        Text("Providers, MCP servers, and prompts can be edited globally or for a local workspace. Creating workspace settings copies the current global configuration; later global changes do not override that workspace.")
        Text("Connection settings for remote hosts are saved on this Mac. Providers, prompts, and skills on a remote server are managed on that server.")
          .foregroundStyle(.secondary)
        Button("Open Global Configuration") { NSWorkspace.shared.open(store.globalURL) }
      }
      Section("Keyboard") {
        LabeledContent("New chat", value: "⌘N")
        LabeledContent("New tab", value: "⌘T")
        LabeledContent("Reopen closed tab", value: "⇧⌘T")
        LabeledContent("Close tab or window", value: "⌘W")
        LabeledContent("Open workspace", value: "⇧⌘O")
        LabeledContent("Toggle left sidebar", value: "⌘S")
        LabeledContent("Toggle conversation options", value: "⌘O")
        LabeledContent("Send message", value: "Return")
        LabeledContent("New line", value: "Shift-Return")
        LabeledContent("Complete prompt or skill", value: "/ or $, then Tab / Shift-Tab")
        LabeledContent("Resize chat text", value: "Pinch or ⌘+ / ⌘−; ⌘0 to reset")
        LabeledContent("Stop response", value: "⌘.")
      }
    }.formStyle(.grouped)
  }

  private var hosts: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Saved Hosts").font(.headline)
        Spacer()
        Button("Connect Host…", systemImage: "plus") { editor = .connection }.disabled(workspace.busy)
      }.padding()
      Form {
        if workspace.hosts.isEmpty { Text("Add a pairing link or connection profile from a pmai or OpenCode host.").foregroundStyle(.secondary) }
        ForEach(workspace.hosts) { host in
          MacSettingsRow(title: host.name, detail: host.url.absoluteString, symbol: "network") {
            Button("Connect") { workspace.selectHost(host.id) }.disabled(workspace.busy)
            Button("Edit…") { editor = .host(host) }.disabled(workspace.busy)
            removeButton {
              removal = .init(title: "Remove \(host.name)?", message: "This disconnects its open chats and removes the saved connection and credentials from this Mac. Remote chats and files are kept.") {
                workspace.removeHost(host) { store.error = $0 }
              }
            }.disabled(workspace.busy)
          }
        }
      }.formStyle(.grouped)
    }
  }

  private var providers: some View {
    MacSettingsPane(store: store, title: "Providers", addTitle: "Add Provider…", add: { editor = .provider(nil) }) {
      if store.configuration.providers.isEmpty { Text("Add the providers you want to use in local conversations.").foregroundStyle(.secondary) }
      ForEach(store.configuration.providers) { provider in
        MacSettingsRow(title: provider.displayName ?? provider.id,
          detail: [provider.id, provider.kind.rawValue, provider.defaultModel].compactMap { $0 }.joined(separator: " · "), symbol: "cpu") {
          Button("Edit…") { editor = .provider(provider) }
          removeButton {
            removal = .init(title: "Remove \(provider.id)?", message: "Remove this provider from the selected configuration. Providers still used by configured agents must be reassigned before removal.") {
              store.perform { try store.save { try $0.removeProvider(provider.id) } }
            }
          }
        }
      }
    }
  }

  private var mcps: some View {
    MacSettingsPane(store: store, title: "MCP Servers", addTitle: "Add MCP Server…", add: { editor = .mcp(nil) }) {
      if store.configuration.mcpServers.isEmpty { Text("Connect tools from a local command or Streamable HTTP server.").foregroundStyle(.secondary) }
      ForEach(store.configuration.mcpServers) { server in
        MacSettingsRow(title: server.displayName ?? server.id,
          detail: server.kind == "stdio" ? server.command ?? "Local command" : server.url?.absoluteString ?? server.kind,
          symbol: "puzzlepiece.extension") {
          Toggle("Enabled", isOn: Binding(get: { server.enabled }, set: { enabled in
            store.perform { var value = server; value.enabled = enabled; try store.saveMCP(value, replacing: server.id) }
          })).labelsHidden().help("Enable \(server.id)")
          Button("Edit…") { editor = .mcp(server) }
          removeButton {
            removal = .init(title: "Remove \(server.id)?", message: "Remove this MCP server from the selected configuration.") {
              store.perform { try store.save { $0.mcpServers.removeAll { $0.id == server.id } } }
            }
          }
        }
      }
    }
  }

  private var prompts: some View {
    MacSettingsPane(store: store, title: "Prompts", addTitle: "Add Prompt…", add: { editor = .prompt(nil) }) {
      ForEach([PromptCatalog.Kind.user, .system, .builtin], id: \.self) { kind in
        Section(kind == .user ? "User Prompts" : kind == .system ? "System Prompts" : "Built-in Prompts") {
          ForEach(store.configuration.promptCatalog().entries(of: kind).filter {
            kind != .builtin || store.configuration.userPromptName(matching: $0.name) == nil
          }) { entry in
            let custom = kind == .system ? store.configuration.prompts?.system[entry.name] != nil
              : store.configuration.prompts?.user[entry.name] != nil
            MacSettingsRow(title: entry.name, detail: entry.summary, symbol: "text.bubble") {
              Button(custom ? "Edit…" : "Customize…") { editor = .prompt(entry) }
              if custom && kind != .builtin {
                removeButton {
                  removal = .init(title: "Remove \(entry.name)?", message: "Remove the custom prompt. Any built-in prompt of the same name becomes available again.") {
                    store.perform { try store.removePrompt(entry) }
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  private var skills: some View {
    MacSettingsPane(store: store, title: "Skills", addTitle: "Create Skill…", add: { editor = .skill(nil) }) {
      Section {
        HStack {
          Button("Import Skill…", systemImage: "square.and.arrow.down", action: store.importSkill)
          Spacer()
          Button("Show Skills Folder") {
            store.perform {
              let url = try store.skillsRoot(create: true)
              try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
              NSWorkspace.shared.open(url)
            }
          }
        }
        Text("Workspace skills override global skills with the same name. Editing a skill keeps its scripts and reference files.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if store.skills.isEmpty { Text("No skills in this scope. Create one or import an existing skill folder.").foregroundStyle(.secondary) }
      ForEach(store.skills) { skill in
        MacSettingsRow(title: skill.name, detail: skill.description, symbol: "sparkles") {
          Button("Edit…") { editor = .skill(skill) }
          removeButton {
            removal = .init(title: "Remove \(skill.name)?", message: "Delete this skill folder, including its supporting files: \(skill.directoryURL.path)") {
              store.perform { try AgentSkillManager.remove(skill); try store.reloadSkills() }
            }
          }
        }
      }
    }
  }

  private func removeButton(_ action: @escaping () -> Void) -> some View {
    Button("Remove", systemImage: "trash", action: action).labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove…")
  }
}

private struct MacSettingsPane<Content: View>: View {
  @Bindable var store: MacSettingsStore
  let title: String
  let addTitle: String
  let add: () -> Void
  @ViewBuilder let content: Content

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Picker("Edit settings for", selection: Binding(get: { store.scopeID }, set: { store.scopeID = $0; store.reload() })) {
            ForEach(store.scopes) { scope in Text(scope.cwd == nil ? scope.name : "Workspace: " + scope.name).tag(scope.id).help(scope.url.path) }
          }.frame(maxWidth: 380)
          Spacer()
          Button("Reload", systemImage: "arrow.clockwise", action: store.reload).labelStyle(.iconOnly).help("Reload settings from disk")
        }
        Text(store.scope?.url.path ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        if store.isNewWorkspace {
          Text("Saving creates workspace settings from the current global configuration.").font(.caption).foregroundStyle(.secondary)
        }
        HStack {
          Text(title).font(.headline)
          Spacer()
          Button(addTitle, systemImage: "plus", action: add).disabled(store.document == nil)
        }.padding(.top, 8)
      }.padding()
      Form { content }.formStyle(.grouped).disabled(store.document == nil)
      if let notice = store.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding() }
    }
  }
}

private struct MacSettingsRow<Actions: View>: View {
  let title: String
  let detail: String
  let symbol: String
  @ViewBuilder let actions: Actions

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body.weight(.medium))
        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
      actions
    }.padding(.vertical, 4)
  }
}

private struct MacHostEditor: View {
  let workspace: MacWorkspace
  let host: ACPRemoteHost
  @State private var name: String
  @State private var url: String
  @State private var cwd: String
  @State private var agentAccess: Bool

  init(workspace: MacWorkspace, host: ACPRemoteHost) {
    self.workspace = workspace
    self.host = host
    _name = State(initialValue: host.name)
    _url = State(initialValue: host.url.absoluteString)
    _cwd = State(initialValue: host.cwd)
    _agentAccess = State(initialValue: host.agentAccess == true)
  }

  var body: some View {
    MacSettingsSheet(title: "Edit Host", save: {
      guard let endpoint = try MacSettingsValues.url(url) else { throw JSONRPCError.invalidParams("Enter the host endpoint") }
      try workspace.hostStore.update(host, name: name, url: endpoint, cwd: cwd, agentAccess: agentAccess)
      workspace.hosts = try workspace.hostStore.hosts()
      for chat in workspace.conversations where chat.hostID == host.id { chat.hostName = name }
    }) {
      Form {
        TextField("Name", text: $name)
        LabeledContent("Backend", value: (host.backend ?? .acp).rawValue)
        TextField("Endpoint", text: $url)
        TextField("Default working directory", text: $cwd)
        Toggle("Allow agents to use this host", isOn: $agentAccess)
        Text("Connection changes apply to new connections. Credentials are retained; use Connect Host to import a new pairing profile when credentials change.")
          .font(.caption).foregroundStyle(.secondary)
      }.formStyle(.grouped)
    }
  }
}
