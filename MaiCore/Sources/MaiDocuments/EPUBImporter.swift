import Foundation

/// Converts an EPUB book (.epub) into Markdown so it can be attached as text.
///
/// An .epub file is a zip container: `META-INF/container.xml` points at the
/// package document (.opf), whose spine lists the XHTML chapters in reading
/// order. Each chapter is walked as XML and the parts that map cleanly onto
/// Markdown are kept: headings, emphasis, code, links, lists, quotes and
/// tables. Everything else (styles, scripts, images, navigation) is dropped.
public enum EPUBImporter {
  public enum ImportError: LocalizedError, Equatable, Sendable {
    case tooLarge
    case unreadableArchive
    case missingPackage
    case emptyDocument

    public var errorDescription: String? {
      switch self {
      case .tooLarge:
        "EPUB attachments are limited to 40 MB."
      case .unreadableArchive:
        "The selected file could not be opened as an EPUB book."
      case .missingPackage:
        "The EPUB book is missing its package document."
      case .emptyDocument:
        "The EPUB book does not contain any text."
      }
    }
  }

  public static let maximumArchiveBytes = 40_000_000

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

  /// Converts already-extracted container parts. Exposed for testing.
  public static func markdown(parts: [String: Data]) throws -> String {
    guard let packagePath = packagePath(in: parts) else { throw ImportError.missingPackage }
    guard let package = parts[packagePath] else { throw ImportError.missingPackage }

    let manifest = PackageIndex(xml: package, basePath: directory(of: packagePath))
    var chapters: [String] = []
    for path in manifest.readingOrder {
      guard let document = parts[path] else { continue }
      let chapter = HTMLToMarkdownParser().parse(document)
      guard !chapter.isEmpty else { continue }
      chapters.append(chapter)
    }

    var sections: [String] = []
    if let title = manifest.title, !title.isEmpty {
      sections.append("# " + title)
    }
    sections.append(contentsOf: chapters)
    let markdown = sections.joined(separator: "\n\n")
    guard !markdown.isEmpty else { throw ImportError.emptyDocument }
    return markdown
  }

  /// The package document is named by `META-INF/container.xml`; a book with a
  /// damaged container still opens when a single .opf file is present.
  private static func packagePath(in parts: [String: Data]) -> String? {
    if let container = parts["META-INF/container.xml"],
      let path = ContainerIndex(xml: container).packagePath,
      parts[path] != nil
    {
      return path
    }
    return parts.keys.filter { $0.lowercased().hasSuffix(".opf") }.min()
  }

  private static func directory(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    return String(path[path.startIndex...slash])
  }
}

// MARK: - Package paths

/// Resolves an href against the package document's folder, the way a reading
/// system does: `../images/cover.xhtml` next to `OEBPS/text/` is
/// `OEBPS/images/cover.xhtml`.
private func resolvePath(_ href: String, relativeTo base: String) -> String {
  let target = href.components(separatedBy: "#")[0]
  guard !target.isEmpty else { return "" }
  let decoded = target.removingPercentEncoding ?? target
  let combined = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : base + decoded
  var components: [String] = []
  for component in combined.components(separatedBy: "/") {
    switch component {
    case "", ".":
      continue
    case "..":
      if !components.isEmpty { components.removeLast() }
    default:
      components.append(component)
    }
  }
  return components.joined(separator: "/")
}

// MARK: - Container

private struct ContainerIndex {
  let packagePath: String?

  init(xml: Data) {
    let handler = ContainerHandler()
    DocumentXML.parse(xml, handler: handler)
    packagePath = handler.fullPath.map { resolvePath($0, relativeTo: "") }
  }
}

private final class ContainerHandler: DocumentXMLHandler {
  private(set) var fullPath: String?

  func startElement(_ elementName: String, attributes: [String: String]) {
    guard elementName == "rootfile", fullPath == nil else { return }
    fullPath = attributes["full-path"]
  }
}

// MARK: - Package document

