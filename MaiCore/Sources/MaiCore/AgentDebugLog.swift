import Foundation

/// Append-only diagnostic log for a CLI project. Entries are independent JSON
/// objects so a failed process still leaves all earlier calls readable.
public actor AgentDebugLog {
  public let url: URL
  private let handle: FileHandle
  private let encoder: JSONEncoder

  public init(url: URL) throws {
    self.url = url
    let manager = FileManager.default
    try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Do not follow a project-controlled symlink when changing permissions.
    if (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil {
      throw CocoaError(.fileWriteNoPermission)
    }
    if !manager.fileExists(atPath: url.path) {
      guard manager.createFile(
        atPath: url.path, contents: nil,
        attributes: [.posixPermissions: 0o600])
      else { throw CocoaError(.fileWriteUnknown) }
    }
    try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
  }

  deinit { try? handle.close() }

  public func record<Value: Encodable>(
    _ kind: String,
    context: AgentEventContext? = nil,
    provider: String? = nil,
    attempt: Int? = nil,
    value: Value
  ) {
    do {
      let entry = Entry(
        timestamp: Date(), kind: kind, context: context, provider: provider,
        attempt: attempt, value: value)
      var data = try encoder.encode(entry)
      data.append(0x0a)
      try handle.write(contentsOf: data)
    } catch {
      FileHandle.standardError.write(
        Data("warning: debug log write failed: \(error.localizedDescription)\n".utf8))
    }
  }

  private struct Entry<Value: Encodable>: Encodable {
    var timestamp: Date
    var kind: String
    var context: AgentEventContext?
    var provider: String?
    var attempt: Int?
    var value: Value
  }
}
