import Foundation
import Testing
@testable import MaiCore

private func lockDirectory() throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mai-lock ü \(UUID())")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

@Test("Independent lock handles exclude each other and throwing releases ownership")
func fileLockIndependentHandles() throws {
  let directory = try lockDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("state.lock")
  enum Expected: Error, Equatable { case failure }
  func throwingOwner() throws {
    let owner = try MaiFileLock(url: url)
    try withExtendedLifetime(owner) {
      #expect(throws: MaiFileLockError.busy) { _ = try MaiFileLock(url: url, wait: false) }
      let other = try MaiFileLock(url: directory.appendingPathComponent("other.lock"), wait: false)
      withExtendedLifetime(other) {}
      throw Expected.failure
    }
  }
  #expect(throws: Expected.failure) { try throwingOwner() }
  let acquired = try MaiFileLock(url: url, wait: false)
  withExtendedLifetime(acquired) {}
}

@Test("File locks distinguish filesystem errors from contention and reject final symlinks")
func fileLockErrors() throws {
  let directory = try lockDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  do {
    _ = try MaiFileLock(url: directory.appendingPathComponent("missing/state.lock"), wait: false)
    Issue.record("A missing lock parent must fail")
  } catch MaiFileLockError.system {
    // The caller owns parent directory creation; this is not a busy lock.
  }
  #if !os(Windows)
  let target = directory.appendingPathComponent("target")
  try Data("unchanged".utf8).write(to: target)
  let link = directory.appendingPathComponent("alias.lock")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  #expect(throws: MaiFileLockError.symbolicLink) { _ = try MaiFileLock(url: link) }
  #expect(try Data(contentsOf: target) == Data("unchanged".utf8))
  #endif
}

@Test("Waiting for a file lock times out or cancels while the owner retains its lease")
func fileLockAsyncAcquisition() async throws {
  let directory = try lockDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("state.lock")
  let owner = try MaiFileLock(url: url)
  defer { withExtendedLifetime(owner) {} }
  await #expect(throws: MaiFileLockError.timedOut) {
    _ = try await MaiFileLock.acquire(url: url, timeout: .seconds(1))
  }
  let started = AgentChangeSignal()
  let waiting = Task {
    started.notify()
    return try await MaiFileLock.acquire(url: url, timeout: .seconds(30))
  }
  try await started.wait(after: 0, until: .now + .seconds(30))
  try #require(started.revision > 0)
  waiting.cancel()
  await #expect(throws: CancellationError.self) { _ = try await waiting.value }
  #expect(throws: MaiFileLockError.busy) { _ = try MaiFileLock(url: url, wait: false) }
}

@Test("A cancelled lock request does not acquire an available file")
func fileLockCancelledBeforeAcquire() async throws {
  let directory = try lockDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("cancelled.lock")
  let gate = AgentChangeSignal()
  let task = Task {
    do { try await gate.wait(after: 0) } catch is CancellationError {}
    return try await MaiFileLock.acquire(url: url, timeout: .seconds(1))
  }
  task.cancel()
  await #expect(throws: CancellationError.self) { _ = try await task.value }
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

#if !os(iOS)
@Test("A separate process owns an exclusive lock and exiting releases it")
func fileLockProcessOwnerExit() async throws {
  let environment = ProcessInfo.processInfo.environment
  if let path = environment["PMAI_FILE_LOCK_WORKER"] {
    let owner = try MaiFileLock(url: URL(fileURLWithPath: path))
    withExtendedLifetime(owner) {
      FileHandle.standardOutput.write(Data([1])) // Dedicated readiness event.
      _ = FileHandle.standardInput.readDataToEndOfFile()
    }
    return
  }
  let directory = try lockDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let url = directory.appendingPathComponent("process.lock")
  let process = Process()
  process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
  // Retain the current runner's bundle selectors, but isolate its selection
  // and output files from the parent's test result stream.
  let optionsWithValue: Set<String> = ["--filter", "--skip", "--event-stream-output-path", "--xunit-output", "--xml-output"]
  var arguments: [String] = []
  var skipValue = false
  for argument in CommandLine.arguments.dropFirst() {
    if skipValue { skipValue = false; continue }
    if optionsWithValue.contains(argument) { skipValue = true; continue }
    if optionsWithValue.contains(where: { argument.hasPrefix($0 + "=") }) { continue }
    arguments.append(argument)
  }
  arguments += ["--filter", "fileLockProcessOwnerExit"]
  process.arguments = arguments
  process.environment = environment.merging(["PMAI_FILE_LOCK_WORKER": url.path]) { _, child in child }
  let input = Pipe(), output = Pipe()
  process.standardInput = input
  process.standardOutput = output
  process.standardError = FileHandle.nullDevice
  let ready = AgentChangeSignal(), exited = AgentChangeSignal()
  output.fileHandleForReading.readabilityHandler = { handle in
    if handle.availableData.contains(1) { ready.notify() }
  }
  process.terminationHandler = { _ in exited.notify() }
  defer {
    output.fileHandleForReading.readabilityHandler = nil
    try? input.fileHandleForWriting.close()
  }
  try process.run()
  do {
    try await ready.wait(after: 0, until: .now + .seconds(30))
    try #require(ready.revision > 0, "Lock worker did not become ready: \(process.executableURL!.path) \(arguments)")
    #expect(throws: MaiFileLockError.busy) { _ = try MaiFileLock(url: url, wait: false) }
    process.terminate()
    try await exited.wait(after: 0, until: .now + .seconds(30))
    try #require(exited.revision > 0)
  } catch {
    if process.isRunning { process.terminate() }
    try? await exited.wait(after: 0, until: .now + .seconds(30))
    throw error
  }
  // Windows may release byte-range locks shortly after process termination.
  let acquired = try await MaiFileLock.acquire(url: url, timeout: .seconds(30))
  withExtendedLifetime(acquired) {}
}
#endif
