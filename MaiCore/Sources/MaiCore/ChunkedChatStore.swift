import Foundation

/// File generations are pinned for the duration of a read. The lock covers
/// file I/O on workers, never rendering or callbacks into the UI.
final class ChatStorageAccess: @unchecked Sendable {
  static let shared = ChatStorageAccess()
  private let lock = NSLock()
  private final class Access {
    let lock = NSRecursiveLock()
    var users = 0
  }
  private var locks: [URL: Access] = [:]
  private var pins: [URL: [String: Int]] = [:]
  private var retired: [URL: Set<String>] = [:]
  static func pin(_ files: Set<String>, in directory: URL, delta: Int) {
    let directory = URL(fileURLWithPath: directory.path, isDirectory: true).standardizedFileURL
    shared.lock.withLock {
      for file in files {
        let count = (shared.pins[directory]?[file] ?? 0) + delta
        shared.pins[directory, default: [:]][file] = count > 0 ? count : nil
      }
      if shared.pins[directory]?.isEmpty == true { shared.pins[directory] = nil }
    }
  }
  static func reclaim(_ expired: Set<String>, keeping retained: Set<String>, in directory: URL) {
    let directory = URL(fileURLWithPath: directory.path, isDirectory: true).standardizedFileURL
    let removable = shared.lock.withLock {
      let candidates = expired.union(shared.retired[directory] ?? []).subtracting(retained)
      let pinned = Set(shared.pins[directory, default: [:]].keys)
      let retained = candidates.intersection(pinned)
      shared.retired[directory] = retained.isEmpty ? nil : retained
      return candidates.subtracting(pinned)
    }
    for file in removable
    where !file.contains("/") && !file.contains("\\")
      && (file.hasSuffix(".json") || file.hasSuffix(".blob"))
      && UUID(uuidString: String(file.dropLast(5))) != nil
    {
      try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
    }
  }
  static func withLock<T>(at url: URL, _ body: () throws -> T) rethrows -> T {
    let url = URL(fileURLWithPath: url.path).standardizedFileURL
    let access = shared.lock.withLock {
      let result = shared.locks[url] ?? Access()
      result.users += 1
      shared.locks[url] = result
      return result
    }
    defer {
      shared.lock.withLock {
        access.users -= 1
        if access.users == 0 { shared.locks[url] = nil }
      }
    }
    return try access.lock.withLock(body)
  }
}

extension CodingUserInfoKey {
  /// Set only by the local page reader. Portable imports cannot introduce
  /// filesystem references through attachment fields.
  public static let pmaiChatStorageDirectory = CodingUserInfoKey(
    rawValue: "pmai.chatStorageDirectory")!
}

/// A window is a projection, never a complete transcript. It is deliberately
/// excluded from the portable JSON schema.
public struct ChatHistoryWindow: Equatable, Sendable {
  public var range: Range<Int>
  public var totalCount: Int
  public var revision: UUID
  public var conversationCount: Int? = nil
  public var hasEarlier: Bool { range.lowerBound > 0 }
  public var hasLater: Bool { range.upperBound < totalCount }
}

private final class ChatTranscriptPin: @unchecked Sendable {
  let directory: URL
  let files: Set<String>
  init(directory: URL, files: Set<String>) {
    self.directory = directory
    self.files = files
    ChatStorageAccess.pin(files, in: directory, delta: 1)
  }
  deinit { ChatStorageAccess.pin(files, in: directory, delta: -1) }
}

public struct AgentTranscriptPage: Sendable {
  public var messages: [AgentMessage]
  public var window: ChatHistoryWindow?
  public init(messages: [AgentMessage], window: ChatHistoryWindow? = nil) {
    self.messages = messages
    self.window = window
  }
}