/// The spine's reading order, resolved to archive paths, plus the book title.
private struct PackageIndex {
  let title: String?
  let readingOrder: [String]

  init(xml: Data, basePath: String) {
    let handler = PackageHandler()
    DocumentXML.parse(xml, handler: handler)

    title = handler.title?.trimmingCharacters(in: .whitespacesAndNewlines)
    var seen: Set<String> = []
    var order: [String] = []
    for reference in handler.spine {
      guard let item = handler.manifest[reference] else { continue }
      guard item.isDocument else { continue }
      let path = resolvePath(item.href, relativeTo: basePath)
      guard !path.isEmpty, seen.insert(path).inserted else { continue }
      order.append(path)
    }
    // A book with an unusable spine still reads when its documents are taken
    // from the manifest in declaration order.
    if order.isEmpty {
      for id in handler.manifestOrder {
        guard let item = handler.manifest[id], item.isDocument else { continue }
        let path = resolvePath(item.href, relativeTo: basePath)
        guard !path.isEmpty, seen.insert(path).inserted else { continue }
        order.append(path)
      }
    }
    readingOrder = order
  }
}

private struct ManifestItem {
  let href: String
  let mediaType: String

  /// Only the text documents are converted; images, fonts and styles are not.
  var isDocument: Bool {
    if mediaType.contains("xhtml") || mediaType.contains("html") { return true }
    if !mediaType.isEmpty { return false }
    let ext = (href.components(separatedBy: "#")[0] as NSString).pathExtension.lowercased()
    return ext == "xhtml" || ext == "html" || ext == "htm"
  }
}

private final class PackageHandler: DocumentXMLHandler {
  private(set) var manifest: [String: ManifestItem] = [:]
  private(set) var manifestOrder: [String] = []
  private(set) var spine: [String] = []
  private(set) var title: String?

  private var isCapturingTitle = false
  private var capturedTitle = ""

  func startElement(_ elementName: String, attributes: [String: String]) {
    switch elementName {
    case "item":
      guard let id = attributes["id"],
        let href = attributes["href"]
      else { break }
      manifest[id] = ManifestItem(
        href: href,
        mediaType: attributes["media-type"]?.lowercased() ?? "")
      manifestOrder.append(id)
    case "itemref":
      guard let id = attributes["idref"] else { break }
      spine.append(id)
    case "title":
      guard title == nil else { break }
      isCapturingTitle = true
      capturedTitle = ""
    default:
      break
    }
  }

  func text(_ string: String) {
    guard isCapturingTitle else { return }
    capturedTitle += string
  }

  func endElement(_ elementName: String) {
    guard elementName == "title", isCapturingTitle else { return }
    isCapturingTitle = false
    let trimmed = capturedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty { title = trimmed }
    capturedTitle = ""
  }
}

// MARK: - Chapter documents

/// Turns one XHTML chapter into Markdown blocks.
///
/// XML events include balanced start/end pairs even for self-closing tags, so
/// every element pushes its inline style and pops it again; unknown tags simply
/// inherit the style around them.
final class HTMLToMarkdownParser: DocumentXMLHandler {
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

  private enum BlockKind {
    case paragraph
    case heading(Int)
    case listItem(level: Int, marker: String)
  }

  private struct ListState {
    let isOrdered: Bool
  }

  private struct TableState {
    var rows: [[String]] = []
    var currentRow: [String] = []
  }

  private static let skippedElements: Set<String> = [
    "head", "script", "style", "svg", "audio", "video", "iframe", "nav", "template",
  ]

  /// Stack of block sinks: index 0 is the chapter body, deeper entries are table cells.
  private var blockStack: [[Block]] = [[]]
  private var tableStack: [TableState] = []
  private var listStack: [ListState] = []
  private var kindStack: [BlockKind] = []
  private var styleStack: [RunStyle] = []
  private var fragments: [Fragment] = []
  private var quoteDepth = 0
  private var preformattedDepth = 0
  private var preformattedText = ""
  private var skipDepth = 0

