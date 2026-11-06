import Foundation
import MaiCore

extension MaiCLI {
  /// Message-level actions on the active transcript (/msg).
  static func handleMessageCommand(
    _ argument: String,
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter
  ) async {
    let parts = argument.split(maxSplits: 2, whereSeparator: \Character.isWhitespace).map(
      String.init)
    guard let action = parts.first?.lowercased(), !action.isEmpty else {
      await terminal.line(msgHelp)
      return
    }
    let actionArgument = String(argument.dropFirst(parts[0].count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    switch action {
    case "list":
      guard actionArgument.isEmpty else {
        await terminal.line("Usage: /msg list")
        return
      }
      await terminal.line(
        await conversationLog(
          session: session, full: false, includeDetails: false, terminal: terminal))
    case "log":
      let verbosity = actionArgument.lowercased()
      guard ["", "quiet", "verbose", "short"].contains(verbosity) else {
        await terminal.line("Usage: /msg log [quiet|verbose|short]")
        return
      }
      await terminal.line(
        await conversationLog(
          session: session, full: true, includeDetails: verbosity == "verbose",
          short: verbosity == "short",
          terminal: terminal))
    case "pin", "pins", "pinlist", "unpin":
      if action == "pins" || action == "pinlist" {
        let allowedArguments = action == "pins" ? ["", "short"] : [""]
        guard allowedArguments.contains(actionArgument.lowercased()) else {
          await terminal.line(action == "pins" ? "Usage: /msg pins [short]" : "Usage: /msg pinlist")
          return
        }
        let pinned = session.history.messages.enumerated().filter { $0.element.isPinned }
        guard !pinned.isEmpty else {
          await terminal.line("No pinned messages. Use /msg pin INDEX or MESSAGE_ID.")
          return
        }
        for (index, message) in pinned {
          if action == "pinlist" || actionArgument.lowercased() == "short" {
            await terminal.line(renderShortChatMessage(message, index: index))
          } else {
            await terminal.line(await renderChatMessage(message, index: index, terminal: terminal))
          }
        }
        return
      }
      let index: Int?
      if action == "pin" && actionArgument.isEmpty {
        guard !session.history.isEmpty else {
          await terminal.line("No messages to pin.")
          return
        }
        index = session.history.count - 1
      } else {
        index = parts.count == 2
          ? chatIndex(actionArgument, count: session.history.count)
            ?? session.history.index(ofMessageID: actionArgument)
          : nil
      }
      guard let index else {
        await terminal.line("Usage: /msg \(action) INDEX|MESSAGE_ID")
        return
      }
      let message = session.history[index]
      session.history.setMessagePinned(action == "pin", id: message.id)
      session.touch()
      await terminal.line("\(action == "pin" ? "📌 Pinned" : "Unpinned") message \(index + 1) (id: \(message.id)).")
    case "last":
      if let message = session.history.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
        await terminal.line(await terminal.render(message.text))
      } else {
        await terminal.line("No assistant response in the chat history.")
      }
    case "edit":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /msg edit INDEX [TEXT]")
        return
      }
      guard parts.count == 3 else {
        await editChatMessage(at: index, session: &session, terminal: terminal)
        return
      }
      do {
        try session.history.editMessage(at: index, text: parts[2])
        await terminal.line("Edited message \(index + 1).")
      } catch {
        await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      }
    case "del", "delete", "rm":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /msg del INDEX")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "undo":
      let index: Int?
      if parts.count >= 2 {
        index = chatIndex(parts[1], count: session.history.count)
      } else {
        index = session.history.messages.lastIndex(where: { $0.role != .system })
      }
      guard let index else {
        await terminal.line(
          session.history.isEmpty ? "No messages to undo." : "No conversation messages to undo.")
        return
      }
      await removeChatMessage(at: index, session: &session, terminal: terminal)
    case "trim":
      guard parts.count >= 2, let index = chatIndex(parts[1], count: session.history.count) else {
        await terminal.line("Usage: /msg trim INDEX")
        return
      }
      await trimChatMessages(through: index, session: &session, terminal: terminal)
    case "rewind":
      guard actionArgument.isEmpty else {
        await terminal.line("Usage: /msg rewind")
        return
      }
      await rewindChatToLastPin(session: &session, terminal: terminal)
    case "chop":
      await terminal.line("Use /msg chop at the REPL prompt to browse and remove messages interactively.")
    case "help":
      await terminal.line(msgHelp)
    default:
      await terminal.line("Unknown /msg action '\(action)'.\n\n\(msgHelp)")
    }
  }

