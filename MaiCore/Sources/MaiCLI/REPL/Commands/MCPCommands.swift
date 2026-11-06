import Foundation
import MaiCore

enum MCPCommandError: LocalizedError {
  case missingID
  case invalidID(String)
  case duplicateID(String)
  case missingCommand
  case missingOptionValue(String)
  case invalidOption(String)
  case invalidEnvironment
  case invalidTimeout
  case invalidApproval
  case invalidURL(String)
  case invalidHTTPArguments
  case unterminatedQuote
  case danglingEscape

  var errorDescription: String? {
    switch self {
    case .missingID: "Could not infer an MCP name from the command. Use --name ID."
    case .invalidID(let id):
      "Invalid MCP name '\(id)'. Start with a letter or number; "
        + "then use letters, numbers, '.', '_', or '-'."
    case .duplicateID(let id): "An MCP server named '\(id)' is already configured."
    case .missingCommand: "The MCP command or HTTP(S) URL is missing."
    case .missingOptionValue(let option): "Missing value after \(option)."
    case .invalidOption(let option): "Unknown MCP option '\(option)'."
    case .invalidEnvironment: "--env expects KEY=VALUE."
    case .invalidTimeout: "--timeout expects a positive number of seconds."
    case .invalidApproval: "--approval expects automatic, confirm, or dangerous."
    case .invalidURL(let url): "Invalid MCP URL '\(url)'. Use an HTTP(S) URL with a host."
    case .invalidHTTPArguments:
      "HTTP MCP servers accept one URL; --env, --cwd, and command arguments are only supported for stdio servers."
    case .unterminatedQuote: "The command contains an unterminated quote."
    case .danglingEscape: "The command ends with an incomplete escape."
    }
  }
}

