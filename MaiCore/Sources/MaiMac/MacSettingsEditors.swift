import AppKit
import MaiCore
import SwiftUI

extension Binding where Value == String? {
  var orEmpty: Binding<String> {
    Binding<String>(get: { wrappedValue ?? "" }, set: { wrappedValue = $0.isEmpty ? nil : $0 })
  }
}

struct MacSettingsSheet<Content: View>: View {
  let title: String
  let save: () throws -> Void
  @ViewBuilder let content: Content
  @Environment(\.dismiss) private var dismiss
  @State private var error: String?

  var body: some View {
    VStack(spacing: 0) {
      Text(title).font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding(20)
      content
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled).padding(.horizontal, 20).padding(.top, 8) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Save") {
          do { try save(); dismiss() } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }.padding(20)
    }.frame(width: 640, height: 640)
  }
}

struct MacSettingsText: View {
  let title: String
  @Binding var text: String
  var height: CGFloat = 150

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.callout)
      TextEditor(text: $text).font(.system(.body, design: .monospaced))
        .frame(minHeight: height, maxHeight: height).accessibilityLabel(title)
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
    }
  }
}

struct MacKeyValue: Identifiable {
  let id = UUID()
  var key: String
  var value: String

  static func rows(_ dictionary: [String: String]) -> [Self] {
    dictionary.keys.sorted().map { .init(key: $0, value: dictionary[$0]!) }
  }

  static func dictionary(_ rows: [Self]) throws -> [String: String] {
    var result: [String: String] = [:]
    for row in rows where !row.key.isEmpty || !row.value.isEmpty {
      guard !row.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, result[row.key] == nil else {
        throw MaiConfigurationError.invalidFile("Each header or environment value needs a unique, nonempty name.")
      }
      result[row.key] = row.value
    }
    return result
  }
}

struct MacKeyValueEditor: View {
  let title: String
  @Binding var rows: [MacKeyValue]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.callout)
      ForEach($rows) { $row in
        HStack {
          TextField("Name", text: $row.key).accessibilityLabel(title + " name")
          TextField("Value", text: $row.value).accessibilityLabel(title + " value")
          Button("Remove", systemImage: "minus.circle") { rows.removeAll { $0.id == row.id } }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
      }
      Button("Add Entry", systemImage: "plus") { rows.append(.init(key: "", value: "")) }
        .buttonStyle(.borderless)
    }
  }
}

enum MacSettingsValues {
  static func json(_ options: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return (try? encoder.encode(options)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
  }
  static func options(_ text: String) throws -> [String: JSONValue] {
    do { return try JSONDecoder().decode([String: JSONValue].self, from: Data(text.utf8)) }
    catch { throw MaiConfigurationError.invalidFile("Options must be a JSON object.") }
  }
  static func timeout(_ text: String) throws -> Double? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    guard let value = Double(text), value.isFinite, value > 0 else { throw ConfiguredProviderValidationError.invalidTimeout }
    return value
  }
  static func url(_ text: String) throws -> URL? {
    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
    guard let url = URL(string: text), url.scheme != nil, url.host?.isEmpty == false else {
      throw MaiConfigurationError.invalidFile("Enter a complete endpoint URL, including its scheme and host.")
    }
    return url
  }
}

struct MacProviderEditor: View {
  let store: MacSettingsStore
  let originalID: String?
  @State private var draft: ConfiguredProvider
  @State private var url: String
  @State private var timeout: String
  @State private var options: String
  @State private var headers: [MacKeyValue]
  @State private var headerEnvironment: [MacKeyValue]

  init(store: MacSettingsStore, provider: ConfiguredProvider?) {
    self.store = store
    originalID = provider?.id
    let draft = provider ?? .init(id: "", kind: .openAI)
    _draft = State(initialValue: draft)
    _url = State(initialValue: draft.baseURL?.absoluteString ?? "")
    _timeout = State(initialValue: draft.timeout.map { String($0) } ?? "")
    _options = State(initialValue: MacSettingsValues.json(draft.options))
    _headers = State(initialValue: MacKeyValue.rows(draft.headers))
    _headerEnvironment = State(initialValue: MacKeyValue.rows(draft.headerEnvironment))
  }

