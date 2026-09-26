import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Shared Files tools manage a root-scoped text workspace")
func fileWorkspaceToolsManageFiles() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let configuration = MaiFileWorkspaceConfiguration(
    rootURL: root,
    displayName: "test-workspace")
  let tools = MaiFileWorkspaceTool.makeTools(configuration: configuration)
  #expect(Set(tools.map(\.definition.name)) == Set(MaiFileWorkspaceTool.toolNames))
  #expect(tool(tools, .delete).definition.annotations.approval == .dangerous)
  #expect(tool(tools, .delete).definition.annotations.destructive)

  let write = try await call(
    tool(tools, .write),
    ["path": .string("notes/todo.md"), "content": .string("one")])
  #expect(!write.isError)
  #expect(write.structuredContent?.objectValue?["bytes"] == .integer(3))

  _ = try await call(
    tool(tools, .write),
    [
      "path": .string("notes/todo.md"),
      "content": .string("\ntwo"),
      "mode": .string("append"),
    ])
  let read = try await call(tool(tools, .read), ["path": .string("notes/todo.md")])
  #expect(read.text == "one\ntwo")
  #expect(read.structuredContent?.objectValue?["truncated"] == .bool(false))

  // JSON stays raw: a model editing a config file wants the bytes it will patch.
  _ = try await call(
    tool(tools, .write),
    ["path": .string("record.json"), "content": .string("{\"name\":\"Mai\"}")])
  let json = try await call(tool(tools, .read), ["path": .string("record.json")])
  #expect(json.text == "{\"name\":\"Mai\"}")

  // Word and PDF files are converted by the same read tool.
  let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
  try FileManager.default.copyItem(
    at: fixtures.appendingPathComponent("sample.docx"),
    to: root.appendingPathComponent("sample.docx"))
  let document = try await call(
    tool(tools, .read), ["path": .string("sample.docx"), "max_bytes": .integer(40)])
  #expect(document.text.contains("Fixture Report"))
  #expect(document.structuredContent?.objectValue?["truncated"] == .bool(true))
  #expect(document.structuredContent?.objectValue?["conversion"] != nil)

  let listing = try await call(tool(tools, .list), ["path": .string("notes")])
  let entries = listing.structuredContent?.objectValue?["entries"]?.arrayValue
  #expect(entries?.first?.objectValue?["path"] == .string("notes/todo.md"))

  let found = try await call(tool(tools, .find), ["query": .string("tdmd")])
  #expect(
    found.structuredContent?.objectValue?["matches"]?.arrayValue?.first?.objectValue?["path"]
      == .string("notes/todo.md"))
  let grepped = try await call(tool(tools, .grep), ["query": .string("two")])
  let grepMatch = grepped.structuredContent?.objectValue?["matches"]?.arrayValue?.first
  #expect(grepMatch?.objectValue?["path"] == .string("notes/todo.md"))
  #expect(grepMatch?.objectValue?["line"] == .integer(2))

  let greppedFile = try await call(
    tool(tools, .grep),
    ["path": .string("notes/todo.md"), "query": .string("one")])
  let fileMatches = greppedFile.structuredContent?.objectValue?["matches"]?.arrayValue
  #expect(fileMatches?.count == 1)
  #expect(fileMatches?.first?.objectValue?["path"] == .string("notes/todo.md"))
  #expect(fileMatches?.first?.objectValue?["line"] == .integer(1))
  #expect(greppedFile.structuredContent?.objectValue?["scannedFiles"] == .integer(1))

  _ = try await call(
    tool(tools, .rename),
    ["path": .string("notes/todo.md"), "new_path": .string("notes/done.md")])
  #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/done.md").path))

  _ = try await call(tool(tools, .delete), ["path": .string("notes/done.md")])
  #expect(
    !FileManager.default.fileExists(atPath: root.appendingPathComponent("notes/done.md").path))
}

