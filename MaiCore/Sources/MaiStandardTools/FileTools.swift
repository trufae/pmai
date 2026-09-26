import Foundation
import MaiCore
import MaiDocuments

/// Configuration for the portable Files tool group. Every path supplied by a
/// model is interpreted relative to `rootURL` and cannot escape it through
/// `..`, absolute paths, or symbolic links.
public struct MaiFileWorkspaceConfiguration: Equatable, Sendable {
  public var rootURL: URL
  public var temporaryDirectoryURL: URL
  public var displayName: String
  public var writeEnabled: Bool
  public var followsProcessWorkingDirectory: Bool
  public var isSecurityScoped: Bool
  public var hiddenRootEntryNames: Set<String>

  public init(
    rootURL: URL,
    temporaryDirectoryURL: URL? = nil,
    displayName: String? = nil,
    writeEnabled: Bool = true,
    followsProcessWorkingDirectory: Bool = false,
    isSecurityScoped: Bool = false,
    hiddenRootEntryNames: Set<String> = []
  ) {
    self.rootURL = rootURL.standardizedFileURL
    self.temporaryDirectoryURL =
      temporaryDirectoryURL?.standardizedFileURL
      ?? URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp", isDirectory: true)
      .standardizedFileURL
    self.displayName = displayName ?? rootURL.lastPathComponent
    self.writeEnabled = writeEnabled
    self.followsProcessWorkingDirectory = followsProcessWorkingDirectory
    self.isSecurityScoped = isSecurityScoped
    self.hiddenRootEntryNames = hiddenRootEntryNames
  }
}

/// One operation in the shared, workspace-scoped Files tool group.
public struct MaiFileWorkspaceTool: AgentTool {
  public enum Operation: String, CaseIterable, Sendable {
    case list = "files_list"
    case find = "files_find"
    case grep = "files_grep"
    case read = "files_read"
    case readIndex = "files_read_index"
    case getFunction = "files_get_function"
    case setFunction = "files_set_function"
    case readRange = "files_read_range"
    case replaceRange = "files_replace_range"
    case patch = "files_patch"
    case write = "files_write"
    case rename = "files_rename"
    case delete = "files_delete"

    var changesFiles: Bool {
      switch self {
      case .list, .find, .grep, .read, .readIndex, .getFunction, .readRange:
        false
      case .setFunction, .replaceRange, .patch, .write, .rename, .delete: true
      }
    }
  }

  public static let toolNames = Operation.allCases.map(\.rawValue)
  public static let advancedOperations: Set<Operation> = [
    .readIndex, .getFunction, .setFunction, .readRange, .replaceRange, .patch,
  ]

  public let operation: Operation
  public let configuration: MaiFileWorkspaceConfiguration
  public let definition: ToolDefinition

  public init(operation: Operation, configuration: MaiFileWorkspaceConfiguration) {
    self.operation = operation
    self.configuration = configuration
    definition = Self.definition(for: operation, workspaceName: configuration.displayName)
  }

  public static func makeTools(
    configuration: MaiFileWorkspaceConfiguration,
    includeAdvancedTools: Bool = true
  ) -> [MaiFileWorkspaceTool] {
    Operation.allCases.compactMap { operation in
      guard includeAdvancedTools || !advancedOperations.contains(operation),
        configuration.writeEnabled || !operation.changesFiles
      else { return nil }
      return MaiFileWorkspaceTool(operation: operation, configuration: configuration)
    }
  }

