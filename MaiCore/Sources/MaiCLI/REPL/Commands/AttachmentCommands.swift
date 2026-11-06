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
  /// `/reply` answers the last assistant message the way the reply action in
  /// the iOS app does: its text is quoted at the terminal width, `$EDITOR` opens on
  /// the quote with room underneath, and what the editor leaves is sent as if
  /// it had been typed at the prompt. An optional argument overrides the width.
  static func composeReply(
    _ argument: String,
    session: REPLSession,
    terminal: TerminalWriter
  ) async -> String? {
    let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    // Leave the terminal's final column unused to avoid an automatic wrap.
    // MarkdownQuote reserves two more columns for the `> ` marker, leaving
    // the quoted text itself the requested screen-width-minus-three columns.
    var width = max(3, TerminalLineEditor.terminalColumns() - 1)
    if !trimmed.isEmpty {
      guard let columns = Int(trimmed), columns > 2 else {
        await terminal.line(
          "Usage: /reply [WIDTH]   (the quote wraps to the screen width by default)"
        )
        return nil
      }
      width = columns
    }
    let reply: String
    do {
      reply = try TranscriptCopy.text(
        for: .lastAssistantReply, in: session.history.messages
      ).text
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      return nil
    }
    let quoted = MarkdownQuote.quote(reply, lineWidth: width)
    return await composeMessage(
      from: quoted + "\n\n",
      suffix: "reply.md",
      unchanged: "Reply cancelled: nothing was written under the quote.",
      terminal: terminal)
  }

  /// Compose without sending until the user has reviewed the editor's output.
  /// Cancellation restores the original; failed edits keep the last draft.
  static func composeInput(
    from original: String = "", command: String? = nil,
    editor: TerminalLineEditor, terminal: TerminalWriter
  ) async -> String? {
    var draft = original
    while true {
      guard let edited = await editTemporaryText(draft, suffix: "input.md", command: command, terminal: terminal) else {
        if !draft.isEmpty { editor.recoverInput(draft) }
        return nil
      }
      guard !edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        if !original.isEmpty { editor.recoverInput(original) }
        await terminal.line("Nothing to send: the editor left the file empty.")
        return nil
      }
      draft = edited
      await terminal.line("Edited prompt:\n" + draft)
      while true {
        let answer = editor.readLine(
          prompt: "input [send/edit/back/cancel]> ",
          completions: ["send", "edit", "back", "cancel"], rememberInput: false
        )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if editor.wasInterrupted || answer == nil || answer == "" || answer == "cancel" || answer == "c" {
          if !original.isEmpty { editor.recoverInput(original) }
          await terminal.line("Input cancelled; original draft restored.")
          return nil
        }
        switch answer {
        case "send", "s":
          return draft
        case "back", "b":
          editor.recoverInput(draft)
          await terminal.line("Edited input restored to the prompt; Enter sends it.")
          return nil
        case "edit", "e": break
        default:
          await terminal.line("Choose send, edit, back, or cancel (Enter cancels).")
          continue
        }
        break
      }
    }
  }

  /// Opens the editor on a draft message and returns what it left, for the
  /// caller to send as if it had been typed at the prompt. A file that comes
  /// back empty, or exactly as it went in, sends nothing.
  private static func composeMessage(
    from draft: String,
    suffix: String,
    unchanged note: String,
    terminal: TerminalWriter
  ) async -> String? {
    guard let edited = await editTemporaryText(draft, suffix: suffix, terminal: terminal)
    else { return nil }
    let message = edited.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty, message != draft.trimmingCharacters(in: .whitespacesAndNewlines)
    else {
      await terminal.line(note)
      return nil
    }
    return message
  }

  /// `/copy [N] [PATH]`: the last reply or the last N messages, on the system
  /// clipboard or, when PATH is given, in that file.
  static func copyToClipboard(
    _ argument: String,
    session: REPLSession,
    terminal: TerminalWriter
  ) async {
    if argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "help" {
      await terminal.line(copyHelp)
      return
    }
    do {
      let command = try TranscriptCopy.command(parsing: argument)
      let result = try TranscriptCopy.text(for: command.selection, in: session.history.messages)
      let count = result.messages.count
      let subject =
        command.selection == .lastAssistantReply
        ? "the last reply" : "\(count) message\(count == 1 ? "" : "s")"
      let destination: String
      if let path = command.path {
        destination = try writeCopiedText(result.text, to: path).path
      } else {
        try SystemClipboard.write(result.text)
        destination = "the clipboard"
      }
      await terminal.line(
        "Copied \(subject) (\(result.text.count) characters) to \(destination).")
    } catch let error as TranscriptCopyError {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
      if case .invalidCount = error { await terminal.line("Usage: /copy [N] [PATH] (/help copy)") }
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Writes `/copy` output to a file: `~` expands, a relative path resolves
  /// against the working directory, an existing file is replaced, and a folder
  /// is refused rather than inventing a name inside it. Text files end with a
  /// newline even though clipboard text does not.
  private static func writeCopiedText(_ text: String, to path: String) throws -> URL {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let expanded = NSString(string: path).expandingTildeInPath
    let target = URL(fileURLWithPath: expanded, relativeTo: current).standardizedFileURL
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if path.hasSuffix("/") || (exists && isDirectory.boolValue) {
      throw CLIError.isDirectory(target.path)
    }
    let parent = target.deletingLastPathComponent()
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw CLIError.missingFolder(parent.path) }
    let contents = text.hasSuffix("\n") ? text : text + "\n"
    try contents.write(to: target, atomically: true, encoding: .utf8)
    return target
  }

  /// `/attach PATH` converts a document to text the model can read and queues it
  /// for the next message; `/attach clear` drops everything queued so far.
  static func attachDocument(
    _ argument: String,
    session: inout REPLSession,
    ocrProvider: any OCRProvider,
    editor: TerminalLineEditor?,
    terminal: TerminalWriter
  ) async {
    var trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      await terminal.line("Usage: /attach [source|markdown|copy] PATH | /attach clear")
      await terminal.line(
        "Word, EPUB and PDF files become Markdown, JSON becomes an outline, arbitrary text/source files attach as they are, and images attach at medium size. HTML asks whether to attach its source, convert it to Markdown, or copy it into the working directory."
      )
      return
    }
    if trimmed.lowercased() == "clear" {
      let count = session.pendingContent.count
      session.pendingContent.removeAll()
      await terminal.line(
        count == 0
          ? "No pending attachments."
          : "Dropped \(count) pending attachment\(count == 1 ? "" : "s").")
      return
    }
    var htmlChoice: String?
    if trimmed.first != "\"" && trimmed.first != "'" {
      let fields = trimmed.split(maxSplits: 1, whereSeparator: \Character.isWhitespace).map(
        String.init)
      if fields.count == 2,
        ["source", "markdown", "copy"].contains(fields[0].lowercased())
      {
        htmlChoice = fields[0].lowercased()
        trimmed = fields[1]
      }
    }
    if trimmed.count >= 2, let first = trimmed.first, first == "\"" || first == "'",
      trimmed.last == first
    {
      trimmed = String(trimmed.dropFirst().dropLast())
    }
    let path = NSString(string: trimmed).expandingTildeInPath
    let url = URL(fileURLWithPath: path)
    do {
      let data = try DocumentAttachmentImporter.data(at: url)
      session.fileAccessLog.record(url)
      let kind = DocumentAttachmentImporter.kind(for: data, filename: url.lastPathComponent)
      if kind == .image {
        session.pendingContent.append(
          try await imageContent(path: path, mode: .medium, ocrProvider: ocrProvider))
        await terminal.line(
          "Image queued at medium size: \(url.lastPathComponent). Use /image for other sizes or OCR."
        )
        return
      }
      if htmlChoice != nil, kind != .html {
        await terminal.line(
          "error: source, markdown, and copy choices apply only to HTML files.",
          to: .standardError)
        return
      }
      if kind == .html, htmlChoice == nil {
        guard isatty(STDIN_FILENO) != 0, let editor else {
          await terminal.line(
            "HTML needs a choice: /attach source \(trimmed), /attach markdown \(trimmed), or /attach copy \(trimmed).",
            to: .standardError)
          return
        }
        await terminal.line(
          "Import \(url.lastPathComponent) as HTML source, Markdown, or a working-directory file?")
        let answer = editor.readLine(
          prompt: "html [source/markdown/copy/cancel]> ",
          completions: ["source", "markdown", "copy", "cancel"],
          rememberInput: false)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !editor.wasInterrupted, let answer, !["cancel", "c", ""].contains(answer) else {
          await terminal.line("HTML import cancelled.")
          return
        }
        switch answer {
        case "source", "s", "1": htmlChoice = "source"
        case "markdown", "md", "m", "2": htmlChoice = "markdown"
        case "copy", "file", "3": htmlChoice = "copy"
        default:
          await terminal.line("HTML import cancelled: unknown choice '\(answer)'.")
          return
        }
      }
      if htmlChoice == "copy" {
        let destination = try DocumentAttachmentImporter.copy(
          data: data,
          filename: url.lastPathComponent,
          into: URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true),
          sourceURL: url)
        await terminal.line("Copied HTML to \(destination.path).")
        return
      }
      let attachment = try DocumentAttachmentImporter.attachment(
        data: data,
        filename: url.lastPathComponent,
        htmlMode: htmlChoice == "markdown" ? .markdown : .source)
      session.pendingContent.append(attachment.content)
      var message = "Attached \(attachment.name) (\(attachment.characterCount) characters"
      if let note = attachment.note { message += ", \(note)" }
      message += "); it is sent with the next message."
      await terminal.line(message)
    } catch {
      await terminal.line("error: \(error.localizedDescription)", to: .standardError)
    }
  }

  /// Reads standard input to its end and attaches it as a text file, the way
  /// `/attach` does with a file on disk. With a message on the command line
  /// the run is one-shot; without one the REPL follows, so the terminal takes
  /// over as standard input, which needs one to exist.
  static func stdinAttachment(reopeningTerminal: Bool) throws -> ContentPart {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let attachment = try DocumentAttachmentImporter.attachment(data: data, filename: "stdin.txt")
    if reopeningTerminal {
      #if os(Windows)
        guard WindowsConsole.reopenStandardInputOnConsole() else {
          throw CLIError.stdinWithoutTerminal
        }
      #else
        let tty = open("/dev/tty", O_RDONLY)
        guard tty >= 0 else { throw CLIError.stdinWithoutTerminal }
        defer { close(tty) }
        guard dup2(tty, STDIN_FILENO) >= 0 else { throw CLIError.stdinWithoutTerminal }
      #endif
    }
    return attachment.content
  }

  static func imageContent(path: String) throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return .image(
      ImageContent(
        source: .data(loaded.data),
        mimeType: loaded.mimeType,
        name: loaded.url.lastPathComponent))
  }

  static func imageContent(
    path: String,
    mode: ImageAttachmentMode,
    ocrProvider: any OCRProvider
  ) async throws -> ContentPart {
    let loaded = try loadImage(path: path)
    return try await ImageAttachmentImporter.content(
      data: loaded.data,
      mimeType: loaded.mimeType,
      filename: loaded.url.lastPathComponent,
      mode: mode,
      ocrProvider: mode == .ocr ? ocrProvider : nil)
  }

  private static func loadImage(path: String) throws -> (data: Data, url: URL, mimeType: String) {
    let expanded = NSString(string: path).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
      throw CLIError.invalidImage(path)
    }
    let mimeType: String
    switch url.pathExtension.lowercased() {
    case "png": mimeType = "image/png"
    case "gif": mimeType = "image/gif"
    case "webp": mimeType = "image/webp"
    case "heic", "heif": mimeType = "image/heic"
    default: mimeType = "image/jpeg"
    }
    return (data, url, mimeType)
  }
}
