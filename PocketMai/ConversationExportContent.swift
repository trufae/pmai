import Foundation
import MaiCore
import MaiDocuments
import SwiftUI
import UIKit

enum ConversationExportContent {
  struct ConversationSummary {
    let title: String
    let started: String
    let lastUpdated: String
    let messageCountText: String
  }

  static func summary(for conversation: Conversation) -> ConversationSummary {
    let trimmedTitle = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .long
    dateFormatter.timeStyle = .short
    let messageCount = conversation.messages.count
    return ConversationSummary(
      title: trimmedTitle.isEmpty ? "Chat" : trimmedTitle,
      started: dateFormatter.string(from: conversation.createdAt),
      lastUpdated: dateFormatter.string(from: conversation.updatedAt),
      messageCountText: "\(messageCount) message\(messageCount == 1 ? "" : "s")")
  }

  struct ImageResource {
    let id: String
    let href: String
    let mediaType: String
    let data: Data
    let width: Int?
    let height: Int?
  }

  struct ImageResourceCatalog {
    private(set) var resources: [ImageResource] = []
    private var attachmentHrefsByID: [UUID: String] = [:]
    private var attachmentResourcesByID: [UUID: ImageResource] = [:]
    private var remoteHrefsBySource: [String: String] = [:]
    private var remoteResourcesBySource: [String: ImageResource] = [:]
    private var mermaidResourcesBySource: [String: ImageResource] = [:]
    private var nextImageIndex = 1
    private let imageSize: AttachmentImageSize

    init(imageSize: AttachmentImageSize) {
      self.imageSize = imageSize
    }

    mutating func addImageAttachment(_ attachment: ChatAttachment) throws {
      guard attachment.kind == .image else { return }
      guard attachmentHrefsByID[attachment.id] == nil else { return }
      guard let dataBase64 = attachment.dataBase64,
        !dataBase64.isEmpty,
        let data = Data(base64Encoded: dataBase64)
      else {
        throw ConversationExportError.unreadableAttachedImage(attachment.displayName)
      }
      guard
        let mediaType = Self.imageMediaType(
          from: data,
          declared: attachment.mimeType,
          suggestedFilename: attachment.filename,
          url: nil)
      else {
        throw ConversationExportError.unsupportedImage(attachment.displayName)
      }

      let prepared = preparedImageData(
        data: data,
        mediaType: mediaType,
        fallbackWidth: attachment.width,
        fallbackHeight: attachment.height)
      let resource = makeResource(
        data: prepared.data,
        mediaType: prepared.mediaType,
        width: prepared.width,
        height: prepared.height,
        suggestedFilename: attachment.filename,
        url: nil)
      resources.append(resource)
      attachmentHrefsByID[attachment.id] = resource.href
      attachmentResourcesByID[attachment.id] = resource
    }

    mutating func addRemoteImage(source: String) async throws {
      let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
      guard remoteHrefsBySource[normalizedSource] == nil else { return }
      guard let url = Self.remoteImageURL(from: normalizedSource) else { return }

      let downloaded: (data: Data, mediaType: String)
      do {
        downloaded = try await Self.downloadRemoteImage(
          from: url,
          displaySource: normalizedSource)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return
      }
      let prepared = preparedImageData(
        data: downloaded.data,
        mediaType: downloaded.mediaType,
        fallbackWidth: nil,
        fallbackHeight: nil)
      let resource = makeResource(
        data: prepared.data,
        mediaType: prepared.mediaType,
        width: prepared.width,
        height: prepared.height,
        suggestedFilename: url.lastPathComponent,
        url: url)
      resources.append(resource)
      remoteHrefsBySource[normalizedSource] = resource.href
      remoteResourcesBySource[normalizedSource] = resource
    }

