import Foundation
import MaiACP
import MaiStandardTools

#if os(Windows)
import WinSDK
#elseif canImport(Android)
import Android
#elseif canImport(Musl)
import Musl
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Lends stdin/stdout to a host PTY without decoding its terminal byte stream.
/// The caller parks the REPL reader until this relay has restored the tty.
enum RemoteTerminalRelay {
  static var available: Bool {
    return isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
  }

  static func run(connection: WorkspaceConnection, name: String) async throws {
    guard available else { throw WorkspaceFileError("Live shells require a terminal; use cmd mode for piped input.") }
    if let screen = TerminalScreen.current {
      try await screen.suspendTerminalAsync { try await relay(connection: connection, name: name) }
    } else {
      try await relay(connection: connection, name: name)
    }
  }

  private static func size() -> (columns: Int, rows: Int) {
    var size = winsize()
    _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size)
    return (max(2, min(1000, Int(size.ws_col == 0 ? 80 : size.ws_col))),
      max(2, min(1000, Int(size.ws_row == 0 ? 24 : size.ws_row))))
  }

  private static func relay(connection: WorkspaceConnection, name: String) async throws {
    var cooked = termios()
    guard tcgetattr(STDIN_FILENO, &cooked) == 0 else { throw error() }
    var raw = cooked
    #if os(Windows)
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~tcflag_t(IXON | ICRNL)
    WindowsConsole.prepareRawMode(&raw)
    #else
    cfmakeraw(&raw)
    // A bounded poll and nonblocking read let cancellation join the input task.
    withUnsafeMutableBytes(of: &raw.c_cc) {
      $0[Int(VMIN)] = 0
      $0[Int(VTIME)] = 0
    }
    #endif
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { throw error() }
    defer {
      #if !os(Windows)
      _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
      #endif
      // A disconnected full-screen program may leave display/input modes set.
      let reset = TerminalInputModes.disable
        + "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1006l"
        + "\u{1b}[?1049l\u{1b}[0m\u{1b}[?25h\r\n"
      FileHandle.standardOutput.write(Data(reset.utf8))
      #if os(Windows)
      // Reset VT state while VT output is still enabled, then restore the
      // caller's exact native modes (which may have VT processing disabled).
      _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
      #endif
    }
    let dimensions = size()
    let shell = try await connection.openTerminal(columns: dimensions.columns, rows: dimensions.rows)
    do {
      FileHandle.standardOutput.write(Data("Live shell \(name). Ctrl+] returns to pmai.\r\n".utf8))
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
          var offset = 0
          while !Task.isCancelled {
            let chunk = try await shell.read(after: offset)
            try Task.checkCancellation()
            offset = chunk.offset ?? offset + chunk.data.count
            if !chunk.data.isEmpty { try FileHandle.standardOutput.write(contentsOf: chunk.data) }
            if chunk.exitCode != nil { return }
          }
        }
        group.addTask {
          var dimensions = dimensions
          var buffer = [UInt8](repeating: 0, count: 16 * 1024)
          while !Task.isCancelled {
            let current = size()
            if current != dimensions {
              try await shell.resize(columns: current.columns, rows: current.rows)
              dimensions = current
            }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
              if errno == EINTR { continue }
              throw error()
            }
            if ready > 0 {
              #if os(Windows)
              let count = Int(read(STDIN_FILENO, &buffer, UInt32(buffer.count)))
              #else
              let count = read(STDIN_FILENO, &buffer, buffer.count)
              #endif
              if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                throw error()
              }
              if count == 0 { return }
              // Ctrl+] is local; Ctrl+C, Ctrl+D, arrows, paste, and all other
              // bytes go to the host's line discipline unchanged.
              let bytes = buffer.prefix(count)
              let escape = bytes.firstIndex(of: 0x1d)
              let data = Data(bytes.prefix(escape ?? count))
              if !data.isEmpty { try await shell.send(data) }
              if escape != nil { return }
            }
            await Task.yield()
          }
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      await shell.close()
    } catch {
      await shell.close()
      throw error
    }
  }

  private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
