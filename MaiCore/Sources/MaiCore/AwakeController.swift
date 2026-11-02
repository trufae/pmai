import Foundation
import Observation

#if os(iOS)
  import UIKit
#elseif os(macOS)
  import IOKit.pwr_mgt
#elseif os(Windows)
  import WinSDK
#endif

/// Owns one temporary inhibitor. Mobile hosts release it when they leave the foreground.
@MainActor @Observable public final class AwakeController {
  public typealias Release = @MainActor () -> Void
  public typealias Acquire = @MainActor () throws -> Release
  public static let shared = AwakeController()
  public nonisolated static let preferenceKey = "pmai.awake"
  public private(set) var isEnabled = false
  @ObservationIgnored private var release: Release?
  @ObservationIgnored private let acquire: Acquire

  /// Android supplies its window implementation through the host's state snapshot.
  public init(acquire: Acquire? = nil) {
    self.acquire = acquire ?? Self.acquirePlatform
  }

  public func setEnabled(_ enabled: Bool) throws {
    guard enabled != isEnabled else { return }
    if enabled {
      release = try acquire()
    } else {
      release?()
      release = nil
    }
    isEnabled = enabled
  }

  private static func acquirePlatform() throws -> Release {
    #if os(iOS)
      let previous = UIApplication.shared.isIdleTimerDisabled
      UIApplication.shared.isIdleTimerDisabled = true
      return { UIApplication.shared.isIdleTimerDisabled = previous }
    #elseif os(macOS)
      var assertion: IOPMAssertionID = 0
      let result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
        IOPMAssertionLevel(kIOPMAssertionLevelOn), "PocketMai keep awake" as CFString,
        &assertion)
      guard result == kIOReturnSuccess else {
        throw AwakeError.unavailable("Cannot prevent sleep (IOKit error \(result)).")
      }
      return { IOPMAssertionRelease(assertion) }
    #elseif os(Windows)
      var reason = Array("PocketMai keep awake".utf16) + [0]
      let handle = reason.withUnsafeMutableBufferPointer { buffer in
        var context = REASON_CONTEXT()
        context.Version = ULONG(POWER_REQUEST_CONTEXT_VERSION)
        context.Flags = DWORD(POWER_REQUEST_CONTEXT_SIMPLE_STRING)
        context.Reason.SimpleReasonString = buffer.baseAddress
        return PowerCreateRequest(&context)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw AwakeError.unavailable("Cannot create a Windows power request.")
      }
      guard PowerSetRequest(handle, PowerRequestSystemRequired) != 0 else {
        CloseHandle(handle)
        throw AwakeError.unavailable("Cannot prevent sleep with a Windows power request.")
      }
      return {
        PowerClearRequest(handle, PowerRequestSystemRequired)
        CloseHandle(handle)
      }
    #elseif os(Linux)
      let process = Process()
      let input = Pipe()
      let ready = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = [
        "systemd-inhibit", "--what=sleep:idle", "--mode=block", "--no-ask-password",
        "--who=PocketMai", "--why=Keep awake enabled",
        "sh", "-c", "printf .; exec cat >/dev/null",
      ]
      process.standardInput = input
      process.standardOutput = ready
      process.standardError = FileHandle.nullDevice
      try process.run()
      try? input.fileHandleForReading.close()
      try? ready.fileHandleForWriting.close()
      var acquired = false
      defer {
        try? ready.fileHandleForReading.close()
        if !acquired { try? input.fileHandleForWriting.close() }
      }
      // The child acknowledges only after logind grants the inhibitor.
      guard try ready.fileHandleForReading.read(upToCount: 1) == Data(".".utf8) else {
        throw AwakeError.unavailable(
          "Cannot prevent sleep. Install systemd-inhibit and check logind permissions.")
      }
      acquired = true
      return {
        // EOF also releases the inhibitor if PocketMai crashes or is killed.
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
      }
    #else
      throw AwakeError.unavailable("This platform needs a host screen-awake handler.")
    #endif
  }
}

public enum AwakeError: LocalizedError {
  case unavailable(String)

  public var errorDescription: String? {
    switch self {
    case .unavailable(let message): message
    }
  }
}
