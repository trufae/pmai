import Foundation
import Testing

@testable import MaiMarkdown

private func stripANSI(_ text: String) -> String {
  var result = ""
  var iterator = text.makeIterator()
  while let char = iterator.next() {
    guard char == "\u{1B}" else {
      result.append(char)
      continue
    }
    guard let next = iterator.next() else { break }
    if next == "[" {
      while let c = iterator.next(), !(c.isLetter) {}
    } else if next == "]" {
      // OSC ... ESC \
      var previous: Character?
      while let c = iterator.next() {
        if previous == "\u{1B}", c == "\\" { break }
        previous = c
      }
    }
  }
  return result
}

private let sampleDocument = """
  # Title with **bold**

  Intro paragraph with *italic*, `code`, ~~gone~~, and a [link](https://example.com/a).
  Second line ends with two spaces  
  and a <br> break.

  ## Lists

  - first **item**
  - second with `code`
    - nested item
  1. one
  2. two
  - [ ] todo
  - [x] done

  > quoted *text*
  > more quote

  ```swift
  let x = "```not a fence"
  print(x)
  ```

  | Name | Value | Note |
  |:-----|------:|:----:|
  | **bold cell** | `code` | [doc](https://example.com/doc) |
  | plain | 42 | a fairly long note that needs wrapping inside the cell |

  ---

  [^1]: A footnote.
  Final paragraph with an unmatched * star and a_b_c words.
  """

@Test("Inline parser recognises emphasis, code, strikethrough, and links")
func inlineRuns() {
  let runs = MarkdownInlineParser.runs(
    from: "plain **bold** *it* `co de` ~~gone~~ [site](https://x.y) snake_case \\*lit\\* &amp;")
  #expect(
    runs == [
      MarkdownInlineRun("plain "),
      MarkdownInlineRun("bold", style: .bold),
      MarkdownInlineRun(" "),
      MarkdownInlineRun("it", style: .italic),
      MarkdownInlineRun(" "),
      MarkdownInlineRun("co de", style: .code),
      MarkdownInlineRun(" "),
      MarkdownInlineRun("gone", style: .strikethrough),
      MarkdownInlineRun(" "),
      MarkdownInlineRun("site", style: .link, destination: "https://x.y"),
      MarkdownInlineRun(" snake_case *lit* &"),
    ])
  #expect(
    MarkdownInlineParser.runs(from: "***both*** and **nested *em* here**") == [
      MarkdownInlineRun("both", style: [.bold, .italic]),
      MarkdownInlineRun(" and "),
      MarkdownInlineRun("nested ", style: .bold),
      MarkdownInlineRun("em", style: [.bold, .italic]),
      MarkdownInlineRun(" here", style: .bold),
    ])
  #expect(
    MarkdownInlineParser.plainText("a * b *c* <http://h.o> ![alt](i.png)")
      == "a * b c http://h.o alt")
}

@Test("LaTex formula delimiters and text commands are terminal-friendly")
func latexRendering() {
  let source = """
    $$\\text{Throughput} = \\frac{\\text{Total Tokens Transfered}}{\\text{Total Time (seconds)}}$$
    Higher Score $\\rightarrow$ More Efficient: $\\frac{\\text{Tokens}}{\\text{Time} \\times \\text{Requests}}$.
    """
  let output = stripANSI(MarkdownTerminalRenderer.render(source, theme: .plain))
  #expect(output.contains("Throughput = Total Tokens Transfered / Total Time (seconds)"))
  #expect(output.contains("Higher Score → More Efficient: Tokens / Time × Requests."))
  #expect(!output.contains("$"))
  #expect(!output.contains("\\\\text{"))

  var renderer = MarkdownTerminalRenderer(theme: .plain)
  #expect(renderer.feed("Rate: $$\\text{Through") == "Rate: ")
  #expect(renderer.feed("put} = \\frac{a}{b}$$") == "Throughput = a / b")
}