/// A completed child can stay in the process table without retaining its body.
public struct StoredAgentTranscript: Equatable, Sendable {
  let directory: URL
  let snapshot: Data
  private let pin: ChatTranscriptPin
  init(directory: URL, snapshot: Data) throws {
    self.directory = directory
    self.snapshot = snapshot
    pin = ChatTranscriptPin(
      directory: directory,
      files: try JSONDecoder().decode(ChatChunkManifest.self, from: snapshot).referencedFiles)
  }
  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.directory == rhs.directory && lhs.snapshot == rhs.snapshot
  }
  func manifest() throws -> ChatChunkManifest {
    try JSONDecoder().decode(ChatChunkManifest.self, from: snapshot)
  }
  public func loadPage(before: Int? = nil) throws -> AgentTranscriptPage {
    defer { withExtendedLifetime(pin) {} }
    return try ChatStorageAccess.withLock(at: directory.deletingPathExtension()) {
      let saved = try manifest()
      let range = saved.pageRange(before: before, limit: 64)
      struct Messages: Decodable { var messages: [AgentMessage] }
      let data = try saved.data(in: directory, range: range, includeChildren: false)
      let messages = try MaiJSONCoding.default.makeDecoder().decode(Messages.self, from: data)
        .messages
      return AgentTranscriptPage(
        messages: messages,
        window: .init(range: range, totalCount: saved.count, revision: saved.revision))
    }
  }

  public func loadMessages() throws -> [AgentMessage] {
    defer { withExtendedLifetime(pin) {} }
    return try ChatStorageAccess.withLock(at: directory.deletingPathExtension()) {
      let data = try manifest().data(in: directory)
      return try MaiJSONCoding.default.makeDecoder().decode(AgentProcessRecord.self, from: data)
        .messages
    }
  }
}

/// Shared by unchanged value snapshots. Mutations detach the ledger, so a
/// background save cannot clear edits made after that snapshot was captured.
public final class ChatHistoryChanges: @unchecked Sendable, Equatable {
  private let lock = NSLock()
  private var source: URL?
  private var revision: UUID?
  private var dirtyStart = 0
  private var committedCount = -1

  public init() {}
  public static func == (lhs: ChatHistoryChanges, rhs: ChatHistoryChanges) -> Bool { true }
  public func copy() -> ChatHistoryChanges {
    lock.withLock {
      let result = ChatHistoryChanges()
      result.source = source
      result.revision = revision
      result.dirtyStart = dirtyStart
      result.committedCount = committedCount
      return result
    }
  }
  public func isCommitted(count: Int) -> Bool {
    lock.withLock { committedCount == count && dirtyStart == count }
  }
  public func changed(from index: Int) { lock.withLock { dirtyStart = min(dirtyStart, index) } }
  func start(in url: URL, revision: UUID) -> Int {
    lock.withLock { source == url && self.revision == revision ? dirtyStart : 0 }
  }
  func committed(to url: URL, revision: UUID, count: Int) {
    lock.withLock {
      source = url
      self.revision = revision
      dirtyStart = count
      committedCount = count
    }
  }
}

public protocol PagedStoredChat: StoredChat {
  var historyWindow: ChatHistoryWindow? { get set }
  var historyChanges: ChatHistoryChanges { get set }
  var historyMessageCount: Int { get }
  var subagents: [AgentProcessRecord] { get set }
  func historyMetadata(coding: MaiJSONCoding) throws -> Data
  func visitHistory(coding: MaiJSONCoding, startingAt: Int, _ visit: (Data) throws -> Void) throws
}

public enum ChatHistoryError: Error, LocalizedError {
  case invalidFile, unsupportedVersion, staleWindow, incompleteSnapshot, partialExport
  public var errorDescription: String? {
    switch self {
    case .invalidFile: "Invalid conversation storage."
    case .unsupportedVersion: "This conversation requires a newer pmai version."
    case .staleWindow: "The conversation changed. Reload it before editing."
    case .incompleteSnapshot:
      "Some conversation files are not available yet. Try again after syncing."
    case .partialExport: "Load the complete conversation before exporting it."
    }
  }
}

