#if os(Windows)
import Foundation
import WinSDK

/// Own the shell and its descendants so timeout/cancellation stops the tree.
final class WindowsRunJob {
  private let handle: HANDLE

  init() throws {
    guard let handle = CreateJobObjectW(nil, nil) else { throw Self.lastError() }
    var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
    limits.BasicLimitInformation.LimitFlags = DWORD(JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE)
    guard SetInformationJobObject(handle, JobObjectExtendedLimitInformation, &limits,
      DWORD(MemoryLayout<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>.size)) else {
      let error = Self.lastError()
      CloseHandle(handle)
      throw error
    }
    self.handle = handle
  }

  deinit { CloseHandle(handle) }

  func attach(pid: Int32) throws {
    guard let process = OpenProcess(DWORD(PROCESS_SET_QUOTA | PROCESS_TERMINATE | SYNCHRONIZE),
      false, DWORD(bitPattern: pid)) else {
      // A command can finish before the launcher returns its PID.
      if GetLastError() == ERROR_INVALID_PARAMETER { return }
      throw Self.lastError()
    }
    defer { CloseHandle(process) }
    guard AssignProcessToJobObject(handle, process) else {
      if WaitForSingleObject(process, 0) == WAIT_OBJECT_0 { return }
      throw Self.lastError()
    }
  }

  func terminate() { _ = TerminateJobObject(handle, 1) }

  private static func lastError() -> NSError {
    NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
  }
}
#endif
