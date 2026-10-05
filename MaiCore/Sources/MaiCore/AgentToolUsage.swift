import Foundation
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
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

  @discardableResult
  public func record(_ name: String) -> AgentToolUsage {
    guard let url else {
      usage.record(name)
      return usage
    }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      #if canImport(Darwin) || canImport(Glibc)
        let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { _ = flock(descriptor, LOCK_UN) }
      #endif
      if let data = try? Data(contentsOf: url),
        let saved = try? JSONDecoder().decode(AgentToolUsage.self, from: data)
      { usage = saved }
      usage.record(name)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(usage).write(to: url, options: .atomic)
      lastPersistenceError = nil
    } catch {
      // A telemetry failure must not fail the requested tool call.
      lastPersistenceError = error.localizedDescription
    }
    return usage
  }
}