@Test("LaTex commands become Unicode symbols, scripts, roots, and accents")
func latexSymbols() {
  func render(_ source: String) -> String {
    stripANSI(MarkdownTerminalRenderer.render(source, theme: .plain))
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
  #expect(
    render("• Compaction logic $\\rightarrow$ summary requests $\\rightarrow$ error handling.")
      == "• Compaction logic → summary requests → error handling.")
  #expect(
    render("$x \\in \\mathbb{R}$, $A \\subseteq B$, $p \\land q \\Rightarrow \\neg r$, $\\forall x \\exists y$")
      == "x ∈ ℝ, A ⊆ B, p ∧ q ⇒ ¬r, ∀x ∃y")
  #expect(
    render("$x^2 + e^{-x} = \\sum_{i=1}^{n} a_i$ and $10^{-3}$, $\\text{TPS}_{\\text{output}}$, $\\lim_{x \\to 0}$")
      == "x² + e⁻ˣ = Σᵢ₌₁ⁿ aᵢ and 10⁻³, TPS_output, lim_(x → 0)")
  #expect(
    render("$\\sqrt{2}$, $\\sqrt{x+1}$, $\\sqrt[3]{8}$, $\\frac12$, $\\binom{n}{k}$, $\\int_0^1 f(x)\\,dx$")
      == "√2, √(x+1), ³√8, 1 / 2, C(n, k), ∫₀¹ f(x) dx")
  #expect(
    render("$a \\not\\in B$, $a \\not= b$, $90^\\circ$, $\\hat{x}$, $\\vec{v}$, $\\overline{AB}$, $\\boxed{42}$")
      == "a ∉ B, a ≠ b, 90°, x\u{0302}, v\u{20D7}, AB, [42]")
  #expect(
    render("$\\left( \\alpha + \\Omega \\right)$, $\\langle a, b \\rangle$, $\\|v\\|$, $a \\ll b \\cdots$, $\\mathbf{v} \\cdot \\nabla$")
      == "( α + Ω ), ⟨a, b⟩, ‖v‖, a ≪ b ⋯, v · ∇")
  #expect(render("it costs $5 and $10 total, or $ 20") == "it costs $5 and $10 total, or $ 20")
}

@Test("Streamable length stops before unfinished constructs")
func streamableLength() {
  #expect(MarkdownInlineParser.streamableLength(of: "Hello world") == 6)
  #expect(MarkdownInlineParser.streamableLength(of: "Hello world ") == 12)
  #expect(MarkdownInlineParser.streamableLength(of: "Hello **wor") == 6)
  #expect(MarkdownInlineParser.streamableLength(of: "see `a b` now [x](y) `open") == 21)
  #expect(MarkdownInlineParser.streamableLength(of: "**bold** text") == 9)
  #expect(MarkdownInlineParser.streamableLength(of: "**bold**") == 0)
  #expect(MarkdownInlineParser.streamableLength(of: "link [text](ur") == 5)
}

@Test("Line classifier distinguishes block kinds")
func lineKinds() {
  #expect(MarkdownLineClassifier.classify("## Heading ") == .heading(level: 2, text: "Heading "))
  #expect(MarkdownLineClassifier.classify("- item") == .bullet(indent: 0, text: "item"))
  #expect(MarkdownLineClassifier.classify("  - nested") == .bullet(indent: 1, text: "nested"))
  #expect(
    MarkdownLineClassifier.classify("3) third") == .ordered(indent: 0, label: "3)", text: "third"))
  #expect(
    MarkdownLineClassifier.classify("- [x] done") == .task(indent: 0, checked: true, text: "done"))
  #expect(MarkdownLineClassifier.classify("- [link](u)") == .bullet(indent: 0, text: "[link](u)"))
  #expect(MarkdownLineClassifier.classify("> quote") == .quote("quote"))
  #expect(MarkdownLineClassifier.classify("***") == .rule)
  #expect(MarkdownLineClassifier.classify("**bold** start") == .paragraph("**bold** start"))
  #expect(MarkdownLineClassifier.classify("```swift ") == .fence(language: "swift"))
  #expect(MarkdownLineClassifier.classify("[^1]: note") == .footnote(key: "1", text: "note"))
  #expect(MarkdownLineClassifier.classify("#hashtag") == .paragraph("#hashtag"))
  #expect(MarkdownLineClassifier.classify("   ") == .blank)

  #expect(MarkdownLineClassifier.analyze(Array("-"), complete: false) == .needMore)
  #expect(MarkdownLineClassifier.analyze(Array("--"), complete: false) == .needMore)
  #expect(MarkdownLineClassifier.analyze(Array("- ["), complete: false) == .needMore)
  #expect(
    MarkdownLineClassifier.analyze(Array("**b"), complete: false)
      == .decided(.paragraph, contentStart: 0))
  #expect(MarkdownLineClassifier.analyze(Array("| a"), complete: false) == .hold)
  #expect(MarkdownLineClassifier.analyze(Array("``"), complete: false) == .needMore)
  #expect(MarkdownLineClassifier.analyze(Array("1"), complete: false) == .needMore)
  #expect(
    MarkdownLineClassifier.analyze(Array("1. x"), complete: false)
      == .decided(.ordered(indent: 0, label: "1."), contentStart: 2))
}