/// Immutable chunks are published by replacing one small manifest last. Readers
/// pin its revision; old chunks remain valid for readers and iCloud downloads.
struct ChatChunkManifest: Codable {
  static let formatName = "pmai-chunks"
  static func canonicalMetadata(_ data: Data) throws -> Data {
    try JSONSerialization.data(
      withJSONObject: JSONSerialization.jsonObject(with: data), options: [.sortedKeys])
  }
  var format = Self.formatName
  var version = 1
  var partsDirectory: String?
  var revision = UUID()
  var metadata: Data
  var chunks: [Chunk] = []
  var children: [ChatChunkManifest] = []
  var count: Int { chunks.reduce(0) { $0 + $1.count } }

  struct Chunk: Codable, Equatable {
    var filename: String
    var count: Int
    var bytes: Int
    var blobs: [String]? = nil
  }

  var referencedFiles: Set<String> {
    Set(chunks.flatMap { [$0.filename] + ($0.blobs ?? []) })
      .union(children.flatMap { Array($0.referencedFiles) })
  }

  func sameContents(as other: Self) -> Bool {
    metadata == other.metadata && chunks == other.chunks && children.count == other.children.count
      && zip(children, other.children).allSatisfy { $0.sameContents(as: $1) }
  }

  func directory(relativeTo url: URL) throws -> URL {
    let name = partsDirectory ?? url.lastPathComponent + ".parts"
    guard !name.contains("/"), !name.contains("\\"), name.hasSuffix(".parts") else {
      throw ChatHistoryError.invalidFile
    }
    return url.deletingLastPathComponent().appendingPathComponent(name)
  }

  func encoded() throws -> Data {
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
    object.removeValue(forKey: "format")
    let body = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    var result = Data("{\"format\":\"pmai-chunks\",".utf8)
    result.append(body.dropFirst())
    return result
  }

