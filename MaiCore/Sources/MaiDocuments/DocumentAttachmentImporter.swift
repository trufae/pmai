import Foundation
import MaiCore

/// A file turned into text a model can read, ready to attach to a message.
public struct DocumentAttachment: Equatable, Sendable {
  /// The attachment's file name, for example `report.md` for a converted document.
  public var name: String
  public var content: ContentPart
  /// How the file was converted, or nil when its text was attached verbatim.
  public var note: String?
  public var characterCount: Int

  public init(name: String, content: ContentPart, note: String?, characterCount: Int) {
    self.name = name
    self.content = content
    self.note = note
    self.characterCount = characterCount
  }
}

public enum DocumentAttachmentKind: String, Equatable, Sendable {
  case word
  case pdf
  case epub
  case html
  case json
  case text
  case image
}

public enum HTMLAttachmentMode: Equatable, Sendable {
  /// Keep the original markup so the model can inspect the source.
  case source
  /// Reduce the document to readable Markdown.
  case markdown
}

public enum DocumentImportError: LocalizedError, Equatable, Sendable {
  case fileNotFound(String)
  case isDirectory(String)
  case invalidFilename(String)
  case imageRequiresImageImporter(String)
  case fileTooLarge(limit: Int)
  case textTooLarge(limit: Int)
  case notUTF8(String)
  case binaryFile(String)
  case emptyText(String)

  public var errorDescription: String? {
    switch self {
    case .fileNotFound(let path):
      "File '\(path)' does not exist."
    case .isDirectory(let path):
      "'\(path)' is a directory."
    case .invalidFilename(let name):
      "'\(name)' is not a valid file name."
    case .imageRequiresImageImporter(let name):
      "'\(name)' is an image; attach it with the image importer instead."
    case .fileTooLarge(let limit):
      "Files are limited to \(limit / 1_000_000) MB."
    case .textTooLarge(let limit):
      "Text attachments are limited to \(limit / 1_000_000).\(limit % 1_000_000 / 100_000) MB."
    case .notUTF8(let name):
      "'\(name)' is not UTF-8 text."
    case .binaryFile(let name):
      "'\(name)' appears to be binary; only documents and text files can be attached."
    case .emptyText(let name):
      "'\(name)' does not contain any text."
    }
  }
}

