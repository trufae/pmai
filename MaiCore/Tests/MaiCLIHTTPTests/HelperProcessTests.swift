#if !os(Windows)
import Foundation
import Testing
@testable import MaiCLI

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#else
  import Darwin
#endif

@Suite(.timeLimit(.minutes(1))) struct HelperProcessTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func helper(in root: URL, body: String) throws -> URL {
    let script = root.appendingPathComponent("helper")
    try ("#!/bin/sh\n" + body).write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
    return script
  }

  private func quoted(_ url: URL) -> String {
    "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func pid(in file: URL) throws -> Int32 {
    try #require(Int32(String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  @Test("Helper input and output cannot deadlock each other")
  func duplex() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output")
    let received = root.appendingPathComponent("received")
    // Both directions exceed pipe capacity, reproducing write-before-read deadlock.
    let noisy = String(repeating: "O", count: 200_000)
    try Data(noisy.utf8).write(to: output)
    let script = try helper(in: root, body: """
      /bin/cat \(quoted(output))
      /bin/cat > \(quoted(received))
      printf complete
      """)
    let input = Data(repeating: 0xff, count: 200_000)
    let result = try await TailcatCLI.capture(script.path, [], input: input)
    #expect(result == noisy + "complete")
    #expect(try Data(contentsOf: received) == input)
  }

  @Test("Update probes finish when a background child inherits the output pipes")
  func backgroundProbe() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = root.appendingPathComponent("owner")
    let script = try helper(in: root, body: """
      /bin/sleep 120 &
      printf '%s' "$!" > \(quoted(owner))
      printf '99.0.0\n'
      """)
    defer { if let child = try? pid(in: owner) { _ = kill(child, SIGKILL) } }
    let version = try await CLIUpdater.runBinary(
      script, argument: "--version", environment: ProcessInfo.processInfo.environment)
    #expect(version == "99.0.0")
  }

  @Test("A stalled update probe times out without waiting for its workload")
  func probeTimeout() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    let script = try helper(in: root, body: """
      trap '' TERM INT
      printf '%s' "$$" > \(quoted(started))
      exec /bin/sleep 120
      """)
    do {
      _ = try await CLIUpdater.runBinary(script, argument: "--help",
        environment: ProcessInfo.processInfo.environment, timeout: 2)
      Issue.record("A stalled startup check should fail")
    } catch {
      #expect(error.localizedDescription.contains("timed out"))
    }
    #expect(kill(try pid(in: started), 0) == -1 && errno == ESRCH)
  }

  @Test("Cancelling a helper stops it even when it never reads stdin")
  func cancelUnreadInput() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    let marker = root.appendingPathComponent("marker")
    let script = try helper(in: root, body: """
      trap '' TERM INT
      printf '%s' "$$" > \(quoted(marker))
      /bin/mv \(quoted(marker)) \(quoted(started))
      exec /bin/sleep 120
      """)
    let task = Task {
      try await TailcatCLI.capture(script.path, [], input: Data(repeating: 1, count: 200_000), timeout: 60)
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: started.path) {
      try #require(ContinuousClock.now < deadline, "Helper did not start")
      try await Task.sleep(for: .milliseconds(25))
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(kill(try pid(in: started), 0) == -1 && errno == ESRCH)
  }

  @Test("REPL filters finish when background children retain their pipes")
  func backgroundFilter() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = root.appendingPathComponent("owner")
    let copied = root.appendingPathComponent("copied")
    let script = try helper(in: root, body: """
      /bin/sleep 120 &
      printf '%s' "$!" > \(quoted(owner))
      /bin/cat > \(quoted(copied))
      """)
    defer { if let child = try? pid(in: owner) { _ = kill(child, SIGKILL) } }
    let redirection = try REPLRedirection(command: quoted(script))
    redirection.write("filter input\n")
    await redirection.finish(terminal: TerminalWriter(capturesOutput: true))
    #expect(try String(contentsOf: copied, encoding: .utf8) == "filter input\n")
  }

  @Test("REPL filter writes and cancellation work when the filter never reads")
  func cancelUnreadFilter() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    let marker = root.appendingPathComponent("marker")
    let script = try helper(in: root, body: """
      trap '' TERM INT
      printf '%s' "$$" > \(quoted(marker))
      /bin/mv \(quoted(marker)) \(quoted(started))
      exec /bin/sleep 120
      """)
    let redirection = try REPLRedirection(command: quoted(script))
    redirection.write(String(repeating: "x", count: 200_000))
    let task = Task { await redirection.finish(terminal: TerminalWriter(capturesOutput: true)) }
    defer { task.cancel(); redirection.cancel() }
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: started.path) {
      try #require(ContinuousClock.now < deadline, "Filter did not start")
      try await Task.sleep(for: .milliseconds(25))
    }
    redirection.cancel()
    await task.value
    #expect(kill(try pid(in: started), 0) == -1 && errno == ESRCH)
  }
}
#endif