  static func read(at url: URL) throws -> Self? {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: 256) ?? Data()
    // Legacy files can be very large. Never run JSONSerialization on them just
    // to determine their format.
    guard prefix.starts(with: Data("{\"format\":\"pmai-chunks\",".utf8)) else { return nil }
    let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard manifest.format == formatName, manifest.version == 1 else {
      throw ChatHistoryError.unsupportedVersion
    }
    try manifest.validateShape()
    return manifest
  }

  private func validateShape() throws {
    for chunk in chunks {
      guard (1...64).contains(chunk.count), chunk.bytes > 0 else { throw ChatHistoryError.invalidFile }
    }
    for child in children { try child.validateShape() }
  }

  func pageRange(before: Int?, limit: Int) -> Range<Int> {
    let end = min(count, max(0, before ?? count))
    let start = max(0, end - max(0, min(limit, 256)))
    var offset = count
    var bytes = 0
    var boundedStart = start
    for chunk in chunks.reversed() {
      offset -= chunk.count
      guard offset < end, offset + chunk.count > start else { continue }
      if bytes > 0 && chunk.bytes > max(0, 1024 * 1024 - bytes) {
        boundedStart = max(start, offset + chunk.count)
        break
      }
      bytes += chunk.bytes
    }
    return boundedStart..<end
  }

  static func availablePage(at url: URL, before: Int?, limit: Int) throws -> Self? {
    guard let current = try read(at: url) else { return nil }
    let directory = try current.directory(relativeTo: url)
    do {
      try current.checkFiles(
        in: directory, range: current.pageRange(before: before, limit: limit),
        includeChildren: false, includeBlobs: false)
      return current
    } catch {
      if let previous = try? read(at: directory.appendingPathComponent("previous.json")) {
        try previous.checkFiles(
          in: directory, range: previous.pageRange(before: before, limit: limit),
          includeChildren: false, includeBlobs: false)
        return previous
      }
      throw ChatHistoryError.incompleteSnapshot
    }
  }

  func checkFiles(
    in directory: URL, range: Range<Int>? = nil, includeChildren: Bool = true,
    includeBlobs: Bool = true
  ) throws {
    var offset = 0
    for chunk in chunks {
      let end = offset + chunk.count
      defer { offset = end }
      if let range, end <= range.lowerBound || offset >= range.upperBound { continue }
      for blob in includeBlobs ? (chunk.blobs ?? []) : [] {
        guard blob.hasSuffix(".blob"), UUID(uuidString: String(blob.dropLast(5))) != nil,
          FileManager.default.fileExists(atPath: directory.appendingPathComponent(blob).path)
        else { throw ChatHistoryError.incompleteSnapshot }
      }
      guard UUID(uuidString: String(chunk.filename.dropLast(5))) != nil,
        chunk.filename.hasSuffix(".json"), chunk.count > 0,
        FileManager.default.fileExists(
          atPath: directory.appendingPathComponent(chunk.filename).path)
      else { throw ChatHistoryError.incompleteSnapshot }
    }
    if includeChildren {
      for child in children { try child.checkFiles(in: directory) }
    }
  }

  func data(in directory: URL, range: Range<Int>? = nil, includeChildren: Bool = true) throws
    -> Data
  {
    var output = Data()
    try write(in: directory, range: range, includeChildren: includeChildren) { output.append($0) }
    return output
  }

  func write(
    in directory: URL, range: Range<Int>? = nil, includeChildren: Bool = true,
    _ output: (Data) throws -> Void
  ) throws {
    var object = try JSONSerialization.jsonObject(with: metadata) as? [String: Any] ?? [:]
    object.removeValue(forKey: "messages")
    object.removeValue(forKey: "subagents")
    // Do not serialize a giant array simply to insert two fields into it.
    var header = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    guard header.popLast() == 125 else { throw ChatHistoryError.invalidFile }
    try output(header)
    try output(Data((object.isEmpty ? "\"messages\":[" : ",\"messages\":[").utf8))
    let wanted = range ?? 0..<count
    var offset = 0
    var first = true
    for chunk in chunks {
      let end = offset + chunk.count
      defer { offset = end }
      guard offset < wanted.upperBound, end > wanted.lowerBound else { continue }
      let data = try Data(contentsOf: directory.appendingPathComponent(chunk.filename))
      guard let values = try JSONSerialization.jsonObject(with: data) as? [Any], values.count == chunk.count
      else { throw ChatHistoryError.invalidFile }
      let start = max(0, wanted.lowerBound - offset)
      let stop = min(values.count, wanted.upperBound - offset)
      for value in values[start..<stop] {
        if !first { try output(Data(",".utf8)) }
        let expanded = try ChatChunkAssets.load(value, in: directory, lazyImages: range != nil)
        try output(JSONSerialization.data(withJSONObject: expanded, options: [.fragmentsAllowed]))
        first = false
      }
    }
    try output(Data("],\"subagents\":[".utf8))
    for (index, child) in children.enumerated() {
      if index > 0 { try output(Data(",".utf8)) }
      if includeChildren {
        try child.write(in: directory, output)
      } else {
        try output(child.metadata)
      }
    }
    try output(Data("]}".utf8))
  }
}

private enum ChatChunkAssets {
  static func store(_ value: Any, in directory: URL) throws -> Any {
    if let object = value as? [String: Any] {
      let encoded = try object.mapValues { try store($0, in: directory) }
      if object["_pmaiBlob"] != nil || object["_pmaiObject"] != nil {
        return ["_pmaiObject": encoded]
      }
      return encoded
    }
    if let array = value as? [Any] { return try array.map { try store($0, in: directory) } }
    if let string = value as? String, string.utf8.count > 64 * 1024 {
      let name = "\(UUID().uuidString).blob"
      try Data(string.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
      return ["_pmaiBlob": name, "bytes": string.utf8.count]
    }
    return value
  }

  static func names(in value: Any, literal: Bool = false) -> [String] {
    if let object = value as? [String: Any] {
      if !literal, let escaped = object["_pmaiObject"] { return names(in: escaped, literal: true) }
      if !literal, let name = object["_pmaiBlob"] as? String { return [name] }
      return object.values.flatMap { names(in: $0) }
    }
    return (value as? [Any] ?? []).flatMap { names(in: $0) }
  }

  static func load(_ value: Any, in directory: URL, lazyImages: Bool, literal: Bool = false) throws
    -> Any
  {
    if let object = value as? [String: Any] {
      if !literal, let escaped = object["_pmaiObject"] {
        return try load(escaped, in: directory, lazyImages: lazyImages, literal: true)
      }
      if !literal, let name = object["_pmaiBlob"] as? String {
        guard name.hasSuffix(".blob"), UUID(uuidString: String(name.dropLast(5))) != nil else {
          throw ChatHistoryError.invalidFile
        }
        return try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
      }
      var result: [String: Any] = [:]
      for (key, value) in object {
        // PocketMai attachments can fault image bytes in on the image loader's
        // actor. Portable exports and full provider reads always expand them.
        if lazyImages, key == "dataBase64", let blob = value as? [String: Any],
          let name = blob["_pmaiBlob"] as? String,
          name.hasSuffix(".blob"), UUID(uuidString: String(name.dropLast(5))) != nil
        {
          let url = directory.appendingPathComponent(name)
          result["storageDataURL"] = url.absoluteString
          result["storedDataLength"] = blob["bytes"]
        } else {
          result[key] = try load(value, in: directory, lazyImages: lazyImages)
        }
      }
      return result
    }
    if let array = value as? [Any] {
      return try array.map { try load($0, in: directory, lazyImages: lazyImages) }
    }
    return value
  }
}

private final class ChatChunkWriter {
  let directory: URL
  let previous: [ChatChunkManifest.Chunk]
  var chunks: [ChatChunkManifest.Chunk] = []
  var pending = Data("[".utf8)
  var count = 0
  var nonSystemCount = 0