  static func removeChatMessage(
    at index: Int,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    do {
      let removed = try session.history.removeMessage(at: index)
      let suffix = removed.count == 1 ? "" : " (including linked tool messages)"
      await terminal.line(
        "Removed \(removed.count) message\(removed.count == 1 ? "" : "s")\(suffix).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func trimChatMessages(
    through index: Int,
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    do {
      let removed = try session.history.trim(through: index)
      if removed.isEmpty {
        await terminal.line("Nothing follows message \(index + 1).")
      } else {
        await terminal.line(
          "Trimmed \(removed.count) message\(removed.count == 1 ? "" : "s"); kept through message \(session.history.count)."
        )
      }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Trims the conversation to the newest pinned message, if there is one.
  private static func rewindChatToLastPin(
    session: inout REPLSession,
    terminal: TerminalWriter
  ) async {
    guard let index = session.history.messages.lastIndex(where: { $0.isPinned }) else {
      await terminal.line(
        "error: No pinned message to rewind to. Pin one with /msg pin [INDEX|MESSAGE_ID].",
        to: .standardError)
      return
    }
    do {
      let removed = try session.history.trim(through: index)
      session.touch()
      let kept = session.history.count
      if removed.isEmpty {
        await terminal.line("Already at pinned message \(index + 1); nothing to rewind.")
      } else {
        let dropped = kept <= index
          ? " An unfinished tool transaction around it was removed too."
          : ""
        await terminal.line(
          "Rewound to pinned message \(index + 1); removed \(removed.count) newer message\(removed.count == 1 ? "" : "s").\(dropped)"
        )
      }
      // Show where the conversation landed, so the rewind point is visible.
      if session.history.messages.indices.contains(index) {
        let landed = session.history.messages[index]
        let preview = messagePreview(landed)
        if !preview.isEmpty {
          await terminal.line(
            "\(landed.isPinned ? "📌 " : "")\(landed.role.rawValue.capitalized): \(preview)")
        }
      }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  static let defaultCompactPrompt = AgentCompactionPrompt.template

  static func editRecapPrompt(
    configuration: inout MaiConfiguration?,
    configurationPath: String?,
    terminal: TerminalWriter
  ) async {
    guard var draft = configuration, let configurationPath else {
      await terminal.line("error: No writable configuration is active.", to: .standardError)
      return
    }
    guard let edited = await editTemporaryText(
      draft.prompts?.recap ?? AgentRecapPrompt.template,
      suffix: "recap-prompt.md", terminal: terminal)
    else { return }
    let candidate = edited.trimmingCharacters(in: .whitespacesAndNewlines)
    if let missing = AgentCompactionPrompt.missingPlaceholder(in: candidate) {
      await terminal.line(
        "error: The recap prompt must contain \(missing); no changes were saved.",
        to: .standardError)
      return
    }
    var prompts = draft.prompts ?? ConfiguredPrompts()
    prompts.recap = candidate.isEmpty || candidate == AgentRecapPrompt.template ? nil : candidate
    draft.prompts = prompts
    do {
      try draft.save(to: URL(fileURLWithPath: configurationPath))
      configuration = draft
      await terminal.line(
        prompts.recap == nil
          ? "Recap prompt restored to the built-in default."
          : "Recap prompt saved to \(configurationPath).")
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Both summaries use the compact model. A recap only prints its result;
  /// compaction replaces the transcript while retaining system instructions.
  static func summarizeChat(
    recap: Bool,
    focus: String,
    promptTemplate: String?,
    session: inout REPLSession,
    runtime: AgentRuntime,
    terminal: TerminalWriter,
    announceCompaction: Bool = true
  ) async {
    let action = recap ? "recap" : "compact"
    let transcript = recap
      ? AgentRecapPrompt.transcript(of: session.history.messages)
      : AgentCompactionPrompt.transcript(of: session.history.messages)
    let spoken = session.history.messages.filter {
      ($0.role == .user || $0.role == .assistant)
        && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    guard recap ? !transcript.isEmpty : spoken.count >= 2 else {
      await terminal.line("Nothing to \(action) yet.")
      return
    }
    let configuredTemplate = promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard configuredTemplate.isEmpty || configuredTemplate.contains("{{transcript}}") else {
      await terminal.line(
        "error: The \(action) prompt must contain {{transcript}}. Edit it with /edit \(recap ? "prompt recap" : "compact").",
        to: .standardError)
      return
    }
    // Compaction shares its template with autocompact; recap has its own
    // reader-facing template while using the same inference settings.
    let profile = session.profile
    let request = AgentRequest(
      agentID: profile.agentID,
      provider: profile.provider,
      model: profile.model,
      messages: [],
      toolNames: [],
      subagentNames: [],
      toolChoice: .none,
      responseFormat: .text,
      options: profile.options,
      limits: profile.limits,
      stream: false,
      toolCallingStrategy: .automatic,
      useToolProxy: true,
      retry: profile.retry,
      sessionID: session.sessionID)
    await terminal.line(recap ? "Recapping conversation…" : "Compacting conversation…")
    do {
      let reply = try await runtime.summarize(
        transcript, request: request,
        renderPrompt: { source in
          recap
            ? AgentRecapPrompt.render(transcript: source, template: configuredTemplate)
            : AgentCompactionPrompt.render(
              transcript: source, focus: focus, template: configuredTemplate)
        }, emit: { event in
          if case .retrying = event { await terminal.consume(event) }
        })
      try Task.checkCancellation()
      let summary = MessageContentFilter.textWithoutReasoning(
        from: session.redactor?.unredact(reply) ?? reply
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !summary.isEmpty else {
        await terminal.line(
          "error: \(action.capitalized) returned an empty summary.", to: .standardError)
        return
      }
      if recap {
        await terminal.line(await terminal.render(summary))
        return
      }
      session.history.replaceAll(with: AgentTranscriptEditor.compactingConversation(
        session.history.messages, summary: summary))
      session.pendingContent.removeAll()
      session.touch()
      if announceCompaction { await terminal.line("Conversation compacted into a summary.") }
    } catch is CancellationError {
      // The interactive loop reports cancellation and keeps the source chat.
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  static func chatIndex(_ raw: String, count: Int) -> Int? {
    ListIndex.resolve(raw, count: count)
  }
}
