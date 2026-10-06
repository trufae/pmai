import Foundation

/// The CLI lends its terminal while an interactive run owns stdin/stdout.
/// Other hosts leave this uninstalled and return a useful error instead.
public actor MaiRunTerminalHost {
  public typealias Operation = @Sendable () throws -> Void
  public typealias Runner = @Sendable (@escaping Operation) async throws -> Void

  public static let shared = MaiRunTerminalHost()
  private var runner: Runner?
  private var busy = false

  public init() {}

  public func install(runner: Runner?) {
    self.runner = runner
  }

  public func run(_ operation: @escaping Operation) async throws {
    guard let runner else { throw MaiRunToolError.noTerminal }
    guard !busy else { throw MaiRunToolError.terminalBusy }
    busy = true
    defer { busy = false }
    try Task.checkCancellation()
    try await runner(operation)
  }
}