  init(directory: URL, previous: [ChatChunkManifest.Chunk] = []) {
    self.directory = directory
    self.previous = previous
  }

  func append(_ original: Data) throws {
    let data = original
    if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["role"] as? String != "system"
    {
      nonSystemCount += 1
    }
    if count > 0 && (count >= 64 || pending.count + data.count + 2 > 256 * 1024) {
      try flush()
    }
    if count > 0 { pending.append(44) }
    pending.append(data)
    count += 1
  }

  private func previousValue(_ chunk: ChatChunkManifest.Chunk?) throws -> Data? {
    guard let chunk else { return nil }
    let data = try Data(contentsOf: directory.appendingPathComponent(chunk.filename))
    let value = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(
      withJSONObject: ChatChunkAssets.load(value, in: directory, lazyImages: false),
      options: [.sortedKeys])
  }

  func flush() throws {
    guard count > 0 else { return }
    pending.append(93)
    let old = previous.indices.contains(chunks.count) ? previous[chunks.count] : nil
    let value = try JSONSerialization.jsonObject(with: pending)
    let canonical = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    let oldValue = try previousValue(old)
    if let old, old.count == count, oldValue == canonical {
      chunks.append(old)
    } else {
      let name = "\(UUID().uuidString).json"
      let stored = try ChatChunkAssets.store(value, in: directory)
      try JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])
        .write(to: directory.appendingPathComponent(name), options: .atomic)
      chunks.append(
        .init(
          filename: name, count: count, bytes: pending.count,
          blobs: ChatChunkAssets.names(in: stored)))
    }
    pending = Data("[".utf8)
    count = 0
  }
}

private enum ChatChunkLimit: Error { case reached }

extension PagedStoredChat {
  func needsChunkStorage(coding: MaiJSONCoding) throws -> Bool {
    if subagents.count > 8 || subagents.contains(where: { $0.historyReference != nil }) {
      return true
    }
    var bytes = 0
    var count = 0
    do {
      try visitHistory(coding: coding, startingAt: 0) { data in
        bytes += data.count
        count += 1
        if bytes > 256 * 1024 || count > 64 { throw ChatChunkLimit.reached }
      }
      for child in subagents {
        for message in child.messages {
          count += 1
          if count > 64 { return true }
          bytes += try coding.makeEncoder().encode(message).count
          if bytes > 256 * 1024 { return true }
        }
      }
    } catch ChatChunkLimit.reached { return true }
    return false
  }

