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

/// Runs a user command in pmai's foreground job, with the terminal restored.
/// Unlike system(), this observes stopped children and does not pass a Swift
/// worker thread's blocked signals on to an interactive editor.
enum TerminalCommand {
  static func run(
    _ command: String, suspendTerminal: Bool = true, retainOutput: Bool = false
  ) throws -> Int32 {
    var result: Result<Int32, Error> = .success(0)
    var output = Data()
    let screen = TerminalScreen.current
    let capturesOutput = retainOutput && screen?.isBufferMode == true
    let launch = {
      result = Result {
        #if !os(Windows)
          if capturesOutput {
            let capture = try OutputCapture()
            defer { output = capture.finish() }
            return try Self.launch(command, outputDescriptor: capture.slave)
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
      screen?.write(String(decoding: output, as: UTF8.self), to: .standardOutput)
    }
    return try result.get()
  }

  private static func launch(_ command: String, outputDescriptor: Int32? = nil) throws -> Int32 {
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
        if hasTerminal { _ = tcsetattr(STDIN_FILENO, TCSADRAIN, &cooked) }
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

      #if canImport(Android)
        let shell = "/system/bin/sh"
      #else
        let shell = "/bin/sh"
      #endif
      let arguments = [shell, "-c", command].map { strdup($0) } + [nil]
      let environment =
        ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        + [nil]
      defer {
        for pointer in arguments + environment { free(pointer) }
      }
      var child: pid_t = 0
      #if canImport(Android)
        var initializedActions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&initializedActions))
        guard var actions = initializedActions else { throw posixError(ENOMEM) }
      #else
        #if canImport(Darwin)
          var actions: posix_spawn_file_actions_t?
        #else
          var actions = posix_spawn_file_actions_t()
        #endif
        try check(posix_spawn_file_actions_init(&actions))
      #endif
      defer { posix_spawn_file_actions_destroy(&actions) }
      if let outputDescriptor {
        try check(posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, outputDescriptor, STDERR_FILENO))
      }
      #if canImport(Android)
        // posix_spawn accepts the nullable handle, unlike the setters above.
        initialized = attributes
        initializedActions = actions
        try check(posix_spawn(&child, shell, &initializedActions, &initialized, arguments, environment))
      #else
        try check(posix_spawn(&child, shell, &actions, &attributes, arguments, environment))
      #endif
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
        // A shell can stay in wait() while its editor stops. Stop the entire
        // job so the user's shell regains the tty; `fg` resumes all of it.
        // SIGSTOP also works when libdispatch has SIGTSTP blocked.
        // Let `fg` send SIGCONT to the whole job. On Linux another thread
        // can receive our SIGSTOP first, so continuing the child here can
        // resume it before pmai has finished stopping.
        _ = kill(-getpgrp(), SIGSTOP)
      }
    #endif
  }

  #if !os(Windows)
    /// Tee a handoff's output through a tty so colors, terminal queries and
    /// interactive programs still work. Input and job control use the real tty.
    private final class OutputCapture: @unchecked Sendable {
      let master: Int32
      let slave: Int32
      private let lock = NSLock()
      private var stopping = false
      private let reader = DispatchGroup()
      // Only the reader accesses bytes until finish() joins it.
      private var bytes = Data()

      init() throws {
        var master: Int32 = -1
        var slave: Int32 = -1
        var attributes = termios()
        var size = winsize()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0,
          ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0
        else { throw posixError(errno) }
        // The real tty still performs output processing when we forward bytes.
        attributes.c_oflag &= ~tcflag_t(OPOST)
        guard openpty(&master, &slave, nil, &attributes, &size) == 0
        else { throw posixError(errno) }
        self.master = master
        self.slave = slave
        guard fcntl(master, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(slave, F_SETFD, FD_CLOEXEC) == 0
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
          while true {
            // The screen's resize watcher is paused during a handoff.
            var size = winsize()
            if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &size) == 0 {
              _ = ioctl(self.master, UInt(TIOCSWINSZ), &size)
            }
            let stopping = self.lock.withLock { self.stopping }
            var descriptor = pollfd(fd: self.master, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, stopping ? 0 : 50)
            if ready < 0 {
              if errno == EINTR { continue }
              break
            }
            if ready == 0 {
              if stopping { break }
              continue
            }
            let count = read(self.master, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            let data = Data(buffer.prefix(count))
            self.bytes.append(data)
            FileHandle.standardOutput.write(data)
          }
        }
      }

      func finish() -> Data {
        lock.withLock { stopping = true }
        reader.wait()
        close(slave)
        close(master)
        return bytes
      }
    }
  #endif

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
