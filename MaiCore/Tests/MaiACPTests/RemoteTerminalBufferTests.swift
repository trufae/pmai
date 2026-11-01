import XCTest
import MaiACP


final class RemoteTerminalBufferTests: XCTestCase {
  func testRestoresScrollbackAndHistoryWithoutReplayingAnInterruptedCommand() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let endpoint = try XCTUnwrap(URL(string: "wss://worker.example/acp"))
    let hostID = UUID()
    let url = RemoteTerminalBuffer.fileURL(
      hostID: hostID, endpoint: endpoint, cwd: "/work", directory: directory)
    var buffer = RemoteTerminalBuffer()
    let first = buffer.append("pwd")
    buffer.update(first, output: "/work\n", isError: false)
    let running = buffer.append("build")
    buffer.update(running, output: "Compiling…", isError: false, isComplete: false)
    try buffer.save(to: url)

    let restored = RemoteTerminalBuffer.load(from: url)
    XCTAssertEqual(restored.history, ["pwd", "build"])
    XCTAssertEqual(restored.entries.first?.output, "/work\n")
    XCTAssertTrue(try XCTUnwrap(restored.entries.last).isComplete)
    XCTAssertTrue(try XCTUnwrap(restored.entries.last).isError)
    XCTAssertTrue(try XCTUnwrap(restored.entries.last?.output).contains("Compiling…"))
    XCTAssertTrue(try XCTUnwrap(restored.entries.last?.output).contains("may still be running"))
    for (host, server, cwd) in [
      (hostID, endpoint, "/other"), (UUID(), endpoint, "/work"),
      (hostID, try XCTUnwrap(URL(string: "wss://other.example/acp")), "/work"),
    ] {
      let other = RemoteTerminalBuffer.fileURL(
        hostID: host, endpoint: server, cwd: cwd, directory: directory)
      XCTAssertTrue(RemoteTerminalBuffer.load(from: other).entries.isEmpty)
    }
  }

  func testClearingScrollbackKeepsCommandsAndDeduplicatesRecentHistory() throws {
    var buffer = RemoteTerminalBuffer()
    _ = buffer.append("pwd")
    _ = buffer.append("ls")
    _ = buffer.append("pwd")
    buffer.clearScrollback()
    XCTAssertTrue(buffer.entries.isEmpty)
    XCTAssertEqual(buffer.history, ["ls", "pwd"])
    buffer.clearHistory()
    XCTAssertTrue(buffer.history.isEmpty)
  }

  func testLargeOutputAndLongSessionsKeepRecentBacklogWithinBounds() throws {
    var buffer = RemoteTerminalBuffer()
    let output = String(repeating: "x", count: RemoteTerminalBuffer.outputLimit + 1) + "tail"
    for index in 0...RemoteTerminalBuffer.historyLimit {
      let id = buffer.append("echo \(index)")
      buffer.update(id, output: output, isError: false)
    }
    XCTAssertEqual(buffer.history.count, RemoteTerminalBuffer.historyLimit)
    XCTAssertEqual(buffer.history.last, "echo \(RemoteTerminalBuffer.historyLimit)")
    XCTAssertLessThanOrEqual(buffer.entries.count, RemoteTerminalBuffer.entryLimit)
    XCTAssertLessThanOrEqual(
      buffer.entries.reduce(0) { $0 + $1.command.utf8.count + ($1.output?.utf8.count ?? 0) },
      RemoteTerminalBuffer.backlogLimit)
    XCTAssertTrue(try XCTUnwrap(buffer.entries.last?.output).hasSuffix("tail"))
    XCTAssertTrue(try XCTUnwrap(buffer.entries.last?.output).contains("earlier output trimmed"))
  }

  func testHistoryNavigationRestoresDraftAndAllowsEditingARecalledCommand() {
    var cursor = RemoteTerminalHistoryCursor()
    let history = ["pwd", "ls"]
    XCTAssertEqual(cursor.move(-1, command: "unfinished", history: history), "ls")
    XCTAssertEqual(cursor.move(-1, command: "ls -l", history: history), "pwd")
    XCTAssertEqual(cursor.move(-1, command: "pwd", history: history), "pwd")
    XCTAssertEqual(cursor.move(1, command: "pwd", history: history), "ls")
    XCTAssertEqual(cursor.move(1, command: "ls", history: history), "unfinished")
    XCTAssertNil(cursor.index)
    cursor.reset()
    XCTAssertEqual(cursor.move(1, command: "new", history: history), "new")
    XCTAssertEqual(cursor.move(-1, command: "new", history: []), "new")
  }
}
