import Foundation

/// LFM's Pythonic wire format, sometimes returned as content by native servers.
/// Parse only literal keyword arguments inside a complete, explicit envelope.
/// Never evaluate Python, infer missing delimiters, or execute part of a bad batch.
enum LFMToolCallParser {
  static let start = "<|tool_call_start|>"
  static let end = "<|tool_call_end|>"

  static func hasEnvelope(in text: String) -> Bool {
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(start)
  }

  static func parseCalls(in text: String) -> [ParsedToolCall] {
    let block = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard block.hasPrefix(start), block.hasSuffix(end) else { return [] }
    var parser = LiteralParser(String(block.dropFirst(start.count).dropLast(end.count)))
    do {
      try parser.expect("[")
      var calls: [ParsedToolCall] = []
      if !parser.consume("]") {
        repeat {
          let name = try parser.identifier()
          try parser.expect("(")
          var arguments: [String: JSONValue] = [:]
          if !parser.consume(")") {
            repeat {
              let key = try parser.identifier()
              guard arguments[key] == nil else { throw Invalid.syntax }
              try parser.expect("=")
              arguments[key] = try parser.value(depth: 0)
            } while try parser.more(until: ")")
          }
          calls.append(ParsedToolCall(
            name: name, arguments: [:], argumentValues: arguments, rawBlock: block,
            toolCallID: "lfm_\(UUID().uuidString)"))
        } while try parser.more(until: "]")
      }
      guard parser.isAtEnd else { return [] }
      return calls
    } catch {
      return []
    }
  }

  private enum Invalid: Error { case syntax }

  private struct LiteralParser {
    var input: ArraySlice<Unicode.Scalar>

    init(_ text: String) { input = Array(text.unicodeScalars)[...] }

    mutating func whitespace() {
      while let c = input.first, CharacterSet.whitespacesAndNewlines.contains(c) {
        input = input.dropFirst()
      }
    }

    var isAtEnd: Bool {
      mutating get {
        whitespace()
        return input.isEmpty
      }
    }

    mutating func consume(_ token: Unicode.Scalar) -> Bool {
      whitespace()
      guard input.first == token else { return false }
      input = input.dropFirst()
      return true
    }

    mutating func expect(_ token: Unicode.Scalar) throws {
      guard consume(token) else { throw Invalid.syntax }
    }

    /// A comma or closing delimiter, including Python's trailing comma.
    mutating func more(until end: Unicode.Scalar) throws -> Bool {
      if consume(end) { return false }
      try expect(",")
      return !consume(end)
    }

    func isLetter(_ c: Unicode.Scalar) -> Bool {
      ("a"..."z").contains(c) || ("A"..."Z").contains(c) || c == "_"
    }

    mutating func identifier() throws -> String {
      whitespace()
      guard let first = input.first, isLetter(first) else { throw Invalid.syntax }
      var result = ""
      // Tool API names can include hyphens (list-tools, call-tool).
      while let c = input.first, isLetter(c) || ("0"..."9").contains(c) || c == "-" {
        result.unicodeScalars.append(c)
        input = input.dropFirst()
      }
      return result
    }

    mutating func value(depth: Int) throws -> JSONValue {
      guard depth < 32 else { throw Invalid.syntax }
      whitespace()
      guard let first = input.first else { throw Invalid.syntax }
      if first == "'" || first == "\"" { return .string(try string()) }
      if consume("[") {
        var values: [JSONValue] = []
        if !consume("]") {
          repeat { values.append(try value(depth: depth + 1)) } while try more(until: "]")
        }
        return .array(values)
      }
      if consume("{") {
        var values: [String: JSONValue] = [:]
        if !consume("}") {
          repeat {
            let key = try string()
            guard values[key] == nil else { throw Invalid.syntax }
            try expect(":")
            values[key] = try value(depth: depth + 1)
          } while try more(until: "}")
        }
        return .object(values)
      }
      if isLetter(first) {
        switch try identifier() {
        case "True", "true": return .bool(true)
        case "False", "false": return .bool(false)
        case "None", "null": return .null
        default: throw Invalid.syntax
        }
      }
      var number = ""
      while let c = input.first, ("0"..."9").contains(c) || "-+.eE".unicodeScalars.contains(c) {
        number.unicodeScalars.append(c)
        input = input.dropFirst()
      }
      let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(number.utf8))
      guard let n = decoded.numberValue, n.isFinite else { throw Invalid.syntax }
      return decoded
    }

    mutating func string() throws -> String {
      whitespace()
      guard let quote = input.popFirst(), quote == "'" || quote == "\"" else {
        throw Invalid.syntax
      }
      var result = ""
      while let c = input.popFirst() {
        if c == quote { return result }
        guard c != "\n", c != "\r", c.value >= 0x20 else { throw Invalid.syntax }
        if c != "\\" {
          result.unicodeScalars.append(c)
          continue
        }
        guard let escape = input.popFirst() else { throw Invalid.syntax }
        switch escape {
        case "\\", "'", "\"", "/": result.unicodeScalars.append(escape)
        case "n": result.append("\n")
        case "r": result.append("\r")
        case "t": result.append("\t")
        case "b": result.append("\u{08}")
        case "f": result.append("\u{0C}")
        case "x", "u", "U":
          var code = try hex(count: escape == "x" ? 2 : escape == "u" ? 4 : 8)
          if escape == "u", (0xD800...0xDBFF).contains(code) {
            guard input.popFirst() == "\\", input.popFirst() == "u" else { throw Invalid.syntax }
            let low = try hex(count: 4)
            guard (0xDC00...0xDFFF).contains(low) else { throw Invalid.syntax }
            code = 0x10000 + ((code - 0xD800) << 10) + low - 0xDC00
          }
          guard let scalar = Unicode.Scalar(code) else { throw Invalid.syntax }
          result.unicodeScalars.append(scalar)
        default: throw Invalid.syntax
        }
      }
      throw Invalid.syntax
    }

    mutating func hex(count: Int) throws -> UInt32 {
      guard input.count >= count else { throw Invalid.syntax }
      let text = String(String.UnicodeScalarView(input.prefix(count)))
      guard let code = UInt32(text, radix: 16) else { throw Invalid.syntax }
      input = input.dropFirst(count)
      return code
    }
  }
}