/// Turns documents into Markdown or plain-text file parts. Detection uses the
/// bytes and declared MIME type first, with the filename only as a fallback, so
/// extensionless and source-code files are accepted when their contents are text.
public enum DocumentAttachmentImporter {
  /// The same ceiling the iOS app applies to text attachments.
  public static let maximumTextBytes = 1_500_000
  /// Covers the largest supported document format while bounding arbitrary inputs.
  public static let maximumFileBytes = EPUBImporter.maximumArchiveBytes

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
  ]
  private static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
  private static let applicationTextMIMETypes: Set<String> = [
    "application/javascript", "application/sql", "application/xml", "application/x-sh",
    "application/yaml",
  ]
  private static let textMIMEByExtension = [
    "md": "text/markdown", "markdown": "text/markdown", "mdown": "text/markdown",
    "mkd": "text/markdown", "c": "text/x-c", "h": "text/x-c", "cc": "text/x-c++",
    "cpp": "text/x-c++", "cxx": "text/x-c++", "hh": "text/x-c++", "hpp": "text/x-c++",
    "hxx": "text/x-c++", "py": "text/x-python", "pyw": "text/x-python",
    "js": "text/javascript", "mjs": "text/javascript", "cjs": "text/javascript",
    "ts": "text/typescript", "tsx": "text/typescript", "swift": "text/x-swift",
    "rs": "text/x-rust", "sh": "text/x-shellscript", "bash": "text/x-shellscript",
    "zsh": "text/x-shellscript", "fish": "text/x-shellscript", "xml": "application/xml",
    "yaml": "application/yaml", "yml": "application/yaml",
  ]

  public static func kind(forFilename name: String) -> DocumentAttachmentKind {
    switch (name as NSString).pathExtension.lowercased() {
    case "docx": .word
    case "pdf": .pdf
    case "epub": .epub
    case let ext where htmlExtensions.contains(ext): .html
    case "json": .json
    case let ext where imageExtensions.contains(ext): .image
    default: .text
    }
  }

  /// Identifies a document without trusting its suffix. Magic bytes take
  /// precedence over a declared MIME type; the filename is the final fallback.
  public static func kind(
    for data: Data,
    filename: String,
    mimeType: String? = nil
  ) -> DocumentAttachmentKind {
    let filenameKind = kind(forFilename: filename)
    return detectByMagicBytes(data)
      ?? detectByMIME(mimeType)
      ?? detectByHeuristics(data, filenameKind: filenameKind)
      ?? filenameKind
  }

  public static func attachment(at url: URL) throws -> DocumentAttachment {
    try attachment(data: data(at: url), filename: url.lastPathComponent)
  }

  /// Reads a picked file once, after rejecting directories and oversized input.
  public static func data(at url: URL) throws -> Data {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw DocumentImportError.fileNotFound(url.path)
    }
    guard !isDirectory.boolValue else { throw DocumentImportError.isDirectory(url.path) }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= maximumFileBytes else {
      throw DocumentImportError.fileTooLarge(limit: maximumFileBytes)
    }
    let data = try Data(contentsOf: url, options: [.mappedIfSafe])
    guard data.count <= maximumFileBytes else {
      throw DocumentImportError.fileTooLarge(limit: maximumFileBytes)
    }
    return data
  }

  /// Copies an imported file without replacing an existing file of the same name.
  public static func copy(
    data: Data,
    filename: String,
    into directory: URL,
    sourceURL: URL? = nil
  ) throws -> URL {
    let name = (filename as NSString).lastPathComponent
    guard !name.isEmpty, name != ".", name != ".." else {
      throw DocumentImportError.invalidFilename(filename)
    }
    let original = directory.appendingPathComponent(name).standardizedFileURL
    if original == sourceURL?.standardizedFileURL { return original }
    let nsName = name as NSString
    let stem = nsName.deletingPathExtension.isEmpty ? name : nsName.deletingPathExtension
    let ext = nsName.pathExtension
    var destination = original
    var suffix = 2
    while FileManager.default.fileExists(atPath: destination.path) {
      let candidate = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
      destination = directory.appendingPathComponent(candidate)
      suffix += 1
    }
    try data.write(to: destination, options: [.withoutOverwriting])
    return destination
  }

  public static func attachment(
    data: Data,
    filename: String,
    mimeType: String? = nil,
    htmlMode: HTMLAttachmentMode = .source
  ) throws -> DocumentAttachment {
    let baseName = (filename as NSString).deletingPathExtension
    switch kind(for: data, filename: filename, mimeType: mimeType) {
    case .word:
      return try converted(
        DOCXImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from Word to Markdown")
    case .pdf:
      return try converted(
        PDFImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from PDF to Markdown")
    case .epub:
      return try converted(
        EPUBImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from EPUB to Markdown")
    case .html where htmlMode == .markdown:
      return try converted(
        HTMLImporter.markdown(from: data),
        name: baseName + ".md",
        mimeType: "text/markdown",
        note: "converted from HTML to Markdown")
    case .html:
      return try textAttachment(
        data: data, filename: filename, mimeType: "text/html")
    case .json:
      return try converted(
        JSONDocumentImporter.render(data: data).text,
        name: baseName + ".txt",
        mimeType: "text/plain",
        note: "converted from JSON to an indented outline")
    case .image:
      throw DocumentImportError.imageRequiresImageImporter(filename)
    case .text:
      return try textAttachment(
        data: data,
        filename: filename,
        mimeType: textMIMEType(filename: filename, declared: mimeType))
    }
  }

  private static func textAttachment(
    data: Data,
    filename: String,
    mimeType: String
  ) throws -> DocumentAttachment {
    guard data.count <= maximumTextBytes else {
      throw DocumentImportError.textTooLarge(limit: maximumTextBytes)
    }
    guard hasUnicodeBOM(data) || !looksBinary(data) else {
      throw DocumentImportError.binaryFile(filename)
    }
    guard let text = decodedText(data) else {
      throw DocumentImportError.notUTF8(filename)
    }
    guard text.contains(where: { !$0.isWhitespace }) else {
      throw DocumentImportError.emptyText(filename)
    }
    return DocumentAttachment(
      name: filename,
      content: .file(FileContent(name: filename, mimeType: mimeType, text: text)),
      note: nil,
      characterCount: text.count)
  }

  private static func converted(
    _ text: String,
    name: String,
    mimeType: String,
    note: String
  ) throws -> DocumentAttachment {
    guard text.utf8.count <= maximumTextBytes else {
      throw DocumentImportError.textTooLarge(limit: maximumTextBytes)
    }
    return DocumentAttachment(
      name: name,
      content: .file(FileContent(name: name, mimeType: mimeType, text: text)),
      note: note,
      characterCount: text.count)
  }

  /// A NUL byte, or a high share of other control characters in the first few
  /// kilobytes, marks a file as binary rather than text.
  static func looksBinary(_ data: Data) -> Bool {
    let sample = data.prefix(8_192)
    guard !sample.isEmpty else { return false }
    var suspicious = 0
    for byte in sample {
      if byte == 0 { return true }
      if byte < 0x20, byte != 0x09, byte != 0x0A, byte != 0x0D, byte != 0x0C, byte != 0x1B {
        suspicious += 1
      }
    }
    return suspicious * 10 > sample.count
  }

  private static func detectByMagicBytes(_ data: Data) -> DocumentAttachmentKind? {
    switch true {
    case isPDF(data): return .pdf
    case isImage(data): return .image
    case !isZIP(data): return nil
    case contains(data, ascii: "word/document.xml"): return .word
    case contains(data, ascii: "application/epub+zip"),
      contains(data, ascii: "META-INF/container.xml"): return .epub
    default: return nil
    }
  }

  private static func detectByMIME(_ value: String?) -> DocumentAttachmentKind? {
    guard let mime = normalizedMIMEType(value) else { return nil }
    switch mime {
    case "application/pdf": return .pdf
    case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return .word
    case "application/epub+zip": return .epub
    case "text/html", "application/xhtml+xml": return .html
    case "application/json", "text/json": return .json
    case let type where type.hasPrefix("image/"): return .image
    default: return nil
    }
  }

  private static func detectByHeuristics(
    _ data: Data,
    filenameKind: DocumentAttachmentKind
  ) -> DocumentAttachmentKind? {
    guard let text = decodedText(data), hasUnicodeBOM(data) || !looksBinary(data) else { return nil }
    if looksLikeHTML(text) || filenameKind == .html { return .html }
    return looksLikeJSON(data) || filenameKind == .json ? .json : .text
  }

  private static func normalizedMIMEType(_ value: String?) -> String? {
    let mime = value?.split(separator: ";", maxSplits: 1).first?
      .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return mime.isEmpty ? nil : mime
  }

  private static func textMIMEType(filename: String, declared: String?) -> String {
    if let mime = normalizedMIMEType(declared),
      mime.hasPrefix("text/") || applicationTextMIMETypes.contains(mime)
    {
      return mime
    }
    let ext = (filename as NSString).pathExtension.lowercased()
    return textMIMEByExtension[ext] ?? "text/plain"
  }

  private static func decodedText(_ data: Data) -> String? {
    if data.starts(with: [0xEF, 0xBB, 0xBF]) {
      return String(data: Data(data.dropFirst(3)), encoding: .utf8)
    }
    if data.starts(with: [0xFF, 0xFE]) {
      return String(data: Data(data.dropFirst(2)), encoding: .utf16LittleEndian)
    }
    if data.starts(with: [0xFE, 0xFF]) {
      return String(data: Data(data.dropFirst(2)), encoding: .utf16BigEndian)
    }
    return String(data: data, encoding: .utf8)
  }

  private static func hasUnicodeBOM(_ data: Data) -> Bool {
    data.starts(with: [0xEF, 0xBB, 0xBF])
      || data.starts(with: [0xFF, 0xFE])
      || data.starts(with: [0xFE, 0xFF])
  }

  private static func looksLikeJSON(_ data: Data) -> Bool {
    guard let first = data.first(where: { ![0x09, 0x0A, 0x0D, 0x20].contains($0) }),
      first == 0x7B || first == 0x5B
    else { return false }
    return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
  }

  private static func looksLikeHTML(_ text: String) -> Bool {
    let prefix = text.prefix(8_192).lowercased()
    let leading = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    return prefix.range(of: #"<!doctype\s+html\b"#, options: .regularExpression) != nil
      || prefix.range(of: #"<html(?:\s|>)"#, options: .regularExpression) != nil
      || prefix.range(of: #"<(?:head|body)(?:\s|>)"#, options: .regularExpression) != nil
      || leading.range(
        of: #"^<(?:article|aside|blockquote|div|h[1-6]|main|ol|p|pre|section|table|ul)\b"#,
        options: .regularExpression) != nil
  }

  private static func isPDF(_ data: Data) -> Bool {
    data.prefix(5).elementsEqual(Data("%PDF-".utf8))
  }

  private static func isZIP(_ data: Data) -> Bool {
    data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B
      && ((data[2] == 0x03 && data[3] == 0x04)
        || (data[2] == 0x05 && data[3] == 0x06)
        || (data[2] == 0x07 && data[3] == 0x08))
  }

  private static func isImage(_ data: Data) -> Bool {
    if data.prefix(8).elementsEqual(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return true
    }
    if data.prefix(3).elementsEqual(Data([0xFF, 0xD8, 0xFF])) { return true }
    if data.prefix(6).elementsEqual(Data("GIF87a".utf8))
      || data.prefix(6).elementsEqual(Data("GIF89a".utf8))
    {
      return true
    }
    if data.prefix(2).elementsEqual(Data("BM".utf8)) { return true }
    if data.prefix(4).elementsEqual(Data([0x49, 0x49, 0x2A, 0x00]))
      || data.prefix(4).elementsEqual(Data([0x4D, 0x4D, 0x00, 0x2A]))
    {
      return true
    }
    if data.count >= 12,
      data[0..<4].elementsEqual(Data("RIFF".utf8)),
      data[8..<12].elementsEqual(Data("WEBP".utf8))
    {
      return true
    }
    if data.count >= 12, data[4..<8].elementsEqual(Data("ftyp".utf8)) {
      let brand = String(decoding: data[8..<12], as: UTF8.self).lowercased()
      if ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif"].contains(brand) {
        return true
      }
    }
    return false
  }

  private static func contains(_ data: Data, ascii: String) -> Bool {
    data.range(of: Data(ascii.utf8)) != nil
  }
}
