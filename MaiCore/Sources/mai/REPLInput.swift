import Foundation
import MaiCore

/// What the REPL loop reacts to. Lines come from the input thread; the rest
/// from turns ending, tools asking for approval, and the process table.
enum REPLEvent: Sendable {
  case line(String, heredoc: Bool)
  /// A non-nil ID means the signal/input path already cancelled that exact
  /// operation. `endedInput` distinguishes a raw Ctrl+C byte from SIGINT.
  case interrupt(REPLInterruptID?, endedInput: Bool)
  case endOfFile
  case turnFinished(Result<AgentResult, any Error>)
  case approval(ApprovalRequest, REPLApprovalReply)
  case approvalFinished(REPLApprovalReply)
  case supervisor(AgentSupervisorEvent)
  /// One-second UI refresh while the input reader is blocked on the terminal.
  case activityPulse
}

struct REPLInterruptID: Equatable, Hashable, Sendable {
  let rawValue: UInt
}

/// Answers one approval a tool call is waiting on, exactly once.
final class REPLApprovalReply: Sendable {
  private let continuation: AsyncThrowingStream<ApprovalDecision, any Error>.Continuation

  init(_ continuation: AsyncThrowingStream<ApprovalDecision, any Error>.Continuation) {
    self.continuation = continuation
  }

  func resume(with decision: ApprovalDecision) {
    continuation.yield(decision)
    continuation.finish()
  }

  func fail(_ error: any Error) {
    continuation.finish(throwing: error)
  }
}

/// Reads lines on a thread of its own, so the loop stays free to print while
/// a person types, and waits for the loop's go-ahead before each line: the
/// prompt then reflects what the loop knows, and nothing reads stdin while an
/// editor or visual mode has the terminal.
final class REPLInputReader: @unchecked Sendable {
  struct Prompt: Sendable {
    var text: String
    var completions: [String]
    /// The line drawn above the prompt on a classic terminal; nil on the
    /// persistent screen, whose status row the loop keeps by itself.
    var separator: String?
  }

  private let editor: TerminalLineEditor
  private let continuation: AsyncStream<REPLEvent>.Continuation
  private let interrupt: @Sendable () -> Void
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var next = Prompt(text: "pmai> ", completions: [], separator: nil)
  private var stopped = false

  init(
    editor: TerminalLineEditor,
    continuation: AsyncStream<REPLEvent>.Continuation,
    interrupt: @escaping @Sendable () -> Void
  ) {
    self.editor = editor
    self.continuation = continuation
    self.interrupt = interrupt
  }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "pmai-input"
    thread.start()
  }

  /// Lets the thread read one more line with this prompt.
  func resume(with prompt: Prompt) {
    lock.withLock { next = prompt }
    gate.signal()
  }

  func stop() {
    lock.withLock { stopped = true }
    gate.signal()
  }

  private func run() {
    while true {
      gate.wait()
      let (prompt, done) = lock.withLock { (next, stopped) }
      if done { return }
      guard
        let line = editor.readLine(
          prompt: prompt.text, completions: prompt.completions, separator: prompt.separator)
      else {
        continuation.yield(.endOfFile)
        return
      }
      if editor.wasInterrupted {
        interrupt()
        continue
      }
      guard let delimiter = Self.heredocDelimiter(in: line) else {
        continuation.yield(.line(line, heredoc: false))
        continue
      }
      var lines: [String] = []
      while true {
        guard let more = editor.readLine(prompt: "...> ", completions: [], rememberInput: false)
        else {
          continuation.yield(.endOfFile)
          return
        }
        if editor.wasInterrupted {
          interrupt()
          break
        }
        if more == delimiter {
          continuation.yield(.line(lines.joined(separator: "\n"), heredoc: true))
          break
        }
        lines.append(more)
      }
    }
  }

  /// `<<WORD` starts a multiline message that ends at WORD on a line of its own.
  static func heredocDelimiter(in input: String) -> String? {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("<<") else { return nil }
    let delimiter = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
    guard !delimiter.isEmpty, !delimiter.contains(where: \.isWhitespace) else { return nil }
    return delimiter
  }
}