  func parse(_ data: Data) -> String {
    DocumentXML.parse(data, handler: self, htmlEntities: true)
    flushBlock()
    return Self.render(blockStack.first ?? [])
  }

  // MARK: XML events

  func startElement(_ elementName: String, attributes: [String: String]) {
    if skipDepth > 0 {
      skipDepth += 1
      return
    }
    let name = elementName.lowercased()
    if Self.skippedElements.contains(name) {
      skipDepth = 1
      return
    }

    var style = styleStack.last ?? RunStyle()
    switch name {
    case "em", "i", "cite", "dfn", "var":
      style.italic = true
    case "strong", "b":
      style.bold = true
    case "del", "s", "strike":
      style.strikethrough = true
    case "code", "kbd", "samp", "tt":
      if preformattedDepth == 0 { style.code = true }
    case "a":
      if let href = attributes["href"], Self.isExternalLink(href) {
        style.link = href
      }
    default:
      break
    }
    styleStack.append(style)

    switch name {
    case "p", "dt", "dd", "figcaption", "caption":
      flushBlock()
      kindStack.append(.paragraph)
    case "h1", "h2", "h3", "h4", "h5", "h6":
      flushBlock()
      kindStack.append(.heading(Int(name.dropFirst()) ?? 1))
    case "div", "section", "article", "aside", "header", "footer", "main", "body", "dl",
      "figure":
      flushBlock()
    case "blockquote":
      flushBlock()
      quoteDepth += 1
    case "pre":
      flushBlock()
      preformattedDepth += 1
    case "ul", "ol":
      flushBlock()
      listStack.append(ListState(isOrdered: name == "ol"))
    case "li":
      flushBlock()
      let level = max(listStack.count - 1, 0)
      let marker = (listStack.last?.isOrdered ?? false) ? "1. " : "- "
      kindStack.append(.listItem(level: level, marker: marker))
    case "br":
      if preformattedDepth > 0 {
        preformattedText += "\n"
      } else {
        fragments.append(.lineBreak)
      }
    case "hr":
      flushBlock()
      append(Block(text: "---", isListItem: false))
    case "table":
      flushBlock()
      tableStack.append(TableState())
    case "tr":
      if !tableStack.isEmpty { tableStack[tableStack.count - 1].currentRow = [] }
    case "td", "th":
      blockStack.append([])
    default:
      break
    }
  }

  func text(_ string: String) {
    guard skipDepth == 0 else { return }
    if preformattedDepth > 0 {
      preformattedText += string
      return
    }
    let text = Self.collapsingWhitespace(string)
    guard !text.isEmpty else { return }
    // A newline between two block tags arrives as a lone space; it would only
    // indent the next paragraph.
    guard text != " " || !fragments.isEmpty else { return }
    fragments.append(.text(text, styleStack.last ?? RunStyle()))
  }

  func endElement(_ elementName: String) {
    if skipDepth > 0 {
      skipDepth -= 1
      return
    }
    let name = elementName.lowercased()
    if !styleStack.isEmpty { styleStack.removeLast() }

    switch name {
    case "p", "dt", "dd", "figcaption", "caption", "h1", "h2", "h3", "h4", "h5", "h6", "li":
      flushBlock()
      if !kindStack.isEmpty { kindStack.removeLast() }
    case "div", "section", "article", "aside", "header", "footer", "main", "body", "dl",
      "figure":
      flushBlock()
    case "blockquote":
      flushBlock()
      quoteDepth = max(quoteDepth - 1, 0)
    case "pre":
      preformattedDepth = max(preformattedDepth - 1, 0)
      guard preformattedDepth == 0 else { break }
      let code = MarkdownImportFormatting.trimmingTrailingWhitespace(preformattedText)
      preformattedText = ""
      guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { break }
      append(Block(text: "```\n" + code + "\n```", isListItem: false))
    case "ul", "ol":
      flushBlock()
      if !listStack.isEmpty { listStack.removeLast() }
    case "td", "th":
      endCell()
    case "tr":
      guard !tableStack.isEmpty else { break }
      let row = tableStack[tableStack.count - 1].currentRow
      tableStack[tableStack.count - 1].currentRow = []
      if !row.isEmpty { tableStack[tableStack.count - 1].rows.append(row) }
    case "table":
      endTable()
    default:
      break
    }
  }

