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
  static func run(_ command: String) throws -> Int32 {
    var result: Result<Int32, Error> = .success(0)
    let launch = { result = Result { try Self.launch(command) } }
    if let screen = TerminalScreen.current {
      screen.suspendTerminal(launch)
    } else {
      launch()
    }
    return try result.get()
  }

  private static func launch(_ command: String) throws -> Int32 {
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
        // posix_spawn accepts the nullable handle, unlike the setters above.
        initialized = attributes
        try check(posix_spawn(&child, shell, nil, &initialized, arguments, environment))
      #else
        try check(posix_spawn(&child, shell, nil, &attributes, arguments, environment))
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
