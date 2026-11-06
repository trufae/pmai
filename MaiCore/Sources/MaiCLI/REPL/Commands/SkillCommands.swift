import Foundation
import MaiCore
import MaiDocuments

extension MaiCLI {
  // MARK: Skills

  static func handleSkillMutation(
    _ action: String, argument: String,
    session: inout REPLSession, runtime: AgentRuntime, skills: SkillState,
    plugins: PluginRegistry, configuration: inout MaiConfiguration?,
    configurationPath: String?, terminal: TerminalWriter
  ) async {
    do {
      var words = try shellWords(argument)
      var scoped = false
      var root = skills.directories[0]
      if words.first == "--user" || words.last == "--user" {
        root = skills.userDirectory
        scoped = true
        if words.first == "--user" { words.removeFirst() } else { words.removeLast() }
      } else if words.first == "--project" || words.last == "--project" {
        scoped = true
        if words.first == "--project" { words.removeFirst() } else { words.removeLast() }
      }
      guard let name = words.first,
        (action == "add" ? [1, 3].contains(words.count) : words.count == 1)
      else {
        await terminal.line(
          "Usage: /skills add [--user] NAME [\"DESCRIPTION\" \"PROMPT\"]\n       /skills edit|del [--user|--project] NAME\n       /skills import [--user] ZIP_OR_FOLDER\n       /edit skill [--user] NAME"
        )
        return
      }
      let catalog = scoped ? AgentSkillCatalog.load(directories: [root]) : skills.catalog
      let skill: AgentSkill
      let created: Bool
      switch action {
      case "del":
        guard let existing = await resolveSkill(name, in: catalog, terminal: terminal) else {
          return
        }
        try AgentSkillManager.remove(existing)
        let synced = await synchronizeSkillTools(runtime: runtime, state: skills)
        if !synced.catalog.modelInvocable.contains(where: { $0.toolName == existing.toolName }) {
          session.profile.toolNames.remove(existing.toolName)
          session.profile.toolPolicy.tools.removeValue(forKey: existing.toolName)
          session.touch()
          if var draft = configuration, let configurationPath {
            for index in draft.agents.indices {
              draft.agents[index].toolNames.remove(existing.toolName)
              draft.agents[index].toolPolicy.tools.removeValue(forKey: existing.toolName)
            }
            try draft.save(to: URL(fileURLWithPath: configurationPath))
            configuration = draft
            for agent in draft.agents {
              try await runtime.register(agent: agent, replacingExisting: true)
            }
          }
        }
        await terminal.line("Deleted skill '\(existing.name)' from \(existing.directoryURL.path).")
        if let revealed = synced.catalog.skill(named: existing.name) {
          await terminal.line(
            "The \(revealed.rootURL.path == skills.userDirectory.path ? "user" : "project") copy is now visible: \(revealed.fileURL.path)."
          )
        }
        return

      case "import":
        let path = (name as NSString).expandingTildeInPath
        let url = URL(
          fileURLWithPath: path,
          relativeTo: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        ).standardizedFileURL
        let archive: MaiArchiveSkill
        if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
          guard let imported = AgentSkill.load(directory: url) else {
            throw AgentSkillManagerError.invalidSkill
          }
          archive = try MaiArchiveSkill(skill: imported)
        } else {
          archive = try SkillArchiveImporter.archive(at: url)
        }
        skill = try AgentSkillManager.install(archive, in: root)
        created = true

      default:
        let existing = catalog.skill(named: name)
        if action == "add", existing != nil { throw AgentSkillManagerError.alreadyExists(name) }
        if words.count == 3 {
          skill = try AgentSkillManager.create(
            name: name, description: words[1], prompt: words[2], in: root)
          created = true
        } else {
          if existing == nil { try AgentSkillManager.ensureAvailable(name: name, in: root) }
          let previous =
            try existing.map { try String(contentsOf: $0.fileURL, encoding: .utf8) }
            ?? AgentSkillManager.document(name: name, description: "", prompt: "")
          guard
            let edited = await editTemporaryText(previous, suffix: "SKILL.md", terminal: terminal)
          else { return }
          guard edited != previous else {
            await terminal.line("Skill unchanged; no files saved.")
            return
          }
          if let existing {
            skill = try AgentSkillManager.saveDocument(edited, for: existing)
            created = false
          } else {
            let parsed = AgentSkillFrontMatter.parse(edited)
            guard parsed.fields["name"] == name else { throw AgentSkillManagerError.renamedSkill }
            guard
              !(parsed.fields["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            else {
              throw AgentSkillManagerError.missingDescription
            }
            skill = try AgentSkillManager.install(
              .init(
                name: name,
                files: [
                  .init(path: AgentSkill.filename, data: Data(edited.utf8))
                ]), in: root)
            created = true
          }
        }
      }
      let synced = await synchronizeSkillTools(runtime: runtime, state: skills)
      await terminal.line(
        "\(action == "import" ? "Imported" : created ? "Created" : "Saved") skill '\(skill.name)' at \(skill.fileURL.path)."
      )
      if created,
        synced.catalog.modelInvocable.contains(where: { $0.directoryURL == skill.directoryURL })
      {
        await handleToolsCommand(
          "enable tool:\(skill.toolName)", session: &session, runtime: runtime,
          plugins: plugins, configuration: &configuration,
          configurationPath: configurationPath, terminal: terminal)
      } else if created, synced.catalog.skill(named: skill.name)?.directoryURL != skill.directoryURL
      {
        await terminal.line(
          "A project skill shadows this copy; /skills show \(skill.name) shows the active skill.")
      }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Registers a `skills_*` tool for every skill the state can see. Called
  /// at startup, before agents are filtered against the known tool names.
  static func registerSkillTools(
    in runtime: AgentRuntime,
    state: SkillState
  ) async throws {
    try await runtime.register(tools: MaiSkillTools.makeTools(catalog: { state.catalog }), replacingExisting: true)
  }

  /// Brings the runtime's skill tools in line with the folders on disk: new
  /// skills are registered, edited ones re-described, removed ones dropped.
  @discardableResult

  static func synchronizeSkillTools(
    runtime: AgentRuntime,
    state: SkillState
  ) async -> (catalog: AgentSkillCatalog, added: [String], removed: [String]) {
    let catalog = state.catalog
    let wanted = catalog.modelInvocable
    let wantedNames = Set(wanted.map(\.toolName))
    let registered = Set(
      await runtime.availableTools().map(\.name).filter(MaiSkillTools.isSkillTool))
    var removed: [String] = []
    for name in registered.subtracting(wantedNames).sorted() {
      await runtime.unregister(toolNamed: name)
      removed.append(name)
    }
    var added: [String] = []
    for skill in wanted {
      let tool = MaiSkillTools.makeTool(for: skill) { state.catalog }
      guard (try? await runtime.register(tool: tool, replacingExisting: true)) != nil else {
        continue
      }
      if !registered.contains(skill.toolName) { added.append(skill.name) }
    }
    return (catalog, added, removed)
  }

  static func isSkillEnabled(_ skill: AgentSkill, profile: SessionProfile) -> Bool {
    skill.isModelInvocable && profile.agentDefinition.toolMode(
      for: skill.toolName, in: [MaiSkillTools.group(toolNames: [skill.toolName])]) != .disabled
  }

  /// The name and extra text of a `/skills prompt NAME [TEXT]` line; nil for
  /// any other /skills action.
  static func skillPromptRequest(_ argument: String)
    -> (name: String, arguments: String)?
  {
    let pieces = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = pieces.first?.lowercased(), ["prompt", "send", "use"].contains(action)
    else { return nil }
    let name = pieces.count > 1 ? pieces[1] : ""
    let arguments =
      pieces.count > 2 ? pieces[2].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    return (name, arguments)
  }

  private static func resolveSkill(
    _ selector: String,
    in catalog: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async -> AgentSkill? {
    guard !selector.isEmpty else {
      await terminal.line("Usage: /skills show|enable|disable|prompt NAME   (/skills lists them)")
      return nil
    }
    guard let skill = catalog.skill(named: selector) else {
      await terminal.line("Unknown skill '\(selector)'. /skills lists them.")
      return nil
    }
    return skill
  }

  static func handleSkillsCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    skills: SkillState,
    plugins: PluginRegistry,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? "list"
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let synced = await synchronizeSkillTools(runtime: runtime, state: skills)
    let catalog = synced.catalog
    let agentID = session.profile.agentID
    let usage = await runtime.toolUsageSnapshot()
    let groups = await runtime.availableToolGroups()
    let modes = session.profile.agentDefinition.toolModes(in: groups, usage: usage)

    switch action {
    case "add", "new", "create", "edit", "del", "import":
      let mutation = ["new", "create"].contains(action) ? "add" : action
      await handleSkillMutation(
        mutation, argument: rest, session: &session, runtime: runtime, skills: skills,
        plugins: plugins, configuration: &configuration,
        configurationPath: configurationPath, terminal: terminal)

    case "", "list", "ls":
      guard !catalog.isEmpty else {
        let places = skills.directories.map { abbreviatedPath($0.path, width: 60) }
        await terminal.line(
          "No skills. /skills add NAME creates one; /skills import ZIP_OR_FOLDER imports one. Skills live under \(places.joined(separator: " or ")); /help skills explains."
        )
        return
      }
      for skill in catalog.skills {
        let mode = modes[skill.toolName] ?? .disabled
        let status = switch (skill.isModelInvocable, mode) {
        case (false, _): "not callable"
        case (true, .direct): "enabled"
        case (true, .proxy): "proxied"
        case (true, .hidden): "hidden"
        case (true, .disabled): "disabled"
        }
        let color: TerminalThemeStyle =
          !skill.isModelInvocable
          ? .warningForeground : mode == .disabled ? .errorForeground : .successForeground
        let label = await terminal.paint("(\(status))", role: color)
        let name = await terminal.paint(skill.name, bold: true)
        let source = skill.rootURL.path == skills.userDirectory.path ? "user" : "project"
        await terminal.line("\(name) \(label) [\(source); \(usage.counts[skill.toolName, default: 0]) calls]")
        await terminal.line("  " + skill.description.replacingOccurrences(of: "\n", with: "\n  "))
      }
      await terminal.line(
        "Statuses apply to agent \(agentID). /skills enable NAME enables a skill; /skills prompt NAME [TEXT] sends an enabled skill now."
      )

    case "show", "cat":
      guard let skill = await resolveSkill(rest, in: catalog, terminal: terminal) else { return }
      let state =
        !skill.isModelInvocable
        ? "not offered to the model"
        : "\((modes[skill.toolName] ?? .disabled).rawValue) for \(agentID)"
      await terminal.line("\(skill.name): \(skill.description)")
      await terminal.line("File: \(skill.fileURL.path)")
      await terminal.line("Tool: \(skill.toolName) (\(state); \(usage.counts[skill.toolName, default: 0]) calls)")
      await terminal.line("")
      await terminal.line(skill.body)

    case "enable", "on", "disable", "off", "direct", "proxy", "hide", "inherit":
      let selector: String
      if rest.lowercased() == "all" {
        selector = "skills"
      } else {
        guard let skill = await resolveSkill(rest, in: catalog, terminal: terminal) else { return }
        guard skill.isModelInvocable else {
          await terminal.line(
            "Skill '\(skill.name)' says disable-model-invocation, so it has no skill tool.")
          return
        }
        selector = "tool:" + skill.toolName
      }
      await handleToolsCommand(
        "\(action) \(selector)", session: &session, runtime: runtime,
        plugins: plugins, configuration: &configuration,
        configurationPath: configurationPath, terminal: terminal)

    case "prompt", "send", "use":
      await terminal.line(
        "Use /skills prompt NAME [TEXT] at the chat prompt; /skills show NAME prints what it sends."
      )

    case "path":
      for directory in skills.directories {
        var isDirectory: ObjCBool = false
        let exists =
          FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory)
          && isDirectory.boolValue
        let count = AgentSkillCatalog.load(directory: directory).count
        await terminal.line(
          "\(directory.path)  \(exists ? "\(count) skill\(count == 1 ? "" : "s")" : "(missing)")")
      }

    case "reload":
      var parts: [String] = []
      if !synced.added.isEmpty { parts.append("added \(synced.added.joined(separator: ", "))") }
      if !synced.removed.isEmpty {
        parts.append("removed \(synced.removed.joined(separator: ", "))")
      }
      await terminal.line(
        "\(catalog.skills.count) skill\(catalog.skills.count == 1 ? "" : "s")"
          + (parts.isEmpty ? ", unchanged." : ": " + parts.joined(separator: "; ") + "."))

    default:
      await terminal.line(skillsHelp)
    }
  }
}
