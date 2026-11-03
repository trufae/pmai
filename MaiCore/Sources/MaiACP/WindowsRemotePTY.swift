#if os(Windows)
import CMaiTerminal
import Foundation
import MaiCore

/// A real ConPTY session. Input, output and lifecycle each have an independent
/// worker: a blocked terminal write must never prevent draining terminal output.
public final class RemotePTY: @unchecked Sendable {
  public static var isSupported: Bool { mai_windows_pty_available() != 0 }
  private let condition = NSCondition()
  private let native: OpaquePointer
  private let reader = DispatchGroup(), writer = DispatchGroup()
  private var output = Data(), input = Data()
  private var outputOffset = 0
  private var stopping = false, ending = false
  private var resizing = 0
  private var exitCode: Int?
  private var pending: (UUID, Bool, CheckedContinuation<RemoteTerminalChunk, Error>)?
  private var closed: [CheckedContinuation<Void, Never>] = []
  private var lastActivity = ProcessInfo.processInfo.systemUptime
  private static let capacity = 256 * 1024

  public init(cwd: URL, columns: Int, rows: Int) throws {
    guard (1...1000).contains(columns), (1...1000).contains(rows) else {
      throw JSONRPCError.invalidParams("Terminal dimensions must be between 1 and 1000")
    }
    let environment = LocalProcess.mergedEnvironment(ProcessInfo.processInfo.environment)
    var candidates = [environment["PMAI_SHELL"], "pwsh", "powershell"]
    if let root = environment["SYSTEMROOT"] {
      candidates.append(root + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
    }
    candidates += [environment["COMSPEC"], "cmd"]
    var executable: String?
    for candidate in candidates.compactMap({ $0 }) {
      if let path = try? LocalExecutable.resolve(candidate, environment: environment, workingDirectory: cwd) {
        executable = path
        break
      }
    }
    guard let executable else { throw JSONRPCError.internalError("No native Windows shell was found") }
    // Only the resolved executable and fixed flags form this command line.
    // Windows executable filenames cannot contain double quotes.
    let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    let flags = name == "cmd.exe" ? "/d" : ["pwsh.exe", "powershell.exe"].contains(name) ? "-NoLogo -NoProfile" : ""
    let command = "\"\(executable)\" " + flags
    let directory = cwd.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? cwd.path
    var error: UInt32 = 0
    let created = executable.withCString(encodedAs: UTF16.self) { application in
      command.withCString(encodedAs: UTF16.self) { arguments in
        directory.withCString(encodedAs: UTF16.self) { path in
          mai_windows_pty_create(application, arguments, path, Int32(columns), Int32(rows), &error)
        }
      }
    }
    guard let created else { throw Self.error(error) }
    native = created
    reader.enter(); writer.enter()
    Thread.detachNewThread { self.readWorker() }
    Thread.detachNewThread { self.writeWorker() }
    Thread.detachNewThread { self.lifecycleWorker() }
  }

  public func readOutput(after offset: Int? = nil) async throws -> RemoteTerminalChunk {
    let token = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        condition.withLock {
          if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
          guard pending == nil else {
            continuation.resume(throwing: JSONRPCError.invalidParams("A terminal read is already pending")); return
          }
          if let offset {
            guard offset >= outputOffset, offset <= outputOffset + output.count else {
              continuation.resume(throwing: JSONRPCError.invalidParams("Invalid terminal output offset")); return
            }
            output.removeFirst(offset - outputOffset)
            outputOffset = offset
            condition.broadcast()
          }
          if !output.isEmpty || exitCode != nil {
            continuation.resume(returning: takeOutput(reliable: offset != nil))
          } else {
            pending = (token, offset != nil, continuation)
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { self.finishRead(token: token) }
          }
        }
      }
    } onCancel: { self.finishRead(token: token, cancelled: true) }
  }

  public func send(_ data: Data) throws {
    try condition.withLock {
      guard !stopping, !ending else { throw JSONRPCTransportError.closed }
      guard data.count <= 16 * 1024, input.count + data.count <= Self.capacity else {
        throw JSONRPCError.invalidParams("Terminal input queue is full; send smaller chunks")
      }
      input.append(data)
      if !data.isEmpty { lastActivity = ProcessInfo.processInfo.systemUptime; condition.broadcast() }
    }
  }

  public func resize(columns: Int, rows: Int) async throws {
    guard (1...1000).contains(columns), (1...1000).contains(rows) else {
      throw JSONRPCError.invalidParams("Terminal dimensions must be between 1 and 1000")
    }
    let perform = try condition.withLock {
      guard !stopping else { throw JSONRPCTransportError.closed }
      if ending { return false }
      resizing += 1
      lastActivity = ProcessInfo.processInfo.systemUptime
      return true
    }
    guard perform else { return }
    defer { condition.withLock { resizing -= 1; condition.broadcast() } }
    try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Void, Error>) in
      DispatchQueue.global().async {
        var error: UInt32 = 0
        if mai_windows_pty_resize(self.native, Int32(columns), Int32(rows), &error) != 0 { reply.resume() }
        else { reply.resume(throwing: Self.error(error)) }
      }
    }
  }

  public func stop() async {
    await withCheckedContinuation { continuation in
      condition.withLock {
        if exitCode != nil { continuation.resume() }
        else {
          stopping = true
          input.removeAll()
          closed.append(continuation)
          condition.broadcast()
        }
      }
    }
  }

  func isIdle(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    condition.withLock { timeout > 0 && now - lastActivity >= timeout }
  }

  func detachReader() {
    condition.withLock {
      if let (_, reliable, continuation) = pending {
        pending = nil
        continuation.resume(returning: takeOutput(reliable: reliable))
      }
    }
  }

  private func takeOutput(reliable: Bool) -> RemoteTerminalChunk {
    let data = Data(output.prefix(64 * 1024))
    if !data.isEmpty { lastActivity = ProcessInfo.processInfo.systemUptime }
    let final = data.count == output.count
    let next = outputOffset + data.count
    if !reliable { output.removeFirst(data.count); outputOffset = next; condition.broadcast() }
    return .init(data: data, exitCode: final ? exitCode : nil, offset: reliable ? next : nil)
  }

  private func finishRead(token: UUID, cancelled: Bool = false) {
    condition.withLock {
      guard let (id, reliable, continuation) = pending, id == token else { return }
      pending = nil
      if cancelled { continuation.resume(throwing: CancellationError()) }
      else { continuation.resume(returning: takeOutput(reliable: reliable)) }
    }
  }

  private func readWorker() {
    defer { reader.leave() }
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      var error: UInt32 = 0
      let count = bytes.withUnsafeMutableBytes { mai_windows_pty_read(native, $0.baseAddress, UInt32($0.count), &error) }
      if count <= 0 {
        condition.withLock { if !ending { stopping = true; condition.broadcast() } }
        return
      }
      condition.lock()
      while !stopping, output.count + Int(count) > Self.capacity { condition.wait() }
      // Explicit stop discards subsequent bytes, but still drains ConPTY while
      // ClosePseudoConsole runs. Natural exit retains its entire final output.
      if !stopping {
        output.append(contentsOf: bytes.prefix(Int(count)))
        lastActivity = ProcessInfo.processInfo.systemUptime
        if let (_, reliable, continuation) = pending {
          pending = nil
          continuation.resume(returning: takeOutput(reliable: reliable))
        }
      }
      condition.unlock()
    }
  }

  private func writeWorker() {
    defer { writer.leave() }
    var error: UInt32 = 0
    guard mai_windows_pty_register_writer(native, &error) != 0 else {
      condition.withLock { stopping = true; condition.broadcast() }
      return
    }
    while true {
      condition.lock()
      while input.isEmpty, !ending, !stopping { condition.wait() }
      if ending || stopping { condition.unlock(); return }
      let bytes = Data(input.prefix(16 * 1024))
      input.removeFirst(bytes.count)
      condition.unlock()
      var offset = 0
      while offset < bytes.count {
        if condition.withLock({ ending || stopping }) { return }
        let count = bytes.withUnsafeBytes {
          mai_windows_pty_write(native, $0.baseAddress!.advanced(by: offset), UInt32($0.count - offset), &error)
        }
        guard count > 0 else {
          condition.withLock { if !ending { stopping = true; condition.broadcast() } }
          return
        }
        offset += Int(count)
      }
    }
  }

  private func lifecycleWorker() {
    var status: UInt32 = 1, error: UInt32 = 0
    while true {
      let result = mai_windows_pty_wait(native, 50, &status, &error)
      if result != 0 || condition.withLock({ stopping }) { break }
    }
    condition.withLock { ending = true; condition.broadcast() }
    mai_windows_pty_terminate(native)
    // Repeat cancellation until joined: a one-shot cancellation can race the
    // writer immediately before it enters synchronous WriteFile.
    repeat { mai_windows_pty_cancel_writer(native) }
      while writer.wait(timeout: .now() + .milliseconds(50)) != .success
    mai_windows_pty_finish_input(native)
    condition.lock()
    while resizing > 0 { condition.wait() }
    condition.unlock()
    // This must not run on the output reader: older Windows versions wait for
    // the reader to drain shutdown output before ClosePseudoConsole returns.
    mai_windows_pty_close_console(native)
    reader.wait()
    var finalStatus: UInt32 = status
    _ = mai_windows_pty_wait(native, UInt32.max, &finalStatus, &error)
    // status was captured before terminating remaining descendants.
    mai_windows_pty_destroy(native)
    condition.withLock {
      exitCode = Int(status)
      if let (_, reliable, continuation) = pending {
        pending = nil
        continuation.resume(returning: takeOutput(reliable: reliable))
      }
      for continuation in closed { continuation.resume() }
      closed.removeAll()
    }
  }

  private static func error(_ code: UInt32) -> NSError {
    NSError(domain: "ConPTY", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "Windows terminal error \(code)"])
  }
}
#endif
