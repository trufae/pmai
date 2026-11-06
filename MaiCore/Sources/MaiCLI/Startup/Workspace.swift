import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

extension MaiCLI {
  /// Where pmai kept chats and history before projects existed.
  private static let legacyStateDirectory = "~/.config/pmai"

  static func resolvedHome(options: CLIOptions, environment: [String: String])
    -> AgentHome
  {
    if let path = options.homePath {
      return AgentHome(
        rootURL: URL(
          fileURLWithPath: AgentHome.expandUserPath(path, environment: environment),
          isDirectory: true))
    }
    return AgentHome.resolve(environment: environment)
  }

  /// Pre-project state is adopted only into the default home: a relocated
  /// home is a deliberate fresh setup, and scratch runs must not touch the
  /// files under the real home directory.
  private static func usesDefaultHome(options: CLIOptions, environment: [String: String])
    -> Bool
  {
    options.homePath == nil
      && (environment[AgentHome.environmentVariable] ?? "").trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty
  }

  static func resolvedChatStore(
    options: CLIOptions,
    home: AgentHome,
    project: AgentProject,
    environment: [String: String]
  ) -> AgentChatStore {
    if let path = options.statePath {
      return AgentChatStore(
        directoryURL: URL(
          fileURLWithPath: AgentHome.expandUserPath(path, environment: environment),
          isDirectory: true))
    }
    return home.chatStore(for: project)
  }

  /// The shared input history, copied once from its pre-project location.
  static func resolvedHistoryURL(
    options: CLIOptions,
    home: AgentHome,
    environment: [String: String]
  ) -> URL {
    if let path = options.historyPath {
      return URL(fileURLWithPath: AgentHome.expandUserPath(path, environment: environment))
    }
    let url = home.historyURL
    let legacy = URL(
      fileURLWithPath: AgentHome.expandUserPath(
        "\(legacyStateDirectory)/history.json", environment: environment))
    if usesDefaultHome(options: options, environment: environment),
      !FileManager.default.fileExists(atPath: url.path),
      FileManager.default.fileExists(atPath: legacy.path)
    {
      try? FileManager.default.createDirectory(at: home.rootURL, withIntermediateDirectories: true)
      try? FileManager.default.copyItem(at: legacy, to: url)
    }
    return url
  }

  /// Adopts the single-file workspace pmai kept before projects existed into
  /// the first project started afterwards, then sets the file aside so it is
  /// imported only once.
  static func importLegacyChats(
    into store: AgentChatStore,
    project: AgentProject,
    options: CLIOptions,
    environment: [String: String]
  ) {
    guard options.statePath == nil, usesDefaultHome(options: options, environment: environment)
    else { return }
    let legacy = URL(
      fileURLWithPath: AgentHome.expandUserPath(
        "\(legacyStateDirectory)/chats.json", environment: environment))
    guard FileManager.default.fileExists(atPath: legacy.path) else { return }
    do {
      var workspace = try AgentChatWorkspace.load(from: legacy)
      let count = workspace.chats.filter { !$0.isDisposable }.count
      try store.commit(&workspace)
      let imported = legacy.appendingPathExtension("imported")
      try? FileManager.default.removeItem(at: imported)
      try FileManager.default.moveItem(at: legacy, to: imported)
      FileHandle.standardError.write(
        Data(
          "Imported \(count) earlier chat\(count == 1 ? "" : "s") from \(legacy.path) into project '\(project.displayName)'.\n"
            .utf8))
    } catch {
      FileHandle.standardError.write(
        Data(
          "warning: earlier chats in \(legacy.path) were not imported: \(error.localizedDescription)\n"
            .utf8))
    }
  }

  /// A project tint colors the prompt so the terminal shows which project is open.
  static func tintedUI(_ ui: ConfiguredTerminalUI, project: AgentProject)
    -> ConfiguredTerminalUI
  {
    guard let tint = project.tint else { return ui }
    var tinted = ui
    tinted.promptForeground = tint.hex
    return tinted
  }

  static func loadChatWorkspace(
    from store: AgentChatStore,
    initialProfile: SessionProfile,
    configuredAgents: [AgentDefinition],
    options: CLIOptions
  ) throws -> (workspace: AgentChatWorkspace, resumed: Bool) {
    var workspace = try store.loadWorkspace(paged: true) { error in
      FileHandle.standardError.write(
        Data("warning: skipped a chat file. \(error.localizedDescription)\n".utf8))
    }
    // Like the PocketMai app, every launch opens a fresh chat and keeps the
    // earlier ones one `/chat use` away; `--resume` reopens a saved chat instead.
    if options.resume {
      let chat: AgentChat?
      if let selector = options.resumeSelector {
        guard let selected = resolveChat(selector, in: workspace) else {
          throw CLIError.unknownChat(selector)
        }
        chat = selected
      } else {
        chat = workspace.mostRecentChat
      }
      if let chat {
        // The chat snapshot owns its settings. Environment and configured
        // defaults seed new chats; only explicit flags change a resumed one.
        var session = REPLSession(chat: chat)
        if let agentID = options.agentOverride,
          let agent = configuredAgents.first(where: { $0.id == agentID })
        {
          session.profile = SessionProfile(definition: agent)
        }
        options.applyOverrides(to: &session.profile)
        if session.profile.instructions != chat.primaryAgent.instructions {
          try applySystemInstructions(
            session.profile.instructions,
            replacing: chat.primaryAgent.instructions,
            session: &session)
        }
        workspace.upsert(session.chat, selecting: true)
        return (workspace, true)
      }
    }
    workspace.startNewChat(primaryAgent: initialProfile.agentDefinition)
    return (workspace, false)
  }

  /// Commits the workspace to the project's chat store. The selected
  /// placeholder stays in memory while the REPL runs and is dropped when it
  /// closes; the store never writes a placeholder, so an empty chat leaves no
  /// file behind however the process ends.
  static func saveWorkspace(
    _ workspace: inout AgentChatWorkspace,
    store: AgentChatStore,
    terminal: TerminalWriter,
    closing: Bool = false, background: Bool = false
  ) async {
    workspace.removeDisposableChats(keeping: closing ? nil : workspace.selectedChatID)
    let write = await REPLWorkspaceWriter.shared.enqueue(
      workspace, store: store, supervisor: await terminal.checkpointSupervisor())
    if background {
      Task {
        do { _ = try await write.value }
        catch { await terminal.line("warning: chats were not saved: \(error.localizedDescription)", to: .standardError) }
      }
      return
    }
    do { workspace = try await write.value }
    catch {
      await terminal.line("warning: chats were not saved: \(error.localizedDescription)", to: .standardError)
    }
  }
}
