import Foundation
import MaiCore

/// What the REPL loop reacts to. Lines come from the input thread; the rest
/// from turns ending, tools asking for approval, and the process table.
enum REPLEvent: Sendable {
  case line(String, heredoc: Bool, promptID: String?, pasted: IndexSet = [])
  /// A non-nil ID means the signal/input path already cancelled that exact
  /// operation. `endedInput` distinguishes a raw Ctrl+C byte from SIGINT.
  case interrupt(REPLInterruptID?, endedInput: Bool)
  case endOfFile
  case turnFinished(AgentPID, Result<AgentResult, any Error>)
  case approval(ApprovalRequest, REPLApprovalReply)
  case approvalFinished(REPLApprovalReply)
  case compaction(AutocompactionRequest, REPLCompactionReply)
  case compactionFinished(REPLCompactionReply)
  case supervisor(AgentSupervisorEvent)
  case switchAgent(REPLAgentSwitch, reply: @Sendable () -> Void)
}

struct REPLInterruptID: Equatable, Hashable, Sendable {
  let rawValue: UInt
}

/// Answers one approval a tool call is waiting on, exactly once.
typealias REPLApprovalReply = REPLReply<ApprovalDecision>
typealias REPLCompactionReply = REPLReply<AutocompactionDecision>

final class REPLReply<Decision: Sendable>: Sendable {
  let id = UUID()
  private let continuation: AsyncThrowingStream<Decision, any Error>.Continuation

  init(_ continuation: AsyncThrowingStream<Decision, any Error>.Continuation) {
    self.continuation = continuation
  }

  func resume(with decision: Decision) {
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
/// editor has the terminal.
final class REPLInputReader: @unchecked Sendable {
  struct Prompt: Sendable {
    var presentation: TerminalPrompt
    var completions: [String]
    var additionalCompletions: (@Sendable (String) -> [String])? = nil
    /// The line drawn above the prompt on a classic terminal; nil on the
    /// persistent screen, whose status row the loop keeps by itself.
    var separator: String?
  }

  private let editor: TerminalLineEditor
  private let continuation: AsyncStream<REPLEvent>.Continuation
  private let interrupt: @Sendable () -> Void
  private let gate = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var next = Prompt(presentation: TerminalPrompt(text: "pmai> "), completions: [], separator: nil)
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
    update(prompt.presentation)
    lock.withLock { next = prompt }
    gate.signal()
  }

  /// Changes an already open prompt without releasing another reader.
  func update(_ prompt: TerminalPrompt) {
    editor.updatePrompt(prompt)
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
          prompt: prompt.presentation.text, completions: prompt.completions,
          additionalCompletions: prompt.additionalCompletions, separator: prompt.separator,
          tracksPromptUpdates: true)
      else {
        continuation.yield(.endOfFile)
        return
      }
      if editor.wasInterrupted {
        interrupt()
        continue
      }
      let promptID = editor.submittedPromptID
      guard promptID == nil, let delimiter = Self.heredocDelimiter(in: line) else {
        continuation.yield(.line(line, heredoc: false, promptID: promptID, pasted: editor.submittedPasteBytes))
        continue
      }
      var lines: [String] = []
      while true {
        guard let more = editor.readLine(
          prompt: "...> ", completions: [], rememberInput: false,
          tracksPromptUpdates: true, continuationPrompt: "...> ")
        else {
          continuation.yield(.endOfFile)
          return
        }
        if editor.wasInterrupted {
          interrupt()
          if editor.submittedPromptID != nil {
            gate.wait()
            if lock.withLock({ stopped }) { return }
            continue
          }
          break
        }
        if let promptID = editor.submittedPromptID {
          // Answer the modal through the event loop, retaining the heredoc
          // and its current line until the normal prompt resumes.
          continuation.yield(.line(more, heredoc: false, promptID: promptID, pasted: editor.submittedPasteBytes))
          gate.wait()
          if lock.withLock({ stopped }) { return }
          continue
        }
        if more == delimiter {
          continuation.yield(.line(lines.joined(separator: "\n"), heredoc: true, promptID: nil))
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
