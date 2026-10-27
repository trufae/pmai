import CMaiTerminal
import Foundation

#if canImport(Android)
  import Android
#elseif canImport(Musl)
  import Musl
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

/// Runs a user command with the terminal restored. Captured commands get
/// their own controlling PTY; direct handoffs share pmai's foreground job.
/// Both observe stops and clear the worker thread's blocked signals.
enum TerminalCommand {
  enum BufferHandoff { case afterDelay, terminalControl }

  static func run(
    _ command: String, suspendTerminal: Bool = true, retainOutput: Bool = false,
    bufferHandoff: BufferHandoff = .afterDelay
  ) throws -> Int32 {
    var result: Result<Int32, Error> = .success(0)
    var output = ""
    let screen = TerminalScreen.current
    let capturesOutput = retainOutput && screen?.isBufferMode == true
    #if !os(Windows)
      if capturesOutput, suspendTerminal, let screen {
        return try runBuffered(command, screen: screen, policy: bufferHandoff)
      }
    #endif
    let launch = {
      result = Result {
        #if !os(Windows)
          if capturesOutput {
            let capture = try OutputCapture()
            defer { output = capture.finish() }
            return try Self.launch(command, capture: capture)
          }
        #endif
        return try Self.launch(command)
      }
    }
    if suspendTerminal, let screen {
      screen.suspendTerminal(launch)
    } else {
      launch()
    }
    if !output.isEmpty {
      screen?.write(output, to: .standardOutput)
    }
    return try result.get()
  }

  #if !os(Windows)
    /// Shell commands may use a short grace period. Pipe filters only hand off
    /// when they change terminal modes or enter an alternate screen, not because
    /// producing their output takes longer than a fixed timeout.
    private static func runBuffered(
      _ command: String, screen: TerminalScreen,
      policy: BufferHandoff
    ) throws -> Int32 {
      var output = ""
      defer {
        if !output.isEmpty {
          screen.write(output, to: .standardOutput)
        }
      }
      var result: Result<Int32, Error> = .success(0)
      screen.suspendTerminal(deferBufferHandoff: { handoff in
        result = Result {
          let capture = try OutputCapture(forwardOutput: false)
          defer { output = capture.finish() }
          return try launch(command, capture: capture) { child in
            let deadline = ProcessInfo.processInfo.systemUptime + 0.15
            while true {
              var status: Int32 = 0
              let waited = waitpid(child, &status, WNOHANG | WUNTRACED)
              if waited == child {
                if status & 0xff != 0x7f { return status }
                handoff()
                capture.beginForwarding()
                capture.resumeAfterStop(child)
                return nil
              }
              if waited == -1 && errno != EINTR { throw posixError(errno) }
              let timedOut =
                policy == .afterDelay && ProcessInfo.processInfo.systemUptime >= deadline
              if timedOut || policy == .terminalControl && capture.requestsTerminalControl {
                handoff()
                capture.beginForwarding()
                return nil
              }
              Thread.sleep(forTimeInterval: 0.005)
            }
          }
        }
      })
      return try result.get()
    }
  #endif

