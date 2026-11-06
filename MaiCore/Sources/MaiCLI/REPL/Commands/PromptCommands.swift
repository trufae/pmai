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
  static func resolvedSystemPromptName(
    _ requested: String,
    configuration: MaiConfiguration?
  ) -> String? {
    (configuration ?? .init()).systemPrompt(named: requested)?.name
  }

  /// `/prompts`: prompts by source, with builtin and user prompts last
  /// so the most commonly sent messages stay close to the input.
  private static func showPrompts(
    session: REPLSession,
    configuration: MaiConfiguration?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async {
    let catalog =
      configuration?.promptCatalog(skills: skills.skills) ?? PromptCatalog(skills: skills.skills)
    let width = max(10, catalog.entries.map { $0.commandName.count }.max() ?? 0)
    func row(_ marker: String, _ name: String, _ detail: String, color: TerminalThemeStyle) async
      -> String
    {
      let label = "\(marker) \(name.padding(toLength: width, withPad: " ", startingAt: 0))"
      return await terminal.paint(label, role: color) + "  \(detail)"
    }
    var lines = [
      await terminal.paint(
        "System prompts — an agent's instructions (/prompt manages them; $NAME switches this agent to one):",
        role: .infoForeground, bold: true)
    ]
    let system = catalog.entries(of: .system)
    for entry in system {
      let selected = session.profile.systemPrompt == entry.name ? "*" : " "
      let agents = configuration?.agentsUsingSystemPrompt(entry.name) ?? []
      lines.append(
        await row(
          selected, entry.commandName,
          agents.isEmpty ? "unused" : "agents: \(agents.joined(separator: ", "))",
          color: .infoForeground))
    }
    if system.isEmpty { lines.append("  None; /prompt add NAME TEXT creates one.") }
    lines.append("")
    lines.append(
      await terminal.paint(
        "Skills — /skills; $NAME sends one when its tool is enabled for this agent:",
        role: .toolCallForeground, bold: true))
    let skillEntries = catalog.entries(of: .skill)
    for entry in skillEntries {
      lines.append(await row(" ", entry.commandName, entry.summary, color: .toolCallForeground))
    }
    if skillEntries.isEmpty { lines.append("  None found; /skills path lists the folders read.") }
    let templates: [(String, String?)] = [
      ("compact", configuration?.prompts?.compact),
      ("smart", configuration?.prompts?.smart),
      ("recap", configuration?.prompts?.recap),
      ("delegation", configuration?.prompts?.delegation),
      ("worker", configuration?.prompts?.worker),
      ("memory", configuration?.prompts?.memory),
    ]
    lines.append("")
    lines.append(
      await terminal.paint(
        "Templates — not sent by name; /edit compact, /edit smart, /edit prompt recap, /edit delegation, /edit worker, /edit memory-prompt:",
        role: .thinkingForeground, bold: true))
    for (name, text) in templates {
      let custom = text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
      lines.append(await row(" ", name, custom ? "custom" : "built-in", color: .thinkingForeground))
    }
    let user = catalog.entries(of: .user)
    let userCommands = Set(user.map { PromptSlashCommand.normalized($0.commandName) })
    lines.append("")
    lines.append(
      await terminal.paint(
        "Builtin prompts — MaiCore's; a user prompt of the same name replaces one:",
        role: .successForeground, bold: true))
    for entry in catalog.entries(of: .builtin) {
      let replaced = userCommands.contains(PromptSlashCommand.normalized(entry.commandName))
      lines.append(
        await row(
          " ", entry.commandName, replaced ? "replaced by the user prompt below" : entry.summary,
          color: .successForeground))
    }
    lines.append("")
    lines.append(
      await terminal.paint(
        "User prompts — messages sent by name (prompts.user; /prompts add NAME TEXT, /edit user NAME):",
        role: .promptForeground, bold: true))
    for entry in user {
      lines.append(await row(" ", entry.commandName, entry.summary, color: .promptForeground))
    }
    if user.isEmpty { lines.append("  None yet.") }
    lines.append("")
    lines.append(
      "$NAME [TEXT] sends a prompt with TEXT after it (/prompts NAME [TEXT] is the long form); /prompts show NAME prints one."
    )
    await terminal.line(lines.joined(separator: "\n"))
  }

  /// What the REPL loop does after `/prompts`: nothing more, send a
  /// message, or switch the agent to a system prompt and then send one.
  enum PromptsCommandOutcome {
    case handled
    case send(String, title: String)
    case selectSystemPrompt(String, then: String?)
  }

  /// `/prompts` — and `$`, its short form — in full: the catalog listed, one
  /// prompt shown, user prompts kept from one line, and a name with words
  /// after it sent as a message. A system prompt is not a message: the agent
  /// is switched to it, and the words after the name are sent as they are.
  static func handlePromptsCommand(
    _ argument: String,
    session: REPLSession,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async -> PromptsCommandOutcome {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let catalog =
      configuration?.promptCatalog(skills: skills.skills) ?? PromptCatalog(skills: skills.skills)

    switch action.lowercased() {
    case "", "list":
      await showPrompts(
        session: session, configuration: configuration, skills: skills, terminal: terminal)

    case "help":
      await terminal.line(promptHelp)

    case "show":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts show NAME")
        return .handled
      }
      guard let entry = catalog.entry(named: rest) else {
        await terminal.line("Unknown prompt '\(rest)'. /prompts lists them.")
        return .handled
      }
      let heading: String
      let text: String
      switch entry.kind {
      case .system:
        let users = configuration?.agentsUsingSystemPrompt(entry.name) ?? []
        heading =
          "System prompt '\(entry.name)' — \(users.isEmpty ? "unused" : "agents: \(users.joined(separator: ", "))"); $\(entry.commandName) [TEXT] switches this agent to it."
        text = entry.text
      case .skill:
        heading = "Skill '\(entry.name)' — \(entry.summary); $\(entry.commandName) [TEXT] sends:"
        text = entry.message(arguments: "") ?? entry.text
      case .user, .builtin:
        let label = entry.kind.label.prefix(1).uppercased() + entry.kind.label.dropFirst()
        heading = "\(label) '\(entry.name)'; $\(entry.commandName) [TEXT] sends:"
        text = entry.text
      }
      await terminal.line(heading)
      await terminal.line(text.isEmpty ? "(empty)" : text)

    case "add", "set", "new", "create":
      let parts = rest.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
      guard parts.count == 2 else {
        await terminal.line("Usage: /prompts \(action) NAME TEXT")
        return .handled
      }
      await storeUserPrompt(
        named: parts[0],
        text: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "edit":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts edit NAME   (/edit user NAME is the same)")
        return .handled
      }
      await editUserPrompt(
        named: rest,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompts del NAME")
        return .handled
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return .handled
      }
      guard let name = draft.userPromptName(matching: rest) else {
        let hint =
          catalog.entry(named: rest).map {
            switch $0.kind {
            case .system: " '\(rest)' is a system prompt: /prompt del drops one."
            case .builtin:
              " '\(rest)' is a builtin prompt, which stays; a user prompt of that name replaces it."
            case .skill: " '\(rest)' is a skill: /skills del NAME deletes it."
            case .user: ""
            }
          } ?? ""
        await terminal.line("Unknown user prompt '\(rest)'. /prompts lists them.\(hint)")
        return .handled
      }
      draft.removeUserPrompt(name)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        let command = PromptSlashCommand.commandName(for: name)
        let uncovered = UserPrompt.builtins.contains {
          PromptSlashCommand.normalized($0.commandName) == PromptSlashCommand.normalized(command)
        }
        await terminal.line(
          "Removed user prompt '\(name)'."
            + (uncovered ? " The builtin prompt of that name is back." : ""))
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    default:
      guard let entry = catalog.entry(named: action) else {
        await terminal.line(
          "Unknown prompt '\(action)'. /prompts lists them; a message that starts with $ can be sent inside <<EOF."
        )
        return .handled
      }
      switch entry.kind {
      case .system:
        return .selectSystemPrompt(entry.name, then: rest.isEmpty ? nil : rest)
      case .skill:
        guard let skill = entry.skill, isSkillEnabled(skill, profile: session.profile) else {
          await terminal.line(
            "Skill '\(entry.name)' has no enabled tool for this agent. /skills lists availability.")
          return .handled
        }
        return .send(skill.prompt(arguments: rest), title: "\(entry.name) \(rest)")
      case .user, .builtin:
        return .send(entry.message(arguments: rest) ?? rest, title: "\(entry.name) \(rest)")
      }
    }
    return .handled
  }

  @discardableResult

  private static func storeUserPrompt(
    named name: String,
    text: String,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedName.isEmpty else {
      await terminal.line("A user prompt needs a name.")
      return false
    }
    let created = draft.setUserPrompt(trimmedName, text: text)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      let command = PromptSlashCommand.commandName(for: trimmedName)
      let replaces = UserPrompt.builtins.contains {
        PromptSlashCommand.normalized($0.commandName) == PromptSlashCommand.normalized(command)
      }
      await terminal.line(
        "\(created ? "Created" : "Saved") user prompt '\(trimmedName)': $\(command) [TEXT] sends it"
          + (replaces ? " instead of the builtin prompt of that name." : "."))
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  /// Opens a user prompt in the editor; a new one named like a builtin
  /// prompt starts from the builtin's text, which is how one is adjusted.
  static func editUserPrompt(
    named requested: String,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /edit user NAME")
      return
    }
    let name = configuration?.userPromptName(matching: trimmed) ?? trimmed
    let command = PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: name))
    let previous =
      configuration?.prompts?.user[name]
      ?? UserPrompt.builtins.first { PromptSlashCommand.normalized($0.commandName) == command }?
      .text ?? ""
    guard
      let edited = await editTemporaryText(previous, suffix: "user-prompt.md", terminal: terminal)
    else { return }
    await storeUserPrompt(
      named: name,
      text: edited.trimmingCharacters(in: .whitespacesAndNewlines),
      configuration: &configuration,
      configurationPath: configurationPath,
      terminal: terminal)
  }

  /// `/prompt` in full: named system prompts are created, edited, dropped,
  /// and pointed at from one line each; the bare name still selects one for
  /// the current agent.
  static func handlePromptCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    skills: AgentSkillCatalog,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

    switch action {
    case "":
      let name = session.profile.systemPrompt ?? "inline"
      await terminal.line("System prompt for agent '\(session.profile.agentID)': \(name)")
      await terminal.line(
        session.profile.instructions.isEmpty ? "(empty)" : session.profile.instructions)

    case "list":
      await showPrompts(
        session: session, configuration: configuration, skills: skills, terminal: terminal)

    case "show":
      let requested = rest.isEmpty ? session.profile.systemPrompt ?? "" : rest
      guard let name = resolvedSystemPromptName(requested, configuration: configuration),
        let text = (configuration ?? .init()).systemPrompt(named: name)?.text
      else {
        await terminal.line("Unknown system prompt '\(requested)'. /prompts lists them.")
        return
      }
      let users = configuration?.agentsUsingSystemPrompt(name) ?? []
      await terminal.line(
        "System prompt '\(name)' — \(users.isEmpty ? "unused" : "agents: \(users.joined(separator: ", "))")"
      )
      await terminal.line(text.isEmpty ? "(empty)" : text)

    case "add", "set", "new", "create":
      let parts = rest.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(String.init)
      guard parts.count == 2 else {
        await terminal.line("Usage: /prompt \(action) NAME TEXT")
        return
      }
      await storeSystemPrompt(
        named: parts[0],
        text: parts[1].trimmingCharacters(in: .whitespacesAndNewlines),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "edit":
      await editSystemPrompt(
        named: rest.isEmpty ? session.profile.systemPrompt ?? session.profile.agentID : rest,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "del":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompt del NAME")
        return
      }
      guard var draft = configuration, let configurationPath else {
        await terminal.line("error: No writable configuration is active.", to: .standardError)
        return
      }
      guard let name = resolvedSystemPromptName(rest, configuration: draft) else {
        await terminal.line("Unknown system prompt '\(rest)'. /prompts lists them.")
        return
      }
      let users = draft.agentsUsingSystemPrompt(name)
      guard users.isEmpty else {
        await terminal.line(
          "System prompt '\(name)' is used by \(users.joined(separator: ", ")). Point them elsewhere first: /agent prompt ID OTHER."
        )
        return
      }
      draft.removeSystemPrompt(name)
      do {
        try draft.save(to: URL(fileURLWithPath: configurationPath))
        configuration = draft
        await terminal.line(
          draft.systemPrompt(named: name) == nil
            ? "Removed system prompt '\(name)'." : "Restored built-in system prompt '\(name)'.")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }

    case "use", "select":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /prompt use NAME")
        return
      }
      await selectSystemPrompt(
        rest,
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)

    case "help":
      await terminal.line(promptHelp)

    default:
      // `/prompt NAME` keeps selecting a prompt for the current agent.
      await selectSystemPrompt(
        argument.trimmingCharacters(in: .whitespacesAndNewlines),
        session: &session,
        runtime: runtime,
        configuration: &configuration,
        configurationPath: configurationPath,
        terminal: terminal)
    }
  }

  /// Points the current agent at a named prompt and saves the association.
  static func selectSystemPrompt(
    _ requested: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard
      let name = resolvedSystemPromptName(requested, configuration: configuration),
      let instructions = (configuration ?? .init()).systemPrompt(named: name)?.text
    else {
      await terminal.line(
        "Unknown system prompt '\(requested)'. /prompts lists them; /prompt add NAME TEXT creates one."
      )
      return
    }
    let previous = session.profile.instructions
    do {
      try applySystemInstructions(instructions, replacing: previous, session: &session)
      session.profile.systemPrompt = name
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return
    }
    if await persistAgentProfile(
      session: session,
      configuration: &configuration,
      configurationPath: configurationPath,
      runtime: runtime,
      terminal: terminal)
    {
      await terminal.line(
        "Agent '\(session.profile.agentID)' now uses system prompt '\(name)'.")
    }
  }

  /// Writes one named system prompt and refreshes every agent that uses it,
  /// in the file, in the live runtime, and in this chat when it is one of
  /// them. Answers false, having said why, when nothing was saved.
  @discardableResult

  private static func storeSystemPrompt(
    named name: String,
    text: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async -> Bool {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return false
    }
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      await terminal.line("A system prompt needs a name.")
      return false
    }
    let created = draft.prompts?.system[name] == nil
    let refreshed = draft.setSystemPrompt(name, text: text)
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      for agent in draft.agents where refreshed.contains(agent.id) {
        try await runtime.register(agent: agent, replacingExisting: true)
      }
      if session.profile.systemPrompt == name {
        try applySystemInstructions(
          text, replacing: session.profile.instructions, session: &session)
      }
      let usage: String
      if !refreshed.isEmpty {
        usage = "used by \(refreshed.joined(separator: ", "))"
      } else if name.lowercased() == "voice" {
        usage = "used by /voice"
      } else if name.lowercased() == "voiceover" {
        usage = "used for voiceover"
      } else {
        usage = "no agent uses it yet; /agent prompt ID \(name) or /agent add picks it"
      }
      await terminal.line("\(created ? "Created" : "Saved") system prompt '\(name)' (\(usage)).")
      return true
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return false
    }
  }

  static func applySystemInstructions(
    _ instructions: String,
    replacing previous: String,
    session: inout REPLSession
  ) throws {
    session.profile.instructions = instructions
    if let index = session.history.messages.firstIndex(where: {
      $0.role == .system && $0.text == previous
    }) {
      if instructions.isEmpty {
        _ = try session.history.removeMessage(at: index)
      } else {
        try session.history.editMessage(at: index, text: instructions)
      }
    } else if !instructions.isEmpty {
      session.history.replaceAll(with: [.system(instructions)] + session.history.messages)
    }
    session.touch()
  }

  static func editSystemPrompt(
    named requested: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard configuration != nil, configurationPath != nil else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /prompt edit [NAME]")
      return
    }
    let name = resolvedSystemPromptName(trimmed, configuration: configuration) ?? trimmed
    let previous = (configuration ?? .init()).systemPrompt(named: name)?.text ?? ""
    guard
      let edited = await editTemporaryText(
        previous, suffix: "system-prompt.md", terminal: terminal)
    else { return }
    await storeSystemPrompt(
      named: name,
      text: edited.trimmingCharacters(in: .whitespacesAndNewlines),
      session: &session,
      runtime: runtime,
      configuration: &configuration,
      configurationPath: configurationPath,
      terminal: terminal)
  }
}
