import Foundation

/// Opt-in diagnostics for the shared CLI path, including Android/Termux.
final class CLIStartupTiming: @unchecked Sendable {
  private let started: ContinuousClock.Instant
  private let enabled: Bool
  private let lock = NSLock()
  private var previous: ContinuousClock.Instant

  init(started: ContinuousClock.Instant, environment: [String: String]) {
    self.started = started
    previous = started
    enabled = environment["PMAI_STARTUP_TIMING"] == "1"
  }

  func mark(_ phase: String) {
    guard enabled else { return }
    lock.withLock {
      let now = ContinuousClock.now
      func milliseconds(since instant: ContinuousClock.Instant) -> Double {
        let duration = instant.duration(to: now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
      }
      let line = String(format: "startup: %.1f ms (+%.1f ms) %@\n",
        milliseconds(since: started), milliseconds(since: previous), phase)
      previous = now
      FileHandle.standardError.write(Data(line.utf8))
    }
  }
}