    mutating func addMermaidDiagram(source: String) async {
      let normalizedSource = MarkdownMermaidRenderer.normalizedSource(source)
      guard !normalizedSource.isEmpty,
        mermaidResourcesBySource[normalizedSource] == nil
      else {
        return
      }

      do {
        guard
          let rendered = try await MarkdownMermaidRenderCache.shared.renderedPNG(
            source: normalizedSource,
            style: .light,
            scale: 2.0)
        else {
          return
        }

        let prepared = preparedImageData(
          data: rendered.data,
          mediaType: "image/png",
          fallbackWidth: rendered.width,
          fallbackHeight: rendered.height)
        let resource = makeResource(
          data: prepared.data,
          mediaType: prepared.mediaType,
          width: prepared.width,
          height: prepared.height,
          suggestedFilename: "mermaid-diagram.png",
          url: nil)
        resources.append(resource)
        mermaidResourcesBySource[normalizedSource] = resource
      } catch {
        return
      }
    }

    func hasImageAttachments(for message: ChatMessage) -> Bool {
      message.attachments.contains { attachment in
        attachment.kind == .image && attachmentHrefsByID[attachment.id] != nil
      }
    }

    func href(for attachment: ChatAttachment) -> String? {
      attachmentHrefsByID[attachment.id]
    }

    func resource(for attachment: ChatAttachment) -> ImageResource? {
      attachmentResourcesByID[attachment.id]
    }

