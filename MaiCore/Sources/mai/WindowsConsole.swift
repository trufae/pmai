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
    if descriptor == STDIN_FILENO, let handle = consoleHandle(descriptor) {
      var mode: DWORD = 0
      if GetConsoleMode(handle, &mode), mode & enableLineInput == 0 {
        return WindowsConsole.readInput(into: buffer, count: count)
      }
    }
    return _read(descriptor, buffer, count)
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
    if state.c_lflag & ICANON == 0 { WindowsConsole.resumeUTF8Output() }
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

  /// Waits for character input, rather than treating key releases, focus,
  /// and resize events as bytes that a following read could consume.
  func poll(_ descriptors: UnsafeMutablePointer<pollfd>, _ count: UInt32, _ timeout: Int32) -> Int32 {
    guard count == 1, let handle = consoleHandle(descriptors.pointee.fd) else { return -1 }
    descriptors.pointee.revents = 0
    var mode: DWORD = 0
    if descriptors.pointee.fd == STDIN_FILENO,
      GetConsoleMode(handle, &mode), mode & enableLineInput == 0
    {
      let ready = WindowsConsole.pollInput(handle, timeout: timeout)
      if ready > 0 { descriptors.pointee.revents = POLLIN }
      return ready
    }
    let outcome = WaitForSingleObject(handle, timeout < 0 ? DWORD.max : DWORD(timeout))
    if outcome == WAIT_OBJECT_0 {
      descriptors.pointee.revents = POLLIN
      return 1
    }
    return outcome == 0x102 ? 0 : -1  // WAIT_TIMEOUT
  }

  // MARK: - Console services without a POSIX shape

  enum WindowsConsole {
    nonisolated(unsafe) private static var originalOutputCodePage: UINT?

    /// All CLI writers emit UTF-8, including Foundation FileHandle and Swift
    /// print. Console output uses a shared code page; redirected streams do not.
    static func configureUTF8Output() {
      guard originalOutputCodePage == nil else { return }
      let hasConsole = [STDOUT_FILENO, STDERR_FILENO].contains { descriptor in
        guard let handle = consoleHandle(descriptor) else { return false }
        var mode: DWORD = 0
        return GetConsoleMode(handle, &mode)
      }
      let previous = GetConsoleOutputCP()
      guard hasConsole, previous != 0, SetConsoleOutputCP(UINT(CP_UTF8)) else { return }
      originalOutputCodePage = previous
      // CLI error paths call exit(), so a main-scope defer is insufficient.
      if atexit(restoreConsoleOutputCodePage) != 0 {
        originalOutputCodePage = nil
        _ = SetConsoleOutputCP(previous)
      }
    }

    /// A foreground child may run chcp. Reclaim UTF-8 when pmai resumes.
    static func resumeUTF8Output() {
      guard originalOutputCodePage != nil else { return }
      _ = SetConsoleOutputCP(UINT(CP_UTF8))
    }

    fileprivate static func restoreOutputCodePage() {
      guard let previous = originalOutputCodePage else { return }
      // exit invokes atexit handlers before flushing buffered print output.
      _ = fflush(nil)
      _ = SetConsoleOutputCP(previous)
    }

    // The editor has one input owner. Keep native reads
    // here so CRT text translation cannot look ahead after CR, hide bytes
    // from poll, or turn a control key into EOF. ReadConsoleW also avoids the
    // console's OEM code page: the editor always consumes UTF-8.
    nonisolated(unsafe) private static var inputBytes: [UInt8] = []
    nonisolated(unsafe) private static var highSurrogate: UInt16?

    private static func hasCharacter(_ record: INPUT_RECORD) -> Bool {
      guard record.EventType == KEY_EVENT else { return false }
      let key = record.Event.KeyEvent
      guard key.bKeyDown.boolValue else { return false }
      if key.uChar.UnicodeChar != 0 { return true }
      // VT mode translates navigation and function keys to escape sequences.
      // Ctrl+Space is a literal NUL; modifier-only presses have no character.
      let code = key.wVirtualKeyCode
      return (WORD(VK_PRIOR)...WORD(VK_DOWN)).contains(code)
        || code == WORD(VK_INSERT) || code == WORD(VK_DELETE)
        || (WORD(VK_F1)...WORD(VK_F12)).contains(code)
        || (code == WORD(VK_SPACE) && key.dwControlKeyState & DWORD(LEFT_CTRL_PRESSED | RIGHT_CTRL_PRESSED) != 0)
    }

    fileprivate static func readInput(into buffer: UnsafeMutableRawPointer, count: UInt32) -> Int32 {
      let size = min(Int(count), inputBytes.count)
      guard size > 0 else {
        if count == 0 { return 0 }
        errno = EINTR
        return -1
      }
      inputBytes.withUnsafeBytes { source in
        buffer.copyMemory(from: source.baseAddress!, byteCount: size)
      }
      inputBytes.removeFirst(size)
      return Int32(size)
    }

    fileprivate static func pollInput(_ handle: HANDLE, timeout: Int32) -> Int32 {
      let started = GetTickCount64()
      while inputBytes.isEmpty {
        let elapsed = GetTickCount64() - started
        let remaining = timeout < 0 ? DWORD.max : DWORD(max(0, Int64(timeout) - Int64(elapsed)))
        let outcome = WaitForSingleObject(handle, remaining)
        if outcome == 0x102 { return 0 }  // WAIT_TIMEOUT
        guard outcome == WAIT_OBJECT_0 else { errno = EIO; return -1 }

        var record = INPUT_RECORD()
        var recordsRead: DWORD = 0
        guard PeekConsoleInputW(handle, &record, 1, &recordsRead) else { errno = EIO; return -1 }
        if recordsRead > 0 {
          if hasCharacter(record) {
            var characters = [UInt16](repeating: 0, count: 64)
            var charactersRead: DWORD = 0
            guard ReadConsoleW(handle, &characters, DWORD(characters.count), &charactersRead, nil) else {
              errno = GetLastError() == ERROR_OPERATION_ABORTED ? EINTR : EIO
              return -1
            }
            var text = Array(characters.prefix(Int(charactersRead)))
            if let highSurrogate { text.insert(highSurrogate, at: 0) }
            highSurrogate = nil
            if let last = text.last, (0xD800...0xDBFF).contains(last) {
              highSurrogate = text.removeLast()
            }
            inputBytes = Array(String(decoding: text, as: UTF16.self).utf8)
          } else {
            // ReadConsole ignores these records and could block waiting for
            // a later key. Discard them without starting a blocking read.
            guard ReadConsoleInputW(handle, &record, 1, &recordsRead) else { errno = EIO; return -1 }
          }
        }
        if inputBytes.isEmpty, timeout >= 0, GetTickCount64() - started >= UInt64(timeout) { return 0 }
      }
      return 1
    }

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

  private func restoreConsoleOutputCodePage() {
    WindowsConsole.restoreOutputCodePage()
  }
#endif