  func writeChunked(at url: URL, coding: MaiJSONCoding) throws {
    let directory = url.appendingPathExtension("parts")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let old =
      FileManager.default.fileExists(atPath: url.path)
      ? try ChatChunkManifest.read(at: url) : nil
    var manifest = ChatChunkManifest(
      partsDirectory: directory.lastPathComponent,
      metadata: try ChatChunkManifest.canonicalMetadata(historyMetadata(coding: coding)))
    guard historyWindow == nil else { throw ChatHistoryError.partialExport }
    do {
      let writer = ChatChunkWriter(directory: directory, previous: old?.chunks ?? [])
      var start = 0
      if let old {
        let dirty = historyChanges.start(in: url, revision: old.revision)
        for (index, chunk) in old.chunks.enumerated() {
          guard start + chunk.count <= dirty else { break }
          if index == old.chunks.count - 1, chunk.count < 64, chunk.bytes < 256 * 1024 { break }
          writer.chunks.append(chunk)
          start += chunk.count
        }
      }
      try visitHistory(coding: coding, startingAt: start, writer.append)
      try writer.flush()
      manifest.chunks = writer.chunks
      var previousChildren: [UUID: ChatChunkManifest] = [:]
      for child in old?.children ?? [] {
        let record = try coding.makeDecoder().decode(AgentProcessRecord.self, from: child.metadata)
        previousChildren[record.id] = child
      }
      manifest.children = try subagents.map { saved in
        if let reference = saved.historyReference,
          reference.directory.standardizedFileURL.path == directory.standardizedFileURL.path
        {
          return try reference.manifest()
        }
        var child = saved
        if let reference = child.historyReference {
          child.messages = try reference.loadMessages()
          child.historyReference = nil
        }
        var header = child
        header.messages = []
        let childWriter = ChatChunkWriter(
          directory: directory,
          previous: previousChildren[child.id]?.chunks ?? [])
        for message in child.messages {
          try childWriter.append(coding.makeEncoder().encode(message))
        }
        try childWriter.flush()
        var result = ChatChunkManifest(
          metadata: try ChatChunkManifest.canonicalMetadata(coding.makeEncoder().encode(header)))
        result.chunks = childWriter.chunks
        if let previous = previousChildren[child.id], previous.sameContents(as: result) {
          return previous
        }
        return result
      }
    }
    if let old, old.metadata == manifest.metadata,
      old.sameContents(as: manifest)
    {
      historyChanges.committed(to: url, revision: old.revision, count: old.count)
      return
    }
    // A missing iCloud chunk is an incomplete download, not a corrupt chat.
    try manifest.checkFiles(in: directory, includeChildren: false)
    let previousURL = directory.appendingPathComponent("previous.json")
    let expired = (try? ChatChunkManifest.read(at: previousURL))?.referencedFiles ?? []
    if let old { try old.encoded().write(to: previousURL, options: .atomic) }
    try manifest.encoded().write(to: url, options: .atomic)
    let retained = manifest.referencedFiles.union(old?.referencedFiles ?? [])
    ChatStorageAccess.reclaim(expired, keeping: retained, in: directory)
    historyChanges.committed(to: url, revision: manifest.revision, count: manifest.count)
  }
}

