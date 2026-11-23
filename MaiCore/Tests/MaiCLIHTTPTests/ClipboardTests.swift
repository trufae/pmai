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

/// Local helpers exercise the Linux clipboard path without a display or a real
/// clipboard. In particular, a background clipboard owner must survive /copy.
@Suite(.timeLimit(.minutes(1))) struct ClipboardTests {
  private func fixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func helper(_ name: String, in root: URL, body: String) throws {
    let file = root.appendingPathComponent(name)
    try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
  }

  private func quoted(_ url: URL) -> String {
    "'" + url.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func pid(in file: URL) throws -> Int32 {
    try #require(Int32(String(contentsOf: file, encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)))
  }

  private func waitForPID(in file: URL) async throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(10)
    while !FileManager.default.fileExists(atPath: file.path) {
      try #require(ContinuousClock.now < deadline, "Clipboard helper did not start")
      try await Task.sleep(for: .milliseconds(25))
    }
    // Write the marker atomically in the helper so existence means it is ready.
    return try pid(in: file)
  }

  @Test("Copy completes while a forked clipboard owner keeps serving the copied text")
  func backgroundOwner() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let owner = root.appendingPathComponent("owner")
    let copied = root.appendingPathComponent("copied")
    try helper("wl-copy", in: root, body: """
      /bin/cat > \(quoted(copied))
      /bin/sleep 120 &
      printf '%s' "$!" > \(quoted(owner))
      exit 0
      """)
    defer { if let child = try? pid(in: owner) { _ = kill(child, SIGKILL) } }
    let text = String(repeating: "café 中文 🙂\n", count: 10_000)
    try await SystemClipboard.writeUsingExternalTool(text, searchPath: [root.path])
    #expect(try String(contentsOf: copied, encoding: .utf8) == text)
    #expect(kill(try pid(in: owner), 0) == 0)
  }

  @Test("Unavailable clipboard backends fall back without losing text")
  func fallback() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let copied = root.appendingPathComponent("copied")
    try helper("wl-copy", in: root, body: "exit 1\n")
    try helper("xclip", in: root, body: "/bin/cat > \(quoted(copied))\n")
    for text in [String(repeating: "Unicode 🙂\nwith a trailing newline\n", count: 5000), ""] {
      try await SystemClipboard.writeUsingExternalTool(text, searchPath: [root.path])
      #expect(try String(contentsOf: copied, encoding: .utf8) == text)
    }
  }

  @Test("A stuck clipboard helper times out and is reaped")
  func timeout() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    try helper("wl-copy", in: root, body: """
      /bin/cat >/dev/null
      trap '' INT TERM
      printf '%s' "$$" > \(quoted(started))
      exec /bin/sleep 120
      """)
    await #expect(throws: ClipboardError.self) {
      try await SystemClipboard.writeUsingExternalTool(
        "copy", searchPath: [root.path], timeout: .seconds(2))
    }
    #expect(kill(try pid(in: started), 0) == -1 && errno == ESRCH)
  }

  @Test("Cancelling copy stops helpers even when they never read large input")
  func cancellation() async throws {
    let root = try fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let started = root.appendingPathComponent("started")
    let marker = root.appendingPathComponent("marker")
    try helper("wl-copy", in: root, body: """
      trap '' INT TERM
      printf '%s' "$$" > \(quoted(marker))
      /bin/mv \(quoted(marker)) \(quoted(started))
      exec /bin/sleep 120
      """)
    let copy = Task {
      try await SystemClipboard.writeUsingExternalTool(
        String(repeating: "x", count: 1_000_000), searchPath: [root.path], timeout: .seconds(60))
    }
    defer { copy.cancel() }
    let child = try await waitForPID(in: started)
    copy.cancel()
    await #expect(throws: CancellationError.self) { try await copy.value }
    #expect(kill(child, 0) == -1 && errno == ESRCH)
  }
}
#endif
