import Foundation
import Testing
@testable import MaiCore

@Test("Executable lookup honors PATH order, working directories and explicit search directories")
func localExecutableSearch() throws {
  let files = FileManager.default
  let root = files.temporaryDirectory.appendingPathComponent("executable ü \(UUID())")
  let cwd = root.appendingPathComponent("working")
  let first = root.appendingPathComponent("first")
  let second = root.appendingPathComponent("second")
  let blocked = root.appendingPathComponent("not-a-program")
  #if os(Windows)
  let filename = "program ü.exe"
  let key = "pAtH", separator = ";"
  #else
  let filename = "program ü"
  let key = "PATH", separator = ":"
  #endif
  for directory in [cwd, first, second, blocked.appendingPathComponent(filename)] {
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  defer { try? files.removeItem(at: root) }
  func native(_ url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
  }
  func program(at url: URL, output: String) throws {
    #if os(Windows)
    let environment = LocalProcess.mergedEnvironment(ProcessInfo.processInfo.environment)
    let system = try #require(environment["SYSTEMROOT"])
    try files.copyItem(at: URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe"), to: url)
    #else
    try "#!/bin/sh\nprintf '%s' '\(output)'\n".write(to: url, atomically: false, encoding: .utf8)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    #endif
  }
  let firstProgram = first.appendingPathComponent(filename)
  let secondProgram = second.appendingPathComponent(filename)
  try program(at: firstProgram, output: "lookup-first")
  try program(at: secondProgram, output: "lookup-second")
  let directories = [blocked, first, second].map { url in
    #if os(Windows)
    "\"\(native(url))\""
    #else
    native(url)
    #endif
  }
  let environment = [key: directories.joined(separator: separator)]
  #expect(try LocalExecutable.resolve("program ü", environment: environment, workingDirectory: cwd)
    == native(firstProgram))
  #expect(try LocalExecutable.resolve("../second/" + filename, workingDirectory: cwd, searchPath: [])
    == native(secondProgram))
  #expect(try LocalExecutable.resolve("program ü", environment: environment,
    workingDirectory: cwd, searchPath: ["../second"]) == native(secondProgram))
  #expect(throws: LocalExecutable.ResolutionError.self) {
    try LocalExecutable.resolve(native(blocked.appendingPathComponent(filename)))
  }
  #if !os(Windows)
  let nonExecutable = root.appendingPathComponent("not-executable")
  try Data().write(to: nonExecutable)
  #expect(throws: LocalExecutable.ResolutionError.self) {
    try LocalExecutable.resolve(native(nonExecutable))
  }
  #endif
  let currentProgram = cwd.appendingPathComponent(filename)
  try files.copyItem(at: firstProgram, to: currentProgram)
  #expect(try LocalExecutable.resolve("program ü", environment: environment,
    workingDirectory: cwd, searchPath: [native(second)]) == native(secondProgram))
  #expect(throws: LocalExecutable.ResolutionError.self) {
    try LocalExecutable.resolve("program ü", environment: environment, workingDirectory: cwd, searchPath: [])
  }
  #expect(try LocalExecutable.resolve("program ü", environment: [key: ""], workingDirectory: cwd)
    == native(currentProgram))
  for command in ["", "invalid\0program"] {
    #expect(throws: LocalExecutable.ResolutionError.self) { try LocalExecutable.resolve(command) }
  }
  #if !os(iOS)
  let process = Process(), output = Pipe(), exited = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in exited.signal() }
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  #if os(Windows)
  let arguments = ["/d", "/c", "echo", "lookup-first"]
  #else
  let arguments: [String] = []
  #endif
  try LocalProcess.configure(process, command: "program ü", arguments: arguments,
    environment: LocalProcess.mergedEnvironment(ProcessInfo.processInfo.environment, overrides: environment),
    workingDirectory: cwd)
  try process.run()
  defer { if process.isRunning { process.terminate() } }
  try #require(exited.wait(timeout: .now() + 30) == .success)
  #expect(process.terminationStatus == 0)
  #expect(String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    .trimmingCharacters(in: .whitespacesAndNewlines) == "lookup-first")
  #endif
}

#if os(Windows)
@Test("Windows local executables resolve PATH, suffixes and relative paths without shell expansion")
func windowsLocalExecutableLaunch() throws {
  let fm = FileManager.default
  let directory = fm.temporaryDirectory.appendingPathComponent("local process ü \(UUID())")
  try fm.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? fm.removeItem(at: directory) }
  let environment = LocalProcess.mergedEnvironment(ProcessInfo.processInfo.environment)
  let system = try #require(environment["SYSTEMROOT"])
  let source = URL(fileURLWithPath: system).appendingPathComponent("System32/cmd.exe")
  let executable = directory.appendingPathComponent("native ü.exe")
  try fm.copyItem(at: source, to: executable)
  try fm.copyItem(at: source, to: directory.appendingPathComponent("native-com.com"))
  let arguments = ["/d", "/c", "exit", "0"]
  for command in ["native ü", "native ü.exe", ".\\native ü", executable.path, "native-com"] {
    let process = Process()
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    try LocalProcess.configure(
      process, command: command, arguments: arguments,
      environment: LocalProcess.mergedEnvironment(environment, overrides: ["pAtH": directory.path]),
      workingDirectory: directory)
    try process.run()
    defer { if process.isRunning { process.terminate() } }
    try #require(exited.wait(timeout: .now() + 30) == .success)
    #expect(process.terminationStatus == 0)
  }
  let normalized = LocalProcess.mergedEnvironment(
    ["Path": "inherited", "TOKEN": "old"], overrides: ["PATH": directory.path, "token": "new"])
  #expect(normalized["Path"] == directory.path)
  #expect(normalized["TOKEN"] == "new")
  #expect(normalized.keys.filter { $0.lowercased() == "path" }.count == 1)
  for key in ["PATH", "Path", "pAtH"] {
    let environment = [key: "\"\(directory.path)\";C:\\missing-directory"]
    let found = try LocalExecutable.resolve("native ü", environment: environment,
      workingDirectory: directory.deletingLastPathComponent())
    #expect(URL(fileURLWithPath: found).standardizedFileURL == executable.standardizedFileURL)
  }
  let batch = directory.appendingPathComponent("wrapper.cmd")
  try "@echo off".write(to: batch, atomically: false, encoding: .utf8)
  #expect(throws: (any Error).self) {
    try LocalProcess.configure(Process(), command: "wrapper", environment: normalized, workingDirectory: directory)
  }
}
#endif
