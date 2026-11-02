import Foundation
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

public enum MaiFileLockError: Error, Equatable, Sendable, LocalizedError {
  case busy
  case timedOut
  case symbolicLink
  case system(operation: String, code: Int)

  public var errorDescription: String? {
    switch self {
    case .busy: "The file lock is in use."
    case .timedOut: "Timed out waiting for the file lock."
    case .symbolicLink: "A file lock cannot be a symbolic link or reparse point."
    case .system(let operation, let code): "Cannot \(operation) file lock (system error \(code))."
    }
  }
}

/// An exclusive, cross-process lock held until this owner is released. The
/// caller creates the parent directory and keeps the sidecar file in place.
public final class MaiFileLock: @unchecked Sendable {
  #if os(Windows)
  private let handle: HANDLE
  #else
  private let descriptor: Int32
  #endif

  public init(url: URL, wait: Bool = true) throws {
    #if os(Windows)
    guard let native = url.withUnsafeFileSystemRepresentation({ pointer in
      pointer.map { String(cString: $0) }
    }) else { throw MaiFileLockError.system(operation: "open", code: Int(ERROR_INVALID_NAME)) }
    // A nil security descriptor makes this handle noninheritable. Do not share
    // deletion: replacing a sidecar would let two owners lock different files.
    let access = DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE)
    let opened = native.withCString(encodedAs: UTF16.self) {
      CreateFileW($0, access, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
        nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT), nil)
    }
    guard let opened, opened != INVALID_HANDLE_VALUE else {
      throw MaiFileLockError.system(operation: "open", code: Int(GetLastError()))
    }
    do {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(opened, &info) else {
        throw MaiFileLockError.system(operation: "inspect", code: Int(GetLastError()))
      }
      guard info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw MaiFileLockError.symbolicLink
      }
      var range = OVERLAPPED()
      let flags = DWORD(LOCKFILE_EXCLUSIVE_LOCK) | (wait ? 0 : DWORD(LOCKFILE_FAIL_IMMEDIATELY))
      // The handle is synchronous; the exclusive range may extend past EOF.
      guard LockFileEx(opened, flags, 0, 1, 0, &range) else {
        let code = GetLastError()
        if code == ERROR_LOCK_VIOLATION { throw MaiFileLockError.busy }
        throw MaiFileLockError.system(operation: "acquire", code: Int(code))
      }
    } catch {
      CloseHandle(opened)
      throw error
    }
    handle = opened
    #else
    var fd: Int32
    repeat {
      fd = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { errno = EINVAL; return -1 }
        return open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
      }
    } while fd < 0 && errno == EINTR
    guard fd >= 0 else {
      if errno == ELOOP { throw MaiFileLockError.symbolicLink }
      throw MaiFileLockError.system(operation: "open", code: Int(errno))
    }
    while flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
      let code = errno
      if code == EINTR { continue }
      close(fd)
      if code == EWOULDBLOCK || code == EAGAIN { throw MaiFileLockError.busy }
      throw MaiFileLockError.system(operation: "acquire", code: Int(code))
    }
    descriptor = fd
    #endif
  }

  /// Wait without blocking a cooperative thread. Only contention is retried;
  /// permission, filesystem and no-follow errors are reported immediately.
  public static func acquire(
    url: URL, timeout: Duration = .seconds(60)
  ) async throws -> MaiFileLock {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while true {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw MaiFileLockError.timedOut }
      do {
        let lock = try MaiFileLock(url: url, wait: false)
        try Task.checkCancellation()
        return lock
      } catch MaiFileLockError.busy {
        guard clock.now < deadline else { throw MaiFileLockError.timedOut }
        let next = min(deadline, clock.now.advanced(by: .milliseconds(100)))
        try await clock.sleep(until: next)
      }
    }
  }

  deinit {
    #if os(Windows)
    var range = OVERLAPPED()
    _ = UnlockFileEx(handle, 0, 1, 0, &range)
    CloseHandle(handle)
    #else
    while flock(descriptor, LOCK_UN) != 0 && errno == EINTR {}
    close(descriptor)
    #endif
  }
}
