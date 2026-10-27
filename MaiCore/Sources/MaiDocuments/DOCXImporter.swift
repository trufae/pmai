import Foundation

/// Converts a Word document (.docx) into Markdown so it can be attached as a text file.
///
/// A .docx file is a zip container; the body lives in `word/document.xml` as
/// WordprocessingML. Only the parts that map cleanly onto Markdown are kept:
/// headings, emphasis, inline code, hyperlinks, lists and tables. Everything
/// else (images, fields, tracked deletions, revision metadata) is dropped.
public enum DOCXImporter {
  public enum ImportError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case unreadableArchive
    case missingDocument
    case emptyDocument

    public var errorDescription: String? {
      switch self {
      case .tooLarge:
        "Word attachments are limited to 25 MB."
      case .unreadableArchive:
        "The selected file could not be opened as a Word document."
      case .missingDocument:
        "The Word document is missing its main body."
      case .emptyDocument:
        "The Word document does not contain any text."
      }
    }
  }

  public static let maximumArchiveBytes = 25_000_000

  public static func markdown(from url: URL) throws -> String {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize <= maximumArchiveBytes else { throw ImportError.tooLarge }
    return try markdown(from: try Data(contentsOf: url))
  }

  public static func markdown(from data: Data) throws -> String {
    guard data.count <= maximumArchiveBytes else { throw ImportError.tooLarge }
    let entries: [ZipArchiveEntry]
    do {
      entries = try ZipArchiveReader.entries(in: data)
    } catch {
      throw ImportError.unreadableArchive
    }

    var parts: [String: Data] = [:]
    for entry in entries {
      parts[entry.path] = entry.data
    }
    return try markdown(parts: parts)
  }

  /// Converts already-extracted document parts. Exposed for testing.
  public static func markdown(parts: [String: Data]) throws -> String {
    guard let document = parts["word/document.xml"] else { throw ImportError.missingDocument }
    let numbering = NumberingIndex(xml: parts["word/numbering.xml"])
    let relationships = RelationshipIndex(xml: parts["word/_rels/document.xml.rels"])
    let parser = DocumentParser(numbering: numbering, relationships: relationships)
    guard let markdown = parser.parse(document) else { throw ImportError.unreadableArchive }
    guard !markdown.isEmpty else { throw ImportError.emptyDocument }
    return markdown
  }
}

// MARK: - Word properties

/// WordprocessingML toggles default to on when the value attribute is absent.
private func isToggleOn(_ attributes: [String: String]) -> Bool {
  guard let value = attributes["val"]?.lowercased() else { return true }
  return value != "0" && value != "false" && value != "off" && value != "none"
}

// MARK: - Numbering

/// Maps a paragraph's `w:numId` and `w:ilvl` onto "ordered" or "bulleted".
private struct NumberingIndex {
  private var orderedLevelsByNumberID: [String: [Int: Bool]] = [:]

  init(xml: Data?) {
    guard let xml else { return }
    let handler = NumberingHandler()
    guard DocumentXML.parse(xml, handler: handler) else { return }
    for (numberID, abstractID) in handler.abstractIDsByNumberID {
      orderedLevelsByNumberID[numberID] = handler.orderedLevelsByAbstractID[abstractID] ?? [:]
    }
  }

  func isOrdered(numberID: String, level: Int) -> Bool {
    guard let levels = orderedLevelsByNumberID[numberID] else { return false }
    return levels[level] ?? levels[0] ?? false
  }
}

private final class NumberingHandler: DocumentXMLHandler {
  private(set) var abstractIDsByNumberID: [String: String] = [:]
  private(set) var orderedLevelsByAbstractID: [String: [Int: Bool]] = [:]

  private var currentAbstractID: String?
  private var currentNumberID: String?
  private var currentLevel: Int?

  func startElement(_ elementName: String, attributes: [String: String]) {
    switch elementName {
    case "abstractNum":
      currentAbstractID = attributes["abstractNumId"]
    case "num":
      currentNumberID = attributes["numId"]
    case "abstractNumId":
      if let numberID = currentNumberID, let value = attributes["val"] {
        abstractIDsByNumberID[numberID] = value
      }
    case "lvl":
      currentLevel = attributes["ilvl"].flatMap { Int($0) }
    case "numFmt":
      guard let abstractID = currentAbstractID, let level = currentLevel,
        let format = attributes["val"]?.lowercased()
      else { break }
      orderedLevelsByAbstractID[abstractID, default: [:]][level] =
        format != "bullet" && format != "none"
    default:
      break
    }
  }

  func endElement(_ elementName: String) {
    switch elementName {
    case "abstractNum":
      currentAbstractID = nil
    case "num":
      currentNumberID = nil
    case "lvl":
      currentLevel = nil
    default:
      break
    }
  }
}

// MARK: - Relationships

