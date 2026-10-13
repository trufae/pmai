import XCTest

@testable import PocketMai

final class MarkdownInlineSymbolsTests: XCTestCase {
  func testNumericMathDelimiters() {
    for (source, expected) in [
      ("$628363$", "628363"),
      ("$10$", "10"),
      ("$1.5$", #"1\.5"#),
      ("$1,5$", "1,5"),
      ("$-12.5$", #"\-12\.5"#),
      ("$+3$", #"\+3"#),
      ("$$10$$", "10"),
      (#"\(10\)"#, "10"),
      (#"\[1.5\]"#, #"1\.5"#),
      ("2. $10$: Es la base.", "2. 10: Es la base."),
      ("**$10$** and $1.5$", #"**10** and 1\.5"#),
    ] {
      XCTAssertTrue(MarkdownInlineSymbols.containsMathSyntax(source), source)
      XCTAssertEqual(MarkdownInlineSymbols.displayString(source), expected, source)
    }
  }

  func testLiteralDollarsAndCodeStayUnchanged() {
    for source in [
      "$628363", "$1.5", "$5 and $10", "$5 $10", "$5$10", "$5\n$10",
      #"\$10\$"#, "`$10$`", "``$1.5$``",
    ] {
      XCTAssertFalse(MarkdownInlineSymbols.containsMathSyntax(source), source)
      XCTAssertEqual(MarkdownInlineSymbols.displayString(source), source, source)
    }
  }

  func testExistingMathStillRenders() {
    XCTAssertEqual(MarkdownInlineSymbols.displayString("$x$ and $10^8$"), "x and 10⁸")
  }
}
