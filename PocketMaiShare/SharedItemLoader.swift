import Foundation
import UniformTypeIdentifiers

/// Turns the attachments of a share sheet into inbox items.
///
/// Apps describe the same content in several ways: WhatsApp offers a voice
/// message as an `.opus` file, Telegram as `.ogg`, Photos hands over an image
/// with no file behind it, Safari shares a URL. Each provider is asked for the
/// richest representation it has, in that order: a file (so the name and
/// extension survive), then a picture, then a link, then plain text.
///
/// The providers arrive on the main actor with the extension's view controller
/// and are not safe to move off it, so the whole walk stays there; the work of
/// producing each representation happens inside `NSItemProvider`.
@MainActor
enum SharedItemLoader {
  /// The biggest attachment worth copying into the App Group container. Voice
  /// messages and documents are far below it; a video usually is not.
  private static let maximumItemBytes = 96 * 1024 * 1024

  private static let audioExtensions: Set<String> = [
    "opus", "ogg", "oga", "m4a", "mp3", "wav", "wave", "caf", "aac", "aif", "aiff", "aifc",
    "amr", "flac", "mp4a", "mpga", "3gp", "3gpp", "wma",
  ]

  private static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
  ]

  static func items(in extensionItems: [NSExtensionItem]) async -> [SharedInboxItem] {
    var items: [SharedInboxItem] = []
    for extensionItem in extensionItems {
      for provider in extensionItem.attachments ?? [] {
        if let item = await self.item(from: provider) {
          items.append(item)
        }
      }
    }
    return items
  }

  private static func item(from provider: NSItemProvider) async -> SharedInboxItem? {
    if let identifier = fileTypeIdentifier(for: provider),
      let item = await fileItem(from: provider, typeIdentifier: identifier)
    {
      return item
    }
    if let item = await fileURLItem(from: provider) {
      return item
    }
    if let item = await imageItem(from: provider) {
      return item
    }
    if let item = await linkItem(from: provider) {
      return item
    }
    return await textItem(from: provider)
  }

  // MARK: - Files

  /// The first registered type that describes a file rather than a link or a
  /// bare string. Plain text only counts when the provider names a file, which
  /// is how a shared `.txt` differs from a shared selection of text.
  private static func fileTypeIdentifier(for provider: NSItemProvider) -> String? {
    let hasFilename = !(provider.suggestedName ?? "").isEmpty
    for identifier in provider.registeredTypeIdentifiers {
      guard let type = UTType(identifier) else { continue }
      guard !type.conforms(to: .url) else { continue }
      if type.conforms(to: .text), !hasFilename { continue }
      guard type.conforms(to: .data) else { continue }
      return identifier
    }
    // A type this device has never seen — messengers declare their own for Opus
    // voice messages — still names a file when the item comes with a file name.
    guard hasFilename else { return nil }
    return provider.registeredTypeIdentifiers.first { identifier in
      guard let type = UTType(identifier) else { return true }
      return !type.conforms(to: .url)
    }
  }

  private static func fileItem(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> SharedInboxItem? {
    guard let file = await loadFileData(from: provider, typeIdentifier: typeIdentifier),
      !file.data.isEmpty
    else {
      return nil
    }
    let type = UTType(typeIdentifier)
    let filename = Self.filename(
      suggested: provider.suggestedName,
      type: type,
      fallback: "shared-file",
      sourceFilename: file.filename)
    return SharedInbox.storeFile(
      data: file.data,
      filename: filename,
      kind: kind(for: type, filename: filename))
  }

  /// Some apps share a document only as a file URL, e.g. a book picked in Files.
  private static func fileURLItem(from provider: NSItemProvider) async -> SharedInboxItem? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
      return nil
    }
    guard let url = await loadURL(from: provider, typeIdentifier: UTType.fileURL.identifier),
      url.isFileURL
    else {
      return nil
    }
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }
    guard let data = try? Data(contentsOf: url), !data.isEmpty,
      data.count <= maximumItemBytes
    else {
      return nil
    }
    let filename = url.lastPathComponent
    return SharedInbox.storeFile(
      data: data,
      filename: filename,
      kind: kind(for: UTType(filenameExtension: url.pathExtension), filename: filename))
  }

  // MARK: - Pictures without a file

  private static func imageItem(from provider: NSItemProvider) async -> SharedInboxItem? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
    guard let data = await loadData(from: provider, typeIdentifier: UTType.image.identifier),
      !data.isEmpty
    else {
      return nil
    }
    let filename = Self.filename(
      suggested: provider.suggestedName,
      type: UTType.jpeg,
      fallback: "shared-image")
    return SharedInbox.storeFile(data: data, filename: filename, kind: .image)
  }

  // MARK: - Links and text

  private static func linkItem(from provider: NSItemProvider) async -> SharedInboxItem? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
    guard let url = await loadURL(from: provider, typeIdentifier: UTType.url.identifier),
      !url.isFileURL
    else {
      return nil
    }
    return SharedInboxItem(kind: .link, filename: url.absoluteString, text: url.absoluteString)
  }

  private static func textItem(from provider: NSItemProvider) async -> SharedInboxItem? {
    guard provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) else { return nil }
    guard let text = await loadText(from: provider),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    return SharedInboxItem(kind: .text, filename: "Shared text", text: text)
  }

  // MARK: - Naming

  private static func filename(
    suggested: String?, type: UTType?, fallback: String, sourceFilename: String? = nil
  ) -> String {
    let name = (suggested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let base =
      name.isEmpty
      ? (sourceFilename ?? "\(fallback)-\(Int(Date().timeIntervalSince1970))") : name
    guard (base as NSString).pathExtension.isEmpty else { return base }
    // A generic data/ZIP type may have no knowledge of the .xdc extension.
    if let ext = (sourceFilename as NSString?)?.pathExtension, !ext.isEmpty {
      return base + "." + ext
    }
    guard let ext = type?.preferredFilenameExtension else { return base }
    return base + "." + ext
  }

  private static func kind(for type: UTType?, filename: String) -> SharedInboxItemKind {
    let ext = (filename as NSString).pathExtension.lowercased()
    // Opus and Ogg are not always registered as audio types, so the extension
    // decides first: that is exactly how WhatsApp and Telegram voice messages
    // arrive.
    if audioExtensions.contains(ext) { return .audio }
    if imageExtensions.contains(ext) { return .image }
    if let type {
      if type.conforms(to: .image) { return .image }
      if type.conforms(to: .audio) || type.conforms(to: .movie) { return .audio }
    }
    return .document
  }

  // MARK: - Provider bridging

  // The handlers below are marked `@Sendable` on purpose: `NSItemProvider`
  // calls them on its own queue, so they must not inherit the main actor.

  private static func loadFileData(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> (data: Data, filename: String?)? {
    let limit = maximumItemBytes
    let fileData: (data: Data, filename: String?)? = await withCheckedContinuation { continuation in
      let handler: @Sendable (URL?, (any Error)?) -> Void = { url, _ in
        // The URL is only valid until this handler returns, so the bytes are
        // read here rather than mapped.
        guard let url,
          let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
          size <= limit
        else {
          continuation.resume(returning: nil)
          return
        }
        guard let data = try? Data(contentsOf: url) else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: (data, url.lastPathComponent))
      }
      _ = provider.loadFileRepresentation(
        forTypeIdentifier: typeIdentifier,
        completionHandler: handler)
    }
    if let fileData { return fileData }
    guard let data = await loadData(from: provider, typeIdentifier: typeIdentifier) else {
      return nil
    }
    return (data, nil)
  }

  private static func loadData(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> Data? {
    guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }
    let limit = maximumItemBytes
    return await withCheckedContinuation { continuation in
      let handler: @Sendable (Data?, (any Error)?) -> Void = { data, _ in
        guard let data, data.count <= limit else {
          continuation.resume(returning: nil)
          return
        }
        continuation.resume(returning: data)
      }
      _ = provider.loadDataRepresentation(
        forTypeIdentifier: typeIdentifier,
        completionHandler: handler)
    }
  }

  private static func loadURL(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> URL? {
    let value = await loadItemText(from: provider, typeIdentifier: typeIdentifier)
    guard let value else { return nil }
    return URL(string: value)
  }

  private static func loadText(from provider: NSItemProvider) async -> String? {
    await loadItemText(from: provider, typeIdentifier: UTType.text.identifier)
  }

  /// Reads a provider item that is meant to be text: a URL, a string, an
  /// attributed string, or UTF-8 data.
  private static func loadItemText(
    from provider: NSItemProvider,
    typeIdentifier: String
  ) async -> String? {
    await withCheckedContinuation { continuation in
      let handler: @Sendable (NSSecureCoding?, (any Error)?) -> Void = { item, _ in
        switch item {
        case let url as URL:
          continuation.resume(returning: url.absoluteString)
        case let text as String:
          continuation.resume(returning: text)
        case let attributed as NSAttributedString:
          continuation.resume(returning: attributed.string)
        case let data as Data:
          continuation.resume(returning: String(data: data, encoding: .utf8))
        default:
          continuation.resume(returning: nil)
        }
      }
      provider.loadItem(
        forTypeIdentifier: typeIdentifier,
        options: nil,
        completionHandler: handler)
    }
  }
}
