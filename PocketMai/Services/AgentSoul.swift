import Foundation

/// The app's counterpart of the CLI's ~/.pmai/SOUL.md. Read it for each
/// request so edits from Settings or the file browser take effect immediately.
struct AgentSoul {
  let url: URL

  init(url: URL = PocketMaiDirectories.filesWorkspaceURL.appendingPathComponent(".pmai/SOUL.md")) {
    self.url = url
  }

  func load() throws -> String {
    do {
      return try String(contentsOf: url, encoding: .utf8)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return ""
    }
  }

  func save(_ text: String) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  var instructions: String? {
    guard let text = try? load().trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
    else {
      return nil
    }
    return text
  }
}
