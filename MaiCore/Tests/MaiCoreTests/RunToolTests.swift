import Foundation
import Testing

@testable import MaiCore
@testable import MaiStandardTools

@Test("Run tools execute shell command lines and report output and exit codes",
  arguments: ["", MaiRunConfiguration.defaultShell, "sh"])
func runSystemCapturesOutput(shellCommand: String) async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration(shell: shellCommand))
  #expect(Set(tools.map(\.definition.name)) == Set(MaiRunTool.toolNames))
  #expect(tools.allSatisfy { $0.definition.annotations.approval == .dangerous })
  #expect(tools.allSatisfy { $0.definition.annotations.destructive })

  let ok = try await call(shell(tools), ["command": .string("printf 'hello world'")])
  #expect(!ok.isError)
  #expect(ok.text == "hello world")
  #expect(ok.structuredContent?.objectValue?["exitCode"] == .integer(0))
  #expect(ok.structuredContent?.objectValue?["timedOut"] == .bool(false))

  let failed = try await call(
    shell(tools),
    ["command": .string("printf out; printf oops >&2; exit 3")])
  #expect(failed.isError)
  #expect(failed.text.contains("out"))
  #expect(failed.text.contains("[stderr]\noops"))
  #expect(failed.text.contains("[exit code 3]"))
  #expect(failed.structuredContent?.objectValue?["exitCode"] == .integer(3))

  let silent = try await call(shell(tools), ["command": .string("true")])
  #expect(silent.text == "(no output; exit code 0)")

  let missing = try await call(shell(tools), [:])
  #expect(missing.isError)
  #expect(missing.text.contains("script is required"))
}

@Test("Run tools pass stdin, arguments, and the working directory to scripts")
func runShellScriptUsesArgumentsAndStdin() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-run-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())

  let output = try await call(
    shell(tools),
    [
      "script": .string("echo \"first=$1 second=$2\"\ncat\npwd"),
      "args": .array([.string("a b"), .string("c")]),
      "stdin": .string("from stdin\n"),
      "cwd": .string(directory.path),
    ])
  #expect(!output.isError)
  let lines = output.text.split(separator: "\n").map(String.init)
  #expect(lines.first == "first=a b second=c")
  #expect(lines.dropFirst().first == "from stdin")
  #expect(lines.last.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
    == directory.standardizedFileURL.resolvingSymlinksInPath().path)

  let badDirectory = try await call(
    shell(tools),
    ["script": .string("true"), "cwd": .string(directory.appendingPathComponent("nope").path)])
  #expect(badDirectory.isError)
  #expect(badDirectory.text.contains("is not a directory"))
}

@Test("Other languages run through the shell, and a missing shell is reported")
func runOtherLanguagesThroughTheShell() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  #expect(tools.map(\.definition.name) == ["run_sh"])
  let environment = ProcessInfo.processInfo.environment
  if (try? MaiHostProcess.resolve("python3", environment: environment)) != nil {
    let output = try await call(
      shell(tools),
      [
        "script": .string("python3 - \"$1\" <<'PY'\nimport sys\nprint('py', sys.argv[1])\nPY"),
        "args": .array([.string("arg")]),
      ])
    #expect(!output.isError)
    #expect(output.text == "py arg")
  }
  let missing = MaiRunTool(configuration: MaiRunConfiguration(shell: "pmai-no-such-shell"))
  let unavailable = try await call(missing, ["script": .string("true")])
  #expect(unavailable.isError)
  #expect(unavailable.text.contains("was not found in PATH"))
}

@Test("Run tools kill processes that exceed their timeout")
func runToolsEnforceTimeout() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let started = Date()
  let output = try await call(
    shell(tools),
    ["command": .string("echo started; sleep 30; echo finished"), "timeout_seconds": .integer(1)])
  #expect(Date().timeIntervalSince(started) < 10)
  #expect(output.isError)
  #expect(output.text.contains("started"))
  #expect(!output.text.contains("finished"))
  #expect(output.text.contains("timed out after 1 seconds"))
  #expect(output.structuredContent?.objectValue?["timedOut"] == .bool(true))
}

@Test("Run tools cap captured output")
func runToolsTruncateOutput() async throws {
  let tool = MaiRunTool(configuration: MaiRunConfiguration(outputLimit: 1_024))
  let output = try await call(tool, [
    "command": .string("head -c 5000 /dev/zero | tr '\\0' x"),
    "output": .string("inline"),
  ])
  #expect(!output.isError)
  #expect(output.text.hasPrefix(String(repeating: "x", count: 1_024)))
  #expect(output.text.contains("[stdout truncated: 3976 more bytes not shown]"))
  #expect(output.structuredContent?.objectValue?["truncated"] == .bool(true))
}

@Test("Concurrent short shell calls safely retire their pipe readers")
func runToolsConcurrentPipeCleanup() async throws {
  let tool = MaiRunTool(configuration: MaiRunConfiguration())
  try await withThrowingTaskGroup(of: Void.self) { group in
    for _ in 0..<8 {
      group.addTask {
        for _ in 0..<8 {
          let output = try await call(tool, ["script": .string("printf out; printf err >&2")])
          #expect(!output.isError)
          #expect(output.text == "out\n[stderr]\nerr")
        }
      }
    }
    try await group.waitForAll()
  }
}

