#if os(Windows)
import Foundation
import MaiCore
import WinSDK

/// Launch suspended, attach the job, then resume: even a fast native program
/// cannot spawn a child outside the job before cancellation becomes effective.
final class WindowsRunProcess: @unchecked Sendable {
  private static let launchLock = NSLock()
  private let lock = NSLock()
  private let executable: URL
  private let arguments: [String]
  private let environment: [String: String]
  let currentDirectoryURL: URL?
  private let input: FileHandle
  private let output: FileHandle
  private let errors: FileHandle
  private let parentHandles: [FileHandle]
  private var handle: HANDLE?
  private var job: WindowsRunJob?
  private var pid: Int32 = 0
  private var status: Int32 = -1
  private var running = false
  var terminationHandler: (@Sendable (WindowsRunProcess) -> Void)?

  init(executable: URL, arguments: [String], directory: URL, environment: [String: String],
    input: FileHandle, output: FileHandle, errors: FileHandle, parentHandles: [FileHandle]) {
    self.executable = executable
    self.arguments = arguments
    self.currentDirectoryURL = directory
    self.environment = LocalProcess.mergedEnvironment(environment)
    self.input = input
    self.output = output
    self.errors = errors
    self.parentHandles = parentHandles
  }

  deinit { if let handle { CloseHandle(handle) } }

  var processIdentifier: Int32 { lock.withLock { pid } }
  var terminationStatus: Int32 { lock.withLock { status } }
  var isRunning: Bool { lock.withLock { running } }

  func terminate() { lock.withLock { job?.terminate() } }

  func run() throws {
    let job = try WindowsRunJob()
    let info: PROCESS_INFORMATION = try Self.launchLock.withLock {
      let null = "NUL".withCString(encodedAs: UTF16.self) {
        CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
          nil, DWORD(OPEN_EXISTING), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
      }
      guard let null, null != INVALID_HANDLE_VALUE else { throw Self.lastError() }
      defer { CloseHandle(null) }
      let handles = [input, output, errors].map { $0 === FileHandle.nullDevice ? null : $0._handle }
      var originalFlags: [(HANDLE, DWORD)] = []
      defer { for (handle, flags) in originalFlags { _ = SetHandleInformation(handle, DWORD(HANDLE_FLAG_INHERIT), flags) } }
      for handle in handles {
        var flags: DWORD = 0
        guard GetHandleInformation(handle, &flags) else { throw Self.lastError() }
        originalFlags.append((handle, flags))
        guard SetHandleInformation(handle, DWORD(HANDLE_FLAG_INHERIT), DWORD(HANDLE_FLAG_INHERIT)) else {
          throw Self.lastError()
        }
      }
      var startup = STARTUPINFOW()
      startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
      startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
      startup.hStdInput = handles[0]
      startup.hStdOutput = handles[1]
      startup.hStdError = handles[2]
      let path = Self.path(executable)
      var command = Array(Self.commandLine(path, arguments: arguments).utf16) + [0]
      var variables = Array(environment.keys.sorted { $0.uppercased() < $1.uppercased() }
        .map { "\($0)=\(environment[$0]!)\0" }.joined().utf16) + [0]
      let directory = currentDirectoryURL.map(Self.path) ?? FileManager.default.currentDirectoryPath
      var info = PROCESS_INFORMATION()
      let success = path.withCString(encodedAs: UTF16.self) { executable in
        command.withUnsafeMutableBufferPointer { command in
          variables.withUnsafeMutableBufferPointer { variables in
            directory.withCString(encodedAs: UTF16.self) { directory in
              CreateProcessW(executable, command.baseAddress, nil, nil, true,
                DWORD(CREATE_SUSPENDED | CREATE_UNICODE_ENVIRONMENT),
                UnsafeMutableRawPointer(variables.baseAddress!), directory, &startup, &info)
            }
          }
        }
      }
      guard success else { throw Self.lastError() }
      return info
    }
    let processHandle = info.hProcess!
    let threadHandle = info.hThread!
    defer { CloseHandle(threadHandle) }
    do {
      try job.attach(process: processHandle)
      lock.withLock {
        self.job = job
        handle = processHandle
        pid = Int32(bitPattern: info.dwProcessId)
        running = true
      }
      guard ResumeThread(threadHandle) != DWORD.max else { throw Self.lastError() }
    } catch {
      _ = TerminateProcess(processHandle, 1)
      _ = WaitForSingleObject(processHandle, DWORD(INFINITE))
      if handle == nil { CloseHandle(processHandle) }
      throw error
    }
    for parent in parentHandles { try? parent.close() }
    let thread = Thread { [self] in
      let process = lock.withLock { handle! }
      _ = WaitForSingleObject(process, DWORD(INFINITE))
      var code: DWORD = 1
      _ = GetExitCodeProcess(process, &code)
      lock.withLock {
        status = Int32(bitPattern: code)
        running = false
      }
      terminationHandler?(self)
    }
    thread.name = "pmai-run-wait"
    thread.start()
  }

  private static func path(_ url: URL) -> String {
    url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
  }

  private static func lastError() -> NSError {
    NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
  }

  private static func commandLine(_ executable: String, arguments: [String]) -> String {
    // cmd parses the text after /c itself, using outer quotes rather than the
    // C runtime's backslash-quote escaping used by native executable arguments.
    if URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent.lowercased() == "cmd",
      let index = arguments.firstIndex(where: { $0.lowercased() == "/c" }) {
      let command = Array(arguments.dropFirst(index + 1))
      let source = command.count == 1 && !FileManager.default.fileExists(atPath: command[0])
        ? command[0] : command.map(quote).joined(separator: " ")
      return ([executable] + Array(arguments[...index])).map(quote).joined(separator: " ")
        + " \"" + source + "\""
    }
    return ([executable] + arguments).map(quote).joined(separator: " ")
  }

  private static func quote(_ value: String) -> String {
    if !value.isEmpty, !value.contains(where: { " \t\n\"".contains($0) }) { return value }
    var result = "\""
    var backslashes = 0
    for character in value {
      if character == "\\" { backslashes += 1; continue }
      result += String(repeating: "\\", count: backslashes * (character == "\"" ? 2 : 1))
      if character == "\"" { result += "\\" }
      result.append(character)
      backslashes = 0
    }
    return result + String(repeating: "\\", count: backslashes * 2) + "\""
  }
}
#endif
