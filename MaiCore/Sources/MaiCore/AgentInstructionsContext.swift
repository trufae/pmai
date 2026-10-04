import Foundation

/// Instructions discovered for one conversation. The same file is read once;
/// each later provider call reuses the cached text while the conversation is
/// active. Paths outside the starting workspace are ignored.
struct AgentInstructionsContext {
  let directory: URL
  private var contents: [URL: String] = [:]
  private var scannedDirectories: Set<URL> = []

  init(directory: URL) {
    self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    for file in AgentInstructionsFile.locate(from: self.directory) {
      if let text = AgentInstructionsFile.read(file) {
        contents[file.standardizedFileURL] = text
      }
    }
    scannedDirectories.insert(self.directory)
  }

  /// Discover instructions between the workspace and each path a file or
  /// shell tool explicitly targets. Returns only newly discovered files.
  mutating func observe(_ call: ToolCall, workingDirectory: URL) -> String? {
    let arguments = call.arguments.objectValue ?? [:]
    let paths: [(String, URL)]
    if call.name.hasPrefix("files_") {
      paths = [arguments["path"]?.stringValue, arguments["new_path"]?.stringValue]
        .compactMap { $0.map { ($0, workingDirectory) } }
    } else if call.name == "run_shell" {
      let cwd = arguments["cwd"]?.stringValue
      let shellDirectory = cwd.map { Self.resolve($0, from: workingDirectory) }
        ?? workingDirectory
      let scripts = [arguments["script"]?.stringValue, arguments["command"]?.stringValue]
        .compactMap { $0 } + (arguments["commands"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      paths = (cwd.map { [($0, workingDirectory)] } ?? [])
        + scripts.flatMap { Self.shellPaths(in: $0, from: shellDirectory) }
          .map { ($0, shellDirectory) }
    } else {
      return nil
    }
    var newlyFound: [(URL, String)] = []
    for (path, base) in paths {
      let target = Self.resolve(path, from: base)
      guard target.path == directory.path || target.path.hasPrefix(directory.path + "/") else {
        continue
      }
      var isDirectory: ObjCBool = false
      let targetDirectory =
        FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
          && isDirectory.boolValue ? target : target.deletingLastPathComponent()
      var chain: [URL] = []
      var current = targetDirectory
      while current.path != directory.path, current.path.hasPrefix(directory.path + "/") {
        chain.append(current)
        current = current.deletingLastPathComponent()
      }
      for folder in chain.reversed() where scannedDirectories.insert(folder).inserted {
        let file = folder.appendingPathComponent(AgentInstructionsFile.filename)
        if let text = AgentInstructionsFile.read(file) {
          contents[file] = text
          newlyFound.append((file, text))
        }
      }
    }
    return AgentInstructionsFile.promptSection(entries: newlyFound)
  }

  private static func resolve(_ path: String, from directory: URL) -> URL {
    (path.hasPrefix("/")
      ? URL(fileURLWithPath: path)
      : URL(fileURLWithPath: directory.path, isDirectory: true)
        .appendingPathComponent(path))
      .standardizedFileURL.resolvingSymlinksInPath()
  }

  /// Shell syntax cannot be resolved in general. These are literal path
  /// arguments whose destination already exists, or whose parent exists for
  /// a new file. Dynamic expressions are left to the tool's explicit cwd.
  private static func shellPaths(in script: String, from directory: URL) -> [String] {
    let punctuation = CharacterSet(charactersIn: "\"'(){}[],:;")
    return script.split(whereSeparator: \.isWhitespace).compactMap { word in
      let path = String(word).trimmingCharacters(in: punctuation)
      guard !path.isEmpty, !path.hasPrefix("-"), !path.contains("://"),
        !path.contains(where: { "$*?|><`".contains($0) })
      else { return nil }
      let target = resolve(path, from: directory)
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
      guard (exists && (isDirectory.boolValue || path.contains("/")))
        || (path.contains("/")
          && FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path))
      else { return nil }
      return path
    }
  }

  /// Do not insert a file twice when a host or restored context already has it.
  func section(alreadyIn messages: [AgentMessage]) -> String? {
    let existing = messages.filter { $0.role == .system || $0.role == .developer }.map(\.text)
    let entries = contents
      .filter { file, _ in !existing.contains { $0.contains("### \(file.path)\n\n") } }
      .sorted { lhs, rhs in
        let left = lhs.key.pathComponents.count
        let right = rhs.key.pathComponents.count
        return left == right ? lhs.key.path < rhs.key.path : left < right
      }
      .map { ($0.key, $0.value) }
    return AgentInstructionsFile.promptSection(entries: entries)
  }
}
