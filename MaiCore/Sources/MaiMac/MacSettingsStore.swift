import AppKit
import MaiCore
import MaiACP
import Observation

struct MacSettingsScope: Identifiable, Hashable {
  let name: String
  let url: URL
  let cwd: String?
  var id: String { url.path }
}

@MainActor @Observable
final class MacSettingsStore {
  var scopes: [MacSettingsScope] = []
  var scopeID = ""
  var document: ConfigurationDocument?
  var skills: [AgentSkill] = []
  var error: String?
  var notice: String?
  let home: AgentHome

  init(home: AgentHome) { self.home = home }

  var scope: MacSettingsScope? { scopes.first { $0.id == scopeID } }
  var configuration: MaiConfiguration { document?.configuration ?? .init() }
  var globalURL: URL { URL(fileURLWithPath: AgentHome.expandUserPath("~/.config/pmai/config.json")) }
  var isNewWorkspace: Bool {
    scope?.cwd != nil && scope.map { !FileManager.default.fileExists(atPath: $0.url.path) } == true
  }

  func prepare(cwd: String?) {
    do {
      var paths = try home.loadProjectIndex().projects.compactMap(\.workingDirectory)
      if let cwd, !cwd.isEmpty { paths.append(cwd) }
      scopes = [.init(name: "Global", url: globalURL, cwd: nil)] + Set(paths).sorted().map {
        .init(name: URL(fileURLWithPath: $0).lastPathComponent, url: URL(fileURLWithPath: $0).appendingPathComponent("pmai.json"), cwd: $0)
      }
      if !scopes.contains(where: { $0.id == scopeID }) {
        let local = cwd.map { URL(fileURLWithPath: $0).appendingPathComponent("pmai.json") }
        let boxed = try cwd.map { try ProjectBoxes(home: home).find(at: URL(fileURLWithPath: $0))?.enabled == true } ?? false
        scopeID = local.flatMap { boxed || FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil } ?? globalURL.path
      }
      reload()
    } catch { self.error = error.localizedDescription }
  }

  func reload() {
    error = nil
    notice = nil
    document = nil
    skills = []
    guard let scope else { return }
    do {
      if let cwd = scope.cwd, try ProjectBoxes(home: home).find(at: URL(fileURLWithPath: cwd))?.enabled == true {
        throw MaiConfigurationError.invalidFile("This project's settings are inside its box. Use Project Box → Configure in Terminal to edit providers, MCP servers and skills there. Global settings do not configure boxed workers.")
      }
      let initial: Data
      if scope.cwd != nil, !FileManager.default.fileExists(atPath: scope.url.path),
        FileManager.default.fileExists(atPath: globalURL.path) {
        initial = try Data(contentsOf: globalURL)
      } else {
        initial = try MaiConfiguration(toolSources: [.init(id: "standard-tools", kind: "standard-tools")], fileAccess: .init()).encoded()
      }
      document = try ConfigurationDocument(url: scope.url, initialData: initial)
      try reloadSkills()
    } catch { self.error = error.localizedDescription }
  }

  func save(_ edit: (inout MaiConfiguration) throws -> Void) throws {
    guard var document else { throw MaiConfigurationError.invalidFile("Reload a valid configuration before editing.") }
    var updated = document.configuration
    try edit(&updated)
    try document.save(updated)
    self.document = document
    notice = "Saved. New local conversations use these settings; open conversations keep their current runtime."
  }

  func saveProvider(_ provider: ConfiguredProvider, replacing id: String?) throws {
    try Self.identifier(provider.id)
    try Self.identifier(provider.kind.rawValue)
    try provider.validate()
    try save { configuration in
      if let id, let index = configuration.providers.firstIndex(where: { $0.id == id }) {
        configuration.providers[index] = provider
      } else {
        guard !configuration.providers.contains(where: { $0.id == provider.id }) else {
          throw MaiConfigurationError.duplicateIdentifier(kind: "provider", id: provider.id)
        }
        configuration.providers.append(provider)
      }
    }
  }

