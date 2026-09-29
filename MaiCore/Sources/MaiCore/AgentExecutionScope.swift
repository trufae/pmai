import Foundation

/// Per-run context inherited by tools and child tasks. Never changes the
/// process cwd: independent ACP sessions may run concurrently.
public struct AgentExecutionScope: Sendable {
  @TaskLocal public static var current: AgentExecutionScope?

  public var sessionID: String
  public var workingDirectory: URL

  public init(sessionID: String, workingDirectory: URL) {
    self.sessionID = sessionID
    self.workingDirectory = workingDirectory
  }

  public static var directory: URL {
    current?.workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
  }
}
