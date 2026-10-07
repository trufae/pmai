import Foundation
import Testing

@testable import MaiCore
@testable import MaiDocuments
@testable import MaiMarkdown

@Test("The block parser covers headings, paragraphs, quotes, lists, fences, tables, rules and footnotes")
func blockParserCoversCommonBlocks() {
  let text = """
    # Title
    Para line one
    line two

    > quoted
    > more

    - a
    - b
      continued
    1. first
    2. second
    - [x] done
    - [ ] todo
    ```swift
    let x = 1
    ```
    | h1 | h2 |
    | --- | ---: |
    | c1 | c2 |
    ---
    [^1]: note
    """
  let blocks = MarkdownBlockParser.blocks(from: text)
  #expect(blocks.count == 10)
  #expect(blocks[0] == .heading(level: 1, text: "Title"))
  #expect(blocks[1] == .paragraph("Para line one\nline two"))
  #expect(blocks[2] == .quote("quoted\nmore"))
  #expect(blocks[3] == .bullets(["a", "b continued"]))
  guard case .ordered(let ordered) = blocks[4] else { Issue.record("expected an ordered list"); return }
  #expect(ordered.map(\.text) == ["first", "second"])
  #expect(blocks[5] == .tasks([MarkdownTaskItem(checked: true, text: "done"), MarkdownTaskItem(checked: false, text: "todo")]))
  #expect(blocks[6] == .code(language: "swift", code: "let x = 1"))
  guard case .table(let table) = blocks[7] else { Issue.record("expected a table"); return }
  #expect(table.headers == ["h1", "h2"])
  #expect(table.rows == [["c1", "c2"]])
  #expect(table.alignments == [.leading, .trailing])
  #expect(blocks[8] == .rule)
  guard case .footnotes(let notes) = blocks[9] else { Issue.record("expected footnotes"); return }
  #expect(notes.map(\.text) == ["note"])
}