  public func call(arguments: JSONValue, context: ToolExecutionContext) async throws -> ToolOutput {
    var arguments = arguments.objectValue ?? [:]
    if operation == .read, arguments["max_bytes"] == nil, let limit = context.suggestedOutputBytes {
      arguments["max_bytes"] = .integer(max(4, limit))
    }
    #if os(macOS) || os(iOS)
      let didStartAccess =
        configuration.isSecurityScoped
        ? configuration.rootURL.startAccessingSecurityScopedResource() : false
      defer {
        if didStartAccess { configuration.rootURL.stopAccessingSecurityScopedResource() }
      }
    #endif
    do {
      try Task.checkCancellation()
      let workspace = try MaiFileWorkspace(configuration: configuration)
      switch operation {
      case .list:
        return try workspace.list(arguments)
      case .find:
        return try await workspace.find(arguments)
      case .grep:
        return try await workspace.grep(arguments)
      case .read:
        var output = try workspace.read(arguments)
        if let page = output.structuredContent?.objectValue,
          page["truncated"]?.boolValue == true, let next = page["nextOffset"]?.intValue {
          let path = page["path"]?.compactJSONString ?? "the same path"
          output.content.append(.text(
            "[Partial file: more content is available. Continue with files_read path \(path), offset \(next), or use files_grep/files_read_range to narrow the read.]"))
        }
        return output
      case .readIndex:
        return try workspace.readIndex(arguments)
      case .getFunction:
        return try workspace.getFunction(arguments)
      case .setFunction:
        return try workspace.setFunction(arguments)
      case .readRange:
        return try workspace.readRange(arguments)
      case .replaceRange:
        return try workspace.replaceRange(arguments)
      case .patch:
        return try workspace.patch(arguments)
      case .write:
        return try workspace.write(arguments)
      case .rename:
        return try workspace.rename(arguments)
      case .delete:
        return try workspace.delete(arguments)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as MaiFileWorkspaceError {
      let root =
        configuration.followsProcessWorkingDirectory
        ? FileManager.default.currentDirectoryPath : configuration.rootURL.path
      return ToolOutput(
        text: "Error: \(error.localizedDescription)\(error.pathHint(root: root))", isError: true)
    } catch {
      return ToolOutput(text: "Error: \(error.localizedDescription)", isError: true)
    }
  }

  private static func definition(
    for operation: Operation,
    workspaceName: String
  ) -> ToolDefinition {
    let path = ToolParameterDef(name: "path", type: "string", description: "File path.", required: true)
    switch operation {
    case .list:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "List one folder of the workspace '\(workspaceName)'. Paths are relative to the current directory or absolute inside it. The last component may be a pattern such as src/*.c; for the whole tree use files_find with query *.",
        parameters: [
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "Folder to list. Omit for the current directory.",
            required: false)
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .find:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Find files and folders by approximate name or glob (* lists the whole tree). An optional filter keeps only paths containing that literal text. Skips ignored, hidden, build, and dependency paths.",
        parameters: [
          ToolParameterDef(
            name: "query",
            type: "string",
            description: "File name, partial path, or glob: *.swift at any depth, src/*.c directly in src, src/**/*.c below it. Omit when using filter alone.",
            required: false),
          ToolParameterDef(
            name: "filter",
            type: "string",
            description: "Literal substring that every returned path must contain, case insensitive. Can be used alone or with query.",
            required: false),
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "Folder to search. Omit for the current directory.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .grep:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Search file contents. Returns up to 100 matching lines; skips ignored and hidden files. Case-insensitive unless query contains uppercase.",
        parameters: [
          ToolParameterDef(
            name: "query",
            type: "string",
            description:
              "Text to find. When regex is true, write the regular expression here; backslashes must be double-escaped in the JSON string so one survives to the regex engine (e.g. '\\\\*' for a literal *, '\\\\(' for a literal parenthesis, '\\\\b' for a word boundary).",
            required: true),
          ToolParameterDef(
            name: "path",
            type: "string",
            description: "File or folder. Default: current directory.",
            required: false),
          ToolParameterDef(
            name: "glob",
            type: "string",
            description: "Optional file filter, e.g. *.swift.",
            required: false),
          ToolParameterDef(
            name: "regex",
            type: "boolean",
            description: "true for regex, false for literal text (default). Never put the pattern here.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .read:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Read a text file. PDF and DOCX are converted to Markdown. For large files, first use files_grep or files_read_index, then read a range/function; delegate independent extraction tasks when agent_start is available.",
        parameters: [
          path,
          ToolParameterDef(
            name: "max_bytes",
            type: "integer",
            description: "Maximum bytes to return, up to 500000. Default: up to 120000, reduced to fit the runtime's context budget.",
            required: false),
          ToolParameterDef(
            name: "offset",
            type: "integer",
            description: "Byte offset to continue a long file. Default: 0.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .readIndex:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "List the functions and types of a source file, or the headings of a document, with line numbers.",
        parameters: [path],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .getFunction:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Read one function of a source file with its line bounds and the revision files_set_function needs.",
        parameters: [
          path,
          ToolParameterDef(
            name: "name", type: "string",
            description: "Function or method name. Unqualified names also match qualified names.",
            required: true),
          ToolParameterDef(
            name: "line", type: "integer",
            description: "Exact 1-based declaration line to disambiguate overloads.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .setFunction:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Replace the body of one function read with files_get_function, rejecting a stale revision, and return a unified diff.",
        parameters: [
          path,
          ToolParameterDef(
            name: "name", type: "string",
            description: "Function or method name used with files_get_function.",
            required: true),
          ToolParameterDef(
            name: "body", type: "string",
            description:
              "Complete new body between the existing delimiters, with its indentation.",
            required: true),
          ToolParameterDef(
            name: "revision", type: "string",
            description: "Revision returned by files_get_function.",
            required: true),
          ToolParameterDef(
            name: "line", type: "integer",
            description: "Exact 1-based declaration line to disambiguate overloads.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .readRange:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Read a 1-based inclusive line range of a file.",
        parameters: [
          path,
          ToolParameterDef(
            name: "start_line", type: "integer", description: "First line, 1-based. Default: 1.",
            required: false),
          ToolParameterDef(
            name: "end_line", type: "integer",
            description: "Last line, inclusive. Default: start_line + 199.", required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: true, idempotent: true, openWorld: false, approval: .confirm))
    case .replaceRange:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Replace a 1-based inclusive line range. Set end_line to start_line - 1 to insert; omit content to delete. Prefer files_patch when the text to change is known.",
        parameters: [
          path,
          ToolParameterDef(
            name: "start_line", type: "integer", description: "First line to replace, 1-based.",
            required: true),
          ToolParameterDef(
            name: "end_line", type: "integer",
            description: "Last line, inclusive. Default: start_line.", required: false),
          ToolParameterDef(
            name: "content", type: "string",
            description: "Replacement text; may contain multiple lines. Omit to delete.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .patch:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Edit a text file by replacing a literal string or regular-expression match; returns a unified diff.",
        parameters: [
          path,
          ToolParameterDef(
            name: "find", type: "string",
            description:
              "Exact text to find, or a regular expression when regex is true. Must match exactly expected_matches times (default once). When regex is true, backslashes must be double-escaped in the JSON string so one survives to the regex engine (e.g. '\\\\(' to match a literal parenthesis, '\\\\b' for a word boundary).",
            required: true),
          ToolParameterDef(
            name: "replace", type: "string",
            description: "Replacement text. Use an empty string to delete the match.",
            required: true),
          ToolParameterDef(
            name: "regex", type: "boolean",
            description: "Interpret find as a regular expression. Default: false.", required: false),
          ToolParameterDef(
            name: "expected_matches", type: "integer",
            description: "Required number of matches, 1-100. Default: 1.", required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .write:
      return ToolDefinition(
        name: operation.rawValue,
        description:
          "Create a file, append to an existing file, or overwrite it. "
          + "Use mode: 'create' to create a new file (default, fails if it already exists), "
          + "mode: 'append' to add content to the end, or mode: 'overwrite' to replace the entire contents. "
          + "To edit part of a file, use files_patch instead. "
          + "Set create_directory: true to create a folder.",
        parameters: [
          path,
          ToolParameterDef(
            name: "content",
            type: "string",
            description: "The complete contents, or the text to append. Omit for a folder.",
            required: false),
          ToolParameterDef(
            name: "mode",
            type: "string",
            description: "How to handle existing files: 'create' (fail if exists), 'append' (add to end), 'overwrite' (replace contents). Default: 'create'.",
            required: false),
          ToolParameterDef(
            name: "create_directory",
            type: "boolean",
            description: "Create a directory instead of writing a file. Default: false.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .rename:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Rename or move a file or folder.",
        parameters: [
          path,
          ToolParameterDef(name: "new_path", type: "string", description: "New path.", required: true),
        ],
        annotations: ToolAnnotations(
          readOnly: false, idempotent: false, openWorld: false, approval: .confirm))
    case .delete:
      return ToolDefinition(
        name: operation.rawValue,
        description: "Delete a file or folder.",
        parameters: [
          path,
          ToolParameterDef(
            name: "recursive",
            type: "boolean",
            description: "Allow deletion of a non-empty directory. Default: false.",
            required: false),
        ],
        annotations: ToolAnnotations(
          readOnly: false,
          destructive: true,
          idempotent: false,
          openWorld: false,
          approval: .dangerous))
    }
  }
}

private struct MaiFileWorkspace: Sendable {
  private enum RepositoryKind: String {
    case git
    case mercurial

    var marker: String {
      switch self {
      case .git: ".git"
      case .mercurial: ".hg"
      }
    }
  }

  private enum FileWriteMode: String, Codable {
    case create    = "create"
    case append    = "append"
    case overwrite = "overwrite"
  }

  private struct VersionControlledEntries {
    var name: String
    var entries: [(URL, URLResourceValues)]
    var truncated: Bool
  }

  private static let defaultReadLimit = 120_000
  private static let maximumReadLimit = 500_000
  private static let maximumWriteBytes = 1_000_000
  private static let maximumEditableFileBytes = 10_000_000
  private static let maximumSourceFileBytes = 50_000_000
  private static let maximumListEntries = 500
  /// Matches returned by find and grep; a model that needs more narrows the query.
  static let searchLimit = 100
  private static let maximumSearchEntries = 10_000
  private static let searchResourceKeys: Set<URLResourceKey> = [
    .fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
  ]
  private static let commonNonSourceDirectories: Set<String> = [
    "__pycache__", "bower_components", "build", "carthage", "cmakefiles", "coverage",
    "deriveddata", "dist", "node_modules", "obj", "out", "pods", "target", "vendor", "venv",
  ]
  private static let functionMutationLock = NSLock()

  let configuration: MaiFileWorkspaceConfiguration
  let rootURL: URL

  init(configuration: MaiFileWorkspaceConfiguration) throws {
    let configuredRoot =
      configuration.followsProcessWorkingDirectory
      ? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
      : configuration.rootURL
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: configuredRoot.path,
        isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.invalidRoot(configuredRoot.path)
    }
    self.configuration = configuration
    rootURL = configuredRoot.resolvingSymlinksInPath().standardizedFileURL
  }

  /// Returns whether the given URL is inside the workspace root or the configured
  /// temporary directory, after resolving symlinks so links inside either root
  /// remain valid while links that escape are rejected.
  private func isAllowed(_ url: URL) -> Bool {
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    return isInside(resolved, directory: rootURL)
      || isInside(resolved, directory: configuration.temporaryDirectoryURL)
      || resolved.path == rootURL.path
      || resolved.path == configuration.temporaryDirectoryURL.path
  }


  func list(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    var rawPath = arguments["path"]?.stringValue ?? ""
    var glob: MaiGlob?
    if let split = MaiGlob.splitPath(rawPath) {
      guard !split.pattern.contains("/") else {
        throw MaiFileWorkspaceError.invalidGlob(
          "'\(split.pattern)' spans folders; files_list takes a pattern for the last component only, files_find searches deeper."
        )
      }
      let pattern = try requiredGlob(split.pattern)
      rawPath = split.directory
      glob = pattern
    }
    let directory = try resolve(rawPath, allowRoot: true, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(displayPath(rawPath))
    }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles]
    )
    .filter {
      directory.path != rootURL.path
        || !configuration.hiddenRootEntryNames.contains($0.lastPathComponent)
    }
    .filter { glob?.matches($0.lastPathComponent) ?? true }
    .sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    let visible = Array(entries.prefix(Self.maximumListEntries))
    let rows: [JSONValue] = visible.map { entry in
      let values = try? entry.resourceValues(
        forKeys: [.fileSizeKey, .isDirectoryKey, .isSymbolicLinkKey])
      return .object([
        "path": .string(relativePath(entry)),
        "kind": .string(
          values?.isSymbolicLink == true
            ? "symlink" : values?.isDirectory == true ? "directory" : "file"),
        "bytes": .integer(values?.fileSize ?? 0),
      ])
    }
    var lines = visible.map { entry in
      let values = try? entry.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
      let suffix = values?.isDirectory == true ? "/" : " (\(values?.fileSize ?? 0) bytes)"
      return relativePath(entry) + suffix
    }
    if lines.isEmpty {
      lines = [glob.map { "(no entries match '\($0.pattern)')" } ?? "(no files)"]
    }
    if entries.count > visible.count {
      lines.append("Truncated: showing \(visible.count) of \(entries.count) entries.")
    }
    var structured: [String: JSONValue] = [
      "workspace": .string(configuration.displayName),
      "path": .string(displayPath(rawPath)),
      "entries": .array(rows),
      "truncated": .bool(entries.count > visible.count),
    ]
    if let glob { structured["pattern"] = .string(glob.pattern) }
    return ToolOutput(
      content: [.text(lines.joined(separator: "\n"))],
      structuredContent: .object(structured))
  }

  func find(_ arguments: [String: JSONValue]) async throws -> ToolOutput {
    let filter: String?
    if arguments["filter"] != nil {
      filter = try requiredText(arguments, key: "filter")
    } else {
      filter = nil
    }
    let query = arguments["query"] == nil && filter != nil
      ? "*" : try requiredText(arguments, key: "query")
    let rawPath = arguments["path"]?.stringValue ?? ""
    let directory = try resolve(rawPath, allowRoot: true, mustExist: true)
    try requireDirectory(directory, displayPath: displayPath(rawPath))
    let glob = try globPattern(query)
    let base = relativePath(directory)
    let limit = Self.searchLimit
    var matches: [(url: URL, score: Int, kind: String)] = []
    var scanned = 0
    var hitScanLimit = false
    let visit: (URL, URLResourceValues, FileManager.DirectoryEnumerator?) throws -> Bool = {
      url, values, enumerator in
      scanned += 1
      guard scanned <= Self.maximumSearchEntries else {
        hitScanLimit = true
        enumerator?.skipDescendants()
        return false
      }
      let relative = relativePath(url)
      if let filter, !relative.localizedCaseInsensitiveContains(filter) { return true }
      let score: Int
      if let glob {
        guard glob.matches(relative) || glob.matches(Self.path(relative, below: base)) else {
          return true
        }
        score = 0
      } else {
        guard let fuzzy = fuzzyScore(relative, query: query) else { return true }
        score = fuzzy
      }
      let kind = values.isDirectory == true ? "directory" : "file"
      matches.append((url, score, kind))
      return true
    }
    let searchMethod: String
    if let controlled = try await versionControlledEntries(
      at: directory, includeDirectories: true,
      limit: Self.maximumSearchEntries + 1)
    {
      searchMethod = controlled.name
      hitScanLimit = controlled.truncated
      for (url, values) in controlled.entries {
        try Task.checkCancellation()
        guard try visit(url, values, nil) else { break }
      }
    } else {
      searchMethod = "filtered-filesystem"
      try enumerateFiles(at: directory) { url, values, enumerator in
        try visit(url, values, enumerator)
      }
    }
    matches.sort {
      $0.score == $1.score
        ? relativePath($0.url).localizedStandardCompare(relativePath($1.url)) == .orderedAscending
        : $0.score < $1.score
    }
    let selected = Array(matches.prefix(limit))
    let rows = selected.map { match in
      JSONValue.object([
        "path": .string(relativePath(match.url)),
        "kind": .string(match.kind),
        "score": .integer(match.score),
      ])
    }
    var text = selected.isEmpty
      ? filter.map { "No files matched '\(query)' with filter '\($0)'." }
        ?? "No files matched '\(query)'."
      : selected.map { relativePath($0.url) + ($0.kind == "directory" ? "/" : "") }
        .joined(separator: "\n")
    if selected.isEmpty, let glob, glob.matchesPath, !glob.pattern.contains("**") {
      text +=
        " A pattern with a slash must match the whole relative path below \(base == "." ? "the search folder" : base); **/ matches any depth, as in **/*.c."
    }
    var structured: [String: JSONValue] = [
      "query": .string(query),
      "matches": .array(rows),
      "scanned": .integer(min(scanned, Self.maximumSearchEntries)),
      "searchMethod": .string(searchMethod),
      "truncated": .bool(matches.count > selected.count || hitScanLimit),
    ]
    if let filter { structured["filter"] = .string(filter) }
    return ToolOutput(
      content: [.text(text)],
      structuredContent: .object(structured))
  }

  /// A glob for a query holding metacharacters; nil for a plain name.
  private func globPattern(_ text: String) throws -> MaiGlob? {
    MaiGlob.isPattern(text) ? try requiredGlob(text) : nil
  }

  private func requiredGlob(_ text: String, anchored: Bool = false) throws -> MaiGlob {
    guard let glob = MaiGlob(text, anchored: anchored) else {
      throw MaiFileWorkspaceError.invalidGlob("'\(text)' cannot be used as a pattern.")
    }
    return glob
  }

  /// A workspace-relative path as seen from a folder inside the workspace,
  /// so a pattern given for a search folder applies below that folder.
  private static func path(_ relative: String, below base: String) -> String {
    guard base != ".", relative.hasPrefix(base + "/") else { return relative }
    return String(relative.dropFirst(base.count + 1))
  }

  /// Compile a regular expression and, on failure, detect the common case where
  /// a backslash intended to escape a metacharacter was consumed by JSON decoding.
  /// In the tool-call JSON a single backslash is an escape for the string itself,
  /// so regex escapes must be doubled (e.g. "\\\\*") for a literal "*" to reach
  /// the NSRegularExpression parser.
  private static func compiledRegex(
    pattern: String,
    options: NSRegularExpression.Options = []
  ) throws -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern, options: options)
    } catch {
      let bareMetacharacters = CharacterSet(charactersIn: "*+?{}[]()|^$.")
      let hasBareMeta = pattern.unicodeScalars.enumerated().contains { index, scalar in
        guard bareMetacharacters.contains(scalar) else { return false }
        // A metacharacter is "bare" if it is not preceded by an odd number of backslashes.
        let prefix = pattern.prefix(index)
        let backslashCount = prefix.reversed().prefix(while: { $0 == "\\" }).count
        return backslashCount % 2 == 0
      }
      let detail: String
      if hasBareMeta {
        detail =
          "\(error.localizedDescription). The pattern contains an unescaped regex metacharacter; "
          + "in the JSON tool call backslashes must be doubled so one survives decoding "
          + "(e.g. '\\\\*' to match a literal '*', '\\\\(' for a literal '(')."
      } else {
        detail = error.localizedDescription
      }
      throw MaiFileWorkspaceError.invalidPattern(detail)
    }
  }

  func grep(_ arguments: [String: JSONValue]) async throws -> ToolOutput {
    let query = try requiredText(arguments, key: "query")
    var rawPath = arguments["path"]?.stringValue ?? ""
    var globs: [MaiGlob] = []
    if let split = MaiGlob.splitPath(rawPath) {
      rawPath = split.directory
      globs.append(try requiredGlob(split.pattern, anchored: true))
    }
    if let pattern = arguments["glob"]?.stringValue?.trimmingCharacters(
      in: .whitespacesAndNewlines), !pattern.isEmpty
    {
      globs.append(try requiredGlob(pattern))
    }
    let target = try resolve(rawPath, allowRoot: true, mustExist: true)
    let base = relativePath(target)
    let limit = Self.searchLimit
    let caseSensitive = query.contains(where: \.isUppercase)
    let useRegex = arguments["regex"]?.coercedBoolValue == true
    let expression: NSRegularExpression?
    if useRegex {
      expression = try Self.compiledRegex(
        pattern: query,
        options: caseSensitive ? [] : [.caseInsensitive])
    } else {
      expression = nil
    }
    var rows: [JSONValue] = []
    var rendered: [String] = []
    var scannedFiles = 0
    var hitLimit = false
    let scanFile: (URL, URLResourceValues) throws -> Bool = { url, values in
      guard rows.count < limit, scannedFiles < Self.maximumSearchEntries else {
        hitLimit = true
        return false
      }
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return true }
      if !globs.isEmpty {
        let relative = relativePath(url)
        let below = Self.path(relative, below: base)
        guard globs.allSatisfy({ $0.matches(relative) || $0.matches(below) }) else { return true }
      }
      scannedFiles += 1
      guard (values.fileSize ?? 0) <= 5_000_000,
        let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
        !looksBinary(data),
        let text = String(data: data, encoding: .utf8)
      else { return true }
      for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
        .enumerated()
      where rows.count < limit {
        if index.isMultiple(of: 64) { try Task.checkCancellation() }
        let line = String(line)
        let matched: Bool
        if let expression {
          matched =
            expression.firstMatch(
              in: line,
              range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
        } else if caseSensitive {
          matched = line.contains(query)
        } else {
          matched = line.localizedCaseInsensitiveContains(query)
        }
        guard matched else { continue }
        let clipped = line.count > 500 ? String(line.prefix(500)) + "…" : line
        let path = relativePath(url)
        rendered.append("\(path):\(index + 1): \(clipped)")
        rows.append(
          .object([
            "path": .string(path),
            "line": .integer(index + 1),
            "text": .string(clipped),
          ]))
      }
      if rows.count == limit { hitLimit = true }
      return rows.count < limit
    }
    let targetValues = try target.resourceValues(forKeys: [
      .fileSizeKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ])
    var searchMethod = "file"
    if targetValues.isDirectory == true {
      if let controlled = try await versionControlledEntries(
        at: target, includeDirectories: false,
        limit: Self.maximumSearchEntries + 1)
      {
        searchMethod = controlled.name
        if controlled.truncated { hitLimit = true }
        for (url, values) in controlled.entries {
          try Task.checkCancellation()
          guard try scanFile(url, values) else { break }
        }
      } else {
        searchMethod = "filtered-filesystem"
        try enumerateFiles(at: target) { url, values, enumerator in
          let shouldContinue = try scanFile(url, values)
          if !shouldContinue { enumerator.skipDescendants() }
          return shouldContinue
        }
      }
    } else {
      _ = try scanFile(target, targetValues)
    }
    var structured: [String: JSONValue] = [
      "query": .string(query),
      "matches": .array(rows),
      "scannedFiles": .integer(scannedFiles),
      "searchMethod": .string(searchMethod),
      "truncated": .bool(hitLimit),
    ]
    if !globs.isEmpty { structured["glob"] = .array(globs.map { .string($0.pattern) }) }
    var text = rendered.isEmpty ? "No matching lines." : rendered.joined(separator: "\n")
    if rendered.isEmpty, scannedFiles == 0, !globs.isEmpty {
      text += " No file matched \(globs.map { "'\($0.pattern)'" }.joined(separator: " and "))."
    }
    if hitLimit {
      // Without this line a model counts what it sees and reports it as the total.
      text +=
        "\nStopped after \(limit) matching lines; more exist. Narrow the query, or count with run_sh (grep -c)."
    }
    return ToolOutput(content: [.text(text)], structuredContent: .object(structured))
  }

  /// Formats whose bytes are useless to a model and whose text the document
  /// importer can produce; everything else is read as UTF-8.
  private static let convertedExtensions: Set<String> = ["pdf", "docx", "epub"]

  func read(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notFile(displayPath(rawPath))
    }
    if Self.convertedExtensions.contains(file.pathExtension.lowercased()) {
      return try readDocument(rawPath: rawPath, file: file, arguments: arguments)
    }
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    guard !looksBinary(data) else { throw MaiFileWorkspaceError.binary(displayPath(rawPath)) }
    let window = try textWindow(data, arguments: arguments, path: rawPath)
    return ToolOutput(
      content: [
        .file(
          FileContent(
            name: file.lastPathComponent,
            mimeType: "text/plain",
            text: window.text))
      ],
      structuredContent: .object([
        "path": .string(displayPath(rawPath)),
        "totalBytes": .integer(data.count),
        "offset": .integer(window.offset),
        "nextOffset": .integer(window.nextOffset),
        "truncated": .bool(window.nextOffset < data.count),
      ]))
  }

  private func readDocument(rawPath: String, file: URL, arguments: [String: JSONValue]) throws
    -> ToolOutput
  {
    let attachment = try DocumentAttachmentImporter.attachment(at: file)
    guard case .file(let content) = attachment.content, let text = content.text else {
      throw MaiFileWorkspaceError.invalidUTF8(displayPath(rawPath))
    }
    let data = Data(text.utf8)
    let window = try textWindow(data, arguments: arguments, path: rawPath)
    return ToolOutput(
      content: [
        .file(
          FileContent(
            name: content.name,
            mimeType: content.mimeType,
            text: window.text))
      ],
      structuredContent: .object([
        "path": .string(displayPath(rawPath)),
        "name": .string(attachment.name),
        "characters": .integer(attachment.characterCount),
        "totalBytes": .integer(data.count),
        "offset": .integer(window.offset),
        "nextOffset": .integer(window.nextOffset),
        "truncated": .bool(window.nextOffset < data.count),
        "conversion": attachment.note.map(JSONValue.string) ?? .null,
      ]))
  }

  func readIndex(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let display = displayPath(rawPath)
    let extension_ = file.pathExtension.lowercased()
    let text: String
    let conversion: String?
    let entries: [MaiDocumentIndexer.Entry]
    if extension_ == "json" {
      let rendered = try JSONDocumentImporter.render(
        data: Data(contentsOf: file, options: [.mappedIfSafe]))
      text = rendered.text
      conversion = "converted from JSON to an indented outline"
      entries = rendered.sections.map {
        MaiDocumentIndexer.Entry(
          line: $0.line, title: String(repeating: "  ", count: $0.depth) + $0.title)
      }
    } else {
      let attachment = try DocumentAttachmentImporter.attachment(at: file)
      guard case .file(let content) = attachment.content, let contentText = content.text else {
        throw MaiFileWorkspaceError.invalidUTF8(display)
      }
      text = contentText
      conversion = attachment.note
      entries =
        conversion == nil
        ? (MaiDocumentIndexer.sourceIndex(text: text, fileExtension: extension_)
          ?? MaiDocumentIndexer.markdownIndex(text: text))
        : MaiDocumentIndexer.markdownIndex(text: text)
    }
    guard !entries.isEmpty else {
      return ToolOutput(text: "No index entries found in \(display).")
    }
    var lines = [
      "Index of \(display)\(conversion.map { " (\($0))" } ?? ""): \(entries.count) entries"
    ]
    lines.append(contentsOf: entries.prefix(400).map { "\($0.line): \($0.title)" })
    if entries.count > 400 { lines.append("Truncated: showing 400 of \(entries.count) entries.") }
    return ToolOutput(
      content: [.text(lines.joined(separator: "\n"))],
      structuredContent: .object([
        "path": .string(display),
        "entries": .array(
          entries.prefix(400).map {
            .object(["line": .integer($0.line), "title": .string($0.title)])
          }),
        "truncated": .bool(entries.count > 400),
      ]))
  }

  func getFunction(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let name = try requiredText(arguments, key: "name")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let source = try sourceText(at: file, path: rawPath)
    let match = try functionMatch(
      named: name,
      line: arguments["line"]?.intValue,
      text: source.text,
      file: file,
      path: rawPath)
    return functionOutput(match, data: source.data, path: rawPath)
  }

  func setFunction(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let name = try requiredText(arguments, key: "name")
    guard let body = arguments["body"]?.stringValue else {
      throw MaiFileWorkspaceError.missingArgument("body")
    }
    let expectedRevision = try requiredText(arguments, key: "revision")
    let bodyData = Data(body.utf8)
    guard bodyData.count <= Self.maximumWriteBytes else {
      throw MaiFileWorkspaceError.writeTooLarge(Self.maximumWriteBytes)
    }
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let requestedLine = arguments["line"]?.intValue

    return try Self.functionMutationLock.withLock {
      let source = try sourceText(at: file, path: rawPath)
      let match = try functionMatch(
        named: name,
        line: requestedLine,
        text: source.text,
        file: file,
        path: rawPath)
      let bodyRange = match.bodyByteOffset..<(match.bodyByteOffset + match.bodyByteSize)
      let currentRevision = MaiSourceFunctionLocator.revision(of: source.data[bodyRange])
      guard currentRevision == expectedRevision else {
        throw MaiFileWorkspaceError.functionChanged(name, currentRevision)
      }

      var updated = Data()
      updated.reserveCapacity(source.data.count - match.bodyByteSize + bodyData.count)
      updated.append(source.data[..<match.bodyByteOffset])
      updated.append(bodyData)
      updated.append(source.data[(match.bodyByteOffset + match.bodyByteSize)...])
      guard updated.count <= Self.maximumSourceFileBytes else {
        throw MaiFileWorkspaceError.fileTooLarge(Self.maximumSourceFileBytes)
      }
      guard let updatedText = String(data: updated, encoding: .utf8) else {
        throw MaiFileWorkspaceError.invalidUTF8(displayPath(rawPath))
      }
      let validated = try functionMatch(
        named: name,
        line: match.declarationLine,
        text: updatedText,
        file: file,
        path: rawPath)
      guard validated.bodyByteOffset == match.bodyByteOffset,
        validated.bodyByteSize == bodyData.count
      else {
        throw MaiFileWorkspaceError.invalidFunctionBody(name)
      }

      let diff = MaiUnifiedDiff.render(
        old: source.text, new: updatedText, path: displayPath(rawPath))
      if updated != source.data { try updated.write(to: file, options: [.atomic]) }
      let newRevision = MaiSourceFunctionLocator.revision(
        of: updated[validated.bodyByteOffset..<(validated.bodyByteOffset + validated.bodyByteSize)])
      return mutationOutput(
        "Replaced body of \(name) in \(displayPath(rawPath)).",
        path: rawPath,
        diff: diff,
        extra: functionMetadata(validated, revision: newRevision))
    }
  }

  func readRange(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let text: String
    switch file.pathExtension.lowercased() {
    case "docx", "pdf", "epub", "json":
      let attachment = try DocumentAttachmentImporter.attachment(at: file)
      guard case .file(let content) = attachment.content, let contentText = content.text else {
        throw MaiFileWorkspaceError.invalidUTF8(displayPath(rawPath))
      }
      text = contentText
    default:
      text = try plainText(at: file, path: rawPath)
    }
    let lines = Self.documentLines(text)
    let start = arguments["start_line"]?.intValue ?? 1
    guard start >= 1 else { throw MaiFileWorkspaceError.invalidLineRange }
    guard start <= lines.count else {
      throw MaiFileWorkspaceError.lineOutOfRange(start, lines.count)
    }
    let end = arguments["end_line"]?.intValue ?? start + min(199, lines.count - start)
    guard end >= start else { throw MaiFileWorkspaceError.invalidLineRange }
    let finalEnd = min(end, start + min(999, lines.count - start))
    let rendered = (start...finalEnd).map { "\($0): \(lines[$0 - 1])" }
    return ToolOutput(content: [
      .text(
        (["File: \(displayPath(rawPath)), lines \(start)-\(finalEnd) of \(lines.count)"] + rendered)
          .joined(separator: "\n"))
    ])
  }

  func replaceRange(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let text = try plainText(at: file, path: rawPath)
    let start = try requiredInteger(arguments, key: "start_line")
    let end = arguments["end_line"]?.intValue ?? start
    let replacement = arguments["content"]?.stringValue ?? ""
    guard replacement.utf8.count <= Self.maximumWriteBytes else {
      throw MaiFileWorkspaceError.writeTooLarge(Self.maximumWriteBytes)
    }
    let edit = try Self.replacingLineRange(
      in: text, startLine: start, endLine: end, replacement: replacement)
    try Data(edit.text.utf8).write(to: file, options: .atomic)
    let action =
      edit.removedLineCount == 0 ? "Inserted" : edit.insertedLineCount == 0 ? "Deleted" : "Replaced"
    // The new numbering is what the next edit needs; without it models
    // re-read the whole file to find out where their lines ended up.
    let placed =
      edit.insertedLineCount == 0
      ? "lines \(start)-\(max(start, end)) removed"
      : edit.insertedLineCount == 1
        ? "now line \(start)" : "now lines \(start)-\(start + edit.insertedLineCount - 1)"
    return mutationOutput(
      "\(action) in \(displayPath(rawPath)): \(placed) of \(edit.totalLineCount).",
      path: rawPath,
      diff: MaiUnifiedDiff.render(old: text, new: edit.text, path: displayPath(rawPath)))
  }

  func patch(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let file = try resolve(rawPath, allowRoot: false, mustExist: true)
    let text = try plainText(at: file, path: rawPath)
    let find = try requiredText(arguments, key: "find")
    guard let replacement = arguments["replace"]?.stringValue else {
      throw MaiFileWorkspaceError.missingArgument("replace")
    }
    let expected = arguments["expected_matches"]?.intValue ?? 1
    guard (1...100).contains(expected) else { throw MaiFileWorkspaceError.invalidMatchCount }

    let patched: String
    let matchCount: Int
    if arguments["regex"]?.coercedBoolValue == true {
      let expression = try Self.compiledRegex(pattern: find)
      let range = NSRange(text.startIndex..<text.endIndex, in: text)
      let matches = expression.matches(in: text, range: range)
      guard matches.allSatisfy({ $0.range.length > 0 }) else {
        throw MaiFileWorkspaceError.emptyPatchMatch
      }
      matchCount = matches.count
      guard matchCount == expected else {
        throw MaiFileWorkspaceError.patchMatchCount(expected, matchCount)
      }
      patched = expression.stringByReplacingMatches(
        in: text, range: range, withTemplate: replacement)
    } else {
      matchCount = text.components(separatedBy: find).count - 1
      guard matchCount == expected else {
        throw MaiFileWorkspaceError.patchMatchCount(expected, matchCount)
      }
      patched = text.replacingOccurrences(of: find, with: replacement)
    }
    let data = Data(patched.utf8)
    guard data.count <= Self.maximumEditableFileBytes else {
      throw MaiFileWorkspaceError.fileTooLarge(Self.maximumEditableFileBytes)
    }
    try data.write(to: file, options: [.atomic])
    return mutationOutput(
      "Patched \(matchCount) match\(matchCount == 1 ? "" : "es") in \(displayPath(rawPath)).",
      path: rawPath,
      diff: MaiUnifiedDiff.render(old: text, new: patched, path: displayPath(rawPath)))
  }

  func write(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let destination = try resolve(rawPath, allowRoot: false, mustExist: false)
    if arguments["create_directory"]?.coercedBoolValue == true {
      try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      return mutationOutput("Created directory \(displayPath(rawPath))", path: rawPath)
    }
    guard let content = arguments["content"]?.stringValue else {
      throw MaiFileWorkspaceError.missingArgument("content")
    }
    let data = Data(content.utf8)
    guard data.count <= Self.maximumWriteBytes else {
      throw MaiFileWorkspaceError.writeTooLarge(Self.maximumWriteBytes)
    }
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      throw MaiFileWorkspaceError.notFile(displayPath(rawPath))
    }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    let mode: FileWriteMode
    if let modeString = arguments["mode"]?.stringValue,
       let parsed = FileWriteMode(rawValue: modeString) {
      mode = parsed
    } else {
      mode = .create
    }

    let fileExists = FileManager.default.fileExists(atPath: destination.path)

    switch mode {
    case .create:
      if fileExists {
        throw MaiFileWorkspaceError.fileAlreadyExists(displayPath(rawPath))
      }
      try data.write(to: destination, options: [.atomic])
    case .append:
      if fileExists {
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
      } else {
        try data.write(to: destination, options: [.atomic])
      }
    case .overwrite:
      try data.write(to: destination, options: [.atomic])
    }

    return mutationOutput(
      "\(mode == .append ? "Appended" : "Wrote") \(data.count) bytes to \(displayPath(rawPath))",
      path: rawPath,
      extra: ["bytes": .integer(data.count), "appended": .bool(mode == .append)])
  }

  func rename(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let newPath = try requiredPath(arguments, key: "new_path")
    let source = try resolve(rawPath, allowRoot: false, mustExist: true)
    let destination = try resolve(newPath, allowRoot: false, mustExist: false)
    guard !FileManager.default.fileExists(atPath: destination.path) else {
      throw MaiFileWorkspaceError.alreadyExists(displayPath(newPath))
    }
    var parentIsDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(
        atPath: destination.deletingLastPathComponent().path,
        isDirectory: &parentIsDirectory),
      parentIsDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(
        relativePath(destination.deletingLastPathComponent()))
    }
    try FileManager.default.moveItem(at: source, to: destination)
    return mutationOutput(
      "Renamed \(displayPath(rawPath)) to \(displayPath(newPath))",
      path: newPath,
      extra: ["previousPath": .string(displayPath(rawPath))])
  }

  func delete(_ arguments: [String: JSONValue]) throws -> ToolOutput {
    try requireWriteAccess()
    let rawPath = try requiredPath(arguments, key: "path")
    let target = try resolve(rawPath, allowRoot: false, mustExist: true)
    var isDirectory: ObjCBool = false
    _ = FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory)
    if isDirectory.boolValue, arguments["recursive"]?.coercedBoolValue != true {
      let entries = try FileManager.default.contentsOfDirectory(atPath: target.path)
      guard entries.isEmpty else {
        throw MaiFileWorkspaceError.recursiveRequired(displayPath(rawPath))
      }
    }
    try FileManager.default.removeItem(at: target)
    return mutationOutput("Deleted \(displayPath(rawPath))", path: rawPath)
  }

  private func plainText(at file: URL, path: String) throws -> String {
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    guard data.count <= Self.maximumEditableFileBytes else {
      throw MaiFileWorkspaceError.fileTooLarge(Self.maximumEditableFileBytes)
    }
    guard !looksBinary(data) else { throw MaiFileWorkspaceError.binary(displayPath(path)) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw MaiFileWorkspaceError.invalidUTF8(displayPath(path))
    }
    return text
  }

  private func sourceText(at file: URL, path: String) throws -> (data: Data, text: String) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
      !isDirectory.boolValue
    else { throw MaiFileWorkspaceError.notFile(displayPath(path)) }
    let data = try Data(contentsOf: file, options: [.mappedIfSafe])
    guard data.count <= Self.maximumSourceFileBytes else {
      throw MaiFileWorkspaceError.fileTooLarge(Self.maximumSourceFileBytes)
    }
    guard !looksBinary(data) else { throw MaiFileWorkspaceError.binary(displayPath(path)) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw MaiFileWorkspaceError.invalidUTF8(displayPath(path))
    }
    return (data, text)
  }

  private func functionMatch(
    named name: String,
    line: Int?,
    text: String,
    file: URL,
    path: String
  ) throws -> MaiSourceFunctionLocator.Match {
    var matches = MaiSourceFunctionLocator.matches(
      named: name,
      in: text,
      fileExtension: file.pathExtension)
    if let line { matches = matches.filter { $0.declarationLine == line } }
    guard !matches.isEmpty else {
      throw MaiFileWorkspaceError.functionNotFound(name, displayPath(path))
    }
    guard matches.count == 1 else {
      throw MaiFileWorkspaceError.functionAmbiguous(name, matches.map(\.declarationLine))
    }
    return matches[0]
  }

  private func functionOutput(
    _ match: MaiSourceFunctionLocator.Match,
    data: Data,
    path: String
  ) -> ToolOutput {
    let functionRange = match.byteOffset..<(match.byteOffset + match.byteSize)
    let bodyRange = match.bodyByteOffset..<(match.bodyByteOffset + match.bodyByteSize)
    let revision = MaiSourceFunctionLocator.revision(of: data[bodyRange])
    let source = String(decoding: data[functionRange], as: UTF8.self)
    let heading = [
      "Function \(match.name) in \(displayPath(path))",
      "Lines: \(match.startLine)-\(match.endLine); UTF-8 bytes: \(match.byteOffset)-\(match.byteOffset + match.byteSize) (\(match.byteSize) bytes)",
      "Body lines: \(match.bodyStartLine)-\(match.bodyEndLine); UTF-8 bytes: \(match.bodyByteOffset)-\(match.bodyByteOffset + match.bodyByteSize) (\(match.bodyByteSize) bytes)",
      "Revision: \(revision)",
    ].joined(separator: "\n")
    var metadata = functionMetadata(match, revision: revision)
    metadata["path"] = .string(displayPath(path))
    return ToolOutput(
      content: [.text(heading + "\n\n" + source)],
      structuredContent: .object(metadata))
  }

  private func functionMetadata(
    _ match: MaiSourceFunctionLocator.Match,
    revision: String
  ) -> [String: JSONValue] {
    [
      "name": .string(match.name),
      "declarationLine": .integer(match.declarationLine),
      "startLine": .integer(match.startLine),
      "endLine": .integer(match.endLine),
      "byteOffset": .integer(match.byteOffset),
      "byteSize": .integer(match.byteSize),
      "bodyStartLine": .integer(match.bodyStartLine),
      "bodyEndLine": .integer(match.bodyEndLine),
      "bodyByteOffset": .integer(match.bodyByteOffset),
      "bodyByteSize": .integer(match.bodyByteSize),
      "revision": .string(revision),
    ]
  }

  private static func documentLines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private static func replacingLineRange(
    in text: String,
    startLine: Int,
    endLine: Int,
    replacement: String
  ) throws -> (text: String, removedLineCount: Int, insertedLineCount: Int, totalLineCount: Int) {
    guard startLine >= 1, endLine >= startLine - 1 else {
      throw MaiFileWorkspaceError.invalidLineRange
    }
    let lines = documentLines(text)
    guard startLine <= lines.count + 1, endLine <= lines.count else {
      throw MaiFileWorkspaceError.lineOutOfRange(max(startLine, endLine), lines.count)
    }
    var replacementLines = replacement.components(separatedBy: "\n")
    if replacementLines.last == "" { replacementLines.removeLast() }
    var result = Array(lines[0..<(startLine - 1)])
    result.append(contentsOf: replacementLines)
    result.append(contentsOf: lines[endLine...])
    var newText = result.joined(separator: "\n")
    if text.hasSuffix("\n"), !newText.isEmpty { newText += "\n" }
    return (newText, endLine - startLine + 1, replacementLines.count, result.count)
  }

  private func resolve(
    _ rawPath: String,
    allowRoot: Bool,
    mustExist: Bool
  ) throws -> URL {
    let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidate: URL
    if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
      // An absolute path is fine as long as it points inside the workspace:
      // models often repeat the directory a shell command just printed.
      candidate =
        URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
        .standardizedFileURL
      if !isInside(candidate) {
        candidate = candidate.resolvingSymlinksInPath().standardizedFileURL
      }
    } else {
      candidate =
        rootURL.appendingPathComponent(trimmed.isEmpty ? "." : trimmed)
        .standardizedFileURL
    }
    guard isInside(candidate) else { throw MaiFileWorkspaceError.outsideWorkspace(rawPath) }
    guard allowRoot || candidate.path != rootURL.path else {
      throw MaiFileWorkspaceError.rootNotAllowed
    }
    if FileManager.default.fileExists(atPath: candidate.path) {
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      guard isInside(resolved) else { throw MaiFileWorkspaceError.outsideWorkspace(rawPath) }
      return resolved
    }
    guard !mustExist else { throw MaiFileWorkspaceError.notFound(displayPath(rawPath)) }

    var ancestor = candidate.deletingLastPathComponent()
    while ancestor.path != rootURL.path, !FileManager.default.fileExists(atPath: ancestor.path) {
      ancestor.deleteLastPathComponent()
    }
    let resolvedAncestor = ancestor.resolvingSymlinksInPath().standardizedFileURL
    guard isInside(resolvedAncestor) else {
      throw MaiFileWorkspaceError.outsideWorkspace(rawPath)
    }
    return candidate
  }

  private func enumerateFiles(
    at directory: URL,
    _ visit: (URL, URLResourceValues, FileManager.DirectoryEnumerator) throws -> Bool
  ) throws {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: Array(Self.searchResourceKeys),
        options: [.skipsHiddenFiles, .skipsPackageDescendants])
    else {
      throw MaiFileWorkspaceError.notDirectory(relativePath(directory))
    }
    while let url = enumerator.nextObject() as? URL {
      try Task.checkCancellation()
      let values = try url.resourceValues(forKeys: Self.searchResourceKeys)
      if shouldExcludeFromSourceSearch(url, values: values, below: directory) {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      if values.isSymbolicLink == true {
        if values.isDirectory == true { enumerator.skipDescendants() }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard isInside(resolved) else { continue }
      }
      if directory.path == rootURL.path,
        configuration.hiddenRootEntryNames.contains(url.lastPathComponent),
        url.deletingLastPathComponent().standardizedFileURL.path == rootURL.path
      {
        if values.isDirectory == true { enumerator.skipDescendants() }
        continue
      }
      guard try visit(url, values, enumerator) else { break }
    }
  }

  /// Returns tracked and untracked-but-not-ignored files. Directories are
  /// reconstructed from those paths so files_find retains its folder matches.
  /// Failure to detect or invoke a VCS is intentionally a cache miss: callers
  /// use the portable filtered filesystem walk instead.
  private func versionControlledEntries(
    at directory: URL,
    includeDirectories: Bool,
    limit: Int
  ) async throws -> VersionControlledEntries? {
    #if os(macOS) || os(Linux)
      guard let repository = repository(containing: directory) else { return nil }
      let environment = ProcessInfo.processInfo.environment
      let command = repository.kind == .git ? "git" : "hg"
      guard let executable = try? MaiHostProcess.resolve(command, environment: environment) else {
        return nil
      }
      let relativeDirectory = path(relativeTo: repository.url, child: directory) ?? "."
      var arguments: [String]
      switch repository.kind {
      case .git:
        arguments = [
          "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z",
          "--",
        ]
      case .mercurial:
        arguments = [
          "status", "--modified", "--added", "--clean", "--unknown", "--no-status",
          "--print0",
        ]
      }
      if relativeDirectory != "." { arguments.append(relativeDirectory) }

      let outcome: MaiHostProcessOutcome
      do {
        outcome = try await MaiHostProcess.run(
          executable: executable.executable,
          arguments: executable.arguments + arguments,
          workingDirectory: repository.url,
          environment: environment,
          stdin: nil,
          timeout: 5,
          outputLimit: 8_000_000,
          outputMode: .inline)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        return nil
      }
      guard outcome.exitCode == 0, !outcome.timedOut, outcome.stdoutDropped == 0 else {
        return nil
      }

      var candidates = Set<URL>()
      for bytes in outcome.stdout.split(separator: 0, omittingEmptySubsequences: true) {
        let relative = String(decoding: bytes, as: UTF8.self)
        let file = repository.url.appendingPathComponent(relative).standardizedFileURL
        guard isInside(file), isInside(file, directory: directory) else { continue }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          let values = try? file.resourceValues(forKeys: Self.searchResourceKeys),
          !isInHiddenRootEntry(file),
          !shouldExcludeFromSourceSearch(file, values: values, below: directory)
        else { continue }
        candidates.insert(file)
        if includeDirectories {
          var parent = file.deletingLastPathComponent().standardizedFileURL
          while parent.path != directory.path, isInside(parent, directory: directory) {
            candidates.insert(parent)
            parent = parent.deletingLastPathComponent().standardizedFileURL
          }
        }
      }

      // A folder the VCS lists nothing for (ignored by a parent repository, say)
      // is searched like any other folder rather than reported empty.
      guard !candidates.isEmpty else { return nil }
      let eligible = candidates.sorted {
        $0.path.localizedStandardCompare($1.path) == .orderedAscending
      }
      let selected = eligible.prefix(limit)
      let entries = selected.compactMap { url -> (URL, URLResourceValues)? in
        guard let values = try? url.resourceValues(forKeys: Self.searchResourceKeys) else {
          return nil
        }
        return (url, values)
      }
      return VersionControlledEntries(
        name: repository.kind.rawValue,
        entries: entries,
        truncated: eligible.count > selected.count)
    #else
      return nil
    #endif
  }

  private func repository(containing directory: URL) -> (kind: RepositoryKind, url: URL)? {
    var candidate = directory.standardizedFileURL
    while true {
      for kind in [RepositoryKind.git, .mercurial]
      where FileManager.default.fileExists(
        atPath: candidate.appendingPathComponent(kind.marker).path)
      {
        return (kind, candidate)
      }
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      guard parent.path != candidate.path else { break }
      candidate = parent
    }
    return nil
  }

  private func shouldExcludeFromSourceSearch(
    _ url: URL,
    values: URLResourceValues,
    below directory: URL
  ) -> Bool {
    guard let relative = path(relativeTo: directory, child: url) else { return true }
    let components = relative.split(separator: "/").map(String.init)
    guard !components.contains(where: { $0.hasPrefix(".") }) else { return true }
    let directoryNames = values.isDirectory == true ? components : Array(components.dropLast())
    return directoryNames.contains {
      Self.commonNonSourceDirectories.contains($0.lowercased())
    }
  }


  private func path(relativeTo directory: URL, child: URL) -> String? {
    let parentPath = directory.standardizedFileURL.path
    let childPath = child.standardizedFileURL.path
    guard childPath.hasPrefix(parentPath + "/") else { return nil }
    return String(childPath.dropFirst(parentPath.count + 1))
  }

  private func isInside(_ url: URL, directory: URL) -> Bool {
    let parentPath = directory.standardizedFileURL.path
    let childPath = url.standardizedFileURL.path
    return childPath.hasPrefix(parentPath + "/")
  }

  private func isInHiddenRootEntry(_ url: URL) -> Bool {
    guard let relative = path(relativeTo: rootURL, child: url),
      let first = relative.split(separator: "/").first
    else { return false }
    return configuration.hiddenRootEntryNames.contains(String(first))
  }

  private func requireDirectory(_ url: URL, displayPath: String) throws {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw MaiFileWorkspaceError.notDirectory(displayPath)
    }
  }

  private func textWindow(
    _ data: Data,
    arguments: [String: JSONValue],
    path: String
  ) throws -> (text: String, offset: Int, nextOffset: Int) {
    let requestedOffset = min(max(arguments["offset"]?.intValue ?? 0, 0), data.count)
    let limit = min(
      max(arguments["max_bytes"]?.intValue ?? Self.defaultReadLimit, 1),
      Self.maximumReadLimit)
    var offset = requestedOffset
    while offset < data.count, data[offset] & 0xC0 == 0x80 { offset += 1 }
    var end = offset + min(limit, data.count - offset)
    while end > offset, end < data.count, data[end] & 0xC0 == 0x80 { end -= 1 }
    // A tiny page must still consume one complete scalar, or nextOffset stalls.
    if end == offset, offset < data.count {
      end += 1
      while end < data.count, end - offset < 4, data[end] & 0xC0 == 0x80 { end += 1 }
    }
    // Decode once. Invalid bytes inside a page are an error, not a reason to
    // repeatedly decode shorter prefixes and silently lose the rest of the file.
    guard let text = String(data: data[offset..<end], encoding: .utf8) else {
      throw MaiFileWorkspaceError.invalidUTF8(displayPath(path))
    }
    return (text, offset, end)
  }

  private func fuzzyScore(_ candidate: String, query: String) -> Int? {
    let candidate = candidate.lowercased()
    let query = query.lowercased()
    let name = (candidate as NSString).lastPathComponent
    if name == query { return 0 }
    if candidate == query { return 1 }
    if let range = name.range(of: query) {
      return 10 + name.distance(from: name.startIndex, to: range.lowerBound) + name.count
        - query.count
    }
    if let range = candidate.range(of: query) {
      return 30 + candidate.distance(from: candidate.startIndex, to: range.lowerBound)
    }
    var queryIndex = query.startIndex
    var gaps = 0
    var lastMatch: String.Index?
    for index in candidate.indices where queryIndex < query.endIndex {
      guard candidate[index] == query[queryIndex] else { continue }
      if let lastMatch { gaps += candidate.distance(from: lastMatch, to: index) - 1 }
      lastMatch = index
      query.formIndex(after: &queryIndex)
    }
    return queryIndex == query.endIndex ? 100 + gaps + candidate.count - query.count : nil
  }

  private func isInside(_ url: URL) -> Bool {
    url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/")
  }

  private func relativePath(_ url: URL) -> String {
    let resolvedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
    if resolvedPath == rootURL.path { return "." }
    if resolvedPath.hasPrefix(rootURL.path + "/") {
      return String(resolvedPath.dropFirst(rootURL.path.count + 1))
    }
    let lexicalRoot = configuration.rootURL.standardizedFileURL.path
    let lexicalPath = url.standardizedFileURL.path
    if lexicalPath == lexicalRoot { return "." }
    if lexicalPath.hasPrefix(lexicalRoot + "/") {
      return String(lexicalPath.dropFirst(lexicalRoot.count + 1))
    }
    return url.lastPathComponent
  }

  private func displayPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed == "." ? configuration.displayName : trimmed
  }

  private func requiredPath(
    _ arguments: [String: JSONValue],
    key: String
  ) throws -> String {
    guard let value = arguments[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MaiFileWorkspaceError.missingArgument(key)
    }
    return value
  }

  private func requiredText(
    _ arguments: [String: JSONValue],
    key: String
  ) throws -> String {
    guard let value = arguments[key]?.stringValue,
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw MaiFileWorkspaceError.missingArgument(key)
    }
    return value
  }

  private func requiredInteger(_ arguments: [String: JSONValue], key: String) throws -> Int {
    guard let value = arguments[key]?.intValue else {
      throw MaiFileWorkspaceError.missingArgument(key)
    }
    return value
  }

  private func requireWriteAccess() throws {
    guard configuration.writeEnabled else { throw MaiFileWorkspaceError.writeDisabled }
  }

  private func looksBinary(_ data: Data) -> Bool {
    data.prefix(8_192).contains(0)
  }

  private func mutationOutput(
    _ text: String,
    path: String,
    diff: String? = nil,
    extra: [String: JSONValue] = [:]
  ) -> ToolOutput {
    var values: [String: JSONValue] = ["path": .string(displayPath(path))]
    values.merge(extra) { _, new in new }
    let rendered = diff.map { $0.isEmpty ? text : text + "\n" + $0 } ?? text
    if let diff { values["changed"] = .bool(!diff.isEmpty) }
    return ToolOutput(content: [.text(rendered)], structuredContent: .object(values))
  }
}

private enum MaiFileWorkspaceError: LocalizedError {
  case invalidRoot(String)
  case missingArgument(String)
  case outsideWorkspace(String)
  case rootNotAllowed
  case notFound(String)
  case notFile(String)
  case notDirectory(String)
  case binary(String)
  case invalidUTF8(String)
  case alreadyExists(String)
  case fileAlreadyExists(String)
  case recursiveRequired(String)
  case writeTooLarge(Int)
  case fileTooLarge(Int)
  case invalidLineRange
  case lineOutOfRange(Int, Int)
  case writeDisabled
  case invalidPattern(String)
  case invalidGlob(String)
  case invalidMatchCount
  case emptyPatchMatch
  case patchMatchCount(Int, Int)
  case invalidPath(String)
  case functionNotFound(String, String)
  case functionAmbiguous(String, [Int])
  case functionChanged(String, String)
  case invalidFunctionBody(String)

  var errorDescription: String? {
    switch self {
    case .invalidRoot(let path): "Files workspace '\(path)' is not an accessible directory."
    case .missingArgument(let name): "\(name) is required."
    case .outsideWorkspace(let path): "Path '\(path)' is outside the configured workspace."
    case .rootNotAllowed: "This operation cannot target the workspace root."
    case .notFound(let path): "'\(path)' does not exist."
    case .notFile(let path): "'\(path)' is not a file; files_list lists a folder."
    case .notDirectory(let path): "'\(path)' is not a folder; files_read reads a file."
    case .binary(let path): "'\(path)' appears to be binary; text files only."
    case .invalidUTF8(let path): "'\(path)' is not valid UTF-8 text."
    case .alreadyExists(let path): "'\(path)' already exists."
    case .fileAlreadyExists(let path):
      "'\(path)' already exists. Use mode: .append to add to the end, or mode: .overwrite to replace the whole file; use files_patch to edit part of it."
    case .recursiveRequired(let path):
      "Directory '\(path)' is not empty; set recursive=true to delete it."
    case .writeTooLarge(let limit): "A single write is limited to \(limit) bytes."
    case .fileTooLarge(let limit):
      "The file is larger than \(limit) bytes; use files_read with offsets instead."
    case .invalidLineRange:
      "Line ranges must be 1-based and inclusive. Use end_line=start_line-1 to insert."
    case .lineOutOfRange(let line, let count): "Line \(line) is outside this file's \(count) lines."
    case .writeDisabled: "File changes are disabled for this tool source."
    case .invalidPattern(let detail): "Invalid regular expression: \(detail)"
    case .invalidGlob(let message): "Invalid pattern: \(message)"
    case .invalidMatchCount: "expected_matches must be between 1 and 100."
    case .emptyPatchMatch: "The regular expression must not match an empty range."
    case .patchMatchCount(let expected, let actual):
      "Expected \(expected) patch matches, found \(actual)."
    case .invalidPath(let path): "Could not change the current directory to '\(path)'."
    case .functionNotFound(let name, let path):
      "Could not find a complete function named '\(name)' in '\(path)'. Use files_read_index to inspect the available declarations."
    case .functionAmbiguous(let name, let lines):
      "Function '\(name)' is ambiguous; pass one of these declaration lines: \(lines.map(String.init).joined(separator: ", "))."
    case .functionChanged(let name, let revision):
      "Function '\(name)' changed since it was read. Call files_get_function again and use revision '\(revision)'."
    case .invalidFunctionBody(let name):
      "The replacement body changes the structural bounds of '\(name)'; check delimiters and indentation."
    }
  }
}

extension MaiFileWorkspaceError {
  /// Where paths are resolved from, for the errors a wrong path produces, so
  /// a model can correct itself instead of guessing.
  func pathHint(root: String) -> String {
    switch self {
    case .outsideWorkspace, .notFound, .notDirectory, .notFile:
      " The workspace is \(root): give paths relative to it, or absolute paths inside it."
    default:
      ""
    }
  }
}