@Test("Run tools spill large output, suppress output, and strip ANSI escapes")
func runToolsManageOutput() async throws {
  let tool = MaiRunTool(configuration: MaiRunConfiguration(outputLimit: 1_024))
  let spilled = try await call(tool, ["command": .string("head -c 5000 /dev/zero | tr '\\0' x")])
  let path = try #require(spilled.structuredContent?.objectValue?["stdoutFile"]?.stringValue)
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(spilled.text.contains("[full stdout saved to \(path)]"))
  #expect(!spilled.text.contains(String(repeating: "x", count: 100)))
  #expect((try Data(contentsOf: URL(fileURLWithPath: path))).count == 5_000)

  let ansi = try await call(tool, ["command": .string("printf '\\033[31mred\\033[0m'")])
  #expect(ansi.text == "red")

  let saved = try await call(tool, [
    "command": .string("printf retained"), "output": .string("file"),
  ])
  let savedPath = try #require(saved.structuredContent?.objectValue?["stdoutFile"]?.stringValue)
  defer { try? FileManager.default.removeItem(atPath: savedPath) }
  #expect(saved.text.contains("[full stdout saved to \(savedPath)]"))
  #expect(String(decoding: try Data(contentsOf: URL(fileURLWithPath: savedPath)), as: UTF8.self) == "retained")

  let silent = try await call(tool, [
    "command": .string("printf hidden; printf hidden >&2"), "output": .string("none"),
  ])
  #expect(silent.text == "(no output; exit code 0)")
}

@Test("Cancellation and timeout kill children even after the shell exits", arguments: [false, true])
func runToolsPropagateCancellation(timeout: Bool) async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("mai-run-cancel-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = directory.appendingPathComponent("child.pid")
  let task = Task {
    try await call(
      shell(tools),
      ["command": .string("sh -c 'trap \"\" TERM; echo $$ > child.pid; exec sleep 30' >/dev/null 2>&1 & wait"),
       "cwd": .string(directory.path), "timeout_seconds": .integer(timeout ? 1 : 30)])
  }
  defer { task.cancel() }
  let deadline = Date().addingTimeInterval(5)
  while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  let child = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
  defer {
    let cleanup = Process()
    cleanup.executableURL = URL(fileURLWithPath: "/bin/kill")
    cleanup.arguments = ["-KILL", child]
    cleanup.standardError = FileHandle.nullDevice
    try? cleanup.run()
    cleanup.waitUntilExit()
  }
  let started = Date()
  if !timeout { task.cancel() }
  do {
    let output = try await task.value
    #expect(timeout)
    #expect(output.structuredContent?.objectValue?["timedOut"] == .bool(true))
  } catch is CancellationError {
    #expect(!timeout)
  }
  #expect(Date().timeIntervalSince(started) < 10)
  let probe = Process()
  let pipe = Pipe()
  probe.executableURL = URL(fileURLWithPath: "/bin/ps")
  probe.arguments = ["-p", child, "-o", "stat="]
  probe.standardOutput = pipe
  try probe.run()
  let status = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines)
  probe.waitUntilExit()
  #expect(status.isEmpty || status.hasPrefix("Z"), "Child \(child) still running: \(status)")
}

@Test("Standard tool factory exposes the Run group with its options")
func standardFactoryExposesRunGroup() async throws {
  let command = "\(MaiRunConfiguration.defaultShell) -e"
  let context = PluginFactoryContext(
    id: "standard",
    options: ["runShell": .string(command), "runTimeoutSeconds": .integer(5)])
  let factory = MaiStandardToolFactory()
  let tools = try await factory.makeTools(context: context)
  let run = try #require(tools.first { $0.definition.name == MaiRunTool.name } as? MaiRunTool)
  #expect(run.configuration.shell == command)
  #expect(run.configuration.defaultTimeout == 5)
  #expect(run.definition.description.contains(command))
  let failed = try await call(run, ["script": .string("false; printf should-not-run")])
  #expect(failed.isError)
  #expect(failed.structuredContent?.objectValue?["exitCode"] == .integer(1))
  #expect(!failed.text.contains("should-not-run"))

  let group = try #require(try await factory.toolGroups(context: context).first { $0.id == "run" })
  #expect(group.toolNames == Set(MaiRunTool.toolNames))
  #expect(group.options.map(\.id) == ["runShell", "runTimeoutSeconds"])
}

private func shell(_ tools: [MaiRunTool]) -> MaiRunTool {
  tools[0]
}

private func call(
  _ tool: MaiRunTool,
  _ arguments: [String: JSONValue]
) async throws -> ToolOutput {
  try await tool.call(
    arguments: .object(arguments),
    context: ToolExecutionContext(
      run: AgentEventContext(
        runID: UUID(),
        parentRunID: nil,
        agentID: "run-test",
        depth: 0),
      modelTurn: 1))
}

@Test("Run tools reap every child: a finished, a killed, and a backgrounded run leave no zombie")
func runToolLeavesNoZombies() async throws {
  let tools = MaiRunTool.makeTools(configuration: MaiRunConfiguration())
  // A run that ends by itself, one the timeout kills, and one whose script
  // leaves a grandchild holding the pipes open after the shell has gone.
  _ = try await call(shell(tools), ["command": .string("printf done")])
  let killed = try await call(
    shell(tools), ["command": .string("sleep 30"), "timeout_seconds": .integer(1)])
  #expect(killed.structuredContent?.objectValue?["timedOut"] == .bool(true))
  _ = try await call(shell(tools), ["command": .string("(sleep 2 &) ; printf spawned")])
  // The termination handlers run on Foundation's queue a moment after exit.
  try await Task.sleep(for: .seconds(3))

  let listing = Process()
  listing.executableURL = URL(fileURLWithPath: "/bin/ps")
  listing.arguments = ["-axo", "pid,ppid,stat,command"]
  let pipe = Pipe()
  listing.standardOutput = pipe
  try listing.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  listing.waitUntilExit()
  let me = String(ProcessInfo.processInfo.processIdentifier)
  let zombies = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { line in
    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
    return fields.count > 2 && fields[1] == me && fields[2].hasPrefix("Z")
  }
  #expect(zombies.isEmpty, "unreaped children: \(zombies)")
}