/// Resolves `w:hyperlink r:id` references to external URLs.
private struct RelationshipIndex {
  private var targetsByID: [String: String] = [:]

  init(xml: Data?) {
    guard let xml else { return }
    let handler = RelationshipHandler()
    guard DocumentXML.parse(xml, handler: handler) else { return }
    targetsByID = handler.targetsByID
  }

  func target(forID id: String?) -> String? {
    guard let id else { return nil }
    return targetsByID[id]
  }
}

private final class RelationshipHandler: DocumentXMLHandler {
  private(set) var targetsByID: [String: String] = [:]

  func startElement(_ elementName: String, attributes: [String: String]) {
    guard elementName == "Relationship",
      let id = attributes["Id"],
      let target = attributes["Target"]
    else { return }
    let isExternal =
      attributes["TargetMode"]?.lowercased() == "external"
      || target.contains("://")
      || target.lowercased().hasPrefix("mailto:")
    guard isExternal else { return }
    targetsByID[id] = target
  }
}

// MARK: - Document body

private final class DocumentParser: DocumentXMLHandler {
  private struct RunStyle: Equatable {
    var bold = false
    var italic = false
    var strikethrough = false
    var code = false
    var link: String?
  }

  private enum Fragment {
    case text(String, RunStyle)
    case lineBreak
  }

  private struct Block {
    var text: String
    var isListItem: Bool
  }

  private struct TableState {
    var rows: [[String]] = []
    var currentRow: [String] = []
  }

  private let numbering: NumberingIndex
  private let relationships: RelationshipIndex

  /// Stack of block sinks: index 0 is the document body, deeper entries are table cells.
  private var blockStack: [[Block]] = [[]]
  private var tableStack: [TableState] = []
  private var linkStack: [String?] = []

  private var fragments: [Fragment] = []
  private var runStyle = RunStyle()
  private var isInsideRun = false
  private var isInsideParagraphProperties = false
  private var paragraphStyle: String?
  private var listLevel: Int?
  private var listNumberID: String?
  private var isCapturingText = false
  private var capturedText = ""

  init(numbering: NumberingIndex, relationships: RelationshipIndex) {
    self.numbering = numbering
    self.relationships = relationships
  }

  func parse(_ data: Data) -> String? {
    let parsed = DocumentXML.parse(data, handler: self)
    let rendered = Self.render(blockStack.first ?? [])
    guard parsed || !rendered.isEmpty else { return nil }
    return rendered
  }

  // MARK: XML events

  func startElement(_ elementName: String, attributes: [String: String]) {
    switch elementName {
    case "p":
      beginParagraph()
    case "pPr":
      isInsideParagraphProperties = true
    case "pStyle":
      if isInsideParagraphProperties { paragraphStyle = attributes["val"] }
    case "ilvl":
      if isInsideParagraphProperties {
        listLevel = attributes["val"].flatMap { Int($0) }
      }
    case "numId":
      if isInsideParagraphProperties { listNumberID = attributes["val"] }
    case "hyperlink":
      linkStack.append(relationships.target(forID: attributes["id"]))
    case "r":
      isInsideRun = true
      runStyle = RunStyle(link: linkStack.last ?? nil)
    case "b":
      if isInsideRun { runStyle.bold = isToggleOn(attributes) }
    case "i":
      if isInsideRun { runStyle.italic = isToggleOn(attributes) }
    case "strike", "dstrike":
      if isInsideRun { runStyle.strikethrough = isToggleOn(attributes) }
    case "rStyle":
      if isInsideRun, let style = attributes["val"]?.lowercased(),
        style.contains("code") || style.contains("htmlcode") || style.contains("verbatim")
      {
        runStyle.code = true
      }
    case "t":
      isCapturingText = true
      capturedText = ""
    case "br", "cr":
      if isInsideRun { fragments.append(.lineBreak) }
    case "tab":
      if isInsideRun { fragments.append(.text(" ", runStyle)) }
    case "tbl":
      tableStack.append(TableState())
    case "tr":
      if !tableStack.isEmpty { tableStack[tableStack.count - 1].currentRow = [] }
    case "tc":
      blockStack.append([])
    default:
      break
    }
  }

  func text(_ string: String) {
    guard isCapturingText else { return }
    capturedText += string
  }

  func endElement(_ elementName: String) {
    switch elementName {
    case "p":
      endParagraph()
    case "pPr":
      isInsideParagraphProperties = false
    case "t":
      if isCapturingText, !capturedText.isEmpty {
        fragments.append(.text(capturedText, runStyle))
      }
      isCapturingText = false
      capturedText = ""
    case "r":
      isInsideRun = false
      runStyle = RunStyle()
    case "hyperlink":
      if !linkStack.isEmpty { linkStack.removeLast() }
    case "tc":
      endCell()
    case "tr":
      guard !tableStack.isEmpty else { break }
      let row = tableStack[tableStack.count - 1].currentRow
      tableStack[tableStack.count - 1].currentRow = []
      if !row.isEmpty { tableStack[tableStack.count - 1].rows.append(row) }
    case "tbl":
      endTable()
    default:
      break
    }
  }

