import Foundation
#if os(Windows)
import WinSDK
#endif

public enum MaiFileReplacement {
  /// Publish a completed sibling file, replacing the destination if it exists.
  public static func replaceItem(at destination: URL, withItemAt source: URL) throws {
    #if os(Windows)
    // Foundation's replaceItemAt is unimplemented on Windows. Keep an existing
    // destination intact until the completed file can be moved into place.
    guard let sourcePath = source.withUnsafeFileSystemRepresentation({ $0.map { String(cString: $0) } }),
      let destinationPath = destination.withUnsafeFileSystemRepresentation({ $0.map { String(cString: $0) } })
    else { throw CocoaError(.fileWriteInvalidFileName) }
    try sourcePath.withCString(encodedAs: UTF16.self) { source in
      try destinationPath.withCString(encodedAs: UTF16.self) { target in
        guard MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING)) else {
          throw NSError(domain: "NSWin32ErrorDomain", code: Int(GetLastError()),
            userInfo: [NSFilePathErrorKey: destination.path])
        }
      }
    }
    #else
    if FileManager.default.fileExists(atPath: destination.path) {
      _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
    } else {
      try FileManager.default.moveItem(at: source, to: destination)
    }
    #endif
  }
}
