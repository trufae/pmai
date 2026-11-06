import Foundation
import MaiCore

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

final class TerminalInterruptHandler: @unchecked Sendable {
  #if !os(Windows)
    private let source: DispatchSourceSignal
  #endif
  private let lock = NSLock()
  private var nextID: UInt = 0
  private var active: (REPLInterruptID, @Sendable () -> Void, reports: Bool)?
  private var interrupted: Set<REPLInterruptID> = []
  private let notify: @Sendable (REPLInterruptID?, Bool) -> Void

  init(notify: @escaping @Sendable (REPLInterruptID?, Bool) -> Void) {
    self.notify = notify
    #if os(Windows)
      WindowsConsole.watchInterrupts { [weak self] in self?.requestInterrupt() }
    #else
      signal(SIGINT, SIG_IGN)
      source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
      source.setEventHandler { [weak self] in self?.requestInterrupt() }
      source.resume()
    #endif
  }

  deinit {
    #if os(Windows)
      WindowsConsole.watchInterrupts(nil)
    #else
      source.cancel()
      signal(SIGINT, SIG_DFL)
    #endif
  }

  @discardableResult
  func activate(
    reports: Bool = true,
    cancellation: @escaping @Sendable () -> Void
  ) -> REPLInterruptID {
    lock.withLock {
      nextID &+= 1
      let registration = REPLInterruptID(rawValue: nextID)
      active = (registration, cancellation, reports)
      return registration
    }
  }

  /// Removes only the operation that registered this token. This prevents a
  /// late completion from disabling Ctrl+C for the job that replaced it.
  @discardableResult
  func deactivate(_ registration: REPLInterruptID) -> Bool {
    lock.withLock {
      if active?.0 == registration { active = nil }
      return interrupted.remove(registration) != nil
    }
  }

  func suspend(_ registration: REPLInterruptID) {
    lock.withLock {
      if active?.0 == registration { active = nil }
    }
  }

  func restore(
    _ registration: REPLInterruptID,
    cancellation: @escaping @Sendable () -> Void
  ) {
    lock.withLock { active = (registration, cancellation, true) }
  }

  func requestInterrupt(endedInput: Bool = false) {
    let (action, registration, reports) = lock.withLock {
      let operation = active
      if let registration = operation?.0 { interrupted.insert(registration) }
      return (operation?.1, operation?.0, operation?.reports ?? true)
    }
    action?()
    if reports { notify(registration, endedInput) }
  }
}
