#if os(Windows)
  import Foundation
  import WinSDK

  // POSIX-shaped shims over the Win32 console, so the terminal code reads the
  // same on every platform. Use the C runtime's supported underscored names
  // for descriptor operations; this also covers the console modes that stand in
  // for the termios flags the editor toggles, the window size, a
  // one-descriptor poll, Ctrl+C, and reopening the console as standard input.

  let STDIN_FILENO: Int32 = 0
  let STDOUT_FILENO: Int32 = 1
  let STDERR_FILENO: Int32 = 2

  func isatty(_ descriptor: Int32) -> Int32 {
    _isatty(descriptor)
  }

  func read(_ descriptor: Int32, _ buffer: UnsafeMutableRawPointer, _ count: UInt32) -> Int32 {
    _read(descriptor, buffer, count)
  }

  // MARK: - Terminal modes

  typealias tcflag_t = UInt32
  let ICANON: tcflag_t = 1 << 0
  let ECHO: tcflag_t = 1 << 1
  let ISIG: tcflag_t = 1 << 2
  let IXON: tcflag_t = 1 << 3
  let ICRNL: tcflag_t = 1 << 4
  let TCSANOW: Int32 = 0
  let TCSADRAIN: Int32 = 1
  let TCSAFLUSH: Int32 = 2

  /// The console input and output modes, exposed through the termios flags
  /// the editor knows. `c_iflag` is accepted and ignored: the console has no
  /// flow control or newline translation to switch off.
  struct termios {
    var c_iflag: tcflag_t = 0
    var c_lflag: tcflag_t = 0
    fileprivate var inputMode: DWORD = 0
    fileprivate var outputMode: DWORD = 0
  }

  private let enableProcessedInput: DWORD = 0x0001
  private let enableLineInput: DWORD = 0x0002
  private let enableEchoInput: DWORD = 0x0004
  private let enableVirtualTerminalInput: DWORD = 0x0200
  private let enableProcessedOutput: DWORD = 0x0001
  private let enableVirtualTerminalProcessing: DWORD = 0x0004

  private func consoleHandle(_ descriptor: Int32) -> HANDLE? {
    let raw = _get_osfhandle(descriptor)
    guard raw != -1, let handle = UnsafeMutableRawPointer(bitPattern: raw) else { return nil }
    return handle
  }

  func tcgetattr(_ descriptor: Int32, _ state: inout termios) -> Int32 {
    guard let input = consoleHandle(STDIN_FILENO), let output = consoleHandle(STDOUT_FILENO)
    else { return -1 }
    var inputMode: DWORD = 0
    var outputMode: DWORD = 0
    guard GetConsoleMode(input, &inputMode), GetConsoleMode(output, &outputMode) else { return -1 }
    state.inputMode = inputMode
    state.outputMode = outputMode
    state.c_lflag = 0
    if inputMode & enableLineInput != 0 { state.c_lflag |= ICANON }
    if inputMode & enableEchoInput != 0 { state.c_lflag |= ECHO }
    if inputMode & enableProcessedInput != 0 { state.c_lflag |= ISIG }
    state.c_iflag = IXON | ICRNL
    return 0
  }

  func tcsetattr(_ descriptor: Int32, _ action: Int32, _ state: inout termios) -> Int32 {
    guard let input = consoleHandle(STDIN_FILENO), let output = consoleHandle(STDOUT_FILENO)
    else { return -1 }
    var inputMode = state.inputMode & ~(enableLineInput | enableEchoInput | enableProcessedInput)
    if state.c_lflag & ICANON != 0 { inputMode |= enableLineInput }
    if state.c_lflag & ECHO != 0 { inputMode |= enableEchoInput }
    if state.c_lflag & ISIG != 0 { inputMode |= enableProcessedInput }
    // Raw mode wants key presses as the escape sequences a Unix tty sends.
    if state.c_lflag & ICANON == 0 { inputMode |= enableVirtualTerminalInput }
    // The editor draws with ANSI escapes whatever the input mode is.
    let outputMode = state.outputMode | enableProcessedOutput | enableVirtualTerminalProcessing
    guard SetConsoleMode(input, inputMode), SetConsoleMode(output, outputMode) else { return -1 }
    return 0
  }

  // MARK: - Window size

  struct winsize {
    var ws_row: UInt16 = 0
    var ws_col: UInt16 = 0
  }

  let TIOCGWINSZ: UInt = 0x5413

  func ioctl(_ descriptor: Int32, _ request: UInt, _ size: inout winsize) -> Int32 {
    guard request == TIOCGWINSZ, let handle = consoleHandle(descriptor) else { return -1 }
    var info = CONSOLE_SCREEN_BUFFER_INFO()
    guard GetConsoleScreenBufferInfo(handle, &info) else { return -1 }
    size.ws_col = UInt16(max(0, Int(info.srWindow.Right) - Int(info.srWindow.Left) + 1))
    size.ws_row = UInt16(max(0, Int(info.srWindow.Bottom) - Int(info.srWindow.Top) + 1))
    return 0
  }

  // MARK: - Waiting for input

  struct pollfd {
    var fd: Int32
    var events: Int16
    var revents: Int16
  }

  let POLLIN: Int16 = 0x1

  /// Waits for one console handle. Any console event wakes it, including key
  /// releases, which is fine for the cursor query that uses it.
  func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ timeout: Int32) -> Int32 {
    guard count == 1, let handle = consoleHandle(descriptors.pointee.fd) else { return -1 }
    let outcome = WaitForSingleObject(handle, timeout < 0 ? DWORD.max : DWORD(timeout))
    if outcome == WAIT_OBJECT_0 {
      descriptors.pointee.revents = POLLIN
      return 1
    }
    return outcome == 0x102 ? 0 : -1  // WAIT_TIMEOUT
  }

  // MARK: - Console services without a POSIX shape

  enum WindowsConsole {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var interruptHandler: (@Sendable () -> Void)?

    /// Runs `handler` on Ctrl+C instead of ending the process; nil restores
    /// the default. The C runtime delivers SIGINT from its own console control
    /// handler on a thread of its own, and resets the handler before each
    /// delivery, so it is re-armed on the way in.
    static func watchInterrupts(_ handler: (@Sendable () -> Void)?) {
      lock.withLock { interruptHandler = handler }
      if handler == nil {
        _ = signal(SIGINT, nil)
      } else {
        _ = signal(SIGINT, interruptSignalHandler)
      }
    }

    fileprivate static func interrupted() {
      let handler = lock.withLock { interruptHandler }
      handler?()
    }

    /// Makes the console standard input again after a pipe was read to its
    /// end, the way `open("/dev/tty")` plus `dup2` does elsewhere.
    static func reopenStandardInputOnConsole() -> Bool {
      let genericReadWrite: DWORD = 0x8000_0000 | 0x4000_0000
      let shareReadWrite: DWORD = 0x1 | 0x2
      let openExisting: DWORD = 3
      let handle = "CONIN$".withCString(encodedAs: UTF16.self) { name in
        CreateFileW(name, genericReadWrite, shareReadWrite, nil, openExisting, 0, nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else { return false }
      let descriptor = _open_osfhandle(Int(bitPattern: handle), 0)
      guard descriptor >= 0 else {
        _ = CloseHandle(handle)
        return false
      }
      defer { _ = _close(descriptor) }
      return _dup2(descriptor, STDIN_FILENO) == 0
    }
  }

  private func interruptSignalHandler(_ number: Int32) {
    _ = signal(number, interruptSignalHandler)
    WindowsConsole.interrupted()
  }
#endif
