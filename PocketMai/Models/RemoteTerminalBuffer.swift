import CryptoKit
import Foundation

struct RemoteTerminalEntry: Codable, Identifiable, Equatable {
  var id = UUID()
  let command: String
  var output: String?
  var isError = false
  var isComplete = false
}

struct RemoteTerminalBuffer: Codable {
  static let historyLimit = 500
  static let entryLimit = 200
  static let outputLimit = 128_000
  static let backlogLimit = 1_000_000

  private(set) var entries: [RemoteTerminalEntry] = []
  private(set) var history: [String] = []

  static func fileURL(hostID: UUID, endpoint: URL, cwd: String, directory: URL) -> URL {
    let key = [hostID.uuidString, endpoint.absoluteString, cwd].joined(separator: "\n")
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent(digest).appendingPathExtension("json")
  }

  static func load(from url: URL) -> Self {
    guard let data = try? Data(contentsOf: url),
      var buffer = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    buffer.interruptPending()
    buffer.trim()
    return buffer
  }

  func save(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }

  mutating func append(_ command: String) -> UUID {
    let entry = RemoteTerminalEntry(command: command)
    entries.append(entry)
    history.removeAll { $0 == command }
    history.append(command)
    trim()
    return entry.id
  }

  mutating func update(_ id: UUID, output: String, isError: Bool, isComplete: Bool = true) {
    guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
    entries[index].output = Self.boundedOutput(output)
    entries[index].isError = isError
    entries[index].isComplete = isComplete
    trim()
  }

  mutating func clearScrollback() { entries.removeAll() }
  mutating func clearHistory() { history.removeAll() }

  mutating func interruptPending() {
    for index in entries.indices where !entries[index].isComplete {
      entries[index].output =
        (entries[index].output ?? "")
        + "\n[connection closed; remote command may still be running]"
      entries[index].isError = true
      entries[index].isComplete = true
    }
  }

  private static func boundedOutput(_ output: String) -> String {
    guard output.utf8.count > outputLimit else { return output }
    return "[earlier output trimmed]\n"
      + String(decoding: output.utf8.suffix(outputLimit), as: UTF8.self)
  }

  private mutating func trim() {
    history = Array(history.suffix(Self.historyLimit))
    entries = Array(entries.suffix(Self.entryLimit))
    var bytes = 0
    for index in entries.indices.reversed() {
      bytes += entries[index].command.utf8.count + (entries[index].output?.utf8.count ?? 0)
      if bytes > Self.backlogLimit, index < entries.count - 1 {
        entries.removeFirst(index + 1)
        break
      }
    }
  }
}

struct RemoteTerminalHistoryCursor {
  private(set) var index: Int?
  private var draft = ""

  mutating func move(_ direction: Int, command: String, history: [String]) -> String {
    guard !history.isEmpty else { return command }
    if index == nil {
      guard direction < 0 else { return command }
      draft = command
    }
    let next = min(max((index ?? history.count) + direction, 0), history.count)
    index = next == history.count ? nil : next
    return index.map { history[$0] } ?? draft
  }

  mutating func reset() {
    index = nil
    draft = ""
  }
}
