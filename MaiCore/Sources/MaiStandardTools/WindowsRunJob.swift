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

  func attach(process: HANDLE) throws {
    guard AssignProcessToJobObject(handle, process) else { throw Self.lastError() }
  }

  func terminate() { _ = TerminateJobObject(handle, 1) }

  private static func lastError() -> NSError {
    NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()))
  }
}
#endif