@Test("Files search covers source paths and offers only the arguments a model needs")
func fileWorkspaceSearchUsesCodingFriendlyDefaults() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-search-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("Sources/Nested"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("node_modules/package"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent("build"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: root.appendingPathComponent(".cache"), withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  for path in [
    "Sources/Needle.swift", "Sources/Nested/Needle.swift",
    "node_modules/package/Needle.swift", "build/Needle.swift", ".cache/Needle.swift",
  ] {
    try Data("needle\n".utf8).write(to: root.appendingPathComponent(path))
  }

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let find = tool(tools, .find)
  let grep = tool(tools, .grep)
  // Only the arguments a model needs are offered; the rest are fixed defaults.
  #expect(Set(find.definition.parameters.map(\.name)) == ["query", "filter", "path"])
  #expect(Set(grep.definition.parameters.map(\.name)) == ["query", "path", "glob", "regex"])

  let normal = try await call(find, ["query": .string("Needle.swift")])
  let normalPaths = Set(
    normal.structuredContent?.objectValue?["matches"]?.arrayValue?.compactMap {
      $0.objectValue?["path"]?.stringValue
    } ?? [])
  #expect(normalPaths.contains("Sources/Needle.swift"))
  #expect(normalPaths.contains("Sources/Nested/Needle.swift"))
  #expect(!normalPaths.contains("node_modules/package/Needle.swift"))
  #expect(!normalPaths.contains("build/Needle.swift"))
  #expect(!normalPaths.contains(".cache/Needle.swift"))
  #expect(
    normal.structuredContent?.objectValue?["searchMethod"] == .string("filtered-filesystem"))

  let filtered = try await call(find, [
    "query": .string("Needle.swift"), "filter": .string("nested"),
  ])
  #expect(filtered.text == "Sources/Nested/Needle.swift")
  #expect(filtered.structuredContent?.objectValue?["filter"] == .string("nested"))
  let filterOnly = try await call(find, ["filter": .string("NEEDLE")])
  let filterOnlyPaths = filterOnly.structuredContent?.objectValue?["matches"]?.arrayValue?
    .compactMap { $0.objectValue?["path"]?.stringValue } ?? []
  #expect(Set(filterOnlyPaths) == ["Sources/Needle.swift", "Sources/Nested/Needle.swift"])
  #expect(filterOnlyPaths.allSatisfy { $0.localizedCaseInsensitiveContains("NEEDLE") })
  let noFilteredMatch = try await call(find, ["filter": .string("absent")])
  #expect(noFilteredMatch.text.contains("filter 'absent'"))
  #expect(noFilteredMatch.structuredContent?.objectValue?["matches"] == .array([]))

  let normalGrep = try await call(grep, ["query": .string("needle")])
  #expect(normalGrep.structuredContent?.objectValue?["scannedFiles"] == .integer(2))

  // A search that stops at the match limit says so in the text the model reads.
  try Data(String(repeating: "needle here\n", count: 150).utf8)
    .write(to: root.appendingPathComponent("Sources/Many.swift"))
  let capped = try await call(grep, ["query": .string("needle")])
  #expect(capped.text.contains("Stopped after 100 matching lines; more exist."))
  #expect(capped.structuredContent?.objectValue?["truncated"] == .bool(true))
}

#if os(macOS) || os(Linux)
  @Test("Files search includes tracked and new non-ignored Git files")
  func fileWorkspaceSearchUsesGitIgnoreRules() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let git = try? MaiHostProcess.resolve("git", environment: environment) else { return }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mai-files-git-\(UUID().uuidString)", isDirectory: true)
    for directory in ["Sources", "Drafts", "scratch"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("scratch/\n".utf8).write(to: root.appendingPathComponent(".gitignore"))
    try Data("tracked\n".utf8).write(
      to: root.appendingPathComponent("Sources/TrackedNeedle.swift"))
    try Data("new\n".utf8).write(
      to: root.appendingPathComponent("Drafts/UntrackedNeedle.swift"))
    try Data("ignored\n".utf8).write(
      to: root.appendingPathComponent("scratch/IgnoredNeedle.swift"))
    try runProcess(git, arguments: ["init", "-q"], at: root, environment: environment)
    try runProcess(
      git, arguments: ["add", ".gitignore", "Sources/TrackedNeedle.swift"], at: root,
      environment: environment)

    let find = MaiFileWorkspaceTool(
      operation: .find, configuration: MaiFileWorkspaceConfiguration(rootURL: root))
    let result = try await call(find, ["query": .string("Needle.swift")])
    let paths = Set(
      result.structuredContent?.objectValue?["matches"]?.arrayValue?.compactMap {
        $0.objectValue?["path"]?.stringValue
      } ?? [])
    #expect(paths.contains("Sources/TrackedNeedle.swift"))
    #expect(paths.contains("Drafts/UntrackedNeedle.swift"))
    #expect(!paths.contains("scratch/IgnoredNeedle.swift"))
    #expect(result.structuredContent?.objectValue?["searchMethod"] == .string("git"))

    // A workspace rooted in a folder the repository ignores is not empty to
    // the model: git lists nothing there, so the filtered walk takes over.
    let ignoredRoot = root.appendingPathComponent("scratch")
    let grep = MaiFileWorkspaceTool(
      operation: .grep, configuration: MaiFileWorkspaceConfiguration(rootURL: ignoredRoot))
    let inside = try await call(grep, ["query": .string("ignored")])
    #expect(inside.text.contains("IgnoredNeedle.swift:1: ignored"))
    #expect(
      inside.structuredContent?.objectValue?["searchMethod"] == .string("filtered-filesystem"))
  }

  @Test("Files search includes tracked and new non-ignored Mercurial files")
  func fileWorkspaceSearchUsesMercurialIgnoreRules() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let hg = try? MaiHostProcess.resolve("hg", environment: environment) else { return }
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("mai-files-hg-\(UUID().uuidString)", isDirectory: true)
    for directory in ["Sources", "Drafts", "scratch"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("syntax: glob\nscratch/**\n".utf8).write(to: root.appendingPathComponent(".hgignore"))
    try Data("tracked\n".utf8).write(
      to: root.appendingPathComponent("Sources/TrackedNeedle.swift"))
    try Data("new\n".utf8).write(
      to: root.appendingPathComponent("Drafts/UntrackedNeedle.swift"))
    try Data("ignored\n".utf8).write(
      to: root.appendingPathComponent("scratch/IgnoredNeedle.swift"))
    try runProcess(hg, arguments: ["init"], at: root, environment: environment)
    try runProcess(
      hg, arguments: ["add", ".hgignore", "Sources/TrackedNeedle.swift"], at: root,
      environment: environment)

    let find = MaiFileWorkspaceTool(
      operation: .find, configuration: MaiFileWorkspaceConfiguration(rootURL: root))
    let result = try await call(find, ["query": .string("Needle.swift")])
    let paths = Set(
      result.structuredContent?.objectValue?["matches"]?.arrayValue?.compactMap {
        $0.objectValue?["path"]?.stringValue
      } ?? [])
    #expect(paths.contains("Sources/TrackedNeedle.swift"))
    #expect(paths.contains("Drafts/UntrackedNeedle.swift"))
    #expect(!paths.contains("scratch/IgnoredNeedle.swift"))
    #expect(result.structuredContent?.objectValue?["searchMethod"] == .string("mercurial"))
  }

  private func runProcess(
    _ executable: (executable: URL, arguments: [String]),
    arguments: [String],
    at directory: URL,
    environment: [String: String]
  ) throws {
    let process = Process()
    process.executableURL = executable.executable
    process.arguments = executable.arguments + arguments
    process.currentDirectoryURL = directory
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "FileWorkspaceToolTests", code: Int(process.terminationStatus))
    }
  }