extension ChatFileStore where Chat: PagedStoredChat {
  /// A bounded projection. `loadChat` remains the explicit full-history API for
  /// inference, compaction, export and operations spanning page boundaries.
  public func loadChatPage(id: UUID, before: Int? = nil, limit: Int = 64) throws -> Chat? {
    return try ChatStorageAccess.withLock(at: fileURL(for: id)) {
      let url = fileURL(for: id)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      guard
        let manifest = try ChatChunkManifest.availablePage(at: url, before: before, limit: limit)
      else {
        let size =
          (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
          ?? 0
        if size <= 256 * 1024, let chat = try loadChat(id: id),
          try !chat.needsChunkStorage(coding: coding)
        {
          guard limit > 0 else {
            let metadata = try chat.historyMetadata(coding: coding)
            var projection = try coding.makeDecoder().decode(Chat.self, from: metadata)
            projection.subagents = chat.subagents
            let count = chat.historyMessageCount
            projection.historyWindow = .init(
              range: count..<count, totalCount: count, revision: UUID())
            let fields = try JSONSerialization.jsonObject(with: metadata) as? [String: Any]
            projection.historyWindow?.conversationCount = fields?["_pmaiMessageCount"] as? Int
            return projection
          }
          return chat
        }
        // Convert legacy JSON once, without materializing its transcript.
        try migrateChat(id: id)
        return try loadChatPage(id: id, before: before, limit: limit)
      }
      let directory = try manifest.directory(relativeTo: url)
      let range = manifest.pageRange(before: before, limit: limit)
      let decoder = coding.makeDecoder()
      decoder.userInfo[.pmaiChatStorageDirectory] = directory
      var chat = try decoder.decode(
        Chat.self,
        from: manifest.data(in: directory, range: range, includeChildren: false))
      chat.historyWindow = .init(
        range: range, totalCount: manifest.count, revision: manifest.revision)
      let metadata = try JSONSerialization.jsonObject(with: manifest.metadata) as? [String: Any]
      chat.historyWindow?.conversationCount = metadata?["_pmaiMessageCount"] as? Int
      try attachChildren(to: &chat, manifest: manifest, directory: directory)
      return chat
    }
  }

  private func attachChildren(to chat: inout Chat, manifest: ChatChunkManifest, directory: URL)
    throws
  {
    guard chat.subagents.count == manifest.children.count else {
      throw ChatHistoryError.invalidFile
    }
    for index in chat.subagents.indices {
      chat.subagents[index].historyReference = try StoredAgentTranscript(
        directory: directory, snapshot: try manifest.children[index].encoded())
    }
  }

  /// Complete parent context, with child bodies still faulted out. This is the
  /// reader used by inference and editing; `loadChat` also expands children.
  public func loadChatHistory(id: UUID) throws -> Chat? {
    return try ChatStorageAccess.withLock(at: fileURL(for: id)) {
      let url = fileURL(for: id)
      guard FileManager.default.fileExists(atPath: url.path) else { return nil }
      guard let manifest = try ChatChunkManifest.read(at: url) else { return try loadChat(id: id) }
      let directory = try manifest.directory(relativeTo: url)
      try manifest.checkFiles(in: directory, includeChildren: false)
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString)
      _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
      let handle = try FileHandle(forWritingTo: temporary)
      defer {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
      }
      try manifest.write(in: directory, includeChildren: false) { try handle.write(contentsOf: $0) }
      try handle.close()
      var chat = try coding.makeDecoder().decode(
        Chat.self, from: Data(contentsOf: temporary, options: .mappedIfSafe))
      try attachChildren(to: &chat, manifest: manifest, directory: directory)
      let metadata = try JSONSerialization.jsonObject(with: manifest.metadata) as? [String: Any]
      if metadata?["commands"] == nil, var agent = chat as? AgentChat {
        for child in agent.subagents {
          let messages = try child.historyReference?.loadMessages() ?? child.messages
          agent.commands += AgentCommandRecord.recovering(
            messages: messages, sessionID: agent.sessionID,
            run: .init(
              runID: child.runID, parentRunID: child.parentRunID, agentID: child.agentID,
              depth: child.depth, pid: child.pid))
        }
        if let recovered = agent as? Chat { chat = recovered }
      }
      chat.historyChanges.committed(to: url, revision: manifest.revision, count: manifest.count)
      return chat
    }
  }

