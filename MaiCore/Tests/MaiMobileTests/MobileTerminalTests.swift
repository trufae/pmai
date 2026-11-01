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
