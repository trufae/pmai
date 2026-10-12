import Foundation

#if canImport(Compression)
  import Compression
#endif

public struct ZipArchiveEntry: Equatable, Sendable {
  public let path: String
  public let data: Data
  public let executable: Bool

  public init(path: String, data: Data, executable: Bool = false) {
    self.path = path
    self.data = data
    self.executable = executable
  }
}

public enum ZipArchiveError: LocalizedError, Equatable, Sendable {
  case notAnArchive
  case unsupportedCompression(method: Int, entry: String)
  case corruptEntry(String)
  case tooLarge

  public var errorDescription: String? {
    switch self {
    case .notAnArchive:
      "The file is not a zip archive."
    case .unsupportedCompression(let method, let entry):
      "Zip entry '\(entry)' uses unsupported compression method \(method)."
    case .corruptEntry(let entry):
      "Zip entry '\(entry)' could not be decompressed."
    case .tooLarge:
      "The zip archive expands beyond the allowed size."
    }
  }
}

/// Reads stored and deflated entries from a zip archive held in memory. Office
/// documents are zip containers, so this is all the DOCX importer needs.
public enum ZipArchiveReader {
  private static let localHeaderSignature: UInt32 = 0x0403_4b50
  private static let centralHeaderSignature: UInt32 = 0x0201_4b50
  private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50

  public static func entries(at url: URL) throws -> [ZipArchiveEntry] {
    try entries(in: try Data(contentsOf: url))
  }

  public static func entries(in data: Data, maximumUncompressedBytes: Int = 256 * 1024 * 1024)
    throws -> [ZipArchiveEntry]
  {
    let bytes = [UInt8](data)
    guard let directoryEnd = findEndOfCentralDirectory(bytes) else {
      throw ZipArchiveError.notAnArchive
    }
    let entryCount = Int(readUInt16(bytes, at: directoryEnd + 10))
    var cursor = Int(readUInt32(bytes, at: directoryEnd + 16))
    var entries: [ZipArchiveEntry] = []
    var totalSize = 0

    for _ in 0..<entryCount {
      guard cursor + 46 <= bytes.count, readUInt32(bytes, at: cursor) == centralHeaderSignature
      else { throw ZipArchiveError.corruptEntry("central directory") }
      let method = Int(readUInt16(bytes, at: cursor + 10))
      let compressedSize = Int(readUInt32(bytes, at: cursor + 20))
      let uncompressedSize = Int(readUInt32(bytes, at: cursor + 24))
      let nameLength = Int(readUInt16(bytes, at: cursor + 28))
      let extraLength = Int(readUInt16(bytes, at: cursor + 30))
      let commentLength = Int(readUInt16(bytes, at: cursor + 32))
      let localOffset = Int(readUInt32(bytes, at: cursor + 42))
      let executable = (readUInt32(bytes, at: cursor + 38) >> 16) & 0o111 != 0
      guard cursor + 46 + nameLength <= bytes.count,
        let name = String(bytes: bytes[cursor + 46..<cursor + 46 + nameLength], encoding: .utf8)
      else { throw ZipArchiveError.corruptEntry("entry name") }
      cursor += 46 + nameLength + extraLength + commentLength

      guard !name.hasSuffix("/") else { continue }
      guard uncompressedSize <= maximumUncompressedBytes - totalSize else {
        throw ZipArchiveError.tooLarge
      }
      totalSize += uncompressedSize
      guard localOffset + 30 <= bytes.count,
        readUInt32(bytes, at: localOffset) == localHeaderSignature
      else { throw ZipArchiveError.corruptEntry(name) }
      let localNameLength = Int(readUInt16(bytes, at: localOffset + 26))
      let localExtraLength = Int(readUInt16(bytes, at: localOffset + 28))
      let start = localOffset + 30 + localNameLength + localExtraLength
      guard start + compressedSize <= bytes.count else { throw ZipArchiveError.corruptEntry(name) }
      let raw = Data(bytes[start..<start + compressedSize])

      switch method {
      case 0:
        guard compressedSize == uncompressedSize else { throw ZipArchiveError.corruptEntry(name) }
        entries.append(ZipArchiveEntry(path: name, data: raw, executable: executable))
      case 8:
        guard let inflated = inflate(raw, expectedSize: uncompressedSize) else {
          throw ZipArchiveError.corruptEntry(name)
        }
        entries.append(ZipArchiveEntry(path: name, data: inflated, executable: executable))
      default:
        throw ZipArchiveError.unsupportedCompression(method: method, entry: name)
      }
    }
    return entries
  }

  private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
    guard bytes.count >= 22 else { return nil }
    let lowest = max(0, bytes.count - 66_000)
    var index = bytes.count - 22
    while index >= lowest {
      if readUInt32(bytes, at: index) == endOfCentralDirectorySignature { return index }
      index -= 1
    }
    return nil
  }

  static func inflate(_ data: Data, expectedSize: Int) -> Data? {
    guard expectedSize > 0 else { return Data() }
    #if canImport(Compression)
      let capacity = max(expectedSize, 64)
      let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
      defer { destination.deallocate() }
      let written = data.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
        guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
        return compression_decode_buffer(
          destination, capacity, base, data.count, nil, COMPRESSION_ZLIB)
      }
      if written == expectedSize { return Data(bytes: destination, count: written) }
    #endif
    guard let inflated = try? Inflate.decompress(data, expectedSize: expectedSize),
      inflated.count == expectedSize
    else { return nil }
    return inflated
  }

  private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
    guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
    return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
  }
}
