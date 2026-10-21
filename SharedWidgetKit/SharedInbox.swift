import Foundation

/// What the share extension recognised in a shared item, which decides how the
/// app attaches it: pictures follow the picture workflow (resize or OCR), voice
/// messages are transcribed, documents are converted to text, and plain text or
/// links are appended to the composer draft. Webxdc documents are installed in
/// the app library before the remaining items reach the composer.
enum SharedInboxItemKind: String, Codable, Sendable {
  case image
  case audio
  case document
  case text
  case link
}

/// One item handed to PocketMai from another app's share sheet.
///
/// The payload of a file item lives in the App Group container so it survives
/// the extension going away; only its name travels in the queue.
struct SharedInboxItem: Codable, Equatable, Identifiable, Sendable {
  var id: UUID
  var kind: SharedInboxItemKind
  /// The name to show in chat, e.g. `AUD-20260101-WA0002.opus`.
  var filename: String
  /// The file's name inside the inbox folder, or nil for text and links.
  var storedName: String?
  /// The shared text or URL, for `.text` and `.link` items.
  var text: String?
  var createdAt: Date

  init(
    id: UUID = UUID(),
    kind: SharedInboxItemKind,
    filename: String,
    storedName: String? = nil,
    text: String? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.kind = kind
    self.filename = filename
    self.storedName = storedName
    self.text = text
    self.createdAt = createdAt
  }
}

/// The hand-off between the share extension and the app.
///
/// The extension copies each shared file into the App Group container and
/// appends a queue entry; the app drains the queue when it next becomes active
/// and routes Webxdc apps to the app library and attachments to the composer.
enum SharedInbox {
  static let appGroupID = SharedAppState.appGroupID
  /// Files older than this are swept on the next drain: the extension may have
  /// stored something the app never got to import.
  private static let staleFileAge: TimeInterval = 7 * 24 * 60 * 60
  private static let queueKey = "share.inbox.items"
  private static let directoryName = "SharedInbox"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupID)
  }

  static var directoryURL: URL? {
    FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
      .appendingPathComponent(directoryName, isDirectory: true)
  }

  static var hasPendingItems: Bool {
    !queuedItems().isEmpty
  }

  // MARK: - Extension side

  /// Copies shared data into the App Group container and returns the queue
  /// entry describing it, or nil when the container is unavailable.
  static func storeFile(
    data: Data,
    filename: String,
    kind: SharedInboxItemKind
  ) -> SharedInboxItem? {
    guard let directory = directoryURL else { return nil }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let name = sanitizedFilename(filename)
    let storedName = UUID().uuidString + "-" + name
    do {
      try data.write(to: directory.appendingPathComponent(storedName), options: .atomic)
    } catch {
      return nil
    }
    return SharedInboxItem(kind: kind, filename: name, storedName: storedName)
  }

  static func enqueue(_ items: [SharedInboxItem]) {
    guard !items.isEmpty else { return }
    let queued = queuedItems() + items
    guard let data = try? JSONEncoder().encode(queued) else { return }
    defaults?.set(data, forKey: queueKey)
  }

  // MARK: - App side

  /// Returns everything the share extension left behind and empties the queue.
  static func takeAll() -> [SharedInboxItem] {
    let items = queuedItems()
    defaults?.removeObject(forKey: queueKey)
    removeStaleFiles(keeping: items)
    return items
  }

  static func fileURL(for item: SharedInboxItem) -> URL? {
    guard let storedName = item.storedName, let directory = directoryURL else { return nil }
    return directory.appendingPathComponent(storedName)
  }

  /// Drops an item's payload once it has been imported (or failed to import).
  static func discard(_ item: SharedInboxItem) {
    guard let url = fileURL(for: item) else { return }
    try? FileManager.default.removeItem(at: url)
  }

  // MARK: - Internals

  private static func queuedItems() -> [SharedInboxItem] {
    guard let data = defaults?.data(forKey: queueKey) else { return [] }
    return (try? JSONDecoder().decode([SharedInboxItem].self, from: data)) ?? []
  }

  /// A share the app never imported (it was force-quit, or the import failed)
  /// would otherwise keep its file in the container forever.
  private static func removeStaleFiles(keeping items: [SharedInboxItem]) {
    guard let directory = directoryURL else { return }
    let keep = Set(items.compactMap(\.storedName))
    let manager = FileManager.default
    let contents =
      (try? manager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles])) ?? []
    let cutoff = Date().addingTimeInterval(-staleFileAge)
    for url in contents where !keep.contains(url.lastPathComponent) {
      let modified =
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      guard let modified, modified < cutoff else { continue }
      try? manager.removeItem(at: url)
    }
  }

  /// Keeps the extension from writing outside its folder and preserves the
  /// extension, which is what the app's importers switch on.
  private static func sanitizedFilename(_ filename: String) -> String {
    let name = (filename as NSString).lastPathComponent
    let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
      .union(.controlCharacters)
      .union(.newlines)
    let cleaned = name.components(separatedBy: invalid).joined()
    let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "shared-item" }
    return String(trimmed.suffix(120))
  }
}
