import Foundation
import MaiCore

/// Raw bytes are base64 on the wire; UTF-8 and escape sequences may span reads.
public struct RemoteTerminalChunk: Codable, Sendable {
  public var data: Data
  public var exitCode: Int?
  public var offset: Int?

  public init(data: Data = Data(), exitCode: Int? = nil, offset: Int? = nil) {
    self.data = data
    self.exitCode = exitCode
    self.offset = offset
  }
}

/// A handle to a host-owned shell. Resumable gateway connections can reattach
/// after a disconnect; explicit close or the host idle timeout ends the shell.
public struct RemoteTerminalSession: Sendable {
  public let id: String
  let client: ACPClient

  public func read(after offset: Int? = nil) async throws -> RemoteTerminalChunk {
    var fields: [String: JSONValue] = ["action": .string("read"), "id": .string(id)]
    if let offset { fields["offset"] = .integer(offset) }
    let result = try await client.terminal(fields)
    return try JSONDecoder().decode(RemoteTerminalChunk.self, from: JSONEncoder().encode(result))
  }

  public func send(_ data: Data) async throws {
    var offset = 0
    while offset < data.count {
      try Task.checkCancellation()
      let chunk = Data(data.dropFirst(offset).prefix(16 * 1024))
      _ = try await client.terminal([
        "action": .string("write"), "id": .string(id), "data": .string(chunk.base64EncodedString()),
      ])
      offset += chunk.count
    }
  }

  public func resize(columns: Int, rows: Int) async throws {
    _ = try await client.terminal([
      "action": .string("resize"), "id": .string(id),
      "columns": .integer(columns), "rows": .integer(rows),
    ])
  }

  public func close() async {
    _ = try? await client.terminal(["action": .string("close"), "id": .string(id)])
  }
}

#if os(macOS) || os(Linux) || os(Android)
import CMaiTerminal
#if canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// A worker owns the descriptor until it has reaped the shell. Bounded queues
/// apply backpressure without dropping terminal bytes or blocking Swift actors.
final class RemotePTY: @unchecked Sendable {
  private let lock = NSLock()
  private let master: Int32
  private let pid: Int32
  private var output = Data()
  private var outputOffset = 0
  private var input = Data()
  private var stopping = false
  private var exitCode: Int?
  private var pending: (UUID, Bool, CheckedContinuation<RemoteTerminalChunk, Error>)?
  private var lastActivity = ProcessInfo.processInfo.systemUptime
  private var closed: [CheckedContinuation<Void, Never>] = []
  private static let capacity = 256 * 1024