@Test("Streaming in any chunk size renders the same bytes as one shot")
func streamingMatchesOneShot() {
  let options = MarkdownLayoutOptions(width: 60, unicode: true)
  let expected = MarkdownTerminalRenderer.render(
    sampleDocument, theme: MarkdownTerminalTheme(), options: options)
  let chars = Array(sampleDocument)
  for size in [1, 2, 3, 5, 7, 11, 29, 64, 257, chars.count] {
    var renderer = MarkdownTerminalRenderer(theme: MarkdownTerminalTheme(), options: options)
    var output = ""
    var index = 0
    while index < chars.count {
      let end = min(chars.count, index + size)
      output += renderer.feed(String(chars[index..<end]))
      index = end
    }
    output += renderer.flush()
    #expect(output == expected, "chunk size \(size)")
  }
}

@Test("Partial lines are emitted up to the last safe word boundary")
func partialEmission() {
  var renderer = MarkdownTerminalRenderer(theme: .plain, options: MarkdownLayoutOptions(width: 40))
  #expect(renderer.feed("Hello **wor") == "Hello ")
  #expect(renderer.feed("ld** and more") == "\u{1B}[1mworld\u{1B}[0m and ")
  #expect(renderer.feed("\n- ite") == "more\n• ")
  #expect(renderer.feed("m one\n") == "item one\n")
  #expect(renderer.feed("## He") == "")
  #expect(renderer.feed("ad\n") == "\u{1B}[1mHead\u{1B}[0m\n")
  #expect(renderer.feed("```py\nprint(1") == "\u{1B}[2m```py\u{1B}[0m\nprint(1")
  #expect(renderer.feed(")\n``") == ")\n")
  #expect(renderer.feed("`\ntail") == "\u{1B}[2m```\u{1B}[0m\n")
  #expect(renderer.flush() == "tail")
}

@Test("Tables buffer until complete, then render with styled cells")
func tableRendering() {
  let source = """
    | Name | Value | Note |
    |:-----|------:|:----:|
    | **bold** | `code` | [doc](https://example.com/d) |
    | plain | 42 | centered |
    """
  var renderer = MarkdownTerminalRenderer(theme: .plain, options: MarkdownLayoutOptions(width: 70))
  #expect(renderer.feed("| Name | Value | Note |\n|:-----|------:|:----:|\n") == "")
  #expect(renderer.feed("| **bold** | `code` | [doc](https://example.com/d) |\n") == "")
  let output = renderer.feed("| plain | 42 | centered |\nafter\n")
  let plain = stripANSI(output)
  let lines = plain.split(separator: "\n").map(String.init)
  #expect(lines[0] == "┌───────┬───────┬─────────────────────────────┐")
  #expect(lines[1] == "│ Name  │ Value │            Note             │")
  #expect(lines[2] == "├───────┼───────┼─────────────────────────────┤")
  #expect(lines[3] == "│ bold  │  code │ doc (https://example.com/d) │")
  #expect(lines[4] == "│ plain │    42 │          centered           │")
  #expect(lines[5] == "└───────┴───────┴─────────────────────────────┘")
  #expect(lines[6] == "after")
  #expect(output.contains("\u{1B}[1mbold\u{1B}[0m"))
  #expect(output.contains("\u{1B}[4mdoc\u{1B}[0m"))

  let oneShot = stripANSI(
    MarkdownTerminalRenderer.render(
      source, theme: .plain, options: MarkdownLayoutOptions(width: 70)))
  #expect(oneShot.split(separator: "\n").map(String.init) == Array(lines.prefix(6)))
}

