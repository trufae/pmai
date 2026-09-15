import XCTest

@testable import PocketMai

@MainActor
final class InteractiveOperationTimeoutTests: XCTestCase {
  private actor ExecutionCounter {
    private(set) var value = 0

    func increment() {
      value += 1
    }
  }

  func testContinueResetsTimerWithoutRestartingOperation() async throws {
    let executions = ExecutionCounter()
    var timeoutCount = 0

    let result = try await InteractiveOperationTimeout.run(
      seconds: 0.01,
      context: context
    ) { _ in
      timeoutCount += 1
      return .continue
    } operation: {
      await executions.increment()
      try await Task.sleep(for: .milliseconds(35))
      return "finished"
    }

    let executionCount = await executions.value
    XCTAssertEqual(result, "finished")
    XCTAssertGreaterThanOrEqual(timeoutCount, 1)
    XCTAssertEqual(executionCount, 1)
  }

  func testSkipCancelsOnlyTheTimedOperation() async {
    do {
      _ = try await InteractiveOperationTimeout.run(
        seconds: 0.01,
        context: context,
        onTimeout: { _ in .skip }
      ) {
        try await Task.sleep(for: .seconds(1))
        return "unexpected"
      }
      XCTFail("Expected the operation to be skipped")
    } catch is LongRunningOperationSkipped {
      // Expected control flow.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInterruptThrowsCancellation() async {
    do {
      _ = try await InteractiveOperationTimeout.run(
        seconds: 0.01,
        context: context,
        onTimeout: { _ in .interrupt }
      ) {
        try await Task.sleep(for: .seconds(1))
        return "unexpected"
      }
      XCTFail("Expected the operation to be interrupted")
    } catch is CancellationError {
      // Expected control flow.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCompletionDismissesPendingTimeoutDecision() async throws {
    // The operation finishes only after its timeout prompt is waiting. Cover
    // both success and failure without relying on the relative speed of tasks.
    for shouldFail in [false, true] {
      let prompt = expectation(description: "Timeout decision requested")
      let dismissed = expectation(description: "Timeout decision cancelled")
      let (finish, finishContinuation) = AsyncStream<Void>.makeStream()
      let task = Task {
        try await InteractiveOperationTimeout.run(seconds: 0.01, context: context) { _ in
          prompt.fulfill()
          do {
            try await Task.sleep(for: .seconds(60))
            XCTFail("Completion was blocked by the timeout prompt")
          } catch {
            dismissed.fulfill()
          }
          return .interrupt
        } operation: {
          for await _ in finish { break }
          if shouldFail { throw URLError(.timedOut) }
          return "finished"
        }
      }
      defer { task.cancel() }
      await fulfillment(of: [prompt], timeout: 2)
      finishContinuation.yield(())
      finishContinuation.finish()
      let dismissal = await XCTWaiter.fulfillment(of: [dismissed], timeout: 2)
      XCTAssertEqual(dismissal, .completed)
      guard dismissal == .completed else { return }
      do {
        let result = try await task.value
        XCTAssertFalse(shouldFail)
        XCTAssertEqual(result, "finished")
      } catch let error as URLError {
        XCTAssertTrue(shouldFail)
        XCTAssertEqual(error.code, .timedOut)
      }
    }
  }

  func testCancellationDismissesPendingDecisionAndCancelsOperation() async {
    let prompt = expectation(description: "Timeout decision requested")
    let cancelled = expectation(description: "Both children cancelled")
    cancelled.expectedFulfillmentCount = 2
    let task = Task {
      try await InteractiveOperationTimeout.run(seconds: 0.01, context: context) { _ in
        prompt.fulfill()
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          cancelled.fulfill()
        }
        return .interrupt
      } operation: {
        do {
          try await Task.sleep(for: .seconds(60))
          return "unexpected"
        } catch {
          cancelled.fulfill()
          throw error
        }
      }
    }
    await fulfillment(of: [prompt], timeout: 2)
    task.cancel()
    await fulfillment(of: [cancelled], timeout: 2)
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Both the underlying request and the UI continuation are released.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private var context: LongRunningOperationContext {
    LongRunningOperationContext(
      kind: .modelResponse,
      conversationID: nil,
      assistantMessageID: nil,
      operationName: "Test operation",
      conversationTitle: nil,
      timeoutInterval: 0.01)
  }
}
