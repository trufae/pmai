#if os(Windows)
import Foundation
import Testing
import WinSDK
@testable import MaiCLI

// Explicit opt-in: this test replaces the current Windows clipboard contents.
// PowerShell: $env:PMAI_TEST_CLIPBOARD='1'; swift test --package-path MaiCore --filter windowsClipboardRoundTrip
@Test("Windows clipboard preserves Unicode and empty text after its owner window closes",
  .enabled(if: ProcessInfo.processInfo.environment["PMAI_TEST_CLIPBOARD"] == "1"))
func windowsClipboardRoundTrip() throws {
  func readText() throws -> String {
    let deadline = GetTickCount64() + 2000
    while !OpenClipboard(nil) {
      try #require(GetTickCount64() < deadline, "Windows clipboard remained busy")
      Sleep(10)
    }
    defer { _ = CloseClipboard() }
    let memory = try #require(GetClipboardData(UINT(CF_UNICODETEXT)))
    let bytes = try #require(GlobalLock(memory))
    defer { _ = GlobalUnlock(memory) }
    let capacity = Int(GlobalSize(memory)) / MemoryLayout<UInt16>.stride
    let units = bytes.assumingMemoryBound(to: UInt16.self)
    var count = 0
    while count < capacity, units[count] != 0 { count += 1 }
    try #require(count < capacity, "Clipboard text is not NUL terminated")
    return String(decoding: UnsafeBufferPointer(start: units, count: count), as: UTF16.self)
  }
  for (text, expected) in [
    ("é 中文 🙂", "é 中文 🙂"),
    ("", ""),
    ("first\nsecond\r\nthird\rfourth", "first\r\nsecond\r\nthird\r\nfourth"),
  ] {
    try SystemClipboard.write(text)
    #expect(try readText() == expected)
  }
  #expect(throws: ClipboardError.self) { try SystemClipboard.write("before\0after") }
  #expect(try readText() == "first\r\nsecond\r\nthird\r\nfourth")
}
#endif