  // MARK: Blocks

  private func flushBlock() {
    // Indented markup leaves a space in front of the first run, which Markdown
    // would read as indentation.
    let body = MarkdownImportFormatting.trimmingTrailingWhitespace(
      Self.render(fragments).trimmingCharacters(in: .whitespaces))
    fragments = []
    guard !body.isEmpty else { return }

    var text = body
    var isListItem = false
    switch kindStack.last ?? .paragraph {
    case .heading(let level):
      text = String(repeating: "#", count: min(max(level, 1), 6)) + " " + body
    case .listItem(let level, let marker):
      text = MarkdownImportFormatting.listItem(body, level: min(level, 8), marker: marker)
      isListItem = true
    case .paragraph:
      text = MarkdownImportFormatting.escapingBlockStart(body)
    }
    if quoteDepth > 0 {
      let prefix = String(repeating: "> ", count: quoteDepth)
      text = prefix + text.replacingOccurrences(of: "\n", with: "\n" + prefix)
    }
    append(Block(text: text, isListItem: isListItem))
  }

  private func append(_ block: Block) {
    blockStack[blockStack.count - 1].append(block)
  }

  private func endCell() {
    guard blockStack.count > 1 else { return }
    flushBlock()
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
    append(Block(text: rendered, isListItem: false))
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

  private static func render(_ fragments: [Fragment]) -> String {
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
        output += MarkdownImportFormatting.decorate(
          text,
          bold: style.bold,
          italic: style.italic,
          code: style.code,
          strikethrough: style.strikethrough,
          link: style.link)
      }
    }
    return output
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

  /// Cross-references inside the book point at files the model cannot open, so
  /// only links that leave the book are kept.
  private static func isExternalLink(_ href: String) -> Bool {
    let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.contains("://") || trimmed.hasPrefix("mailto:")
  }

  /// HTML folds every run of whitespace, newlines included, into one space.
  private static func collapsingWhitespace(_ text: String) -> String {
    var output = ""
    output.reserveCapacity(text.utf8.count)
    var pendingSpace = false
    for character in text {
      if character.isWhitespace || character == "\u{00A0}" {
        pendingSpace = true
        continue
      }
      if pendingSpace {
        output.append(" ")
        pendingSpace = false
      }
      output.append(character)
    }
    if pendingSpace { output.append(" ") }
    return output
  }
}

// MARK: - Entities

/// XML only defines five named entities, but EPUB 2 books are full of
/// HTML ones such as `&nbsp;` and `&mdash;`. Known names become numeric
/// references and unknown ones become literal text, so a chapter is never lost
/// to a parse error.
enum XHTMLEntities {
  static func normalized(_ text: String) -> String {
    guard text.contains("&") else { return text }

    var output = ""
    output.reserveCapacity(text.count)
    var index = text.startIndex
    while let ampersand = text[index...].firstIndex(of: "&") {
      output += text[index..<ampersand]
      let afterAmpersand = text.index(after: ampersand)
      let window = text[afterAmpersand...].prefix(32)
      guard let semicolon = window.firstIndex(of: ";") else {
        output += "&amp;"
        index = afterAmpersand
        continue
      }
      let name = String(text[afterAmpersand..<semicolon])
      let next = text.index(after: semicolon)
      guard isReferenceName(name) else {
        output += "&amp;"
        index = afterAmpersand
        continue
      }
      if name.hasPrefix("#") || predefined.contains(name) {
        output += text[ampersand..<next]
      } else if let scalar = named[name] {
        output += "&#\(scalar);"
      } else {
        output += "&amp;" + name + ";"
      }
      index = next
    }
    output += text[index...]
    return output
  }