    func href(forMarkdownImageSource source: String) -> String? {
      remoteHrefsBySource[source.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func resource(forMarkdownImageSource source: String) -> ImageResource? {
      remoteResourcesBySource[source.trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func resource(forMermaidDiagram source: String) -> ImageResource? {
      mermaidResourcesBySource[MarkdownMermaidRenderer.normalizedSource(source)]
    }

    /// The remote images and rendered diagrams, keyed the way the shared
    /// export document expects: by markdown source and by fence source.
    func exportImages(diagramSources: [String]) -> (inline: [String: ExportImage], diagrams: [String: ExportImage]) {
      func image(_ resource: ImageResource, name: String) -> ExportImage {
        ExportImage(
          name: name, mediaType: resource.mediaType, data: resource.data,
          width: resource.width, height: resource.height)
      }
      let inline = remoteResourcesBySource.mapValues { image($0, name: "Image") }
      var diagrams: [String: ExportImage] = [:]
      for source in diagramSources {
        if let resource = resource(forMermaidDiagram: source) {
          diagrams[source] = image(resource, name: "Mermaid diagram")
        }
      }
      return (inline, diagrams)
    }

    func firstImageAttachmentDisplayName(in message: ChatMessage) -> String? {
      message.attachments.first { attachment in
        attachment.kind == .image && attachmentHrefsByID[attachment.id] != nil
      }?.displayName
    }

    private mutating func makeResource(
      data: Data,
      mediaType: String,
      width: Int?,
      height: Int?,
      suggestedFilename: String,
      url: URL?
    ) -> ImageResource {
      let resourceIndex = nextImageIndex
      nextImageIndex += 1
      let ext = Self.imageFileExtension(
        mediaType: mediaType,
        suggestedFilename: suggestedFilename,
        url: url)
      let filename = String(format: "image%03d.%@", resourceIndex, ext)
      return ImageResource(
        id: String(format: "img%03d", resourceIndex),
        href: "images/\(filename)",
        mediaType: mediaType,
        data: data,
        width: width,
        height: height)
    }

    private func preparedImageData(
      data: Data,
      mediaType: String,
      fallbackWidth: Int?,
      fallbackHeight: Int?
    ) -> (data: Data, mediaType: String, width: Int?, height: Int?) {
      guard let maxDimension = imageSize.maxDimension else {
        return (data, mediaType, fallbackWidth, fallbackHeight)
      }
      guard let image = UIImage(data: data) else {
        return (data, mediaType, fallbackWidth, fallbackHeight)
      }
      let pixelSize = CGSize(
        width: image.size.width * image.scale,
        height: image.size.height * image.scale)
      let scale =
        max(pixelSize.width, pixelSize.height) > CGFloat(maxDimension)
        ? CGFloat(maxDimension) / max(pixelSize.width, pixelSize.height)
        : 1
      let target = CGSize(
        width: max(1, floor(pixelSize.width * scale)),
        height: max(1, floor(pixelSize.height * scale)))
      let format = UIGraphicsImageRendererFormat.default()
      format.scale = 1
      let renderer = UIGraphicsImageRenderer(size: target, format: format)
      let resized = renderer.image { _ in
        image.draw(in: CGRect(origin: .zero, size: target))
      }
      guard let output = resized.jpegData(compressionQuality: 0.82) else {
        return (
          data,
          mediaType,
          Int(pixelSize.width.rounded()),
          Int(pixelSize.height.rounded())
        )
      }
      return (
        output,
        "image/jpeg",
        Int(target.width.rounded()),
        Int(target.height.rounded())
      )
    }

    private static func remoteImageURL(from source: String) -> URL? {
      MarkdownWebURL.url(from: source)
    }

    private static func downloadRemoteImage(from url: URL, displaySource: String) async throws
      -> (data: Data, mediaType: String)
    {
      var request = URLRequest(url: url)
      request.timeoutInterval = 30
      request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await URLSession.shared.data(for: request)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        throw ConversationExportError.remoteImageDownloadFailed(
          displaySource,
          error.localizedDescription)
      }

      if let http = response as? HTTPURLResponse,
        !(200..<300).contains(http.statusCode)
      {
        throw ConversationExportError.remoteImageDownloadFailed(
          displaySource,
          "HTTP \(http.statusCode)")
      }
      guard data.count <= maxImageBytes else {
        throw ConversationExportError.remoteImageDownloadFailed(displaySource, "image is too large")
      }
      let responseURL = response.url ?? url
      guard
        let mediaType = imageMediaType(
          from: data,
          declared: response.mimeType,
          suggestedFilename: responseURL.lastPathComponent,
          url: responseURL)
      else {
        throw ConversationExportError.unsupportedImage(displaySource)
      }
      return (data, mediaType)
    }

    private static func imageMediaType(
      from data: Data,
      declared: String?,
      suggestedFilename: String,
      url: URL?
    ) -> String? {
      if let mediaType = normalizedImageMediaType(declared) {
        return mediaType
      }
      if dataStarts(data, [0xff, 0xd8, 0xff]) {
        return "image/jpeg"
      }
      if dataStarts(data, [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) {
        return "image/png"
      }
      if dataStarts(data, [0x47, 0x49, 0x46, 0x38]) {
        return "image/gif"
      }
      let header = Array(data.prefix(12))
      if header.count == 12,
        String(bytes: header[0..<4], encoding: .ascii) == "RIFF",
        String(bytes: header[8..<12], encoding: .ascii) == "WEBP"
      {
        return "image/webp"
      }
      if let text = String(data: data.prefix(512), encoding: .utf8),
        text.localizedCaseInsensitiveContains("<svg")
      {
        return "image/svg+xml"
      }
      return normalizedImageMediaType(
        mimeTypeForImageExtension(fileExtension(suggestedFilename: suggestedFilename, url: url)))
    }

    private static func imageFileExtension(
      mediaType: String,
      suggestedFilename: String,
      url: URL?
    ) -> String {
      if let ext = fileExtensionForImageMediaType(mediaType) {
        return ext
      }
      return fileExtension(suggestedFilename: suggestedFilename, url: url) ?? "img"
    }

    private static func fileExtension(suggestedFilename: String, url: URL?) -> String? {
      let candidates = [URL(fileURLWithPath: suggestedFilename).pathExtension, url?.pathExtension]
      for candidate in candidates {
        let ext = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if isSupportedImageExtension(ext) {
          return ext == "jpeg" ? "jpg" : ext
        }
      }
      return nil
    }

    private static func normalizedImageMediaType(_ raw: String?) -> String? {
      guard let raw else { return nil }
      let mediaType =
        raw
        .components(separatedBy: ";")
        .first?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? ""
      guard mediaType.hasPrefix("image/") else { return nil }
      if mediaType == "image/jpg" || mediaType == "image/pjpeg" {
        return "image/jpeg"
      }
      return mediaType
    }

    private static let mediaTypesByImageExtension: [String: String] = [
      "jpg": "image/jpeg", "jpeg": "image/jpeg", "png": "image/png", "gif": "image/gif",
      "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic", "heif": "image/heif",
      "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp",
    ]

    private static let imageExtensionsByMediaType: [String: String] = [
      "image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/svg+xml": "svg",
      "image/webp": "webp", "image/heic": "heic", "image/heif": "heif", "image/tiff": "tif",
      "image/bmp": "bmp",
    ]

    private static func mimeTypeForImageExtension(_ ext: String?) -> String? {
      ext.flatMap { mediaTypesByImageExtension[$0] }
    }

    private static func fileExtensionForImageMediaType(_ mediaType: String) -> String? {
      normalizedImageMediaType(mediaType).flatMap { imageExtensionsByMediaType[$0] }
    }

    private static func isSupportedImageExtension(_ ext: String) -> Bool {
      mimeTypeForImageExtension(ext) != nil
    }

    private static func dataStarts(_ data: Data, _ prefix: [UInt8]) -> Bool {
      guard data.count >= prefix.count else { return false }
      return zip(data.prefix(prefix.count), prefix).allSatisfy { $0 == $1 }
    }

    private static let maxImageBytes = 25 * 1024 * 1024
    private static let userAgent = "PocketMai/1.0 (iOS; +https://github.com/trufae/mai)"
  }

  private enum ConversationExportError: LocalizedError {
    case unreadableAttachedImage(String)
    case unsupportedImage(String)
    case remoteImageDownloadFailed(String, String)

    var errorDescription: String? {
      switch self {
      case .unreadableAttachedImage(let name):
        return "Could not read attached image \"\(name)\"."
      case .unsupportedImage(let source):
        return "Could not identify an image format for \"\(source)\"."
      case .remoteImageDownloadFailed(let source, let reason):
        return "Could not download image \"\(source)\": \(reason)."
      }
    }
  }

  struct MessageContent {
    let visibleText: String
    let reasoningSections: [String]

    var hasExportedBody: Bool {
      !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || reasoningSections.contains {
          !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
  }

  static func messageContent(for message: ChatMessage, options: DocumentExportOptions = .init())
    -> MessageContent
  {
    guard options.includeToolCalls || message.role != .tool else {
      return MessageContent(visibleText: "", reasoningSections: [])
    }
    let rendered = MessageContentFilter.render(message.presentationText)
    let reasoningSections =
      options.includeThinking
      ? rendered.hiddenSections.filter { $0.tag == "think" }.map(\.content)
      : []
    var body = [rendered.visibleText]
    if options.includeToolCalls {
      for section in rendered.hiddenSections
      where section.tag == "tool_call" || section.tag == "tool_run" {
        var fence = "```"
        while section.content.contains(fence) { fence += "`" }
        body.append("\(fence)\n\(section.content)\n\(fence)")
      }
    }
    return MessageContent(
      visibleText: body.filter { !$0.isEmpty }.joined(separator: "\n\n"),
      reasoningSections: reasoningSections)
  }

  static func buildImageResourceCatalog(
    conversation: Conversation,
    options: DocumentExportOptions = .init(),
    imageSize: AttachmentImageSize
  ) async throws -> ImageResourceCatalog {
    var catalog = ImageResourceCatalog(imageSize: imageSize)
    for message in conversation.messages {
      if message.role == .tool && !options.includeToolCalls { continue }
      for attachment in message.attachments where attachment.kind == .image {
        try catalog.addImageAttachment(attachment)
      }

      let content = messageContent(for: message, options: options)
      for source in markdownImageSources(in: content.visibleText) {
        try await catalog.addRemoteImage(source: source)
      }
      await addMermaidDiagrams(in: content.visibleText, to: &catalog)
      for section in content.reasoningSections {
        for source in markdownImageSources(in: section) {
          try await catalog.addRemoteImage(source: source)
        }
        await addMermaidDiagrams(in: section, to: &catalog)
      }
    }
    return catalog
  }

  private static func addMermaidDiagrams(
    in text: String,
    to catalog: inout ImageResourceCatalog
  ) async {
    for block in MarkdownParser.blocks(from: text) {
      if case .mermaid(let source) = block.kind {
        await catalog.addMermaidDiagram(source: source)
      }
    }
  }

  indirect enum MarkdownInlineNode {
    case text(String)
    case lineBreak
    case code(String)
    case emphasis([MarkdownInlineNode])
    case strong([MarkdownInlineNode])
    case strikethrough([MarkdownInlineNode])
    case link(label: [MarkdownInlineNode], url: String)
    case image(altText: String, source: String)
  }

  static func inlineNodes(_ raw: String) -> [MarkdownInlineNode] {
    let chars = Array(MarkdownInlineSymbols.displayString(raw))
    var nodes: [MarkdownInlineNode] = []
    var pending = ""

    func flush() {
      if !pending.isEmpty {
        nodes.append(.text(pending))
        pending = ""
      }
    }

    var index = 0
    while index < chars.count {
      let c = chars[index]

      if c == "\\", index + 1 < chars.count, "\\`*_{}[]()#+-.!~".contains(chars[index + 1]) {
        pending.append(chars[index + 1])
        index += 2
        continue
      }

      if let codeSpan = MarkdownInlineCodeSpan.span(in: chars, at: index) {
        flush()
        nodes.append(.code(codeSpan.code))
        index = codeSpan.end
        continue
      }

      if c == "~", index + 1 < chars.count, chars[index + 1] == "~",
        let end = findClose(chars: chars, start: index + 2, marker: "~~"),
        end > index + 2
      {
        flush()
        nodes.append(.strikethrough(inlineNodes(String(chars[(index + 2)..<end]))))
        index = end + 2
        continue
      }

      if (c == "*" || c == "_") && index + 1 < chars.count && chars[index + 1] == c,
        let end = findClose(chars: chars, start: index + 2, marker: String([c, c]))
      {
        flush()
        nodes.append(.strong(inlineNodes(String(chars[(index + 2)..<end]))))
        index = end + 2
        continue
      }

      if c == "*" || c == "_",
        let end = findClose(chars: chars, start: index + 1, marker: String(c)),
        end > index + 1
      {
        flush()
        nodes.append(.emphasis(inlineNodes(String(chars[(index + 1)..<end]))))
        index = end + 1
        continue
      }

      if let image = markdownImageToken(in: chars, at: index) {
        flush()
        nodes.append(.image(altText: image.altText, source: image.source))
        index = image.end
        continue
      }

      if c == "[",
        let textEnd = findClose(chars: chars, start: index + 1, marker: "]"),
        textEnd + 1 < chars.count, chars[textEnd + 1] == "(",
        let urlEnd = findClose(chars: chars, start: textEnd + 2, marker: ")")
      {
        flush()
        nodes.append(
          .link(
            label: inlineNodes(String(chars[(index + 1)..<textEnd])),
            url: String(chars[(textEnd + 2)..<urlEnd])))
        index = urlEnd + 1
        continue
      }

      if c == "\n" {
        flush()
        nodes.append(.lineBreak)
        index += 1
        continue
      }

      pending.append(c)
      index += 1
    }
    flush()
    return nodes
  }

  private static func markdownImageSources(in raw: String) -> [String] {
    imageSources(in: inlineNodes(raw))
  }

  private static func imageSources(in nodes: [MarkdownInlineNode]) -> [String] {
    nodes.flatMap { node -> [String] in
      switch node {
      case .image(_, let source):
        return [source]
      case .emphasis(let children), .strong(let children), .strikethrough(let children),
        .link(let children, _):
        return imageSources(in: children)
      case .text, .lineBreak, .code:
        return []
      }
    }
  }

  private struct MarkdownImageToken {
    let altText: String
    let source: String
    let end: Int
  }

  private static func markdownImageToken(in chars: [Character], at index: Int)
    -> MarkdownImageToken?
  {
    guard index + 1 < chars.count,
      chars[index] == "!",
      chars[index + 1] == "[",
      !isEscaped(chars, at: index),
      let altEnd = findImageAltEnd(in: chars, start: index + 2),
      altEnd + 1 < chars.count,
      chars[altEnd + 1] == "(",
      let destinationEnd = findImageDestinationEnd(in: chars, start: altEnd + 2)
    else {
      return nil
    }

    let alt = String(chars[(index + 2)..<altEnd])
    let destination = String(chars[(altEnd + 2)..<destinationEnd])
    guard let source = markdownImageSource(from: destination) else { return nil }
    return MarkdownImageToken(altText: alt, source: source, end: destinationEnd + 1)
  }

  private static func markdownImageSource(from destination: String) -> String? {
    let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.first == "<", let close = trimmed.firstIndex(of: ">") {
      let start = trimmed.index(after: trimmed.startIndex)
      guard start <= close else { return nil }
      return String(trimmed[start..<close])
    }

    let chars = Array(trimmed)
    var end = 0
    while end < chars.count, !chars[end].isWhitespace {
      end += 1
    }
    guard end > 0 else { return nil }
    return String(chars[0..<end])
      .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
  }

  private static func findImageAltEnd(in chars: [Character], start: Int) -> Int? {
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "]" {
        return index
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      index += 1
    }
    return nil
  }

  private static func findImageDestinationEnd(in chars: [Character], start: Int) -> Int? {
    var depth = 0
    var index = start
    while index < chars.count {
      if chars[index] == "\\" {
        index += 2
        continue
      }
      if chars[index] == "\n" || chars[index] == "\r" {
        return nil
      }
      if chars[index] == "(" {
        depth += 1
      } else if chars[index] == ")" {
        if depth == 0 {
          return index
        }
        depth -= 1
      }
      index += 1
    }
    return nil
  }

  private static func isEscaped(_ chars: [Character], at index: Int) -> Bool {
    guard index > 0 else { return false }
    var slashCount = 0
    var cursor = index - 1
    while cursor >= 0, chars[cursor] == "\\" {
      slashCount += 1
      cursor -= 1
    }
    return slashCount % 2 == 1
  }

  static func findClose(chars: [Character], start: Int, marker: String) -> Int? {
    let markerChars = Array(marker)
    guard !markerChars.isEmpty, start <= chars.count else { return nil }
    var i = start
    while i + markerChars.count <= chars.count {
      if chars[i] == "\\" {
        i += 2
        continue
      }
      var matched = true
      for (offset, mc) in markerChars.enumerated() where chars[i + offset] != mc {
        matched = false
        break
      }
      if matched {
        return i
      }
      i += 1
    }
    return nil
  }

  static func xmlEscaped(_ value: String) -> String {
    value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&#39;")
  }
}


extension ConversationExportContent {
  /// The document the shared writers in MaiDocuments export. With an image
  /// catalog the attached, remote, and rendered images travel along; without
  /// one only the text does, which is all markdown needs.
  static func exportDocument(
    conversation: Conversation,
    options: DocumentExportOptions = .init(),
    imageCatalog: ImageResourceCatalog? = nil
  ) -> ExportDocument {
    var entries: [ExportEntry] = []
    var diagramSources: [String] = []
    for message in conversation.messages {
      if message.role == .tool && !options.includeToolCalls { continue }
      let content = messageContent(for: message, options: options)
      let attachments = message.attachments.compactMap { attachment -> ExportImage? in
        guard attachment.kind == .image, let resource = imageCatalog?.resource(for: attachment)
        else { return nil }
        return ExportImage(
          name: attachment.displayName, mediaType: resource.mediaType, data: resource.data,
          width: resource.width, height: resource.height)
      }
      let entry = ExportEntry(
        role: ExportRole(rawValue: message.role.rawValue) ?? .assistant,
        reasoning: content.reasoningSections,
        body: content.visibleText,
        attachments: attachments)
      if !entry.isEmpty { entries.append(entry) }
      for text in [content.visibleText] + content.reasoningSections {
        diagramSources.append(contentsOf: ExportDocument.mermaidSources(in: text))
      }
    }
    var document = ExportDocument(
      identifier: conversation.id,
      title: summary(for: conversation).title,
      createdAt: conversation.createdAt,
      updatedAt: conversation.updatedAt,
      generator: "PocketMai",
      entries: entries)
    if let imageCatalog {
      let images = imageCatalog.exportImages(diagramSources: diagramSources)
      document.inlineImages = images.inline
      document.diagrams = images.diagrams
    }
    return document
  }
}