#endif

@Test("Shared Files tools index, read, and replace source line ranges")
func fileWorkspaceToolsSupportAdvancedSourceNavigation() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-advanced-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root, displayName: "test-workspace"))
  _ = try await call(
    tool(tools, .write),
    [
      "path": .string("example.swift"),
      "content": .string("struct Greeter {\n  func hello() {}\n}\n"),
    ])

  let index = try await call(tool(tools, .readIndex), ["path": .string("example.swift")])
  #expect(index.text.contains("1: struct Greeter"))
  #expect(index.text.contains("2: hello"))

  let range = try await call(
    tool(tools, .readRange),
    ["path": .string("example.swift"), "start_line": .integer(2), "end_line": .integer(2)])
  #expect(range.text.contains("2:   func hello() {}"))

  for start in [Int.max, Int.min, 0] {
    let invalid = try await call(tool(tools, .readRange), [
      "path": .string("example.swift"), "start_line": .integer(start),
    ])
    #expect(invalid.isError)
  }
  let last = try await call(tool(tools, .readRange), [
    "path": .string("example.swift"), "start_line": .integer(3), "end_line": .integer(Int.max),
  ])
  #expect(!last.isError)
  #expect(last.text.contains("3: }"))

  let replaced = try await call(
    tool(tools, .replaceRange),
    [
      "path": .string("example.swift"), "start_line": .integer(2), "end_line": .integer(2),
      "content": .string("  func goodbye() {}"),
    ])
  #expect(replaced.text.contains("--- a/example.swift"))
  #expect(replaced.text.contains("-  func hello() {}"))
  #expect(replaced.text.contains("+  func goodbye() {}"))
  let read = try await call(tool(tools, .read), ["path": .string("example.swift")])
  #expect(read.text.contains("goodbye"))

  let patchedResult = try await call(
    tool(tools, .patch),
    [
      "path": .string("example.swift"), "find": .string("func\\s+goodbye"),
      "replace": .string("func farewell"), "regex": .bool(true),
    ])
  #expect(patchedResult.text.contains("-  func goodbye() {}"))
  #expect(patchedResult.text.contains("+  func farewell() {}"))
  let patched = try await call(tool(tools, .read), ["path": .string("example.swift")])
  #expect(patched.text.contains("farewell"))
}

