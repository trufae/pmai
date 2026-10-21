import Foundation

/// Conversation-owned file access history, inherited by child tasks. Paths stay
/// outside model context so compaction cannot erase or invent access records.
public final class FileAccessLog: @unchecked Sendable {
  @TaskLocal public static var current: FileAccessLog?
  private let lock = NSLock()
  private var paths: Set<String>

  public init(paths: [String] = []) { self.paths = Set(paths) }

  public func record(_ url: URL) {
    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
    lock.withLock { _ = paths.insert(path) }
  }

  public func snapshot() -> [String] { lock.withLock { paths.sorted() } }
}