  private static func launch(
    _ command: String, capture: OutputCapture? = nil,
    beforeWait: (Int32) throws -> Int32? = { _ in nil }
  ) throws -> Int32 {
    #if os(Windows)
      let status = command.withCString(terminalSystem)
      guard status != -1 else { throw posixError(errno) }
      return status
    #else
      // Match system()'s protection of its caller while the child owns Ctrl+C
      // and Ctrl+\. Restore the exact dispositions, including REPL handlers.
      let previousINT = signal(SIGINT, SIG_IGN)
      let previousQUIT = signal(SIGQUIT, SIG_IGN)
      // Only the wait loop stops pmai. Otherwise a terminal SIGTSTP can stop
      // us between observing a child stop and sending SIGSTOP, making the
      // first `fg` immediately stop the same job a second time.
      let previousTSTP = signal(SIGTSTP, SIG_IGN)
      defer {
        signal(SIGINT, previousINT)
        signal(SIGQUIT, previousQUIT)
        signal(SIGTSTP, previousTSTP)
      }
      var cooked = termios()
      let hasTerminal = tcgetattr(STDIN_FILENO, &cooked) == 0
      defer {
        if hasTerminal, capture == nil { _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked) }
      }
      #if canImport(Android)
        let shell = "/system/bin/sh"
      #else
        let shell = "/bin/sh"
      #endif
      let arguments = [shell, "-c", command].map { $0.withCString { strdup($0) } } + [nil]
      let environment =
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        + [nil]
      defer {
        for pointer in arguments + environment { free(pointer) }
      }
      if let capture {
        let child = mai_terminal_spawn(capture.master, capture.slave, shell, command, environment)
        guard child != -1 else { throw posixError(errno) }
        capture.resumeInput()
        defer { capture.pauseInput() }
        return try wait(child, beforeWait: beforeWait, capture: capture, cooked: &cooked)
      }
      #if canImport(Android)
        // Bionic's initializer writes an optional handle; its other APIs
        // require the initialized, non-optional handle.
        var initialized: posix_spawnattr_t?
        try check(posix_spawnattr_init(&initialized))
        guard var attributes = initialized else { throw posixError(ENOMEM) }
      #else
        #if canImport(Darwin)
          var attributes: posix_spawnattr_t?
        #else
          var attributes = posix_spawnattr_t()
        #endif
        try check(posix_spawnattr_init(&attributes))
      #endif
      defer { posix_spawnattr_destroy(&attributes) }