  var body: some View {
    MacSettingsSheet(title: originalID == nil ? "Add Provider" : "Edit Provider", save: save) {
      Form {
        Section("Connection") {
          TextField("Identifier", text: $draft.id).disabled(originalID != nil)
          TextField("Display name", text: $draft.displayName.orEmpty)
          Picker("Type", selection: Binding(get: { draft.kind.rawValue }, set: { draft.kind = .init($0) })) {
            ForEach(Array(Set(["openai", "chatgpt", "systemone", "apple", "mlx", "acp", "hello", draft.kind.rawValue])).sorted(), id: \.self) {
              Text($0).tag($0)
            }
          }
          TextField("API endpoint (optional)", text: $url)
          TextField("Default model", text: $draft.defaultModel.orEmpty)
          if draft.kind == .chatGPT { Text("Uses the same saved ChatGPT sign-in as the CLI.").font(.caption).foregroundStyle(.secondary) }
        }
        Section("Authentication") {
          SecureField("API key", text: $draft.apiKey.orEmpty)
          TextField("API key environment variable", text: $draft.apiKeyEnvironment.orEmpty)
          TextField("API key file", text: $draft.apiKeyFile.orEmpty)
          Text("An available environment variable takes precedence, followed by the key file and API key. Finder-launched apps may have a different environment from your shell.")
            .font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Advanced") {
          TextField("Provider kind", text: Binding(get: { draft.kind.rawValue }, set: { draft.kind = .init($0) }))
          TextField("Timeout in seconds (optional)", text: $timeout)
          MacKeyValueEditor(title: "HTTP headers", rows: $headers)
          MacKeyValueEditor(title: "Header environment variables", rows: $headerEnvironment)
          MacSettingsText(title: "Provider options (JSON)", text: $options, height: 120)
        }
      }.formStyle(.grouped)
    }
  }

  private func save() throws {
    var value = draft
    value.baseURL = try MacSettingsValues.url(url)
    value.timeout = try MacSettingsValues.timeout(timeout)
    value.options = try MacSettingsValues.options(options)
    value.headers = try MacKeyValue.dictionary(headers)
    value.headerEnvironment = try MacKeyValue.dictionary(headerEnvironment)
    try store.saveProvider(value, replacing: originalID)
  }
}

struct MacMCPEditor: View {
  let store: MacSettingsStore
  let originalID: String?
  @State private var draft: ConfiguredMCPServer
  @State private var url: String
  @State private var timeout: String
  @State private var arguments: String
  @State private var options: String
  @State private var environment: [MacKeyValue]
  @State private var headers: [MacKeyValue]
  @State private var headerEnvironment: [MacKeyValue]

  init(store: MacSettingsStore, server: ConfiguredMCPServer?) {
    self.store = store
    originalID = server?.id
    let draft = server ?? .init(id: "")
    _draft = State(initialValue: draft)
    _url = State(initialValue: draft.url?.absoluteString ?? "")
    _timeout = State(initialValue: draft.timeout.map { String($0) } ?? "")
    _arguments = State(initialValue: draft.args.joined(separator: "\n"))
    _options = State(initialValue: MacSettingsValues.json(draft.options))
    _environment = State(initialValue: MacKeyValue.rows(draft.env))
    _headers = State(initialValue: MacKeyValue.rows(draft.headers))
    _headerEnvironment = State(initialValue: MacKeyValue.rows(draft.headerEnvironment))
  }

