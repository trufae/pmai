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

/// Lifetime counters are for display. A bounded recent window drives exposure
/// so old workflows do not permanently occupy the direct-tool slots.
public struct AgentToolUsage: Codable, Equatable, Sendable {
  public static let recentWindow = 128
  public static let minimumCalls = 3
  public static let maximumPromotedTools = 4

  public private(set) var counts: [String: Int] = [:]
  public private(set) var recent: [String] = []

  public init() {}

  public mutating func record(_ name: String) {
    counts[name] = min(counts[name, default: 0], Int.max - 1) + 1
    recent.append(name)
    if recent.count > Self.recentWindow { recent.removeFirst(recent.count - Self.recentWindow) }
  }

  mutating func add(counts additions: [String: Int], recent appended: [String]) {
    for (name, count) in additions {
      counts[name] = min(counts[name, default: 0], Int.max - count) + count
    }
    recent = Array((recent + appended).suffix(Self.recentWindow))
  }

  public func count(for group: ToolGroupDefinition) -> Int {
    group.toolNames.reduce(0) { total, name in
      total.addingReportingOverflow(counts[name, default: 0]).overflow
        ? Int.max : total + counts[name, default: 0]
    }
  }

  public func promotedTools(among eligible: Set<String>) -> Set<String> {
    var frequencies: [String: Int] = [:]
    var latest: [String: Int] = [:]
    for (index, name) in recent.enumerated() where eligible.contains(name) {
      frequencies[name, default: 0] += 1
      latest[name] = index
    }
    let ranked = eligible.filter { frequencies[$0, default: 0] >= Self.minimumCalls }.sorted {
      if frequencies[$0] != frequencies[$1] {
        return frequencies[$0, default: 0] > frequencies[$1, default: 0]
      }
      return latest[$0, default: 0] > latest[$1, default: 0]
    }
    return Set(ranked.prefix(Self.maximumPromotedTools))
  }
}

/// One ledger shared by projects and chats. A lock file and atomic replacement
/// preserve increments when separate pmai processes use the same home.
public actor AgentToolUsageStore {
  public private(set) var usage: AgentToolUsage
  public private(set) var lastPersistenceError: String?
  public let url: URL?

  public init(url: URL? = nil) {
    self.url = url
    usage = url.flatMap { try? Data(contentsOf: $0) }
      .flatMap { try? JSONDecoder().decode(AgentToolUsage.self, from: $0) } ?? .init()
  }

  private var pendingCounts: [String: Int] = [:]
  private var pendingRecent: [String] = []
  private var scheduledFlush: Task<Void, Never>?
  private var flushing = false
  private let flushChanges = AgentChangeSignal()

  /// Learning is immediate; disk locking never lies on the tool's critical path.
  @discardableResult
  public func record(_ name: String) -> AgentToolUsage {
    usage.record(name)
    guard url != nil else { return usage }
    pendingCounts[name] = min(pendingCounts[name, default: 0], Int.max - 1) + 1
    pendingRecent.append(name)
    if pendingRecent.count > AgentToolUsage.recentWindow { pendingRecent.removeFirst() }
    if scheduledFlush == nil {
      scheduledFlush = Task { [weak self] in
        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
        await self?.flush()
      }
    }
    return usage
  }

  /// Hosts flush on orderly shutdown. Concurrent stores merge their increments
  /// under the file lock; a failed batch stays pending for a later attempt.
  public func flush() async {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    while flushing {
      let revision = flushChanges.revision
      do { try await flushChanges.wait(after: revision) } catch { return }
    }
    guard let url, !pendingCounts.isEmpty else { return }
    let counts = pendingCounts
    let recent = pendingRecent
    pendingCounts = [:]
    pendingRecent = []
    flushing = true
    let result = await Task.detached(priority: .utility) {
      Result { try Self.persist(counts: counts, recent: recent, at: url) }
    }.value
    switch result {
    case .success(var saved):
      saved.add(counts: pendingCounts, recent: pendingRecent)
      usage = saved
      lastPersistenceError = nil
    case .failure(let error):
      for (name, count) in counts {
        pendingCounts[name] = min(pendingCounts[name, default: 0], Int.max - count) + count
      }
      pendingRecent = Array((recent + pendingRecent).suffix(AgentToolUsage.recentWindow))
      lastPersistenceError = error.localizedDescription
    }
    flushing = false
    flushChanges.notify()
  }

  private nonisolated static func persist(
    counts: [String: Int], recent: [String], at url: URL
  ) throws -> AgentToolUsage {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if !os(Windows)
      let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
      guard descriptor >= 0 else { throw POSIXError(.EIO) }
      defer { _ = close(descriptor) }
      guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
      defer { _ = flock(descriptor, LOCK_UN) }
    #endif
    var saved = (try? Data(contentsOf: url))
      .flatMap { try? JSONDecoder().decode(AgentToolUsage.self, from: $0) } ?? .init()
    saved.add(counts: counts, recent: recent)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(saved).write(to: url, options: .atomic)
    return saved
  }
}