  // MARK: Blocks

  private func beginParagraph() {
    fragments = []
    paragraphStyle = nil
    listLevel = nil
    listNumberID = nil
  }

  private func endParagraph() {
    let body = MarkdownImportFormatting.trimmingTrailingWhitespace(
      Self.render(fragments: fragments))
    fragments = []
    guard !body.isEmpty else { return }

    let style =
      paragraphStyle?
      .lowercased()
      .replacingOccurrences(of: "_20_", with: "")
      .replacingOccurrences(of: " ", with: "")
    var text = body
    var isListItem = false

    if let numberID = listNumberID, numberID != "0" {
      let level = min(max(listLevel ?? 0, 0), 8)
      let marker = numbering.isOrdered(numberID: numberID, level: level) ? "1. " : "- "
      text = MarkdownImportFormatting.listItem(body, level: level, marker: marker)
      isListItem = true
    } else if style == "listparagraph" {
      let level = min(max(listLevel ?? 0, 0), 8)
      text = MarkdownImportFormatting.listItem(body, level: level, marker: "- ")
      isListItem = true
    } else if let level = Self.headingLevel(for: style) {
      text = String(repeating: "#", count: level) + " " + body
    } else if let style, Self.isQuoteStyle(style) {
      text = "> " + body.replacingOccurrences(of: "\n", with: "\n> ")
    } else {
      text = MarkdownImportFormatting.escapingBlockStart(body)
    }

    blockStack[blockStack.count - 1].append(Block(text: text, isListItem: isListItem))
  }

  private func endCell() {
    guard blockStack.count > 1 else { return }
    let cell = Self.tableCellText(Self.render(blockStack.removeLast()))
    guard !tableStack.isEmpty else { return }
    tableStack[tableStack.count - 1].currentRow.append(cell)
  }

  private func endTable() {
    guard !tableStack.isEmpty else { return }
    var table = tableStack.removeLast()
    if !table.currentRow.isEmpty {
      table.rows.append(table.currentRow)
    }
    let rendered = Self.render(table: table)
    guard !rendered.isEmpty else { return }
    blockStack[blockStack.count - 1].append(Block(text: rendered, isListItem: false))
  }

  // MARK: Rendering

  private static func render(_ blocks: [Block]) -> String {
    var output = ""
    var previousWasListItem = false
    for block in blocks where !block.text.isEmpty {
      if !output.isEmpty {
        output += block.isListItem && previousWasListItem ? "\n" : "\n\n"
      }
      output += block.text
      previousWasListItem = block.isListItem
    }
    return output
  }

  private static func render(fragments: [Fragment]) -> String {
    var merged: [Fragment] = []
    for fragment in fragments {
      if case .text(let text, let style) = fragment, let last = merged.last,
        case .text(let previous, let previousStyle) = last, previousStyle == style
      {
        merged[merged.count - 1] = .text(previous + text, style)
      } else {
        merged.append(fragment)
      }
    }

    var output = ""
    for fragment in merged {
      switch fragment {
      case .lineBreak:
        output += "  \n"
      case .text(let text, let style):
        output += decorate(text, style: style)
      }
    }
    return output
  }

  private static func decorate(_ text: String, style: RunStyle) -> String {
    MarkdownImportFormatting.decorate(
      text,
      bold: style.bold,
      italic: style.italic,
      code: style.code,
      strikethrough: style.strikethrough,
      link: style.link)
  }

  private static func render(table: TableState) -> String {
    let rows = table.rows.filter { !$0.isEmpty }
    guard let columnCount = rows.map(\.count).max(), columnCount > 0 else { return "" }

    var lines: [String] = []
    for (index, row) in rows.enumerated() {
      var cells = row.map { $0.isEmpty ? " " : $0 }
      cells.append(contentsOf: Array(repeating: " ", count: columnCount - cells.count))
      lines.append("| " + cells.joined(separator: " | ") + " |")
      if index == 0 {
        let separator = Array(repeating: "---", count: columnCount).joined(separator: " | ")
        lines.append("| " + separator + " |")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func tableCellText(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: true)
      .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|") }
      .filter { !$0.isEmpty }
      .joined(separator: "<br>")
  }

  private static func isQuoteStyle(_ style: String) -> Bool {
    style == "quote" || style == "intensequote" || style == "blockquote"
      || style == "quotations" || style == "blocktext"
  }

  private static func headingLevel(for style: String?) -> Int? {
    guard let style else { return nil }
    if style == "title" { return 1 }
    if style == "subtitle" { return 2 }
    guard style.hasPrefix("heading") else { return nil }
    guard let level = Int(style.dropFirst("heading".count)) else { return nil }
    return min(max(level, 1), 6)
  }
}