@Test("Files function tools locate large HolyC sources and replace one body safely")
func fileWorkspaceFunctionToolsSupportHolyC() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-functions-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let filler = String(repeating: "// filler outside the normal read window\n", count: 4_000)
  let source =
    filler + """
      U0 print_gvars(I64 count)
      {
        for (I64 i = 0; i < count; i++) {
          Print("{still text}");
        }
      }

      U0 untouched()
      {
        Print("same");
      }
      """
  try Data(source.utf8).write(to: root.appendingPathComponent("debug.HC"))
  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root, displayName: "test-workspace"))

  let get = try await call(
    tool(tools, .getFunction),
    ["path": .string("debug.HC"), "name": .string("print_gvars")])
  #expect(!get.isError)
  #expect(get.text.contains("U0 print_gvars(I64 count)"))
  #expect(get.structuredContent?.objectValue?["byteOffset"]?.intValue ?? 0 > 120_000)
  #expect(get.structuredContent?.objectValue?["bodyByteSize"]?.intValue ?? 0 > 0)
  let revision = try #require(
    get.structuredContent?.objectValue?["revision"]?.stringValue)
  let untouchedGet = try await call(
    tool(tools, .getFunction),
    ["path": .string("debug.HC"), "name": .string("untouched")])
  let untouchedRevision = try #require(
    untouchedGet.structuredContent?.objectValue?["revision"]?.stringValue)

  let set = try await call(
    tool(tools, .setFunction),
    [
      "path": .string("debug.HC"),
      "name": .string("print_gvars"),
      "body": .string("\n  Print(\"updated\");\n"),
      "revision": .string(revision),
    ])
  #expect(!set.isError)
  #expect(set.text.contains("--- a/debug.HC"))
  #expect(set.text.contains("-  for (I64 i = 0; i < count; i++) {"))
  #expect(set.text.contains("+  Print(\"updated\");"))
  let updated = try String(contentsOf: root.appendingPathComponent("debug.HC"), encoding: .utf8)
  #expect(updated.contains("Print(\"updated\");"))
  #expect(updated.contains("U0 untouched()\n{\n  Print(\"same\");\n}"))

  // This revision was read before the first update. A separate function edit
  // still succeeds and starts from the latest complete file contents.
  let parallelSet = try await call(
    tool(tools, .setFunction),
    [
      "path": .string("debug.HC"),
      "name": .string("untouched"),
      "body": .string("\n  Print(\"also updated\");\n"),
      "revision": .string(untouchedRevision),
    ])
  #expect(!parallelSet.isError)
  let parallelUpdated = try String(
    contentsOf: root.appendingPathComponent("debug.HC"), encoding: .utf8)
  #expect(parallelUpdated.contains("Print(\"updated\");"))
  #expect(parallelUpdated.contains("Print(\"also updated\");"))

  let stale = try await call(
    tool(tools, .setFunction),
    [
      "path": .string("debug.HC"),
      "name": .string("print_gvars"),
      "body": .string("\n  Print(\"stale\");\n"),
      "revision": .string(revision),
    ])
  #expect(stale.isError)
  #expect(stale.text.contains("changed since it was read"))
}

