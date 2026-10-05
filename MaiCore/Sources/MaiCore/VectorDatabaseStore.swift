import Foundation

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Serializes tool calls across chats and child agents. Atomic JSON snapshots
/// survive restarts; modified snapshots are reloaded before the next operation.
public actor MaiVectorDatabaseStore {
  public static let shared = MaiVectorDatabaseStore()
  public static let relativePath = ".pmai/vdb.json"

  private struct Cached {
    var url: URL
    var modified: Date?
    var size: Int?
    var fileNumber: UInt64?
    var database: MaiVectorDatabase
  }
  private var cached: Cached?

  public init() {}

  public func database(at url: URL) throws -> MaiVectorDatabase {
    guard FileManager.default.fileExists(atPath: url.path) else { return MaiVectorDatabase() }
    // URL.resourceValues can itself cache metadata on a reused URL, including
    // across an atomic replacement. Read fresh filesystem attributes instead.
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let modified = attributes[.modificationDate] as? Date
    let size = (attributes[.size] as? NSNumber)?.intValue
    let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    if let cached, cached.url == url, cached.modified == modified,
      cached.size == size, cached.fileNumber == fileNumber
    {
      return cached.database
    }
    guard (size ?? 0) <= MaiVectorDatabase.maximumIndexBytes else {
      throw MaiVectorDatabaseError.tooLarge
    }
    let data = try Data(contentsOf: url)
    guard data.count <= MaiVectorDatabase.maximumIndexBytes else {
      throw MaiVectorDatabaseError.tooLarge
    }
    let database = try JSONDecoder().decode(MaiVectorDatabase.self, from: data)
    cached = Cached(
      url: url, modified: modified, size: size, fileNumber: fileNumber, database: database)
    return database
  }

  @discardableResult
  public func replace(
    at url: URL, with chunks: [MaiVectorChunk], removingSources: Set<String> = [],
    embeddingSpace: String? = nil
  ) throws -> MaiVectorDatabase {
    try withWriteLock(at: url) {
      var database = try database(at: url)
      try database.replace(
        with: chunks, removingSources: removingSources, embeddingSpace: embeddingSpace)
      try save(database, at: url)
      return database
    }
  }

  public func remove(at url: URL, sourcePrefix: String) throws -> MaiVectorDatabase {
    try withWriteLock(at: url) {
      var database = try database(at: url)
      let sources = Set(
        database.chunks.map(\.source).filter {
          MaiVectorDatabase.contains(source: $0, in: sourcePrefix)
        })
      try database.replace(
        with: [], removingSources: sources, embeddingSpace: database.embeddingSpace)
      try save(database, at: url)
      return database
    }
  }

  /// Clearing deliberately also recovers an unreadable or obsolete snapshot.
  public func clear(at url: URL) throws {
    try withWriteLock(at: url) { try save(MaiVectorDatabase(), at: url) }
  }

  private func withWriteLock<T>(at url: URL, _ operation: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if !os(Windows)
      let descriptor = open(
        url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else {
        throw MaiVectorDatabaseError.invalidIndex("cannot open index lock")
      }
      defer { close(descriptor) }
      guard flock(descriptor, LOCK_EX) == 0 else {
        throw MaiVectorDatabaseError.invalidIndex("cannot lock index")
      }
      defer { _ = flock(descriptor, LOCK_UN) }
    #endif
    try Task.checkCancellation()
    // Another process or store may have committed while we acquired the lock.
    cached = nil
    return try operation()
  }

  private func save(_ database: MaiVectorDatabase, at url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(database)
    guard data.count <= MaiVectorDatabase.maximumIndexBytes else {
      throw MaiVectorDatabaseError.tooLarge
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    cached = nil
  }
}
