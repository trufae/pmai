import Foundation
import MaiCore
import Observation
import Testing

@testable import MaiMobile

@MainActor private func waitForTerminal(_ terminal: MobileTerminal) async {
  while terminal.running {
    await withCheckedContinuation { continuation in
      withObservationTracking {
        _ = terminal.running
      } onChange: { continuation.resume() }
    }
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func terminalResultsAndErrorsStaySeparateFromChat() async throws {
  let terminal = MobileTerminal()
  #expect(terminal.run(id: "command") {
    ToolResult(callID: "command", text: "working directory\n", isError: false)
  })
  #expect(!terminal.run(id: "duplicate") {
    ToolResult(callID: "duplicate", text: "must not run", isError: false)
  })
  await waitForTerminal(terminal)
  #expect(terminal.output == "working directory\n")
  #expect(!terminal.isError)
  #expect(terminal.run(id: "failed") { throw CocoaError(.fileReadNoPermission) })
  await waitForTerminal(terminal)
  #expect(terminal.id == "failed")
  #expect(terminal.isError)
  #expect(terminal.output.hasPrefix("Error:"))
}

@Test(.timeLimit(.minutes(1))) @MainActor
func closingTerminalIgnoresLateResultsFromThePreviousCommand() async throws {
  let terminal = MobileTerminal()
  let (started, start) = AsyncStream<Void>.makeStream()
  let (returned, finish) = AsyncStream<Void>.makeStream()
  defer { start.finish(); finish.finish() }
  var reply: CheckedContinuation<ToolResult, Never>?
  #expect(terminal.run(id: "old") {
    defer { finish.yield(()) }
    return await withCheckedContinuation { continuation in
      reply = continuation
      start.yield(())
    }
  })
  var startIterator = started.makeAsyncIterator()
  _ = await startIterator.next()
  terminal.close()
  #expect(!terminal.running)
  #expect(terminal.run(id: "new") {
    ToolResult(callID: "new", text: "new result", isError: false)
  })
  await waitForTerminal(terminal)
  let previous = try #require(reply)
  previous.resume(returning: ToolResult(callID: "old", text: "late result", isError: false))
  var finishIterator = returned.makeAsyncIterator()
  _ = await finishIterator.next()
  #expect(terminal.id == "new")
  #expect(terminal.output == "new result")
}

@Test(.timeLimit(.minutes(1))) @MainActor
func stoppingTerminalKeepsPartialOutputAndAllowsAnotherCommand() async throws {
  let terminal = MobileTerminal()
  let (started, start) = AsyncStream<Void>.makeStream()
  defer { start.finish() }
  #expect(terminal.run(id: "streaming") {
    terminal.update(id: "streaming", output: "partial output")
    start.yield(())
    try await Task.sleep(for: .seconds(60))
    return ToolResult(callID: "streaming", text: "unexpected result", isError: false)
  })
  var iterator = started.makeAsyncIterator()
  _ = await iterator.next()
  #expect(terminal.output == "partial output")
  terminal.stop()
  await waitForTerminal(terminal)
  #expect(terminal.isError)
  #expect(terminal.output.contains("partial output"))
  #expect(terminal.output.contains("stopped"))
  #expect(terminal.run(id: "next") {
    ToolResult(callID: "next", text: "ready", isError: false)
  })
  await waitForTerminal(terminal)
  #expect(terminal.output == "ready")
}

#if os(macOS) || os(Linux)
@MainActor private func shellOutput(_ shell: MobileShell, containing marker: String) async throws -> Data {
  var output = Data()
  while true {
    let snapshot = shell.snapshot
    let error = snapshot["error"] as? String ?? ""
    #expect(error.isEmpty)
    if let encoded = snapshot["data"] as? String, let data = Data(base64Encoded: encoded), !data.isEmpty {
      output.append(data)
      shell.acknowledge(snapshot["sequence"] as? Int ?? -1)
      if marker.isEmpty || String(decoding: output, as: UTF8.self).contains(marker) { return output }
    } else {
      await withCheckedContinuation { continuation in
        withObservationTracking { _ = shell.snapshot } onChange: { continuation.resume() }
      }
    }
  }
}

@Test(.timeLimit(.minutes(1))) @MainActor
func mobileShellSessionsKeepIndependentWorkingDirectoriesAndResize() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let first = MobileShell(id: UUID().uuidString, cwd: directory.path, profile: nil, preparation: nil)
  let second = MobileShell(id: UUID().uuidString, cwd: "/", profile: nil, preparation: nil)
  first.connect(); second.connect()
  _ = try await shellOutput(first, containing: "")
  _ = try await shellOutput(second, containing: "")
  first.resize(columns: 101, rows: 33)
  first.send(Data("stty -echo; printf 'FIRST:%s\\n' \"$PWD\"; stty size; printf 'DONE_%s\\n' first\n".utf8))
  let output = try await shellOutput(first, containing: "DONE_first")
  #expect(String(decoding: output, as: UTF8.self).contains("FIRST:" + directory.path))
  #expect(String(decoding: output, as: UTF8.self).contains("33 101"))
  second.send(Data("stty -echo; printf 'SECOND:%s\\n' \"$PWD\"; printf 'DONE_%s\\n' second\n".utf8))
  let other = try await shellOutput(second, containing: "DONE_second")
  #expect(String(decoding: other, as: UTF8.self).contains("SECOND:/"))
  await first.close(); await second.close()
  #expect(first.snapshot["status"] as? String == "Closed")
  #expect(second.snapshot["status"] as? String == "Closed")
}
#endif
