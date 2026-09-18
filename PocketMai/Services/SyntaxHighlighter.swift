import SwiftUI

enum SyntaxHighlighter {
  static func highlight(_ code: String, language: String) -> AttributedString {
    let language =
      language
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .split(whereSeparator: \.isWhitespace)
      .first
      .map(String.init) ?? ""
    if language == "diff" || language == "patch" {
      return highlightDiff(code)
    }
    if isMarkupLanguage(language) {
      return highlightMarkup(code)
    }

    var output = AttributedString()
    var token = ""

    func appendToken() {
      guard !token.isEmpty else { return }
      var part = AttributedString(token)
      part.foregroundColor = color(for: token, language: language)
      output.append(part)
      token.removeAll()
    }

    for character in code {
      if character.isLetter || character.isNumber || character == "_" {
        token.append(character)
      } else {
        appendToken()
        var part = AttributedString(String(character))
        part.foregroundColor = .primary
        output.append(part)
      }
    }
    appendToken()
    return output
  }

  private static func isMarkupLanguage(_ language: String) -> Bool {
    [
      "application/xml", "atom", "html", "html5", "htm", "mathml", "rss", "svg",
      "text/html", "text/xml", "xhtml", "xml",
    ].contains(language)
  }

  private static func highlightDiff(_ code: String) -> AttributedString {
    var output = AttributedString()
    code.enumerateSubstrings(in: code.startIndex..<code.endIndex, options: .byLines) {
      _, range, enclosingRange, _ in
      let line = code[range]
      var part = AttributedString(String(code[enclosingRange]))
      part.foregroundColor = .primary
      if line.hasPrefix("--- ") || line.hasPrefix("+++ ") || line.hasPrefix("@@")
        || line.hasPrefix("diff ") || line.hasPrefix("index ")
      {
        part.foregroundColor = .secondary
      } else if line.hasPrefix("+") {
        part.backgroundColor = Color.green.opacity(0.14)
      } else if line.hasPrefix("-") {
        part.backgroundColor = Color.red.opacity(0.14)
      }
      output.append(part)
    }
    return output
  }

