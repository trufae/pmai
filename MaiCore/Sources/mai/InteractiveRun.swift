import Foundation
import MaiStandardTools

/// Run blocking terminal programs off the cooperative executor. The input
/// gate stops keystroke consumption; the screen lock holds background output
/// until the child exits and terminal modes have been restored.
func installInteractiveRunHost(
  screen: TerminalScreen? = nil, inputGate: TerminalInputGate? = nil
) async {
  await MaiRunTerminalHost.shared.install { operation in
    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, any Error>) in
      DispatchQueue.global(qos: .userInitiated).async {
        do {
          let run = {
            if let screen {
              try screen.handOverTerminal(operation)
            } else {
              try operation()
            }
          }
          if let inputGate { try inputGate.withSuspendedInput(run) } else { try run() }
          reply.resume()
        } catch {
          reply.resume(throwing: error)
        }
      }
    }
  }
}