  /// Streams the original portable schema to a file; no complete JSON buffer.
  public func exportChat(id: UUID, to destination: URL) throws {
    return try ChatStorageAccess.withLock(at: fileURL(for: id)) {
      let source = fileURL(for: id)
      let temporary = destination.appendingPathExtension(UUID().uuidString)
      _ = FileManager.default.createFile(atPath: temporary.path, contents: nil)
      let handle = try FileHandle(forWritingTo: temporary)
      defer {
        try? handle.close()
        try? FileManager.default.removeItem(at: temporary)
      }
      if let manifest = try ChatChunkManifest.read(at: source) {
        try manifest.write(in: manifest.directory(relativeTo: source)) {
          try handle.write(contentsOf: $0)
        }
      } else {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
          try handle.write(contentsOf: data)
        }
      }
      try handle.close()
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
      } else {
        try FileManager.default.moveItem(at: temporary, to: destination)
      }
    }
  }

  public func migrateChat(id: UUID) throws {
    return try ChatStorageAccess.withLock(at: fileURL(for: id)) {
      let url = fileURL(for: id)
      if try ChatChunkManifest.read(at: url) != nil { return }
      let directory = url.appendingPathExtension("parts")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let scanner = try ChatJSONScanner(url: url)
      var manifest = try scanner.manifest(in: directory)
      try scanner.whitespace()
      guard try scanner.peek() == nil else { throw ChatHistoryError.invalidFile }
      manifest.partsDirectory = directory.lastPathComponent
      try manifest.checkFiles(in: directory)
      // Keep the original until migration has been fully published.
      let backup = url.appendingPathExtension("legacy")
      if !FileManager.default.fileExists(atPath: backup.path) {
        try FileManager.default.copyItem(at: url, to: backup)
      }
      try manifest.encoded().write(to: url, options: .atomic)
    }
  }
}

/// A small structural scanner, not a second semantic JSON decoder. It captures
/// one value at a time, understands strings/escapes, and leaves schema handling
/// to the existing Decodable implementations.
private final class ChatJSONScanner {
  let handle: FileHandle
  var buffer = Data()
  var index = 0
  init(url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
  deinit { try? handle.close() }
  func peek() throws -> UInt8? {
    if index == buffer.count {
      buffer = try handle.read(upToCount: 64 * 1024) ?? Data()
      index = 0
    }
    return index < buffer.count ? buffer[index] : nil
  }
  func take() throws -> UInt8 {
    guard let byte = try peek() else { throw ChatHistoryError.invalidFile }
    index += 1
    return byte
  }
  func whitespace() throws {
    while let byte = try peek(), [9, 10, 13, 32].contains(byte) { index += 1 }
  }
  func expect(_ byte: UInt8) throws {
    try whitespace()
    guard try take() == byte else { throw ChatHistoryError.invalidFile }
  }
  func value() throws -> Data {
    try whitespace()
    var result = Data()
    var depth = 0
    var string = false
    var escape = false
    while let byte = try peek() {
      if !string && depth == 0 && !result.isEmpty && [44, 93, 125, 9, 10, 13, 32].contains(byte) {
        break
      }
      result.append(try take())
      if string {
        if escape {
          escape = false
        } else if byte == 92 {
          escape = true
        } else if byte == 34 {
          string = false
          if depth == 0 { break }
        }
      } else if byte == 34 {
        string = true
      } else if byte == 123 || byte == 91 {
        depth += 1
      } else if byte == 125 || byte == 93 {
        depth -= 1
        if depth == 0 { break }
      }
    }
    guard !result.isEmpty, !string, depth == 0 else { throw ChatHistoryError.invalidFile }
    _ = try JSONSerialization.jsonObject(with: result, options: [.fragmentsAllowed])
    return result
  }
  func manifest(in directory: URL) throws -> ChatChunkManifest {
    try expect(123)
    var fields: [String: Any] = [:]
    let writer = ChatChunkWriter(directory: directory)
    var children: [ChatChunkManifest] = []
    try whitespace()
    while try peek() != 125 {
      let key = try JSONDecoder().decode(String.self, from: value())
      try expect(58)
      if key == "messages" || key == "subagents" {
        try expect(91)
        try whitespace()
        while try peek() != 93 {
          if key == "messages" {
            try writer.append(value())
          } else {
            children.append(try manifest(in: directory))
          }
          try whitespace()
          if try peek() == 44 { _ = try take() } else { break }
        }
        try expect(93)
        fields[key] = [Any]()
      } else {
        fields[key] = try JSONSerialization.jsonObject(with: value(), options: [.fragmentsAllowed])
      }
      try whitespace()
      if try peek() == 44 { _ = try take() } else { break }
    }
    try expect(125)
    try writer.flush()
    fields["messages"] = [Any]()
    fields["_pmaiMessageCount"] = writer.nonSystemCount
    var result = ChatChunkManifest(
      metadata: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]))
    result.chunks = writer.chunks
    result.children = children
    return result
  }
}
