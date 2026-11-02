#if os(Windows)
import Foundation
import Testing
@testable import MaiCore

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
  let batch = directory.appendingPathComponent("wrapper.cmd")
  try "@echo off".write(to: batch, atomically: false, encoding: .utf8)
  #expect(throws: (any Error).self) {
    try LocalProcess.configure(Process(), command: "wrapper", environment: normalized, workingDirectory: directory)
  }
}
#endif
