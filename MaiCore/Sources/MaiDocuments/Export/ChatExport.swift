import Foundation
import MaiCore

/// The files a chat can be saved as.
public enum ChatExportFormat: String, CaseIterable, Sendable {
  case markdown
  case json
  /// The JSON envelope plus what the host knows about how the chat ran.
  case debug
  case html
  case epub
  case docx

  public var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .json, .debug: "json"
    case .html: "html"
    case .epub: "epub"
    case .docx: "docx"
    }
  }

  public var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .json: "JSON"
    case .debug: "Debug JSON"
    case .html: "HTML"
    case .epub: "EPUB"
    case .docx: "Word"
    }
  }

  /// Accepts what people type: `md`, `word`, `doc`, `debug-json`.
  public init?(argument: String) {
    switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "markdown", "md": self = .markdown
    case "json": self = .json
    case "debug", "debug-json", "debugjson": self = .debug
    case "html", "htm": self = .html
    case "epub": self = .epub
    case "docx", "doc", "word": self = .docx
    default: return nil
    }
  }
}

/// One process a run of this chat started, with its own transcript. The
/// chat's messages hold only the parent's `agent_*` call and the child's
/// answer; what the child was told, which tools it called, and how it ended
/// are here, so a debug export shows the whole run. It is the record a chat
/// file keeps for the same purpose, so an export and a saved chat agree.
public typealias ChatExportSubagent = AgentProcessRecord

/// What the host knows about how the chat was run, for the debug export: the
/// tools the model was offered, the child agents its runs started, and
/// whatever else it wants to record.
public struct ChatExportDebug: Codable, Equatable, Sendable {
  public var provider: String
  public var providerDisplayName: String?
  public var toolDefinitions: [ToolDefinition]
  /// Free-form facts such as the working directory or the tool strategy.
  public var settings: [String: String]
  /// Child agents of this chat's runs, parents before children, each with
  /// its transcript.
  public var subagents: [ChatExportSubagent]

  public init(
    provider: String,
    providerDisplayName: String? = nil,
    toolDefinitions: [ToolDefinition] = [],
    settings: [String: String] = [:],
    subagents: [ChatExportSubagent] = []
  ) {
    self.provider = provider
    self.providerDisplayName = providerDisplayName
    self.toolDefinitions = toolDefinitions
    self.settings = settings
    self.subagents = subagents
  }

  /// Exports written before subagents were recorded still decode.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(String.self, forKey: .provider)
    providerDisplayName = try container.decodeIfPresent(String.self, forKey: .providerDisplayName)
    toolDefinitions =
      try container.decodeIfPresent([ToolDefinition].self, forKey: .toolDefinitions) ?? []
    settings = try container.decodeIfPresent([String: String].self, forKey: .settings) ?? [:]
    subagents = try container.decodeIfPresent([ChatExportSubagent].self, forKey: .subagents) ?? []
  }
}

/// The JSON export: the chat as stored, wrapped with where it came from. It
/// decodes back, so a chat can be moved between machines and hosts.
public struct ChatExportEnvelope: Codable, Equatable, Sendable {
  public static let format = "maicore.chat"

  public var format: String
  public var version: Int
  public var title: String
  public var agent: String
  public var provider: String
  public var model: String
  public var generator: String
  public var exportedAt: Date
  public var chat: AgentChat
  public var debug: ChatExportDebug?

  public init(
    chat: AgentChat,
    generator: String,
    exportedAt: Date = Date(),
    debug: ChatExportDebug? = nil
  ) {
    format = Self.format
    version = 1
    title = chat.displayTitle
    agent = chat.primaryAgent.id
    provider = chat.primaryAgent.provider.rawValue
    model = chat.primaryAgent.model
    self.generator = generator
    self.exportedAt = exportedAt
    self.chat = chat
    self.debug = debug
  }
}