@Test("Files function tools understand indentation-delimited Python functions")
func fileWorkspaceFunctionToolsSupportPython() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-python-functions-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = """
    def greet(name):
        if name:
            return f"hi {name}"
        return "hi"

    def untouched():
        return 1
    """
  try Data(source.utf8).write(to: root.appendingPathComponent("hello.py"))
  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))

  let get = try await call(
    tool(tools, .getFunction),
    ["path": .string("hello.py"), "name": .string("greet")])
  #expect(!get.isError)
  #expect(get.structuredContent?.objectValue?["startLine"] == .integer(1))
  #expect(get.structuredContent?.objectValue?["endLine"] == .integer(5))
  #expect(get.text.contains("return f\"hi {name}\""))
  #expect(!get.text.contains("def untouched"))
}

@Test("Shared Files tools reject traversal and symlink escapes")
func fileWorkspaceToolsStayInsideRoot() async throws {
  let base = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-boundary-\(UUID().uuidString)", isDirectory: true)
  let root = base.appendingPathComponent("root", isDirectory: true)
  let outside = base.appendingPathComponent("outside", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
  try Data("private".utf8).write(to: outside.appendingPathComponent("secret.txt"))
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("escape"),
    withDestinationURL: outside)
  defer { try? FileManager.default.removeItem(at: base) }

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let traversal = try await call(
    tool(tools, .write),
    ["path": .string("../outside/new.txt"), "content": .string("no")])
  #expect(traversal.isError)
  #expect(traversal.text.contains("outside the configured workspace"))
  #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("new.txt").path))

  let symlink = try await call(
    tool(tools, .read),
    ["path": .string("escape/secret.txt")])
  #expect(symlink.isError)
  #expect(symlink.text.contains("outside the configured workspace"))

  let grep = try await call(tool(tools, .grep), ["query": .string("private")])
  #expect(grep.text == "No matching lines.")
}

@Test("Files group can expose a read-only workspace")
func fileWorkspaceCanDisableChanges() async throws {
  let root = FileManager.default.temporaryDirectory
  let context = PluginFactoryContext(
    id: "standard",
    options: [
      "filesRoot": .string(root.path),
      "filesWriteEnabled": .bool(false),
    ])
  let factory = MaiStandardToolFactory()
  let tools = try await factory.makeTools(context: context)
  let names = Set(tools.map(\.definition.name))
  #expect(names.contains(MaiFileWorkspaceTool.Operation.list.rawValue))
  #expect(names.contains(MaiFileWorkspaceTool.Operation.read.rawValue))
  #expect(names.contains(MaiFileWorkspaceTool.Operation.getFunction.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.write.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.setFunction.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.rename.rawValue))
  #expect(!names.contains(MaiFileWorkspaceTool.Operation.delete.rawValue))

  let group = try #require(
    try await factory.toolGroups(context: context).first { $0.id == "files" })
  #expect(group.toolNames.contains(MaiFileWorkspaceTool.Operation.read.rawValue))
  #expect(!group.toolNames.contains(MaiFileWorkspaceTool.Operation.write.rawValue))
  #expect(group.options.contains { $0.id == "filesWriteEnabled" })
}