@Test("Wide tables shrink and wrap cells without losing styles")
func tableWrapping() {
  let source = """
    | Key | Description |
    |-----|-------------|
    | one | a **fairly long description** that must wrap across several lines |
    | two | short |
    """
  let output = MarkdownTerminalRenderer.render(
    source, theme: .plain, options: MarkdownLayoutOptions(width: 34, unicode: false))
  let lines = stripANSI(output).split(separator: "\n").map(String.init)
  #expect(lines.allSatisfy { MarkdownDisplayWidth.width(of: $0) <= 34 })
  #expect(lines.first == "+-----+--------------------------+")
  #expect(lines.contains("| one | a fairly long            |"))
  #expect(lines.contains("|     | description that must    |"))
  #expect(lines.contains("| two | short                    |"))
  #expect(output.contains("\u{1B}[1mfairly long\u{1B}[0m"))
  #expect(output.contains("\u{1B}[1mdescription\u{1B}[0m that must"))
  #expect(lines.filter { $0 == "+-----+--------------------------+" }.count == 4)
}

@Test("Block elements render with markers, colours, and ASCII fallbacks")
func blockRendering() {
  let source = """
    # Head
    > quote
    - [ ] todo
      1. sub
    ---
    ```
    code
    ```
    """
  let colored = MarkdownTerminalRenderer.render(source, options: MarkdownLayoutOptions(width: 20))
  #expect(colored.hasPrefix("\u{1B}[95;1mHead\u{1B}[0m\n"))
  #expect(colored.contains("\u{1B}[90;3m│ quote\u{1B}[0m\n"))
  #expect(colored.contains("\u{1B}[93m☐ \u{1B}[0mtodo\n"))
  #expect(colored.contains("\u{1B}[93m  1. \u{1B}[0msub\n"))
  #expect(colored.contains("\u{1B}[90m────────────────────\u{1B}[0m\n"))
  #expect(
    colored.contains("\u{1B}[90m```\u{1B}[0m\n\u{1B}[92mcode\u{1B}[0m\n\u{1B}[90m```\u{1B}[0m"))

  let ascii = stripANSI(
    MarkdownTerminalRenderer.render(
      source, theme: .plain, options: MarkdownLayoutOptions(width: 20, unicode: false)))
  #expect(ascii.contains("| quote\n[ ] todo\n  1. sub\n--------------------\n```\ncode\n```"))
}

@Test("Layout lines carry roles for the visual mode")
func styledLines() {
  let lines = MarkdownStreamLayout.lines(
    for: "## T\n\ntext **b**", options: MarkdownLayoutOptions(width: 30))
  #expect(lines.count == 3)
  #expect(lines[0] == [MarkdownSpan("T", MarkdownSpanStyle(role: .heading(2)))])
  #expect(lines[1] == [])
  #expect(lines[2] == [MarkdownSpan("text "), MarkdownSpan("b", MarkdownSpanStyle(inline: .bold))])
}

@Test("Terminal environment detection")
func environmentDetection() {
  let dumb = MarkdownTerminalEnvironment.detect(["TERM": "dumb", "LANG": "en_US.UTF-8"])
  #expect(dumb == MarkdownTerminalEnvironment(colors: false, hyperlinks: false, unicode: true))
  let noColor = MarkdownTerminalEnvironment.detect(["NO_COLOR": "1", "LANG": "C"])
  #expect(noColor == MarkdownTerminalEnvironment(colors: false, hyperlinks: false, unicode: false))
  let full = MarkdownTerminalEnvironment.detect(["TERM": "xterm-256color"])
  #expect(full == MarkdownTerminalEnvironment(colors: true, hyperlinks: true, unicode: true))

  let linked = MarkdownTerminalRenderer.render(
    "[x](https://e.com)", theme: MarkdownTerminalTheme(colors: false, hyperlinks: true))
  #expect(
    linked
      == "\u{1B}[4m\u{1B}]8;;https://e.com\u{1B}\\x\u{1B}]8;;\u{1B}\\\u{1B}[0m\u{1B}[2m (https://e.com)\u{1B}[0m"
  )
}

@Test("Display width counts wide glyphs as two cells")
func displayWidth() {
  #expect(MarkdownDisplayWidth.width(of: "abc") == 3)
  #expect(MarkdownDisplayWidth.width(of: "日本") == 4)
  #expect(MarkdownDisplayWidth.width(of: "e\u{301}") == 1)
  #expect(MarkdownDisplayWidth.width(of: "🙂") == 2)
}