  /// `&` on its own is common in older books; only a well-formed name is
  /// treated as a reference, everything else is escaped as literal text.
  private static func isReferenceName(_ name: String) -> Bool {
    guard let first = name.first else { return false }
    if first == "#" {
      let digits = name.dropFirst()
      guard !digits.isEmpty else { return false }
      if digits.first == "x" || digits.first == "X" {
        let hex = digits.dropFirst()
        return !hex.isEmpty && hex.allSatisfy(\.isHexDigit)
      }
      return digits.allSatisfy(\.isNumber)
    }
    return first.isLetter && name.allSatisfy { $0.isLetter || $0.isNumber }
  }

  private static let predefined: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

  private static let named: [String: Int] = [
    "nbsp": 160, "iexcl": 161, "cent": 162, "pound": 163, "curren": 164, "yen": 165,
    "brvbar": 166, "sect": 167, "uml": 168, "copy": 169, "ordf": 170, "laquo": 171,
    "not": 172, "shy": 173, "reg": 174, "macr": 175, "deg": 176, "plusmn": 177,
    "sup2": 178, "sup3": 179, "acute": 180, "micro": 181, "para": 182, "middot": 183,
    "cedil": 184, "sup1": 185, "ordm": 186, "raquo": 187, "frac14": 188, "frac12": 189,
    "frac34": 190, "iquest": 191, "Agrave": 192, "Aacute": 193, "Acirc": 194,
    "Atilde": 195, "Auml": 196, "Aring": 197, "AElig": 198, "Ccedil": 199,
    "Egrave": 200, "Eacute": 201, "Ecirc": 202, "Euml": 203, "Igrave": 204,
    "Iacute": 205, "Icirc": 206, "Iuml": 207, "ETH": 208, "Ntilde": 209,
    "Ograve": 210, "Oacute": 211, "Ocirc": 212, "Otilde": 213, "Ouml": 214,
    "times": 215, "Oslash": 216, "Ugrave": 217, "Uacute": 218, "Ucirc": 219,
    "Uuml": 220, "Yacute": 221, "THORN": 222, "szlig": 223, "agrave": 224,
    "aacute": 225, "acirc": 226, "atilde": 227, "auml": 228, "aring": 229,
    "aelig": 230, "ccedil": 231, "egrave": 232, "eacute": 233, "ecirc": 234,
    "euml": 235, "igrave": 236, "iacute": 237, "icirc": 238, "iuml": 239,
    "eth": 240, "ntilde": 241, "ograve": 242, "oacute": 243, "ocirc": 244,
    "otilde": 245, "ouml": 246, "divide": 247, "oslash": 248, "ugrave": 249,
    "uacute": 250, "ucirc": 251, "uuml": 252, "yacute": 253, "thorn": 254,
    "yuml": 255, "OElig": 338, "oelig": 339, "Scaron": 352, "scaron": 353,
    "Yuml": 376, "fnof": 402, "circ": 710, "tilde": 732, "ensp": 8194,
    "emsp": 8195, "thinsp": 8201, "zwnj": 8204, "zwj": 8205, "lrm": 8206,
    "rlm": 8207, "ndash": 8211, "mdash": 8212, "lsquo": 8216, "rsquo": 8217,
    "sbquo": 8218, "ldquo": 8220, "rdquo": 8221, "bdquo": 8222, "dagger": 8224,
    "Dagger": 8225, "bull": 8226, "hellip": 8230, "permil": 8240, "prime": 8242,
    "Prime": 8243, "lsaquo": 8249, "rsaquo": 8250, "oline": 8254, "frasl": 8260,
    "euro": 8364, "trade": 8482, "larr": 8592, "uarr": 8593, "rarr": 8594,
    "darr": 8595, "harr": 8596, "minus": 8722, "lowast": 8727, "ne": 8800,
    "le": 8804, "ge": 8805, "loz": 9674, "spades": 9824, "clubs": 9827,
    "hearts": 9829, "diams": 9830,
  ]
}