@Test("Files tools propagate task cancellation")
func fileWorkspaceToolsPropagateCancellation() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-cancel-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let grep = MaiFileWorkspaceTool(
    operation: .grep,
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let (stream, continuation) = AsyncStream<Void>.makeStream()
  let task = Task {
    for await _ in stream { break }
    return try await call(grep, ["query": .string("needle")])
  }

  task.cancel()
  continuation.yield()
  continuation.finish()
  do {
    _ = try await task.value
    Issue.record("Expected files_grep to propagate cancellation")
  } catch is CancellationError {
    // Expected: the runtime can return to the REPL instead of treating cancellation as tool output.
  }
}

private func tool(
  _ tools: [MaiFileWorkspaceTool],
  _ operation: MaiFileWorkspaceTool.Operation
) -> MaiFileWorkspaceTool {
  tools.first { $0.operation == operation }!
}

private func call(
  _ tool: MaiFileWorkspaceTool,
  _ arguments: [String: JSONValue]
) async throws -> ToolOutput {
  try await tool.call(
    arguments: .object(arguments),
    context: ToolExecutionContext(
      run: AgentEventContext(
        runID: UUID(),
        parentRunID: nil,
        agentID: "files-test",
        depth: 0),
      modelTurn: 1))
}

@Test("Shared Files tools require overwrite to replace an existing file")
func fileWorkspaceWriteRequiresOverwrite() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-files-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root, displayName: "test-workspace"))
  let write = tool(tools, .write)
  #expect(write.definition.parameters.contains { $0.name == "mode" })

  let created = try await call(write, ["path": .string("main.c"), "content": .string("int a;\n")])
  #expect(!created.isError)

  let refused = try await call(write, ["path": .string("main.c"), "content": .string("int b;\n")])
  #expect(refused.isError)
  #expect(refused.text.contains("files_patch"))
  #expect(refused.text.contains("mode"))
  let unchanged = try await call(tool(tools, .read), ["path": .string("main.c")])
  #expect(unchanged.text == "int a;\n")

  let appended = try await call(
    write,
    ["path": .string("main.c"), "content": .string("int c;\n"), "mode": .string("append")])
  #expect(!appended.isError)

  let replaced = try await call(
    write,
    ["path": .string("main.c"), "content": .string("int b;\n"), "mode": .string("overwrite")])
  #expect(!replaced.isError)
  let read = try await call(tool(tools, .read), ["path": .string("main.c")])
  #expect(read.text == "int b;\n")

  try Data().write(to: root.appendingPathComponent("empty.txt"))
  let filledEmpty = try await call(
    write,
    ["path": .string("empty.txt"), "content": .string("now full"), "mode": .string("overwrite")])
  #expect(!filledEmpty.isError)
}

