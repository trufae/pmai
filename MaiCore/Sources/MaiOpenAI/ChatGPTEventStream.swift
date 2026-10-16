import Foundation

/// Frame SSE from bytes: Foundation's AsyncBytes.lines drops the empty lines
/// that delimit events on Apple platforms. Decode UTF-8 only after a full line.
struct ChatGPTEventStream {
  private static let maximumEventBytes = 16 * 1_024 * 1_024
  private var line: [UInt8] = []
  private var dataLines: [String] = []
  private var byteCount = 0
  private var firstLine = true
  private var skipLF = false

  mutating func consume(_ byte: UInt8) throws -> String? {
    if skipLF {
      skipLF = false
      if byte == 10 { return nil }
    }
    byteCount += 1
    guard byteCount <= Self.maximumEventBytes else {
      throw ChatGPTError.message("ChatGPT returned a response event larger than 16 MiB.")
    }
    if byte == 13 || byte == 10 {
      skipLF = byte == 13
      return try consumeLine()
    }
    line.append(byte)
    return nil
  }

  mutating func finish() throws -> String? {
    // Accept a final event without a trailing blank line, as long as its JSON
    // is complete. The response decoder still requires response.completed.
    if !line.isEmpty { _ = try consumeLine() }
    return dispatch()
  }

  private mutating func consumeLine() throws -> String? {
    guard var value = String(bytes: line, encoding: .utf8) else {
      throw ChatGPTError.message("ChatGPT returned invalid UTF-8 in a response event.")
    }
    line.removeAll(keepingCapacity: true)
    if firstLine {
      firstLine = false
      if value.first == "\u{FEFF}" { value.removeFirst() }
    }
    if value.isEmpty { return dispatch() }
    if value == "data" {
      dataLines.append("")
    } else if value.hasPrefix("data:") {
      var data = value.dropFirst(5)
      if data.first == " " { data = data.dropFirst() }
      dataLines.append(String(data))
    }
    // Comments, event names, IDs, retry hints, and unknown fields carry no
    // JSON data. Responses events identify themselves in the JSON type field.
    return nil
  }

  private mutating func dispatch() -> String? {
    defer {
      dataLines.removeAll(keepingCapacity: true)
      byteCount = 0
    }
    return dataLines.isEmpty ? nil : dataLines.joined(separator: "\n")
  }
}