extension MaiCLI {
  static func handleMCPCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    catalogs: inout [MCPServerCatalog],
    terminal: TerminalWriter
  ) async {
    let pieces = argument.split(
      maxSplits: 1, whereSeparator: \Character.isWhitespace
    ).map(String.init)
    let action = pieces.first?.lowercased() ?? "list"
    if ["direct", "proxy", "hide", "inherit", "tools"].contains(action), pieces.count == 2 {
      let selector = "mcp/" + pieces[1]
      await handleToolsCommand(
        "\(action == "tools" ? "show" : action) \(selector)", session: &session,
        runtime: runtime, plugins: plugins, configuration: &configuration,
        configurationPath: configurationPath, terminal: terminal)
      return
    }
    switch action {
    case "", "list":
      let usage = await runtime.toolUsageSnapshot()
      let groups = await runtime.availableToolGroups()
      let configured = configuration?.mcpServers ?? []
      let connected = Dictionary(uniqueKeysWithValues: catalogs.map { ($0.serverID, $0) })
      if configured.isEmpty, catalogs.isEmpty {
        await terminal.line("No configured MCP servers.")
        return
      }
      for server in configured {
        let transport =
          server.kind == "stdio"
          ? server.command ?? "stdio" : server.url?.absoluteString ?? server.kind
        let state: String
        if !server.enabled {
          state = "disabled"
        } else if let catalog = connected[server.id] {
          state =
            "connected — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion)"
        } else {
          state = "not connected"
        }
        let count = groups.first { $0.sourceID == "mcp" && $0.id == server.id }
          .map { usage.count(for: $0) } ?? 0
        await terminal.line("\(server.id) — \(transport) [\(state); \(count) calls]")
      }
      let configuredIDs = Set(configured.map(\.id))
      for catalog in catalogs where !configuredIDs.contains(catalog.serverID) {
        let count = groups.first { $0.sourceID == "mcp" && $0.id == catalog.serverID }
          .map { usage.count(for: $0) } ?? 0
        await terminal.line(
          "\(catalog.serverID) — \(catalog.tools.count) tools, \(catalog.resources.count) resources, MCP \(catalog.protocolVersion) [connected; \(count) calls]"
        )
      }

    case "info":
      let requestedID = pieces.count == 2 ? pieces[1] : nil
      guard (requestedID?.split(whereSeparator: \Character.isWhitespace).count ?? 0) <= 1 else {
        await terminal.line("Usage: /mcp info [ID]")
        return
      }
      let configured = configuration?.mcpServers ?? []
      let ids = configured.map(\.id)
        + catalogs.map(\.serverID).filter { id in !configured.contains { $0.id == id } }
      if let requestedID, !ids.contains(requestedID) {
        await terminal.line("Unknown MCP server '\(requestedID)'. /mcp list shows them.")
        return
      }
      guard !ids.isEmpty else {
        await terminal.line("No configured MCP servers.")
        return
      }
      let groups = await runtime.availableToolGroups()
      let usage = await runtime.toolUsageSnapshot()
      for (index, id) in (requestedID.map { [$0] } ?? ids).enumerated() {
        if index > 0 { await terminal.line("") }
        let server = configured.first { $0.id == id }
        let catalog = catalogs.first { $0.serverID == id }
        await terminal.line(await terminal.paint("MCP server: \(id)", bold: true))
        for line in mcpInfoLines(server: server, catalog: catalog) {
          await terminal.line(line)
        }
        if groups.contains(where: { $0.sourceID == "mcp" && $0.id == id }) {
          await handleToolsCommand(
            "show mcp/\(id)", session: &session, runtime: runtime, plugins: plugins,
            configuration: &configuration, configurationPath: configurationPath, terminal: terminal)
        } else {
          let prefix = server.map { mcpNamespace(for: $0) } ?? id
          let names = Set(usage.counts.keys.filter { $0.hasPrefix("\(prefix)::") })
          let group = ToolGroupDefinition(
            id: id, sourceID: "mcp", displayName: id, description: "", toolNames: names)
          await terminal.line("Tools: unavailable until connected; \(usage.count(for: group)) recorded calls.")
          for name in names.sorted() {
            await terminal.line("  \(name) [not connected; \(usage.counts[name, default: 0]) calls]")
          }
        }
      }

    case "add":
      guard let rawAddArguments = pieces.dropFirst().first else {
        await terminal.line(mcpCommandHelp)
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      do {
        let server = try parseMCPAddArguments(rawAddArguments)
        guard !draft.mcpServers.contains(where: { $0.id == server.id }) else {
          throw MCPCommandError.duplicateID(server.id)
        }
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)

        draft.mcpServers.append(server)
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Added and connected \(server.kind) MCP '\(server.id)'; \(addedTools.count) tools available under mcp/\(server.id); /tools selects per-agent exposure."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "enable":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath,
        let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id })
      else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if catalogs.contains(where: { $0.serverID == id }) {
        await terminal.line("MCP server '\(id)' is already enabled and connected.")
        return
      }
      do {
        var server = draft.mcpServers[serverIndex]
        server.enabled = true
        let source = try await plugins.makeMCPToolSource(
          kind: server.kind,
          configuration: server,
          environment: ProcessInfo.processInfo.environment)
        let toolsBefore = Set(await runtime.availableTools().map(\.name))
        let catalog = try await runtime.register(mcp: source)
        let addedTools = Set(await runtime.availableTools().map(\.name)).subtracting(toolsBefore)
        draft.mcpServers[serverIndex] = server
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        catalogs.append(catalog)
        await terminal.line(
          "Enabled and connected MCP '\(id)'; \(addedTools.count) tools available under mcp/\(id); /tools selects per-agent exposure."
        )
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "disable", "del":
      guard pieces.count == 2 else {
        await terminal.line(mcpCommandHelp)
        return
      }
      let removing = action != "disable"
      let id = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      guard let serverIndex = draft.mcpServers.firstIndex(where: { $0.id == id }) else {
        await terminal.line("error: MCP server '\(id)' is not configured.", to: .standardError)
        return
      }
      if !removing, !draft.mcpServers[serverIndex].enabled {
        await terminal.line("MCP server '\(id)' is already disabled.")
        return
      }
      let namespace = mcpNamespace(for: draft.mcpServers[serverIndex])
      let removedTools = await runtime.availableToolGroups()
        .first { $0.sourceID == "mcp" && $0.id == id }?.toolNames ?? []
      var profile = session.profile
      if removing {
        draft.mcpServers.remove(at: serverIndex)
        for index in draft.agents.indices {
          removeMCPReferences(
            from: &draft.agents[index], serverID: id, namespace: namespace, tools: removedTools)
        }
        var definition = profile.agentDefinition
        removeMCPReferences(
          from: &definition, serverID: id, namespace: namespace, tools: removedTools)
        profile = SessionProfile(definition: definition)
      } else {
        draft.mcpServers[serverIndex].enabled = false
        for index in draft.agents.indices {
          draft.agents[index].toolNames.subtract(removedTools)
        }
        profile.toolNames.subtract(removedTools)
      }
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        _ = await runtime.unregisterMCP(serverID: id)
        for agent in draft.agents {
          try await runtime.register(agent: agent, replacingExisting: true)
        }
        session.profile = profile
        configuration = draft
        catalogs.removeAll { $0.serverID == id }
        session.touch()
        await terminal.line(
          "\(removing ? "Removed" : "Disabled") MCP '\(id)' and removed \(removedTools.count) live tools.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      await terminal.line(mcpCommandHelp)
    }
  }

  private static func mcpInfoLines(
    server: ConfiguredMCPServer?, catalog: MCPServerCatalog?
  ) -> [String] {
    let state = server?.enabled == false ? "disabled" : catalog == nil ? "not connected" : "connected"
    var lines = ["State: \(state)"]
    if let name = server?.displayName ?? catalog?.serverName { lines.append("Name: \(name)") }
    if let server {
      lines.append("Transport: \(server.kind)")
      if let command = server.command {
        lines.append("Command: \(([command] + server.args).map(shellQuote).joined(separator: " "))")
        lines.append("Working directory: \(server.cwd ?? FileManager.default.currentDirectoryPath)")
      }
      if let url = server.url { lines.append("URL: \(url.absoluteString)") }
      let timeout = max(1, server.timeout ?? MCPServerConfiguration.defaultTimeout)
      lines.append("Timeout: \(String(format: "%g", timeout)) seconds")
      lines.append("Tool prefix: \(mcpNamespace(for: server))")
      lines.append("Approval: \(server.defaultApproval.rawValue)")
      if !server.env.isEmpty {
        lines.append("Environment variables: \(server.env.keys.sorted().joined(separator: ", "))")
      }
      let headers = Set(server.headers.keys).union(server.headerEnvironment.keys)
      if !headers.isEmpty { lines.append("Headers: \(headers.sorted().joined(separator: ", "))") }
      if let variable = server.bearerTokenEnvironment {
        lines.append("Bearer token: environment variable \(variable)")
      } else if server.bearerToken != nil {
        lines.append("Bearer token: configured")
      }
    } else {
      lines.append("Configuration: runtime only")
    }
    if let catalog {
      lines.append("Protocol: \(catalog.protocolVersion)")
      lines.append("Resources: \(catalog.resources.count)")
    }
    return lines
  }

  private static func removeMCPReferences(
    from agent: inout AgentDefinition, serverID: String, namespace: String, tools: Set<String>
  ) {
    let belongsToServer = { (name: String) in
      tools.contains(name) || name.hasPrefix("\(namespace)::")
    }
    agent.toolNames = agent.toolNames.filter { !belongsToServer($0) }
    agent.proxyExposedTools = agent.proxyExposedTools.map { $0.filter { !belongsToServer($0) } }
    agent.toolPolicy.tools = agent.toolPolicy.tools.filter { !belongsToServer($0.key) }
    agent.toolGroupNames.remove("mcp/\(serverID)")
    agent.toolPolicy.groups.removeValue(forKey: "mcp/\(serverID)")
  }

  private static func mcpNamespace(for server: ConfiguredMCPServer) -> String {
    let prefix = server.toolNamePrefix?.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.flatMap { $0.isEmpty ? nil : $0 } ?? server.id
  }

  private static func parseMCPAddArguments(_ arguments: String) throws
    -> ConfiguredMCPServer
  {
    let words = try shellWords(arguments)
    guard !words.isEmpty else { throw MCPCommandError.missingCommand }
    var environment: [String: String] = [:]
    var workingDirectory: String?
    var timeout: TimeInterval?
    var prefix: String?
    var approval = ToolApprovalRequirement.confirm
    var id: String?
    let separatorIndex = words.firstIndex(of: "--")
    let optionWords: ArraySlice<String>
    let commandWords: ArraySlice<String>
    if let separatorIndex {
      var optionsStart = words.startIndex
      if optionsStart < separatorIndex, !words[optionsStart].hasPrefix("-") {
        id = words[optionsStart]
        optionsStart += 1
      }
      optionWords = words[optionsStart..<separatorIndex]
      commandWords = words[words.index(after: separatorIndex)...]
    } else {
      optionWords = []
      commandWords = words[...]
    }

    var index = optionWords.startIndex
    while index < optionWords.endIndex {
      switch optionWords[index] {
      case "--name":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--name")
        }
        id = optionWords[index]
        index += 1
      case "--env":
        index += 1
        guard index < optionWords.endIndex,
          let separator = optionWords[index].firstIndex(of: "="),
          separator != optionWords[index].startIndex
        else { throw MCPCommandError.invalidEnvironment }
        environment[String(optionWords[index][..<separator])] = String(
          optionWords[index][optionWords[index].index(after: separator)...])
        index += 1
      case "--cwd":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--cwd")
        }
        workingDirectory = optionWords[index]
        index += 1
      case "--timeout":
        index += 1
        guard index < optionWords.endIndex,
          let value = TimeInterval(optionWords[index]), value > 0
        else {
          throw MCPCommandError.invalidTimeout
        }
        timeout = value
        index += 1
      case "--prefix":
        index += 1
        guard index < optionWords.endIndex else {
          throw MCPCommandError.missingOptionValue("--prefix")
        }
        prefix = optionWords[index]
        index += 1
      case "--approval":
        index += 1
        guard index < optionWords.endIndex,
          let value = ToolApprovalRequirement(rawValue: optionWords[index].lowercased())
        else { throw MCPCommandError.invalidApproval }
        approval = value
        index += 1
      default:
        throw MCPCommandError.invalidOption(optionWords[index])
      }
    }
    guard let command = commandWords.first, !command.isEmpty else {
      throw MCPCommandError.missingCommand
    }
    let url: URL?
    if command.contains("://") {
      guard let endpoint = URL(string: command),
        ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
        endpoint.host?.isEmpty == false
      else { throw MCPCommandError.invalidURL(command) }
      guard commandWords.count == 1, environment.isEmpty, workingDirectory == nil else {
        throw MCPCommandError.invalidHTTPArguments
      }
      url = endpoint
    } else {
      url = nil
    }
    let inferredID = url?.host ?? URL(fileURLWithPath: command).lastPathComponent
    let resolvedID = id ?? inferredID
    guard !resolvedID.isEmpty else { throw MCPCommandError.missingID }
    guard isValidMCPID(resolvedID) else { throw MCPCommandError.invalidID(resolvedID) }
    return ConfiguredMCPServer(
      id: resolvedID,
      kind: url == nil ? "stdio" : "streamable-http",
      url: url,
      command: url == nil ? command : nil,
      args: Array(commandWords.dropFirst()),
      env: environment,
      cwd: workingDirectory,
      timeout: timeout,
      toolNamePrefix: prefix,
      defaultApproval: approval)
  }

  private static func isValidMCPID(_ id: String) -> Bool {
    guard id != ".", id != "..",
      id.first.map({ $0.isLetter || $0.isNumber }) == true
    else {
      return false
    }
    return id.allSatisfy { $0.isLetter || $0.isNumber || "._-".contains($0) }
  }
}