      var mask = sigset_t()
      sigemptyset(&mask)
      try check(posix_spawnattr_setsigmask(&attributes, &mask))
      var defaults = sigset_t()
      sigemptyset(&defaults)
      for number in [SIGINT, SIGQUIT, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGPIPE, SIGWINCH] {
        sigaddset(&defaults, number)
      }
      try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
      try check(
        posix_spawnattr_setflags(
          &attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)))

      var child: pid_t = 0
      #if canImport(Android)
        // posix_spawn accepts the nullable handle, unlike the setters above.
        initialized = attributes
        try check(posix_spawn(&child, shell, nil, &initialized, arguments, environment))
      #else
        try check(posix_spawn(&child, shell, nil, &attributes, arguments, environment))
      #endif
      return try wait(child, beforeWait: beforeWait, cooked: &cooked)
    #endif
  }

  #if !os(Windows)
    private static func wait(
      _ child: Int32, beforeWait: (Int32) throws -> Int32?,
      capture: OutputCapture? = nil, cooked: inout termios
    ) throws -> Int32 {
      if let status = try beforeWait(child) { return status }
      var status: Int32 = 0
      while true {
        let waited = waitpid(child, &status, WUNTRACED)
        if waited == -1 {
          if errno == EINTR { continue }
          throw posixError(errno)
        }
        // WIFSTOPPED is a C macro, unavailable to Swift. The low status byte
        // is 0x7f for stops; do not mistake that for a signal termination.
        guard status & 0xff == 0x7f else { return status }
        // Direct children share pmai's job. A captured session needs an
        // explicit resume after fg. Target this worker with raise so it
        // cannot resume the child before the process has actually stopped.
        if let capture {
          capture.resumeAfterStop(child)
        } else {
          _ = kill(-getpgrp(), SIGSTOP)
        }
      }
    }
  #endif

  /// One controlling tty for the child's stdin, stdout, stderr and /dev/tty.
  /// Relay bytes with the real tty in raw mode; the child's line discipline
  /// handles echo, editing and signals, including Ctrl+C and Ctrl+Z.
  private final class OutputCapture: @unchecked Sendable {
    #if !os(Windows)
      let master: Int32
      let slave: Int32
      private let lock = NSLock()
      private var stopping = false
      private var forwardOutput: Bool
      private var forwardInput = false
      private var cooked: termios
      private let reader = DispatchGroup()
      // The reader and beginForwarding() access bytes under the lock;
      // finish() joins the reader before decoding them.
      private var bytes = Data()

      init(forwardOutput: Bool = true) throws {
        self.forwardOutput = forwardOutput
        var master: Int32 = -1
        var slave: Int32 = -1
        var attributes = termios()
        var size = winsize()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0,
          ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0
        else { throw posixError(errno) }
        cooked = attributes
        guard openpty(&master, &slave, nil, &attributes, &size) == 0
        else { throw posixError(errno) }
        self.master = master
        self.slave = slave
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(slave, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(master, F_SETFL, O_NONBLOCK) == 0
        else {
          let code = errno
          close(slave)
          close(master)
          throw posixError(code)
        }
        reader.enter()
        DispatchQueue.global().async {
          defer { self.reader.leave() }
          var buffer = [UInt8](repeating: 0, count: 16384)
          var pending = Data()
          while true {
            // The screen's resize watcher is paused during a handoff.
            var size = winsize()
            if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
              _ = ioctl(self.master, UInt(TIOCSWINSZ), &size)
            }
            let (stopping, input) = self.lock.withLock { (self.stopping, self.forwardInput) }
            var descriptors = [
              pollfd(
                fd: self.master, events: Int16(POLLIN) | (pending.isEmpty ? 0 : Int16(POLLOUT)),
                revents: 0),
              pollfd(
                fd: input && !stopping && pending.isEmpty ? STDIN_FILENO : -1,
                events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&descriptors, 2, stopping ? 0 : 50)
            if ready < 0 {
              if errno == EINTR { continue }
              break
            }
            if ready == 0 {
              if stopping { break }
              continue
            }
            if descriptors[0].revents & Int16(POLLIN | POLLHUP) != 0 {
              let count = read(self.master, &buffer, buffer.count)
              if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
              guard count > 0 else { break }
              let data = Data(buffer.prefix(count))
              self.lock.withLock {
                self.bytes.append(data)
                if self.forwardOutput { FileHandle.standardOutput.write(data) }
              }
            }
            if descriptors[1].revents & Int16(POLLIN) != 0 {
              self.lock.withLock {
                guard self.forwardInput, !self.stopping else { return }
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 { pending.append(contentsOf: buffer.prefix(count)) }
              }
            }
            if !pending.isEmpty {
              let count = pending.withUnsafeBytes { write(self.master, $0.baseAddress, $0.count) }
              if count > 0 { pending.removeFirst(count) }
            }
          }
        }
      }

      func resumeInput() {
        lock.withLock {
          var raw = cooked
          cfmakeraw(&raw)
          // poll readiness can be stale after fg consumes the shell's input.
          // Never block in read while holding the relay lock.
          withUnsafeMutableBytes(of: &raw.c_cc) {
            $0[Int(VMIN)] = 0
            $0[Int(VTIME)] = 0
          }
          _ = tcsetattr(STDIN_FILENO, TCSANOW, &raw)
          forwardInput = true
        }
      }

      func pauseInput() {
        lock.withLock { forwardInput = false }
      }

      func resumeAfterStop(_ child: Int32) {
        pauseInput()
        _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
        _ = raise(SIGSTOP)
        resumeInput()
        _ = kill(-child, SIGCONT)
      }

      var requestsTerminalControl: Bool {
        var attributes = termios()
        if tcgetattr(slave, &attributes) == 0,
          (attributes.c_lflag ^ cooked.c_lflag) & tcflag_t(ICANON | ECHO | ISIG) != 0
        {
          return true
        }
        return lock.withLock { Self.usesAlternateScreen(String(decoding: bytes, as: UTF8.self)) }
      }

      private static func usesAlternateScreen(_ output: String) -> Bool {
        let pattern = #"\x1B\[\?(?:[0-9]+;)*(?:47|1047|1049)(?:;[0-9]+)*h"#
        return output.range(of: pattern, options: .regularExpression) != nil
      }

      func beginForwarding() {
        lock.withLock {
          FileHandle.standardOutput.write(bytes)
          forwardOutput = true
        }
      }

      func finish() -> String {
        lock.withLock { stopping = true }
        reader.wait()
        _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked)
        close(slave)
        close(master)
        // Full-screen applications paint frames that do not belong in the transcript.
        let output = String(decoding: bytes, as: UTF8.self)
        return Self.usesAlternateScreen(output) ? "" : output
      }
    #endif
  }

  private static func check(_ code: Int32) throws {
    if code != 0 { throw posixError(code) }
  }

  private static func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
  }
}

#if os(Windows)
  @_silgen_name("system")
  private func terminalSystem(_ command: UnsafePointer<CChar>) -> CInt
#endif