  func saveMCP(_ server: ConfiguredMCPServer, replacing id: String?) throws {
    try Self.identifier(server.id)
    if let timeout = server.timeout, !timeout.isFinite || timeout <= 0 { throw ConfiguredProviderValidationError.invalidTimeout }
    if server.kind == "stdio" {
      guard server.command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw MaiConfigurationError.mcpServerMissingCommand(server.id)
      }
    } else if server.kind == "streamable-http" {
      guard let url = server.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else {
        throw MaiConfigurationError.invalidFile("Enter an HTTP or HTTPS MCP endpoint.")
      }
    }
    try save { configuration in
      if let id, let index = configuration.mcpServers.firstIndex(where: { $0.id == id }) {
        configuration.mcpServers[index] = server
      } else {
        guard !configuration.mcpServers.contains(where: { $0.id == server.id }) else {
          throw MaiConfigurationError.duplicateIdentifier(kind: "MCP server", id: server.id)
        }
        configuration.mcpServers.append(server)
      }
    }
  }

  func savePrompt(name: String, text: String, system: Bool, creating: Bool) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MaiConfigurationError.invalidFile("Enter a prompt name and instructions.")
    }
    try save { configuration in
      let names = system ? Array(configuration.prompts?.system.keys ?? [:].keys) : Array(configuration.prompts?.user.keys ?? [:].keys)
      if creating, names.contains(where: {
        PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: $0)) == PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: name))
      }) { throw MaiConfigurationError.invalidFile("A prompt with this command name already exists.") }
      if system { configuration.setSystemPrompt(name, text: text) }
      else { configuration.setUserPrompt(name, text: text) }
    }
  }

  func removePrompt(_ entry: PromptCatalog.Entry) throws {
    try save { configuration in
      if entry.kind == .system {
        let users = configuration.agentsUsingSystemPrompt(entry.name)
        guard users.isEmpty else { throw MaiConfigurationError.invalidFile("This prompt is used by agents: " + users.joined(separator: ", ")) }
        _ = configuration.removeSystemPrompt(entry.name)
      } else { _ = configuration.removeUserPrompt(entry.name) }
    }
  }

  func skillsRoot(create: Bool = false) throws -> URL {
    guard let cwd = scope?.cwd else { return home.skillsDirectoryURL }
    let folder = URL(fileURLWithPath: cwd)
    if let project = try home.loadProject(atWorkingDirectory: folder) { return home.skillsURL(for: project) }
    if create { return home.skillsURL(for: try home.openProject(atWorkingDirectory: folder)) }
    throw MaiConfigurationError.invalidFile("Open this folder as a workspace before managing its skills.")
  }

  func reloadSkills() throws {
    skills = AgentSkillCatalog.load(directory: try skillsRoot()).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  func saveSkill(_ skill: AgentSkill?, name: String, description: String, prompt: String) throws {
    if let skill {
      guard let current = AgentSkill.load(directory: skill.directoryURL, rootURL: skill.rootURL),
        current.body == skill.body, current.description == skill.description else {
        throw MaiConfigurationError.invalidFile("This skill changed in another app. Reload Settings before editing it again.")
      }
      _ = try AgentSkillManager.update(skill, description: description, prompt: prompt)
    }
    else { _ = try AgentSkillManager.create(name: name, description: description, prompt: prompt, in: skillsRoot(create: true)) }
    try reloadSkills()
    notice = "Skill saved. New conversations load the updated skill."
  }

  func importSkill() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = true
    panel.prompt = "Import Skill"
    panel.message = "Choose a skill folder or its SKILL.md file. Supporting files are copied with it."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    perform {
      let folder = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
      guard let skill = AgentSkill.load(directory: folder) else { throw AgentSkillManagerError.invalidSkill }
      _ = try AgentSkillManager.install(MaiArchiveSkill(skill: skill), in: skillsRoot(create: true))
      try reloadSkills()
      notice = "Skill imported. New conversations can use it."
    }
  }

  func perform(_ action: () throws -> Void) {
    do { try action(); error = nil } catch { self.error = error.localizedDescription }
  }

  static func identifier(_ value: String) throws {
    guard !value.isEmpty, !value.contains(where: \.isWhitespace), !value.contains("::"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw MaiConfigurationError.invalidFile("Enter an identifier without spaces, control characters, or '::'.")
    }
  }
}