  init(cwd: URL, columns: Int, rows: Int) throws {
    var master: Int32 = -1, slave: Int32 = -1
    var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
    guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw Self.error() }
    defer { _ = close(slave) }
    guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(slave, F_SETFD, FD_CLOEXEC) == 0,
      fcntl(master, F_SETFL, O_NONBLOCK) == 0 else {
      let error = Self.error()
      _ = close(master)
      throw error
    }
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["PWD"] = cwd.path
    #if os(Android)
    let fallback = "/system/bin/sh"
    #else
    let fallback = "/bin/sh"
    #endif
    let configured = environment["SHELL"] ?? fallback
    let shell = FileManager.default.isExecutableFile(atPath: configured) ? configured : fallback
    let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { for pointer in env { free(pointer) } }
    let child = mai_terminal_shell(master, slave, shell, cwd.path, env)
    guard child >= 0 else {
      let error = Self.error()
      _ = close(master)
      throw error
    }
    self.master = master
    pid = child
    Thread.detachNewThread { self.pump() }
  }

  func readOutput(after offset: Int? = nil) async throws -> RemoteTerminalChunk {
    let token = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock {
          if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
          guard pending == nil else {
            continuation.resume(throwing: JSONRPCError.invalidParams("A terminal read is already pending"))
            return
          }
          if let offset {
            guard offset >= outputOffset, offset <= outputOffset + output.count else {
              continuation.resume(throwing: JSONRPCError.invalidParams("Invalid terminal output offset"))
              return
            }
            output.removeFirst(offset - outputOffset)
            outputOffset = offset
          }
          if !output.isEmpty || exitCode != nil {
            continuation.resume(returning: takeOutput(reliable: offset != nil))
          } else {
            pending = (token, offset != nil, continuation)
            // An idle response keeps long-lived requests within transport timeouts.
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
              self.finishRead(token: token)
            }
          }
        }
      }
    } onCancel: { self.finishRead(token: token, cancelled: true) }
  }

  func send(_ data: Data) throws {
    try lock.withLock {
      guard !stopping, exitCode == nil else { throw JSONRPCTransportError.closed }
      guard data.count <= 16 * 1024, input.count + data.count <= Self.capacity else {
        throw JSONRPCError.invalidParams("Terminal input queue is full; send smaller chunks")
      }
      input.append(data)
      if !data.isEmpty { lastActivity = ProcessInfo.processInfo.systemUptime }
    }
  }

  func resize(columns: Int, rows: Int) throws {
    try lock.withLock {
      guard !stopping else { throw JSONRPCTransportError.closed }
      // Reattaching a shell that exited offline must still deliver its final
      // output and status, even though there is no longer a tty to resize.
      if exitCode != nil { return }
      var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(columns), ws_xpixel: 0, ws_ypixel: 0)
      guard ioctl(master, UInt(TIOCSWINSZ), &size) == 0 else { throw Self.error() }
      lastActivity = ProcessInfo.processInfo.systemUptime
    }
  }

  func stop() async {
    await withCheckedContinuation { continuation in
      lock.withLock {
        if exitCode != nil { continuation.resume() }
        else { stopping = true; closed.append(continuation) }
      }
    }
  }

  func isIdle(timeout: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
    lock.withLock { timeout > 0 && now - lastActivity >= timeout }
  }

  func detachReader() {
    lock.withLock {
      if let (_, reliable, continuation) = pending {
        pending = nil
        continuation.resume(returning: takeOutput(reliable: reliable))
      }
    }
  }

  private func takeOutput(reliable: Bool) -> RemoteTerminalChunk {
    let data = Data(output.prefix(64 * 1024))
    if !data.isEmpty { lastActivity = ProcessInfo.processInfo.systemUptime }
    let isFinal = data.count == output.count
    let offset = outputOffset + data.count
    if !reliable { output.removeFirst(data.count); outputOffset = offset }
    return .init(data: data, exitCode: isFinal ? exitCode : nil,
      offset: reliable ? offset : nil)
  }

  private func finishRead(token: UUID, cancelled: Bool = false) {
    lock.withLock {
      guard let (id, reliable, continuation) = pending, id == token else { return }
      pending = nil
      if cancelled { continuation.resume(throwing: CancellationError()) }
      else { continuation.resume(returning: takeOutput(reliable: reliable)) }
    }
  }

  private func pump() {
    var status: Int32 = 0
    var reaped = false
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
      let (stop, canRead, canWrite) = lock.withLock {
        (stopping, output.count < Self.capacity, !input.isEmpty)
      }
      if stop { break }
      var descriptor = pollfd(fd: canRead || canWrite ? master : -1,
        events: (canRead ? Int16(POLLIN) : 0) | (canWrite ? Int16(POLLOUT) : 0), revents: 0)
      let ready = poll(&descriptor, 1, 50)
      if ready < 0, errno != EINTR { break }
      if canWrite, descriptor.revents & Int16(POLLOUT) != 0 {
        lock.withLock {
          let count = input.withUnsafeBytes { write(master, $0.baseAddress, min($0.count, 16 * 1024)) }
          if count > 0 { input.removeFirst(count) }
        }
      }
      if !reaped {
        let waited = waitpid(pid, &status, WNOHANG)
        reaped = waited == pid || waited == -1 && errno != EINTR
      }
      // After exit, drain only as the consumer makes room. Do not turn a
      // final burst of output into an unbounded buffer or truncate its tail.
      if canRead, reaped || descriptor.revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
        let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        if count > 0 {
          lock.withLock {
            output.append(contentsOf: buffer.prefix(count))
            lastActivity = ProcessInfo.processInfo.systemUptime
            if let (_, reliable, continuation) = pending {
              pending = nil
              continuation.resume(returning: takeOutput(reliable: reliable))
            }
          }
        } else if reaped {
          break
        }
      }
    }
    if !reaped {
      // The foreground job may have a different group from its shell (vim,
      // pipelines). Stop both before closing the controlling terminal.
      let foreground = tcgetpgrp(master)
      if foreground > 0 { _ = kill(-foreground, SIGKILL) }
      _ = kill(-pid, SIGKILL)
      _ = kill(pid, SIGKILL)
      while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
    }
    lock.withLock {
      _ = close(master)
      exitCode = status & 0x7f == 0 ? Int((status >> 8) & 0xff) : 128 + Int(status & 0x7f)
      if let (_, reliable, continuation) = pending {
        pending = nil
        continuation.resume(returning: takeOutput(reliable: reliable))
      }
      for continuation in closed { continuation.resume() }
      closed.removeAll()
    }
  }

  private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
#endif