/// Turns a MaiCore chat into any export format.
public enum ChatExport {
  /// Readable documents omit tool traffic and thinking unless requested.
  public static func document(
    for chat: AgentChat,
    generator: String = "MaiCore",
    includeToolTraffic: Bool = false,
    includeThinking: Bool = false
  ) -> ExportDocument {
    var entries: [ExportEntry] = []
    for message in chat.messages {
      if message.role == .tool && !includeToolTraffic { continue }
      var body: [String] = []
      var reasoning: [String] = []
      var attachments: [ExportImage] = []
      for part in message.content {
        switch part {
        case .text(let text):
          let rendered = MessageContentFilter.render(text)
          body.append(rendered.visibleText)
          if includeThinking {
            reasoning.append(
              contentsOf: rendered.hiddenSections.filter { $0.tag == "think" }.map(\.content))
          }
          if includeToolTraffic {
            body.append(
              contentsOf: rendered.hiddenSections.filter {
                $0.tag == "tool_call" || $0.tag == "tool_run"
              }.map { fenced($0.content) })
          }
        case .reasoning(let text):
          if includeThinking { reasoning.append(text) }
        case .image(let image):
          switch image.source {
          case .data(let data):
            attachments.append(
              ExportImage(
                name: image.name ?? "Image \(attachments.count + 1)",
                mediaType: image.mimeType, data: data, width: image.width, height: image.height))
          case .url(let url):
            body.append("![\(image.name ?? "image")](\(url.absoluteString))")
          }
        case .file(let file):
          if let text = file.text, !text.isEmpty {
            body.append("**\(file.name)**\n\n" + fenced(text))
          } else {
            body.append("*Attached: \(file.name)*")
          }
        case .audio(let audio):
          body.append("*Audio: \(audio.name ?? audio.mimeType)*")
        case .resource(let resource):
          if let text = resource.text, !text.isEmpty { body.append(text) }
        case .toolCall(let call):
          guard includeToolTraffic else { continue }
          body.append(fenced("→ \(call.name) \(call.arguments.compactJSONString)"))
        case .toolResult(let result):
          guard includeToolTraffic else { continue }
          body.append(fenced("← \(result.isError ? "error" : "result")\n\(result.text)"))
        }
      }
      let role: ExportRole =
        switch message.role {
        case .user: .user
        case .assistant: .assistant
        case .system, .developer: .system
        case .tool: .tool
        }
      let entry = ExportEntry(
        role: role,
        reasoning: reasoning,
        body: body.joined(separator: "\n\n"),
        attachments: attachments)
      if !entry.isEmpty { entries.append(entry) }
    }
    return ExportDocument(
      identifier: chat.id,
      title: chat.displayTitle,
      createdAt: chat.createdAt,
      updatedAt: chat.updatedAt,
      generator: generator,
      entries: entries)
  }

  public static func data(
    for chat: AgentChat,
    format: ChatExportFormat,
    generator: String = "MaiCore",
    debug: ChatExportDebug? = nil,
    options: DocumentExportOptions = .init()
  ) throws -> Data {
    func exportDocument() -> ExportDocument {
      document(
        for: chat, generator: generator,
        includeToolTraffic: options.includeToolCalls, includeThinking: options.includeThinking)
    }
    switch format {
    case .markdown:
      return Data(MarkdownExport.text(for: exportDocument()).utf8)
    case .json, .debug:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let envelope = ChatExportEnvelope(
        chat: chat, generator: generator, debug: format == .debug ? debug : nil)
      return try encoder.encode(envelope)
    case .html:
      return HTMLExport.data(for: exportDocument())
    case .epub:
      return EPUBExport.data(for: exportDocument())
    case .docx:
      return DOCXExport.data(for: exportDocument())
    }
  }

  /// A file name made from the title, safe on every file system.
  public static func filename(for chat: AgentChat, format: ChatExportFormat) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
    let words = chat.displayTitle.components(separatedBy: invalid).joined(separator: " ")
      .split(whereSeparator: \.isWhitespace)
    var name = words.joined(separator: " ")
    if name.count > 80 { name = String(name.prefix(80)) }
    // A title ending in a period would otherwise read "title..md".
    name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    if name.isEmpty { name = "chat" }
    return name + "." + format.fileExtension
  }

  /// A fenced block that survives backticks in the text.
  private static func fenced(_ text: String) -> String {
    var fence = "```"
    while text.contains(fence) { fence += "`" }
    return fence + "\n" + text + "\n" + fence
  }
}