@Test(
  "Globs follow shell rules: * within a folder, ** across folders, classes, alternatives, smart case"
)
func globSemantics() throws {
  let star = try #require(MaiGlob("*.c"))
  #expect(star.matches("a.c") && star.matches("src/deep/a.c") && !star.matches("a.h"))
  #expect(!star.matchesPath)
  let path = try #require(MaiGlob("src/*.c"))
  #expect(path.matchesPath)
  #expect(path.matches("src/a.c") && !path.matches("src/sub/a.c") && !path.matches("a.c"))
  let deep = try #require(MaiGlob("src/**/*.c"))
  #expect(deep.matches("src/a.c") && deep.matches("src/x/y/a.c") && !deep.matches("lib/a.c"))
  let any = try #require(MaiGlob("**/*.md"))
  #expect(any.matches("README.md") && any.matches("docs/x/README.md"))
  let below = try #require(MaiGlob("src/**"))
  #expect(below.matches("src/a.c") && below.matches("src/x/a.c") && !below.matches("lib/a.c"))
  let cls = try #require(MaiGlob("[!m]*.c"))
  #expect(cls.matches("a.c") && !cls.matches("main.c"))
  let alt = try #require(MaiGlob("*.{c,h}"))
  #expect(alt.matches("a.h") && alt.matches("a.c") && !alt.matches("a.m"))
  #expect(try #require(MaiGlob("?ain.c")).matches("main.c"))
  #expect(try #require(MaiGlob("./*.c")).matches("./a.c"))
  #expect(try #require(MaiGlob("*.c")).matches("A.C"))
  #expect(!(try #require(MaiGlob("*.C")).matches("a.c")))
  #expect(try #require(MaiGlob("a+b.c")).matches("a+b.c"))
  #expect(MaiGlob.isPattern("src/*.c"))
  #expect(!MaiGlob.isPattern("Parser.swift"))
  #expect(MaiGlob.splitPath("src/lib/*.c")?.directory == "src/lib")
  #expect(MaiGlob.splitPath("src/lib/*.c")?.pattern == "*.c")
  #expect(MaiGlob.splitPath("src/**/x/*.c")?.pattern == "**/x/*.c")
  #expect(MaiGlob.splitPath("*.c")?.directory == "")
  #expect(MaiGlob.splitPath("plain/name") == nil)
}

@Test(
  "Files tools take glob patterns: find by pattern, grep narrowed by glob or path, list by name pattern"
)
func fileToolsAcceptGlobs() async throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-glob-\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: root) }
  for folder in ["src/sub", "docs"] {
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
  }
  for path in ["a.c", "src/main.c", "src/util.h", "src/sub/deep.c"] {
    try Data("needle\n".utf8).write(to: root.appendingPathComponent(path))
  }
  try Data("prose\n".utf8).write(to: root.appendingPathComponent("docs/README.md"))

  let tools = MaiFileWorkspaceTool.makeTools(
    configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let find = tool(tools, .find)
  let grep = tool(tools, .grep)
  let list = tool(tools, .list)
  #expect(grep.definition.parameters.contains { $0.name == "glob" })
  func paths(_ output: ToolOutput) -> [String] {
    output.structuredContent?.objectValue?["matches"]?.arrayValue?.compactMap {
      $0.objectValue?["path"]?.stringValue
    } ?? []
  }

  #expect(
    paths(try await call(find, ["query": .string("*.c")])) == [
      "a.c", "src/main.c", "src/sub/deep.c",
    ])
  #expect(paths(try await call(find, ["query": .string("src/*.c")])) == ["src/main.c"])
  #expect(
    paths(try await call(find, ["query": .string("src/**/*.c")])) == [
      "src/main.c", "src/sub/deep.c",
    ])
  #expect(
    Set(paths(try await call(find, ["query": .string("*.{c,h}")])))
      == ["a.c", "src/main.c", "src/util.h", "src/sub/deep.c"])
  #expect(paths(try await call(find, ["query": .string("?ain.c")])) == ["src/main.c"])
  #expect(
    paths(try await call(find, ["query": .string("*.c"), "path": .string("src")]))
      == ["src/main.c", "src/sub/deep.c"])
  // A pattern with a slash applies below the search folder, or from the root.
  #expect(
    paths(try await call(find, ["query": .string("sub/*.c"), "path": .string("src")]))
      == ["src/sub/deep.c"])
  #expect(
    paths(try await call(find, ["query": .string("src/sub/*.c"), "path": .string("src")]))
      == ["src/sub/deep.c"])
  let none = try await call(find, ["query": .string("docs/*.c")])
  #expect(none.text.hasPrefix("No files matched 'docs/*.c'."))
  #expect(none.text.contains("**/"))
  // Plain names still match fuzzily.
  #expect(paths(try await call(find, ["query": .string("deep")])).first == "src/sub/deep.c")

  #expect(
    paths(try await call(grep, ["query": .string("needle"), "glob": .string("*.h")])) == [
      "src/util.h"
    ])
  #expect(
    paths(try await call(grep, ["query": .string("needle"), "path": .string("src/*.c")]))
      == ["src/main.c"])
  #expect(
    Set(paths(try await call(grep, ["query": .string("needle"), "glob": .string("src/**/*.c")])))
      == ["src/main.c", "src/sub/deep.c"])
  let grepNone = try await call(grep, ["query": .string("needle"), "glob": .string("*.rs")])
  #expect(grepNone.text.contains("No file matched '*.rs'"))
  #expect(grepNone.structuredContent?.objectValue?["glob"] == .array([.string("*.rs")]))

  let listed = try await call(list, ["path": .string("src/*.c")])
  let entries = listed.structuredContent?.objectValue?["entries"]?.arrayValue?.compactMap {
    $0.objectValue?["path"]?.stringValue
  }
  #expect(entries == ["src/main.c"])
  #expect(listed.structuredContent?.objectValue?["pattern"] == .string("*.c"))
  let empty = try await call(list, ["path": .string("docs/*.c")])
  #expect(empty.text == "(no entries match '*.c')")
  let deepList = try await call(list, ["path": .string("src/**/*.c")])
  #expect(deepList.isError)
  #expect(deepList.text.hasPrefix("Error: Invalid pattern: '**/*.c' spans folders"))
  #expect(deepList.text.contains("files_find"))
}

