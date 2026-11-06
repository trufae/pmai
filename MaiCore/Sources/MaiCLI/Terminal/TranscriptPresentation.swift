import Foundation
import MaiCore

extension MaiCLI {
  static func conversationLog(
    session: REPLSession,
    full: Bool,
    includeDetails: Bool,
    short: Bool = false,
    terminal: TerminalWriter
  ) async -> String {
    guard !session.history.isEmpty else { return "No conversation messages yet." }
    var lines = [
      full
        ? await terminal.paintHeading(includeDetails ? "# Full conversation log" : "# Conversation log")
        : await terminal.paintHeading("Conversation log:")
    ]
    if !full { lines.append(await terminal.paint("-----------------", role: .thinkingForeground)) }
    for (index, storedMessage) in session.history.messages.enumerated() {
      var message = storedMessage
      if full && !includeDetails && !short {
        guard message.role != .tool else { continue }
        message.content.removeAll { part in
          switch part {
          case .reasoning, .toolCall, .toolResult: true
          case .text(let text): text.isEmpty
          default: false
          }
        }
        guard !message.content.isEmpty else { continue }
      }
      let role = message.role.rawValue.capitalized
      let pin = message.isPinned ? "📌 " : ""
      if short {
        lines.append(renderShortChatMessage(message, index: index))
      } else if full {
        lines.append(
          "\n" + (await renderChatMessage(message, index: index, terminal: terminal)))
        lines.append("--------------------")
      } else {
        let roleColor: TerminalThemeStyle = switch message.role {
        case .user: .infoForeground
        case .assistant: .successForeground
        case .tool: .toolCallForeground
        case .system, .developer: .thinkingForeground
        }
        let number = await terminal.paint("[\(index + 1)]", role: .infoForeground, bold: true)
        let pinMarker = await terminal.paint(pin, role: .warningForeground, bold: true)
        let label = await terminal.paint(role, role: roleColor, bold: true)
        let identifier = await terminal.paint("(id: \(message.id))", role: .thinkingForeground)
        lines.append("\(number) \(pinMarker)\(label) \(identifier): \(messagePreview(message))")
      }
    }
    let total = "Total messages: \(session.history.count)"
    lines.append("\n" + (full ? total : await terminal.paint(total, role: .thinkingForeground)))
    if !session.pendingContent.isEmpty {
      lines.append(
        "Pending for next message: \(session.pendingContent.map(renderCompactContent).joined(separator: ", "))"
      )
    }
    return lines.joined(separator: "\n")
  }

  static func renderShortChatMessage(_ message: AgentMessage, index: Int) -> String {
    let text = TranscriptCopy.render(message)
    let preview = TranscriptCopy.firstParagraph(text.isEmpty ? message.content.map(renderCompactContent).joined(separator: "\n") : text)
    return "[\(index + 1)] \(message.isPinned ? "📌 " : "")\(message.role.rawValue.capitalized) (id: \(message.id)): \(preview.isEmpty ? "[empty message]" : preview)"
  }

  static func renderChatMessage(
    _ message: AgentMessage,
    index: Int,
    count: Int? = nil,
    terminal: TerminalWriter
  ) async -> String {
    let position = "\(index + 1)" + (count.map { "/\($0)" } ?? "")
    let heading = await terminal.paintHeading(
      "## [\(position)] \(message.isPinned ? "📌 " : "")\(message.role.rawValue.capitalized) (id: \(message.id))")
    let renderer = await terminal.markdownRenderer
    let body = message.content.map { part in
      renderFullContent(part) { text in
        guard let renderer else { return text }
        var rendered = renderer.render(text)
        while rendered.hasSuffix("\n") { rendered.removeLast() }
        return rendered
      }
    }.joined(separator: "\n")
    return heading + "\n" + body
  }

  static func messagePreview(_ message: AgentMessage) -> String {
    let rendered = message.content.map(renderCompactContent).joined(separator: " ")
      .replacingOccurrences(of: "\n", with: " ")
    guard rendered.count > 120 else { return rendered }
    return String(rendered.prefix(117)) + "..."
  }

  private static func renderCompactContent(_ part: ContentPart) -> String {
    switch part {
    case .text(let text):
      text
    case .image(let image):
      "[image \(image.name ?? image.mimeType)]"
    case .file(let file):
      "[file \(file.name)]"
    case .audio(let audio):
      "[audio \(audio.name ?? audio.mimeType)]"
    case .resource(let resource):
      "[resource \(resource.name ?? resource.uri)]"
    case .reasoning(let reasoning):
      "[reasoning] \(reasoning)"
    case .toolCall(let call):
      "[tool call \(call.name) \(call.arguments.compactJSONString)]"
    case .toolResult(let result):
      "[tool result \(result.callID)\(result.isError ? " error" : "")] \(result.text)"
    }
  }

  static func renderFullContent(
    _ part: ContentPart,
    renderText: (String) -> String = { $0 }
  ) -> String {
    switch part {
    case .text(let text):
      return renderText(text)
    case .image(let image):
      return
        "[image name=\(image.name ?? "-") mime=\(image.mimeType) source=\(binarySourceSummary(image.source))]"
    case .file(let file):
      return
        "[file name=\(file.name) mime=\(file.mimeType)\(file.source.map { " source=\(binarySourceSummary($0))" } ?? "")]\(file.text.map { "\n\($0)" } ?? "")"
    case .audio(let audio):
      return
        "[audio name=\(audio.name ?? "-") mime=\(audio.mimeType) source=\(binarySourceSummary(audio.source))]"
    case .resource(let resource):
      return
        "[resource name=\(resource.name ?? "-") uri=\(resource.uri) mime=\(resource.mimeType ?? "-")]\(resource.text.map { "\n\($0)" } ?? "")"
    case .reasoning(let reasoning):
      return "[reasoning]\n\(renderText(reasoning))"
    case .toolCall(let call):
      return "[tool call name=\(call.name) id=\(call.id)]\n\(call.arguments.compactJSONString)"
    case .toolResult(let result):
      var value = "[tool result call=\(result.callID) status=\(result.isError ? "error" : "ok")]"
      if !result.content.isEmpty {
        value +=
          "\n"
          + result.content.map { renderFullContent($0, renderText: renderText) }
            .joined(separator: "\n")
      }
      if let structured = result.structuredContent {
        value += "\n[structured content]\n\(structured.compactJSONString)"
      }
      return value
    }
  }

  private static func binarySourceSummary(_ source: BinarySource) -> String {
    switch source {
    case .data(let data): "inline:\(data.count)-bytes"
    case .url(let url): url.absoluteString
    }
  }
}
