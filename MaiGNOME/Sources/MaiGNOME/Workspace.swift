import Foundation
import MaiACP
import MaiCore
import MaiDocuments

struct LaunchOptions: Sendable {
  let home: AgentHome
  let directory: URL
  let explicitDirectory: Bool
  let statePath: URL?
  let environment: [String: String]
  let explicitHome: Bool

  static let usage = "Usage: pmai-gnome [--home DIR] [--state DIR] [--cd DIR]"

  init(_ arguments: [String]) throws {
    var environment = ProcessInfo.processInfo.environment
    var path = FileManager.default.currentDirectoryPath
    var state = environment.removeValue(forKey: "PMAI_STATE")
    var homePath: String?
    var explicitDirectory = false
    var arguments = arguments[...]
    while let flag = arguments.popFirst() {
      guard ["--home", "--state", "--cd"].contains(flag), let value = arguments.popFirst() else {
        throw AppError("Invalid argument: \(flag)\n\(Self.usage)")
      }
      switch flag {
      case "--home": homePath = value
      case "--state": state = value
      default:
        path = value
        explicitDirectory = true
      }
    }
    let directory = URL(fileURLWithPath: AgentHome.expandUserPath(path), isDirectory: true)
      .resolvingSymlinksInPath().standardizedFileURL
    if let homePath {
      environment[AgentHome.environmentVariable] = homePath
    }
    let home = AgentHome.resolve(environment: environment)
    if let configuredHome = environment[AgentHome.environmentVariable],
      !configuredHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      environment[AgentHome.environmentVariable] = home.rootURL.path
    }
    self.directory = directory
    self.explicitDirectory = explicitDirectory
    self.home = home
    self.explicitHome = homePath != nil
    self.statePath = state.map {
      URL(fileURLWithPath: AgentHome.expandUserPath($0), isDirectory: true, relativeTo: directory).standardizedFileURL
    }
    self.environment = environment
  }

  var workspace: AgentHomeACPWorkspace {
    AgentHomeACPWorkspace(home: home, stateOverride: statePath.map {
      (directory.path, AgentChatStore(directoryURL: $0))
    })
  }

  var hostStore: ACPRemoteHostStore {
    .init(directory: home.rootURL.appendingPathComponent("remotes", isDirectory: true))
  }

  func snapshot(for host: ACPRemoteHost?) async throws -> ACPWorkspaceSnapshot {
    guard let host else { return try await workspace.snapshot() }
    let client = try hostStore.connection(for: host).makeSession()
    do {
      let snapshot = try await client.workspace() ?? .init()
      await client.disconnect()
      return snapshot
    } catch {
      await client.disconnect()
      throw error
    }
  }

  func settingsDocument(cwd: String?) throws -> ConfigurationDocument {
    let global = home.configurationFileURL(environment: environment)
    let directory = cwd.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? self.directory
    let url: URL
    if let explicit = environment["PMAI_CONFIG"], !explicit.isEmpty {
      url = URL(fileURLWithPath: AgentHome.expandUserPath(explicit, environment: environment),
        relativeTo: directory).standardizedFileURL
    } else if cwd != nil {
      let project = directory.appendingPathComponent("pmai.json")
      url = FileManager.default.fileExists(atPath: project.path) ? project : global
    } else {
      url = global
    }
    let initial = try MaiConfiguration(toolSources: [.init(id: "standard-tools", kind: "standard-tools")],
      fileAccess: .init()).encoded()
    return try ConfigurationDocument(url: url, initialData: initial)
  }

  func localPrompts(cwd: String) throws -> PromptCatalog {
    let directory = URL(fileURLWithPath: cwd, isDirectory: true)
    let project = try home.loadProject(atWorkingDirectory: directory)
    let localSkills = project.map { home.skillsURL(for: $0) }
      ?? directory.appendingPathComponent(".pmai/skills", isDirectory: true)
    let skills = AgentSkillCatalog.load(directories: [localSkills, home.skillsDirectoryURL]).skills
    return try settingsDocument(cwd: cwd).configuration.promptCatalog(skills: skills)
  }

  func pairHost(invitation: String, name: String) async throws -> ACPRemoteHost {
    var profile: RemoteHostConnection
    if let link = try? OpenCodePairingLink.parse(invitation) {
      profile = .init(try await link.redeem())
    } else {
      let parsed = try ACPRemoteConnection.parse(invitation)
      profile = .init(parsed)
      if parsed.requiresApproval == true {
        let client = ACPClient(configuration: .init(command: parsed.name, permission: .reject,
          remoteWorkingDirectory: parsed.cwd, readClientFiles: false, webSocketURL: parsed.url,
          bearerToken: parsed.token, forwirohInvitation: parsed.forwirohInvitation))
        profile.token = try await client.requestPairing(clientID: UUID().uuidString, name: "PocketMai for GNOME")
        profile.requiresApproval = false
      }
    }
    try Task.checkCancellation()
    return try hostStore.pair(profile, name: name.isEmpty ? nil : name)
  }

  func arguments(cwd: String, session: String?) -> [String] {
    var arguments: [String] = []
    if let session { arguments += ["--resume", session] }
    if explicitHome { arguments += ["--home", home.rootURL.path] }
    if cwd == directory.path, let statePath { arguments += ["--state", statePath.path] }
    return arguments
  }

  func worker(cwd: String, session: String?) throws -> ACPClient.Configuration {
    let directory = URL(fileURLWithPath: cwd, isDirectory: true)
    var configuration = ACPClient.Configuration(
      command: "pmai", arguments: ["--acp"] + arguments(cwd: cwd, session: session),
      environment: environment, workingDirectory: directory,
      permission: .reject, readClientFiles: false, sessionID: session)
    try configuration.restrictProjectBoxAccess()
    if configuration.command == "pmai" { configuration.command = try pmaiExecutable() }
    return configuration
  }

  func openInTerminal(cwd: String, session: String) throws {
    let executable = try pmaiExecutable()
    let candidates = [
      ("xdg-terminal-exec", "--dir="),
      ("kgx", "--working-directory="),
      ("gnome-terminal", "--working-directory="),
    ]
    for (program, directoryFlag) in candidates {
      guard let launcher = findExecutable(program) else { continue }
      let process = Process()
      process.executableURL = URL(fileURLWithPath: launcher)
      process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
      process.environment = environment
      var arguments = arguments(cwd: cwd, session: session)
      if !explicitHome { arguments += ["--home", home.rootURL.path] }
      process.arguments = [directoryFlag + cwd, "--", executable] + arguments + ["--cd", cwd]
      try process.run()
      return
    }
    throw AppError("Install a terminal that supports xdg-terminal-exec, GNOME Console, or GNOME Terminal.")
  }

  private func pmaiExecutable() throws -> String {
    if let override = environment["PMAI_EXECUTABLE"], !override.isEmpty {
      let path = URL(fileURLWithPath: AgentHome.expandUserPath(override, environment: environment)).path
      guard FileManager.default.isExecutableFile(atPath: path) else {
        throw AppError("PMAI_EXECUTABLE does not point to an executable file.")
      }
      return path
    }
    if let binary = Bundle.main.executableURL {
      let sibling = binary.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("pmai")
      if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling.path }
    }
    guard let path = findExecutable("pmai") else {
      throw AppError("Install the pmai CLI or set PMAI_EXECUTABLE to its path.")
    }
    return path
  }

  private func findExecutable(_ name: String) -> String? {
    let fallback = AgentHome.userHomeDirectory(environment: environment).appendingPathComponent(".local/bin").path
    let directories = (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init) + [fallback]
    return directories.lazy.map { $0 + "/" + name }
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

struct AppError: LocalizedError, Sendable {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

struct Attachment: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let content: ContentPart

  static func load(_ url: URL, mimeType: String?) async throws -> Self {
    let name = url.lastPathComponent
    let data = try DocumentAttachmentImporter.data(at: url)
    if DocumentAttachmentImporter.kind(for: data, filename: name, mimeType: mimeType) == .image {
      guard data.count <= 10 * 1024 * 1024 else { throw AppError("Image attachments are limited to 10 MB.") }
      guard let mimeType, mimeType.hasPrefix("image/") else { throw AppError("Unrecognized image type.") }
      let content = try await ImageAttachmentImporter.content(
        data: data, mimeType: mimeType, filename: name, mode: .full)
      return .init(name: name, content: content)
    }
    let document = try DocumentAttachmentImporter.attachment(data: data, filename: name)
    return .init(name: document.name, content: document.content)
  }
}