@Test("Files read uses the runtime page hint without overriding an explicit size")
func fileWorkspaceReadContextBudget() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  try Data(String(repeating: "x", count: 30_000).utf8).write(to: root.appendingPathComponent("large.txt"))
  let tool = MaiFileWorkspaceTool(operation: .read, configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  let context = ToolExecutionContext(
    run: AgentEventContext(runID: UUID(), parentRunID: nil, agentID: "test", depth: 0),
    modelTurn: 1, suggestedOutputBytes: 1024)
  let small = try await tool.call(arguments: .object(["path": .string("large.txt")]), context: context)
  #expect(fileReadBody(small).utf8.count == 1024)
  #expect(small.text.contains("offset 1024"))
  #expect(small.structuredContent?.objectValue?["nextOffset"] == .integer(1024))
  let explicit = try await tool.call(arguments: .object(["path": .string("large.txt"), "max_bytes": .integer(20_000)]), context: context)
  #expect(fileReadBody(explicit).utf8.count == 20_000)
}

@Test("Tiny UTF-8 file pages advance and invalid bytes do not discard a page suffix")
func fileWorkspacePagesAdvance() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let body = "🦊é\n}\n}\n"
  let file = root.appendingPathComponent("utf8.txt")
  try Data(body.utf8).write(to: file)
  let tool = MaiFileWorkspaceTool(operation: .read, configuration: MaiFileWorkspaceConfiguration(rootURL: root))
  var offset = 0
  var reconstructed = ""
  while offset < body.utf8.count {
    let result = try await call(tool, ["path": .string("utf8.txt"), "offset": .integer(offset), "max_bytes": .integer(1)])
    try #require(!result.isError)
    let next = try #require(result.structuredContent?.objectValue?["nextOffset"]?.intValue)
    try #require(next > offset)
    if next < body.utf8.count { #expect(result.text.contains("offset \(next)")) }
    reconstructed += fileReadBody(result)
    offset = next
  }
  #expect(reconstructed == body)
  try (Data("prefix".utf8) + Data([0xFF]) + Data(repeating: 0x78, count: 100_000)).write(to: file)
  let invalid = try await call(tool, ["path": .string("utf8.txt")])
  #expect(invalid.isError)
  #expect(invalid.text.contains("UTF-8"))
}

private func fileReadBody(_ output: ToolOutput) -> String {
  output.content.compactMap { part in
    if case .file(let file) = part { return file.text }
    return nil
  }.joined()
}
