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
  /// `/memory` in full: read it, edit it, extend it from what was said, and
  /// decide how far the chat tools may look.
  static func handleMemoryCommand(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    let fields = argument.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
      String.init)
    let action = fields.first?.lowercased() ?? ""
    let rest = fields.count > 1 ? fields[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    let settings = memory.configuration

    switch action {
    case "", "show":
      let current = memory.current
      let state = settings.enabled ? "on" : "off"
      await terminal.line(
        "Memory: \(state) · scope \(settings.scope.rawValue) · \(current.lineCount) line\(current.lineCount == 1 ? "" : "s")"
      )
      await terminal.line(current.isEmpty ? "(empty)" : current.text)

    case "edit":
      guard
        let edited = await editTemporaryText(
          memory.current.text, suffix: "memory.md", terminal: terminal)
      else { return }
      await store(
        AgentMemory(text: edited), in: memory, runtime: runtime, terminal: terminal)

    case "set", "replace":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory set TEXT")
        return
      }
      await store(AgentMemory(text: rest), in: memory, runtime: runtime, terminal: terminal)

    case "add", "append":
      guard !rest.isEmpty else {
        await terminal.line("Usage: /memory add TEXT")
        return
      }
      var updated = memory.current
      updated.append(rest)
      await store(updated, in: memory, runtime: runtime, terminal: terminal)

    case "clear":
      await store(AgentMemory(), in: memory, runtime: runtime, terminal: terminal)

    case "reload":
      memory.reload()
      await runtime.configureMemory(memory.promptSection)
      await terminal.line("Reloaded \(memory.url?.path ?? AgentMemory.filename).")

    case "learn":
      await learnMemory(
        rest,
        session: session,
        runtime: runtime,
        memory: memory,
        promptTemplate: configuration?.prompts?.memory,
        terminal: terminal)

    case "scope":
      guard !rest.isEmpty else {
        await terminal.line("Memory scope: \(settings.scope.rawValue)")
        return
      }
      guard let scope = MemoryScope(rawValue: rest.lowercased()) else {
        await terminal.line("Usage: /memory scope <none|project|all>")
        return
      }
      await persistMemorySettings(
        ConfiguredMemory(enabled: settings.enabled, scope: scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          "The chat tools now read \(scope == .none ? "nothing" : scope.displayName.lowercased()).",
        terminal: terminal)

    case "on", "off":
      await persistMemorySettings(
        ConfiguredMemory(enabled: action == "on", scope: settings.scope),
        memory: memory,
        configuration: &configuration,
        configurationPath: configurationPath,
        note:
          action == "on"
          ? "Memory is added to the system prompt again."
          : "Memory is kept but no longer sent to the model.",
        terminal: terminal)
      await runtime.configureMemory(memory.promptSection)

    default:
      await terminal.line(memoryHelp)
    }
  }

  static func store(
    _ updated: AgentMemory,
    in memory: MemoryState,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    do {
      try memory.save(updated)
      await runtime.configureMemory(memory.promptSection)
      await terminal.line(
        updated.isEmpty
          ? "Memory cleared."
          : "Memory saved to \(memory.url?.path ?? AgentMemory.filename) (\(updated.lineCount) line\(updated.lineCount == 1 ? "" : "s"))."
      )
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  private static func persistMemorySettings(
    _ settings: ConfiguredMemory,
    memory: MemoryState,
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    note: String,
    terminal: TerminalWriter
  ) async {
    memory.apply(settings)
    guard var draft = configuration, let configurationPath else {
      await terminal.line("\(note) (not saved: no writable configuration is active.)")
      return
    }
    draft.memory = settings
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(note)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Folds conversations into the notes. The model is given what is already
  /// known and returns the merged set, so learning never silently forgets.
  private static func learnMemory(
    _ argument: String,
    session: REPLSession,
    runtime: AgentRuntime,
    memory: MemoryState,
    promptTemplate: String?,
    terminal: TerminalWriter
  ) async {
    var focus = argument
    var everyChat = false
    for flag in ["--all", "-a"] where focus == flag || focus.hasPrefix(flag + " ") {
      everyChat = true
      focus = String(focus.dropFirst(flag.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let chats =
      everyChat ? memory.projectChats() : [MemoryChat(session.chat, scope: session.title)]
    let transcript = AgentMemoryPrompt.transcript(of: chats)
    guard !transcript.isEmpty else {
      await terminal.line(
        everyChat ? "No conversations in this project yet." : "Nothing said in this chat yet.")
      return
    }
    if let template = promptTemplate,
      let missing = AgentMemoryPrompt.missingPlaceholder(in: template)
    {
      await terminal.line(
        "error: The memory prompt must contain \(missing). Edit it with /edit memory-prompt.",
        to: .standardError)
      return
    }

    let existing = memory.current
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [
        .user(
          AgentMemoryPrompt.render(
            existing: existing,
            transcript: transcript,
            focus: focus,
            template: promptTemplate))
      ],
      toolChoice: .none,
      options: profile.options,
      limits: profile.limits,
      stream: false,
      sessionID: session.sessionID)
    await terminal.line(
      "Learning from \(everyChat ? "\(chats.count) chat\(chats.count == 1 ? "" : "s")" : "this chat")…"
    )
    do {
      let result = try await runtime.run(request) { _ in }
      let learned = MessageContentFilter.promptSafeText(
        from: session.redactor?.unredact(result.response.text) ?? result.response.text
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !learned.isEmpty else {
        await terminal.line("Nothing durable to remember; memory is unchanged.")
        return
      }
      await store(AgentMemory(text: learned), in: memory, runtime: runtime, terminal: terminal)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }
}
