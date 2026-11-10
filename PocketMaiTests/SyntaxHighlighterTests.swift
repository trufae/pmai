import SwiftUI
import XCTest

@testable import PocketMai

final class SyntaxHighlighterTests: XCTestCase {
  func testBatchedHighlightingPreservesTextAndTokenColors() {
    let code = "let café = call(参数, \"👩‍💻\") + 42;\n\treturn café_2\n"
    let result = SyntaxHighlighter.highlight(code, language: "Swift")
    XCTAssertEqual(String(result.characters), code)
    for run in result.runs {
      let text = String(result.characters[run.range])
      let color: Color = text == "let" || text == "return" ? .purple : text == "42" ? .orange : .primary
      XCTAssertEqual(run.foregroundColor, color, text)
    }
    for language in ["", "unknown", "diff", "xml"] {
      let source = "  text & punctuation();\n\n界\n"
      XCTAssertEqual(String(SyntaxHighlighter.highlight(source, language: language).characters), source)
    }
  }
}