  var body: some View {
    MacSettingsSheet(title: originalID == nil ? "Add MCP Server" : "Edit MCP Server", save: save) {
      Form {
        Section("Server") {
          TextField("Identifier", text: $draft.id).disabled(originalID != nil)
          TextField("Display name", text: $draft.displayName.orEmpty)
          Toggle("Enabled", isOn: $draft.enabled)
          Picker("Transport", selection: $draft.kind) {
            Text("Streamable HTTP").tag("streamable-http")
            Text("Local command (stdio)").tag("stdio")
            if !["streamable-http", "stdio"].contains(draft.kind) { Text(draft.kind).tag(draft.kind) }
          }
          if draft.kind == "stdio" {
            TextField("Executable", text: $draft.command.orEmpty)
            MacSettingsText(title: "Arguments (one per line, without shell quoting)", text: $arguments, height: 80)
            TextField("Working directory", text: $draft.cwd.orEmpty)
            MacKeyValueEditor(title: "Environment variables", rows: $environment)
          } else {
            TextField("Endpoint URL", text: $url)
            SecureField("Bearer token", text: $draft.bearerToken.orEmpty)
            TextField("Token environment variable", text: $draft.bearerTokenEnvironment.orEmpty)
          }
        }
        Section("Tools") {
          TextField("Tool name prefix (optional)", text: $draft.toolNamePrefix.orEmpty)
          Picker("Default approval", selection: $draft.defaultApproval) {
            Text("Ask").tag(ToolApprovalRequirement.confirm)
            Text("Automatic").tag(ToolApprovalRequirement.automatic)
            Text("Dangerous").tag(ToolApprovalRequirement.dangerous)
          }
          Text("The conversation’s approval policy still applies.").font(.caption).foregroundStyle(.secondary)
        }
        DisclosureGroup("Advanced") {
          TextField("Timeout in seconds (optional)", text: $timeout)
          MacKeyValueEditor(title: "HTTP headers", rows: $headers)
          MacKeyValueEditor(title: "Header environment variables", rows: $headerEnvironment)
          MacSettingsText(title: "MCP options (JSON)", text: $options, height: 120)
        }
      }.formStyle(.grouped)
    }
  }

  private func save() throws {
    var value = draft
    value.url = try MacSettingsValues.url(url)
    value.timeout = try MacSettingsValues.timeout(timeout)
    if arguments != value.args.joined(separator: "\n") {
      value.args = arguments.isEmpty ? [] : arguments.components(separatedBy: "\n")
    }
    value.env = try MacKeyValue.dictionary(environment)
    value.headers = try MacKeyValue.dictionary(headers)
    value.headerEnvironment = try MacKeyValue.dictionary(headerEnvironment)
    value.options = try MacSettingsValues.options(options)
    try store.saveMCP(value, replacing: originalID)
  }
}

struct MacPromptEditor: View {
  let store: MacSettingsStore
  let entry: PromptCatalog.Entry?
  @State private var name: String
  @State private var text: String
  @State private var system: Bool

  init(store: MacSettingsStore, entry: PromptCatalog.Entry?) {
    self.store = store
    self.entry = entry
    _name = State(initialValue: entry?.name ?? "")
    _text = State(initialValue: entry?.text ?? "")
    _system = State(initialValue: entry?.kind == .system)
  }

  var body: some View {
    MacSettingsSheet(title: entry == nil ? "Add Prompt" : "Edit Prompt", save: {
      try store.savePrompt(name: name, text: text, system: system, creating: entry == nil)
    }) {
      Form {
        TextField("Name", text: $name).disabled(entry != nil)
        Picker("Kind", selection: $system) {
          Text("User prompt").tag(false)
          Text("System prompt").tag(true)
        }.disabled(entry != nil)
        if system {
          Text("System prompts provide agent instructions. Editing one also updates agents that use it.")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          Text("Use /\(PromptSlashCommand.commandName(for: name)) or $\(PromptSlashCommand.commandName(for: name)) in chat. $ARGUMENTS is replaced with the words after its name.")
            .font(.caption).foregroundStyle(.secondary)
        }
        MacSettingsText(title: "Instructions", text: $text, height: 280)
      }.formStyle(.grouped)
    }
  }
}

struct MacSkillEditor: View {
  let store: MacSettingsStore
  let skill: AgentSkill?
  @State private var name: String
  @State private var description: String
  @State private var prompt: String

  init(store: MacSettingsStore, skill: AgentSkill?) {
    self.store = store
    self.skill = skill
    _name = State(initialValue: skill?.name ?? "")
    _description = State(initialValue: skill?.description ?? "")
    _prompt = State(initialValue: skill?.body ?? "")
  }

  var body: some View {
    MacSettingsSheet(title: skill == nil ? "Create Skill" : "Edit Skill", save: {
      try store.saveSkill(skill, name: name, description: description, prompt: prompt)
    }) {
      Form {
        TextField("Name", text: $name).disabled(skill != nil)
        TextField("When to use this skill", text: $description, axis: .vertical).lineLimit(2...4)
        MacSettingsText(title: "Instructions", text: $prompt, height: 280)
        if let skill {
          Text(skill.fileURL.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
          Text("Supporting files and additional front matter are preserved.").font(.caption).foregroundStyle(.secondary)
        }
      }.formStyle(.grouped)
    }
  }
}
