#if os(macOS) || os(Linux) || os(Android)
  import CMaiTerminal
  import Foundation

  #if canImport(Android)
    import Android
  #elseif canImport(Musl)
    import Musl
  #elseif canImport(Glibc)
    import Glibc
  #else
    import Darwin
  #endif

  /// Captured commands must not inherit the REPL's controlling terminal, which
  /// would let /dev/tty bypass their pipes. Interactive commands use Foundation's
  /// process group so the host can explicitly hand them its foreground terminal.
  final class POSIXRunProcess: @unchecked Sendable {
    private let lock = NSLock()
    private let interactiveProcess: Process?
    private let executable: URL
    private let arguments: [String]
    private let environment: [String: String]
    let currentDirectoryURL: URL?
    private let input: FileHandle
    private let output: FileHandle
    private let errors: FileHandle
    private let parentHandles: [FileHandle]
    private var pid: Int32 = 0
    private var status: Int32 = -1
    private var running = false
    var terminationHandler: (@Sendable (POSIXRunProcess) -> Void)?

    init(
      executable: URL, arguments: [String], directory: URL, environment: [String: String],
      input: FileHandle, output: FileHandle, errors: FileHandle, parentHandles: [FileHandle],
      interactive: Bool
    ) {
      self.executable = executable
      self.arguments = arguments
      self.currentDirectoryURL = directory
      self.environment = environment
      self.input = input
      self.output = output
      self.errors = errors
      self.parentHandles = parentHandles
      if interactive {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        interactiveProcess = process
      } else {
        interactiveProcess = nil
      }
    }

    var processIdentifier: Int32 { interactiveProcess?.processIdentifier ?? lock.withLock { pid } }
    var terminationStatus: Int32 {
      interactiveProcess?.terminationStatus ?? lock.withLock { status }
    }
    var isRunning: Bool { interactiveProcess?.isRunning ?? lock.withLock { running } }

    func run() throws {
      if let process = interactiveProcess {
        process.terminationHandler = { [weak self] _ in
          guard let self else { return }
          self.terminationHandler?(self)
        }
        try process.run()
        return
      }
      let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
      let env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
      defer { for pointer in argv + env { free(pointer) } }
      // Foundation's nullDevice is a sentinel with no usable descriptor.
      let nullInput =
        input === FileHandle.nullDevice
        ? try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null")) : nil
      defer { try? nullInput?.close() }
      let child = mai_process_spawn(
        executable.path, argv, env, currentDirectoryURL!.path,
        (nullInput ?? input).fileDescriptor, output.fileDescriptor, errors.fileDescriptor)
      guard child != -1 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
      lock.withLock {
        pid = child
        running = true
      }
      for handle in parentHandles { try? handle.close() }
      let thread = Thread { [self] in
        var result: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(child, &result, 0) } while waited == -1 && errno == EINTR
        lock.withLock {
          // waitpid encodes normal exit in the high byte and signal in the low
          // seven bits. Match Foundation's terminationStatus for both cases.
          status = waited == -1 ? -1 : (result & 0x7f == 0 ? (result >> 8) & 0xff : result & 0x7f)
          running = false
        }
        terminationHandler?(self)
      }
      thread.name = "pmai-run-wait"
      thread.start()
    }
  }
#endif
