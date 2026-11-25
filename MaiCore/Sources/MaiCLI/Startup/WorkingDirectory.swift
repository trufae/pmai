import Foundation
import MaiCore

extension MaiCLI {
  static func startupDirectory(
    _ path: String, option: String, environment: [String: String]
  ) throws -> URL {
    let expanded = AgentHome.expandUserPath(path, environment: environment)
    let url = URL(fileURLWithPath: expanded, relativeTo: AgentExecutionScope.directory)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw CLIError.notDirectory(option, url.path) }
    return url
  }

  static func enterStartupDirectory(_ url: URL) throws {
    guard FileManager.default.changeCurrentDirectoryPath(url.path) else {
      throw CLIError.cannotChangeDirectory(url.path)
    }
  }

  static func createStartupWorktree(name: String, environment: [String: String]) throws -> URL {
    guard name.isEmpty || name.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z"#,
      options: .regularExpression) != nil
    else { throw CLIError.invalidWorktreeName(name) }

    let root = try runWorktreeGit(["rev-parse", "--show-toplevel"], environment: environment)
    let repository = URL(fileURLWithPath: root, isDirectory: true)
    // The checkout is a sibling so it does not appear as an untracked directory.
    let parent = environment["PMAI_BOX_ID"] == nil ? repository.deletingLastPathComponent()
      : AgentHome.userHomeDirectory(environment: environment)
    let worktrees = parent.appendingPathComponent(repository.lastPathComponent + ".pmai-worktrees", isDirectory: true)
    let id = UUID().uuidString.lowercased()
    let checkout = worktrees.appendingPathComponent(name.isEmpty ? id : "\(name)-\(id)", isDirectory: true)
    let branch = "pmai/" + (name.isEmpty ? id : name)
    _ = try runWorktreeGit(["worktree", "add", "--quiet", "-b", branch, "--", checkout.path, "HEAD"],
      environment: environment)
    return checkout
  }

  private static func runWorktreeGit(_ arguments: [String], environment: [String: String]) throws -> String {
    let process = Process()
    try LocalProcess.configure(process, command: "git", arguments: arguments, environment: environment)
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.standardError
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationReason == .exit, process.terminationStatus == 0 else {
      throw CLIError.worktreeFailed(process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
  }
}

extension CLIOptions {
  /// Explicit launch paths stay relative to --cd when the REPL moves into the checkout.
  mutating func resolveWorktreeLaunchPaths(home: AgentHome, environment: [String: String]) {
    func resolve(_ path: String) -> String {
      URL(fileURLWithPath: AgentHome.expandUserPath(path, environment: environment)).standardizedFileURL.path
    }
    if homePath != nil || environment[AgentHome.environmentVariable]?
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
      homePath = home.rootURL.path
    }
    configPath = configPath.map(resolve)
    statePath = statePath.map(resolve)
    historyPath = historyPath.map(resolve)
    pluginPaths = pluginPaths.map(resolve)
    imagePaths = imagePaths.map(resolve)
  }
}
