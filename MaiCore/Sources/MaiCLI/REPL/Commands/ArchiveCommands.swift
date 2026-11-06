import Foundation
import MaiCore
import MaiDocuments

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
  /// `/export FORMAT [PATH]` writes this chat as a document, or writes a
  /// portable archive containing the active configuration, visible skills,
  /// and current chat. MaiCore owns the archive format used by both hosts.
  static func handleExportCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    process: AgentPID?,
    configuration: MaiConfiguration?,
    skills: AgentSkillCatalog,
    services: REPLServices,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let first = fields.first else {
      await terminal.line(exportHelp)
      return
    }
    var chat = session.chat
    chat.commands = runtime.commandHistory.records(sessionID: session.sessionID, saved: session.commands)
    // The agents of this chat's runs as they stand: what the process table
    // holds now, live or finished, over what was saved with the chat.
    if chat.hasConversation, let process {
      chat.subagents = AgentProcessRecord.merging(
        saved: chat.subagents, current: await runtime.conversationRecords(under: process))
      chat.subagents = session.redactor?.unredact(chat.subagents) ?? chat.subagents
    }
    if ["archive", "pack", "portable"].contains(first.lowercased()) {
      do {
        let archive = MaiArchive(
          generator: "pmai",
          settings: configuration.map { MaiArchiveSettings(configuration: $0) },
          chats: chat.hasConversation ? [chat] : nil,
          skills: try skills.skills.map { try MaiArchiveSkill(skill: $0) })
        let filename =
          chat.hasConversation
          ? archiveFilename(for: chat) : "Mai-Archive.\(MaiArchive.fileExtension)"
        let target = exportTarget(
          fields.count > 1 ? fields[1] : nil, defaultFilename: filename)
        let data = try archive.encoded()
        try data.write(to: target, options: .atomic)
        await terminal.line(
          "Exported Mai archive (\(AgentProcessInfo.compactCount(data.count)) bytes) to \(target.path)"
        )
      } catch {
        await terminal.line(
          "error: Could not export: \(error.localizedDescription)", to: .standardError)
      }
      return
    }
    guard let format = ChatExportFormat(argument: first) else {
      await terminal.line(exportHelp)
      return
    }
    guard chat.hasConversation else {
      await terminal.line("Nothing to export yet: this chat has no messages.")
      return
    }
    var debug: ChatExportDebug?
    if format == .debug {
      let profile = session.profile
      let tools = await runtime.availableTools().filter { profile.toolNames.contains($0.name) }
      let provider = await runtime.availableProviders().first { $0.id == profile.provider }
      let snapshot = try? await diagnosticConfiguration(
        session: session, configuration: configuration, runtime: runtime,
        providerBaseURLs: services.providerBaseURLs, approvalHandler: services.approvalHandler)
      let settings = snapshot?.objectValue?["settings"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
      debug = ChatExportDebug(
        provider: profile.provider.rawValue,
        providerDisplayName: provider?.displayName,
        toolDefinitions: tools,
        settings: [
          "workingDirectory": FileManager.default.currentDirectoryPath,
          "toolCallingStrategy": profile.toolCallingStrategy.rawValue,
          "toolDelegation": profile.toolDelegation.rawValue,
          "useToolProxy": profile.useToolProxy ? "true" : "false",
          "proxyExposedTools": profile.proxyExposedTools.map { $0.sorted().joined(separator: ", ") }
            ?? "default",
          "subagentNames": profile.subagentNames.sorted().joined(separator: ", "),
          "limits.maxToolCalls": String(profile.limits.maxToolCalls),
          "limits.maxModelTurns": String(profile.limits.maxModelTurns),
          "limits.maxSubagents": String(profile.limits.maxSubagents),
          "limits.maxSubagentDepth": String(profile.limits.maxSubagentDepth),
          "limits.maxTotalTokens": limitValue("limits.maxTotalTokens", in: profile.limits),
          "limits.maxSeconds": limitValue("limits.maxSeconds", in: profile.limits),
          "limits.runTimeoutSeconds": limitValue("limits.runTimeoutSeconds", in: profile.limits),
          "retry.attempts": String(profile.retry.attempts),
          "retry.delay": durationSetting(profile.retry.delaySeconds),
          "ctx.compact": autocompactSetting(profile.autocompact),
          "ctx.recent": profile.autocompact.preserveRecentTokens.map(String.init) ?? "auto",
          "ctx.window": profile.options.contextWindowTokens.map(String.init) ?? "auto",
          "ctx.strategy": profile.context.rawValue,
        ].merging(settings, uniquingKeysWith: { _, current in current }),
        subagents: chat.subagents,
        configuration: snapshot)
    }
    let target = exportTarget(
      fields.count > 1 ? fields[1] : nil,
      defaultFilename: ChatExport.filename(for: chat, format: format))
    do {
      let data = try ChatExport.data(
        for: chat, format: format, generator: "pmai", debug: debug,
        options: configuration?.documentExport ?? .init())
      try data.write(to: target, options: .atomic)
      await terminal.line(
        "Exported \(format.displayName) (\(AgentProcessInfo.compactCount(data.count)) bytes) to \(target.path)"
      )
    } catch {
      await terminal.line(
        "error: Could not export: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func exportTarget(_ path: String?, defaultFilename: String) -> URL {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    guard let path else { return current.appendingPathComponent(defaultFilename) }
    let raw = path.trimmingCharacters(in: .whitespacesAndNewlines)
    let expanded = NSString(string: raw).expandingTildeInPath
    var target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if raw.hasSuffix("/") || (exists && isDirectory.boolValue) {
      try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
      target.appendPathComponent(defaultFilename)
    }
    return target
  }

  private static func archiveFilename(for chat: AgentChat) -> String {
    let json = ChatExport.filename(for: chat, format: .json)
    return String(json.dropLast(".json".count)) + "." + MaiArchive.fileExtension
  }

  /// Imports a Mai archive (standalone or embedded in a PocketMai backup).
  /// Older pmai JSON chat exports remain valid inputs as a convenience.
  static func handleImportCommand(
    _ argument: String,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    services: REPLServices,
    selectImportedChat: Bool,
    terminal: TerminalWriter
  ) async {
    guard !argument.isEmpty else {
      await terminal.line(importHelp)
      return
    }
    let expanded = NSString(string: argument).expandingTildeInPath
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let url = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    do {
      let archive = try importArchive(from: Data(contentsOf: url))
      let summary = try await applyImportedArchive(
        archive,
        session: &session,
        workspace: &workspace,
        runtime: runtime,
        plugins: plugins,
        configuration: &configuration,
        catalogs: &catalogs,
        services: services,
        selectImportedChat: selectImportedChat,
        terminal: terminal)
      await terminal.line("Imported \(summary.joined(separator: ", ")) from \(url.path).")
      if !selectImportedChat, archive.chats?.isEmpty == false {
        await terminal.line("The current turn kept its chat; /chat list shows the imported chats.")
      }
    } catch {
      await terminal.line(
        "error: Could not import: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func importArchive(from data: Data) throws -> MaiArchive {
    do {
      return try MaiArchive.decode(from: data)
    } catch let archiveError {
      let decoder = MaiJSONCoding.default.makeDecoder()
      guard let envelope = try? decoder.decode(ChatExportEnvelope.self, from: data),
        envelope.format == ChatExportEnvelope.format,
        envelope.version == 1
      else { throw archiveError }
      return MaiArchive(
        generator: envelope.generator, exportedAt: envelope.exportedAt, chats: [envelope.chat])
    }
  }

  private static func applyImportedArchive(
    _ archive: MaiArchive,
    session: inout REPLSession,
    workspace: inout AgentChatWorkspace,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    catalogs: inout [MCPServerCatalog],
    services: REPLServices,
    selectImportedChat: Bool,
    terminal: TerminalWriter
  ) async throws -> [String] {
    var summary: [String] = []
    var importedConfiguration = configuration
    if let settings = archive.settings {
      guard let path = services.configurationPath else {
        throw ArchiveImportError.configurationUnavailable
      }
      var draft = configuration ?? MaiConfiguration()
      let merged = try draft.mergeArchiveSettings(settings)
      try draft.save(to: URL(fileURLWithPath: path))
      importedConfiguration = draft
      configuration = draft
      summary.append(contentsOf: archiveSettingsSummary(merged))
    }

    if let skills = archive.skills {
      for skill in skills { try skill.install(in: services.skills.userDirectory) }
      _ = await synchronizeSkillTools(runtime: runtime, state: services.skills)
      summary.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")")
    }

    if let settings = archive.settings, let draft = importedConfiguration {
      await reloadImportedSettings(
        settings,
        configuration: draft,
        session: &session,
        runtime: runtime,
        plugins: plugins,
        catalogs: &catalogs,
        providerBaseURLs: services.providerBaseURLs,
        terminal: terminal)
    }

    if let chats = archive.chats {
      var existingIDs = Set(workspace.chats.map(\.id))
      var firstImported: AgentChat?
      for var chat in chats {
        if existingIDs.contains(chat.id) {
          chat.id = UUID()
          chat.sessionID = ChatSession.newID()
          chat.commands = chat.commands.map { $0.copied(to: chat.sessionID) }
        }
        while !existingIDs.insert(chat.id).inserted { chat.id = UUID() }
        workspace.upsert(chat)
        if firstImported == nil { firstImported = chat }
      }
      if selectImportedChat, let firstImported {
        workspace.selectChat(id: firstImported.id)
        session = REPLSession(chat: firstImported)
      }
      summary.append("\(chats.count) chat\(chats.count == 1 ? "" : "s")")
    }
    return summary.isEmpty ? ["nothing"] : summary
  }

  private static func archiveSettingsSummary(_ summary: MaiArchiveMergeSummary) -> [String] {
    [
      (summary.providers, "provider"),
      (summary.prompts, "prompt"),
      (summary.mcpServers, "MCP server"),
      (summary.agents, "agent"),
    ].compactMap { item in
      let (count, name) = item
      return count == 0 ? nil : "\(count) \(name)\(count == 1 ? "" : "s")"
    }
  }

  private static func reloadImportedSettings(
    _ imported: MaiArchiveSettings,
    configuration: MaiConfiguration,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    catalogs: inout [MCPServerCatalog],
    providerBaseURLs: ProviderBaseURLStore,
    terminal: TerminalWriter
  ) async {
    let environment = ProcessInfo.processInfo.environment
    for requested in imported.providers ?? [] {
      guard let provider = configuration.providers.first(where: { $0.id == requested.id }) else {
        continue
      }
      do {
        try await runtime.register(
          plugins.makeProvider(from: provider, environment: environment), replacingExisting: true)
        if let url = provider.baseURL { providerBaseURLs.set(url, for: provider.id) }
      } catch {
        await terminal.line(
          "warning: Provider '\(provider.id)' was saved but could not be loaded: \(error.localizedDescription)",
          to: .standardError)
      }
    }

    for requested in imported.mcpServers ?? [] {
      guard let server = configuration.mcpServers.first(where: { $0.id == requested.id }) else {
        continue
      }
      _ = await runtime.unregisterMCP(serverID: server.id)
      catalogs.removeAll { $0.serverID == server.id }
      guard server.enabled else { continue }
      do {
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind, configuration: server, environment: environment)
        catalogs.append(try await runtime.register(mcp: source))
      } catch {
        await terminal.line(
          "warning: MCP server '\(server.id)' was saved but could not connect: \(error.localizedDescription)",
          to: .standardError)
      }
    }

    await runtime.configureDelegation(
      prompt: configuration.prompts?.delegation,
      workerInstructions: configuration.prompts?.worker)
    await runtime.configureCompaction(prompt: configuration.prompts?.compact)
    await runtime.configureSmartContext(prompt: configuration.prompts?.smart)
    await runtime.configureTaskAgents(configuration.taskAgents)
    let knownTools = Set(await runtime.availableTools().map(\.name))
    for requested in imported.agents ?? [] {
      guard var agent = configuration.agents.first(where: { $0.id == requested.id }) else {
        continue
      }
      agent.toolNames.formIntersection(knownTools)
      do {
        try await runtime.register(agent: agent, replacingExisting: true)
      } catch {
        await terminal.line(
          "warning: Agent '\(agent.id)' was saved but could not be loaded: \(error.localizedDescription)",
          to: .standardError)
      }
    }
    if let agent = configuration.agents.first(where: { $0.id == session.profile.agentID }) {
      try? applyDefinition(agent, to: &session)
    }
  }

  private enum ArchiveImportError: LocalizedError {
    case configurationUnavailable

    var errorDescription: String? {
      "No writable configuration is active; chats and skills were not imported."
    }
  }
}