@Test("A chat exports to markdown, HTML, EPUB, DOCX and a JSON envelope that decodes back")
func chatExportsToEveryFormat() throws {
  let chat = sampleChat()

  let markdown = String(decoding: try ChatExport.data(for: chat, format: .markdown, generator: "pmai"), as: UTF8.self)
  #expect(markdown.hasPrefix("# Export sample\n"))
  #expect(markdown.contains("## You\n\nHello **there**"))
  #expect(!markdown.contains("thinking hard"))
  #expect(!markdown.contains("→ echo"))
  #expect(!markdown.contains("← result"))
  #expect(markdown.contains("*Attached image: dot.gif*"))

  let html = String(
    decoding: try ChatExport.data(for: chat, format: .html, generator: "pmai"),
    as: UTF8.self)
  #expect(html.hasPrefix("<!DOCTYPE html>"))
  #expect(html.contains("<meta name=\"generator\" content=\"pmai\"/>"))
  #expect(html.contains("<h1 class=\"role\">You</h1>"))
  #expect(html.contains("<p>Hello <strong>there</strong></p>"))
  #expect(html.contains("src=\"data:image/gif;base64,"))

  let epub = try ZipArchiveReader.entries(in: try ChatExport.data(for: chat, format: .epub, generator: "pmai"))
  #expect(epub.first?.path == "mimetype")
  #expect(epub.first.map { String(decoding: $0.data, as: UTF8.self) } == "application/epub+zip")
  let opf = try #require(epub.first { $0.path == "OEBPS/content.opf" })
  #expect(String(decoding: opf.data, as: UTF8.self).contains("<dc:title>Export sample</dc:title>"))
  let chapter = try #require(epub.first { $0.path == "OEBPS/msg001.xhtml" })
  let xhtml = String(decoding: chapter.data, as: UTF8.self)
  #expect(xhtml.contains("<h1 class=\"role\">You</h1>"))
  #expect(xhtml.contains("<p>Hello <strong>there</strong></p>"))
  #expect(xhtml.contains("<img src=\"images/image001.gif\""))
  #expect(epub.contains { $0.path == "OEBPS/images/image001.gif" })
  #expect(!epub.contains { $0.path == "OEBPS/msg003.xhtml" })
  let final = try #require(epub.first { $0.path == "OEBPS/msg002.xhtml" })
  let finalHTML = String(decoding: final.data, as: UTF8.self)
  #expect(finalHTML.contains("<pre><code class=\"language-swift\"><span class=\"syntax-keyword\">let</span> x = <span class=\"syntax-number\">1</span></code></pre>"))
  #expect(finalHTML.contains("<a href=\"https://example.com/\">a link</a>"))

  let docx = try ZipArchiveReader.entries(in: try ChatExport.data(for: chat, format: .docx, generator: "pmai"))
  let document = try #require(docx.first { $0.path == "word/document.xml" })
  let wordXML = String(decoding: document.data, as: UTF8.self)
  #expect(wordXML.contains("<w:t xml:space=\"preserve\">Hello </w:t>"))
  #expect(wordXML.contains("<w:rPr><w:b/></w:rPr><w:t xml:space=\"preserve\">there</w:t>"))
  #expect(wordXML.contains("<w:pStyle w:val=\"CodeBlock\"/>"))
  #expect(wordXML.contains("<w:drawing>"))
  #expect(docx.contains { $0.path == "word/media/image1.gif" })
  #expect(docx.contains { $0.path == "[Content_Types].xml" })
  let app = try #require(docx.first { $0.path == "docProps/app.xml" })
  #expect(String(decoding: app.data, as: UTF8.self).contains("<Application>pmai</Application>"))

  let json = try ChatExport.data(for: chat, format: .json, generator: "pmai")
  let decoder = JSONDecoder()
  decoder.dateDecodingStrategy = .iso8601
  let envelope = try decoder.decode(ChatExportEnvelope.self, from: json)
  #expect(envelope.format == ChatExportEnvelope.format)
  #expect(envelope.generator == "pmai")
  #expect(envelope.chat.messages == chat.messages)
  #expect(envelope.chat.primaryAgent.id == "hello")
  #expect(envelope.debug == nil)

  let debug = ChatExportDebug(
    provider: "hello", providerDisplayName: "Offline hello",
    toolDefinitions: [ToolDefinition(name: "echo", description: "Echo", inputSchema: .object(["type": .string("object")]), annotations: ToolAnnotations(approval: .automatic))],
    settings: ["workingDirectory": "/tmp"])
  let debugJSON = try ChatExport.data(for: chat, format: .debug, generator: "pmai", debug: debug)
  let debugEnvelope = try decoder.decode(ChatExportEnvelope.self, from: debugJSON)
  #expect(debugEnvelope.debug?.toolDefinitions.map(\.name) == ["echo"])
  #expect(debugEnvelope.debug?.settings["workingDirectory"] == "/tmp")
  #expect(debugEnvelope.debug?.subagents.isEmpty == true)

  // A child agent's own transcript travels with the debug export.
  let child = AgentProcessInfo(
    pid: 2, parent: 1, runID: UUID(), agentID: "helper", task: "add up", state: .completed,
    depth: 1)
  let withChildren = ChatExportDebug(
    provider: "hello",
    subagents: [
      ChatExportSubagent(process: child, messages: [.user("add 2 and 2"), .assistant("4")])
    ])
  let childJSON = try ChatExport.data(
    for: chat, format: .debug, generator: "pmai", debug: withChildren)
  let childEnvelope = try decoder.decode(ChatExportEnvelope.self, from: childJSON)
  #expect(childEnvelope.debug?.subagents.map(\.pid) == [2])
  #expect(childEnvelope.debug?.subagents.first?.parent == 1)
  #expect(childEnvelope.debug?.subagents.first?.state == .completed)
  #expect(childEnvelope.debug?.subagents.first?.messages.last?.text == "4")

  // Exports written before subagents were recorded still decode.
  let older = try decoder.decode(
    ChatExportDebug.self,
    from: Data(#"{"provider":"hello","toolDefinitions":[],"settings":{}}"#.utf8))
  #expect(older.subagents.isEmpty)

  // A subagent written before records carried run ids still decodes, and
  // the records a chat file keeps are the same shape as the export's.
  let legacyChild = try decoder.decode(
    ChatExportDebug.self,
    from: Data(
      #"{"provider":"hello","subagents":[{"pid":2,"parent":1,"agentID":"helper","displayName":"helper","task":"add up","state":"completed","depth":1,"startedAt":"2026-09-07T10:00:00Z","finishedAt":"2026-09-07T10:00:05Z","modelTurns":1,"toolCalls":0,"messages":[]}]}"#
        .utf8))
  #expect(legacyChild.subagents.first?.agentID == "helper")
  #expect(legacyChild.subagents.first?.parentRunID == nil)
  #expect(legacyChild.subagents.first?.updatedAt == legacyChild.subagents.first?.finishedAt)
  var kept = chat
  kept.subagents = withChildren.subagents
  let keptEnvelope = try decoder.decode(
    ChatExportEnvelope.self,
    from: try ChatExport.data(for: kept, format: .json, generator: "pmai"))
  #expect(keptEnvelope.chat.subagents.map(\.runID) == withChildren.subagents.map(\.runID))
  #expect(keptEnvelope.chat.subagents.first?.messages == withChildren.subagents.first?.messages)
}

@Test("Documents independently opt into tools and thinking in every format",
  arguments: [ChatExportFormat.markdown, .html, .epub, .docx],
  [DocumentExportOptions(), .init(includeToolCalls: true), .init(includeThinking: true),
   .init(includeToolCalls: true, includeThinking: true)])
func documentExportContentOptions(format: ChatExportFormat, options: DocumentExportOptions) throws {
  var chat = sampleChat()
  chat.messages.append(AgentMessage(role: .tool, content: [.text("plain tool result")]))
  chat.messages.append(.assistant("<think>inline thought</think>\n\nVisible answer."))
  chat.messages.append(.assistant("<tool_call>legacy call</tool_call>\n\n<tool_run>legacy result</tool_run>"))
  let data = try ChatExport.data(for: chat, format: format, options: options)
  let text: String
  switch format {
  case .epub, .docx:
    text = try ZipArchiveReader.entries(in: data)
      .filter { $0.path.hasSuffix(".xml") || $0.path.hasSuffix(".xhtml") }
      .map { String(decoding: $0.data, as: UTF8.self) }.joined(separator: "\n")
  default:
    text = String(decoding: data, as: UTF8.self)
  }
  #expect(text.contains("Visible answer."))
  #expect(text.contains("thinking hard") == options.includeThinking)
  #expect(text.contains("inline thought") == options.includeThinking)
  #expect(text.contains("→ echo") == options.includeToolCalls)
  #expect(text.contains("← result") == options.includeToolCalls)
  #expect(text.contains("plain tool result") == options.includeToolCalls)
  #expect(text.contains("legacy call") == options.includeToolCalls)
  #expect(text.contains("legacy result") == options.includeToolCalls)
  #expect(ChatExport.document(for: chat).entries.map(\.role) == [.user, .assistant, .assistant])
}

@Test("Export file names come from the title and formats accept common spellings")
func exportNamesAndFormats() {
  var chat = sampleChat()
  chat.title = "Weird: title/name? with \"quotes\""
  #expect(ChatExport.filename(for: chat, format: .markdown) == "Weird title name with quotes.md")
  #expect(ChatExport.filename(for: chat, format: .docx).hasSuffix(".docx"))
  chat.title = "Ends with a period."
  #expect(ChatExport.filename(for: chat, format: .markdown) == "Ends with a period.md")
  chat.title = ""
  #expect(ChatExport.filename(for: chat, format: .epub) == "New chat.epub")
  #expect(ChatExportFormat(argument: "md") == .markdown)
  #expect(ChatExportFormat(argument: "HTML") == .html)
  #expect(ChatExportFormat(argument: "Word") == .docx)
  #expect(ChatExportFormat(argument: "debug") == .debug)
  #expect(ChatExportFormat(argument: "pdf") == nil)
}

private func sampleChat() -> AgentChat {
  let gif = Data([
    0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00,
    0x00, 0xff, 0xff, 0xff, 0x21, 0xf9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00,
    0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3b,
  ])
  let messages: [AgentMessage] = [
    AgentMessage(
      role: .user,
      content: [
        .text("Hello **there**"),
        .image(ImageContent(source: .data(gif), mimeType: "image/gif", name: "dot.gif", width: 1, height: 1)),
      ]),
    AgentMessage(
      role: .assistant,
      content: [
        .reasoning("thinking hard"),
        .toolCall(ToolCall(id: "c1", name: "echo", arguments: .object(["text": .string("hi")]))),
      ]),
    AgentMessage(role: .tool, content: [.toolResult(ToolResult(callID: "c1", text: "hi"))]),
    AgentMessage(
      role: .assistant,
      content: [.text("Done.\n\n```swift\nlet x = 1\n```\n\nSee [a link](https://example.com/).")]),
  ]
  return AgentChat(
    id: UUID(),
    title: "Export sample",
    primaryAgent: AgentDefinition(id: "hello", instructions: "", provider: "hello", model: "hello"),
    messages: messages,
    pendingContent: [],
    createdAt: Date(timeIntervalSince1970: 1_700_000_000),
    updatedAt: Date(timeIntervalSince1970: 1_700_003_600),
    isArchived: false)
}