  private static func highlightMarkup(_ code: String) -> AttributedString {
    var output = AttributedString()

    func append(_ range: Range<String.Index>, color: Color) {
      guard !range.isEmpty else { return }
      var part = AttributedString(String(code[range]))
      part.foregroundColor = color
      output.append(part)
    }

    func entityEnd(at start: String.Index) -> String.Index? {
      var cursor = code.index(after: start)
      var length = 0
      while cursor < code.endIndex, length < 32 {
        let character = code[cursor]
        if character == ";", length > 0 {
          return code.index(after: cursor)
        }
        guard character.isLetter || character.isNumber || character == "#" else { return nil }
        length += 1
        cursor = code.index(after: cursor)
      }
      return nil
    }

    func appendTag(at start: String.Index) -> String.Index? {
      var cursor = code.index(after: start)
      guard cursor < code.endIndex else { return nil }

      if code[cursor] == "/" || code[cursor] == "!" || code[cursor] == "?" {
        cursor = code.index(after: cursor)
      }
      guard cursor < code.endIndex, isMarkupNameStart(code[cursor]) else { return nil }

      append(start..<cursor, color: .secondary)
      let nameStart = cursor
      while cursor < code.endIndex, isMarkupNameCharacter(code[cursor]) {
        cursor = code.index(after: cursor)
      }
      append(nameStart..<cursor, color: .purple)

      while cursor < code.endIndex {
        if code[cursor] == ">" {
          let end = code.index(after: cursor)
          append(cursor..<end, color: .secondary)
          return end
        }
        if (code[cursor] == "/" || code[cursor] == "?"),
          code.index(after: cursor) < code.endIndex,
          code[code.index(after: cursor)] == ">"
        {
          let end = code.index(cursor, offsetBy: 2)
          append(cursor..<end, color: .secondary)
          return end
        }
        if code[cursor].isWhitespace {
          let whitespaceStart = cursor
          while cursor < code.endIndex, code[cursor].isWhitespace {
            cursor = code.index(after: cursor)
          }
          append(whitespaceStart..<cursor, color: .primary)
          continue
        }

        let attributeStart = cursor
        while cursor < code.endIndex, !isMarkupAttributeBoundary(code[cursor]) {
          cursor = code.index(after: cursor)
        }
        if attributeStart == cursor {
          let end = code.index(after: cursor)
          append(cursor..<end, color: .secondary)
          cursor = end
          continue
        }
        append(attributeStart..<cursor, color: .blue)

        let whitespaceStart = cursor
        while cursor < code.endIndex, code[cursor].isWhitespace {
          cursor = code.index(after: cursor)
        }
        append(whitespaceStart..<cursor, color: .primary)
        guard cursor < code.endIndex, code[cursor] == "=" else { continue }

        let equalsEnd = code.index(after: cursor)
        append(cursor..<equalsEnd, color: .secondary)
        cursor = equalsEnd
        let valueWhitespaceStart = cursor
        while cursor < code.endIndex, code[cursor].isWhitespace {
          cursor = code.index(after: cursor)
        }
        append(valueWhitespaceStart..<cursor, color: .primary)
        guard cursor < code.endIndex else { break }

        let valueStart = cursor
        if code[cursor] == "\"" || code[cursor] == "'" {
          let quote = code[cursor]
          cursor = code.index(after: cursor)
          while cursor < code.endIndex {
            let character = code[cursor]
            cursor = code.index(after: cursor)
            if character == quote { break }
          }
        } else {
          while cursor < code.endIndex, !code[cursor].isWhitespace, code[cursor] != ">" {
            if code[cursor] == "/", code.index(after: cursor) < code.endIndex,
              code[code.index(after: cursor)] == ">"
            {
              break
            }
            cursor = code.index(after: cursor)
          }
        }
        append(valueStart..<cursor, color: .green)
      }
      return cursor
    }

    var cursor = code.startIndex
    while cursor < code.endIndex {
      let remainder = code[cursor...]
      if remainder.hasPrefix("<!--") {
        let end = remainder.range(of: "-->")?.upperBound ?? code.endIndex
        append(cursor..<end, color: .secondary)
        cursor = end
      } else if remainder.hasPrefix("<![CDATA[") {
        let contentStart = code.index(cursor, offsetBy: 9)
        append(cursor..<contentStart, color: .purple)
        if let closingRange = code[contentStart...].range(of: "]]>") {
          append(contentStart..<closingRange.lowerBound, color: .primary)
          append(closingRange, color: .purple)
          cursor = closingRange.upperBound
        } else {
          append(contentStart..<code.endIndex, color: .primary)
          cursor = code.endIndex
        }
      } else if code[cursor] == "<", let end = appendTag(at: cursor) {
        cursor = end
      } else if code[cursor] == "&", let end = entityEnd(at: cursor) {
        append(cursor..<end, color: .orange)
        cursor = end
      } else {
        let textStart = cursor
        cursor = code.index(after: cursor)
        while cursor < code.endIndex, code[cursor] != "<", code[cursor] != "&" {
          cursor = code.index(after: cursor)
        }
        append(textStart..<cursor, color: .primary)
      }
    }
    return output
  }

  private static func isMarkupNameStart(_ character: Character) -> Bool {
    character.isLetter || character == "_" || character == ":"
  }

  private static func isMarkupNameCharacter(_ character: Character) -> Bool {
    isMarkupNameStart(character) || character.isNumber || character == "-" || character == "."
  }

  private static func isMarkupAttributeBoundary(_ character: Character) -> Bool {
    character.isWhitespace || character == "=" || character == ">" || character == "/"
      || character == "?"
  }

  private static func color(for token: String, language: String) -> Color {
    let keywords: Set<String> = [
      "actor", "as", "async", "await", "case", "catch", "class", "const", "default", "defer", "do",
      "else",
      "enum", "export", "false", "final", "for", "func", "function", "guard", "if", "import", "in",
      "let",
      "nil", "null", "private", "public", "return", "self", "static", "struct", "switch", "throw",
      "throws",
      "true", "try", "var", "while",
    ]
    if keywords.contains(token) {
      return .purple
    }
    if token.allSatisfy(\.isNumber) {
      return .orange
    }
    if token.hasPrefix("//") || token.hasPrefix("#") {
      return .secondary
    }
    return .primary
  }
}
