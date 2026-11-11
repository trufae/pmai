import Foundation

// The standalone editor does not link the CLI. Keep these samples consistent
// with TerminalOutputBuffer.userMessageRows and TerminalToolBlock: bubble tails,
// semantic tool parameters, background inheritance, and independently styled spans.
// Markdown colors follow TerminalWriter.configureMarkdown's role overrides.
struct PreviewSpan {
  var text: String
  var foreground = "foreground"
  var background = "background"
  var bold = false
  var italic = false
  var attributes = ""
  var flag: String?

  func roles(_ palette: [String: String]) -> Set<String> {
    var roles: Set<String> = [foreground, background]
    if let flag { roles.insert(flag) }
    if ["bubbleForeground", "boldForeground", "italicForeground"].contains(foreground),
      palette[foreground, default: ""].isEmpty { roles.insert("foreground") }
    if ["bubbleBackground", "promptBackground", "toolCallBackground", "toolResultBackground"]
      .contains(background), palette[background, default: ""].isEmpty { roles.insert("background") }
    return roles
  }

  func style(_ palette: [String: String], flashing: String?) -> String {
    let roles = roles(palette)
    let fg = palette[foreground, default: ""]
    let bg = palette[background, default: ""]
    let codes = [ThemeColor.code(fg.isEmpty && roles.contains("foreground")
        ? palette["foreground", default: ""] : fg),
      ThemeColor.code(bg.isEmpty && roles.contains("background")
        ? palette["background", default: ""] : bg, background: true),
      bold || flag.map { palette[$0] == "true" } == true ? "1" : "22",
      italic ? "3" : "23", attributes,
      flashing.map { roles.contains($0) ? "7" : "" } ?? ""].filter { !$0.isEmpty }
    return Terminal.reset + "\u{1b}[\(codes.joined(separator: ";"))m"
  }
}

struct PreviewLine {
  var spans: [PreviewSpan] = []
  var fill = PreviewSpan(text: "")

  func contains(_ field: String, palette: [String: String]) -> Bool {
    spans.contains { $0.roles(palette).contains(field) } || fill.roles(palette).contains(field)
  }

  // All fixture glyphs are one terminal cell. Clip before adding ANSI escapes.
  func render(width: Int, palette: [String: String], flashing: String?) -> String {
    var result = ""
    var remaining = width
    for span in spans {
      let text = String(span.text.prefix(max(0, remaining)))
      result += span.style(palette, flashing: flashing) + text
      remaining -= text.count
    }
    return result + fill.style(palette, flashing: flashing)
      + String(repeating: " ", count: max(0, remaining)) + Terminal.reset
  }
}

struct ThemePreview {
  let palette: [String: String]
  let width: Int
  var lines: [PreviewLine] = []

  init(palette: [String: String], width: Int) {
    self.palette = palette
    self.width = max(8, width)
    bubble("Update the greeting and add a test.")
    line("Thinking... inspecting the project", foreground: "thinkingForeground")
    tool("files_read", parameter: "path", value: "Sources/main.swift")
    line("← print(\"Hello\")", foreground: "toolResultForeground", background: "toolResultBackground")
    line("")
    line("Greeting update", foreground: "infoForeground", bold: true)
    wrapped([PreviewSpan(text: "I'll make the greeting "),
      PreviewSpan(text: "more welcoming", foreground: "boldForeground", bold: true),
      PreviewSpan(text: " and keep the change "),
      PreviewSpan(text: "small", foreground: "italicForeground", italic: true),
      PreviewSpan(text: ".")])
    tool("files_patch", parameter: "path", value: "Sources/main.swift")
    line("← --- a/Sources/main.swift", foreground: "diffHeaderForeground", background: "toolResultBackground")
    line("  +++ b/Sources/main.swift", foreground: "diffHeaderForeground", background: "toolResultBackground")
    line("  @@ -1 +1 @@", foreground: "diffHeaderForeground", background: "toolResultBackground")
    line("  - print(\"Hello\")", foreground: "diffRemovedForeground", background: "diffRemovedBackground")
    line("  + print(\"Hello, world!\")", foreground: "diffAddedForeground", background: "diffAddedBackground")
    line("")
    wrapped([PreviewSpan(text: "• ", foreground: "warningForeground"), PreviewSpan(text: "Updated "),
      PreviewSpan(text: "main.swift", foreground: "toolCallForeground"),
      PreviewSpan(text: " with the new greeting.")])
    wrapped([PreviewSpan(text: "• ", foreground: "warningForeground"), PreviewSpan(text: "Added a regression test.")])
    wrapped([PreviewSpan(text: "  ☑ ", foreground: "toolCallForeground"), PreviewSpan(text: "Greeting includes the audience")])
    wrapped([PreviewSpan(text: "  ☐ ", foreground: "warningForeground"), PreviewSpan(text: "Run the test suite")])
    line("│ Keep the output friendly and brief.", foreground: "thinkingForeground", italic: true)
    line("")
    bubble("Run the tests and show an example.")
    tool("run_shell", parameter: "command", value: "swift test", extra: ("timeout_seconds", "30"))
    line("← error: expected \"Hello\"", foreground: "errorForeground", background: "toolResultBackground")
    line("Warning: the old assertion needs updating.", foreground: "warningForeground")
    wrapped([PreviewSpan(text: "The test still expects "),
      PreviewSpan(text: "Hello", attributes: "9"), PreviewSpan(text: ". Updating it now.")])
    tool("files_patch", parameter: "path", value: "Tests/GreetingTests.swift")
    line("← Updated the expected greeting.", foreground: "toolResultForeground", background: "toolResultBackground")
    tool("run_shell", parameter: "command", value: "swift test")
    line("← Executed 1 test, 0 failures", foreground: "toolResultForeground", background: "toolResultBackground")
    line("✔ Tests passed. Greeting updated.", foreground: "successForeground")
    line("")
    line("Example", foreground: "diffHeaderForeground", bold: true)
    line("```swift", foreground: "thinkingForeground")
    line("print(\"Hello, world!\")", foreground: "toolCallForeground")
    line("```", foreground: "thinkingForeground")
    line("")
    line("File                 Result", bold: true)
    line("────────────────────────────", foreground: "thinkingForeground")
    line("main.swift           Updated")
    line("GreetingTests.swift  Passed")
    line("")
    wrapped([PreviewSpan(text: "See "),
      PreviewSpan(text: "the project guide", foreground: "diffHeaderForeground", attributes: "4"),
      PreviewSpan(text: " for more examples.")])
    line("Info: 2 files changed · 1 test passed", foreground: "infoForeground")
    line("")
    line("Conversations  /  search: greeting", foreground: "infoForeground")
    line("› Greeting update    just now", foreground: "selectionForeground", background: "selectionBackground")
    line("  Project setup      yesterday")
    line("")
    bubble("Thanks! Summarize what changed.")
    wrapped([PreviewSpan(text: "The app now prints "),
      PreviewSpan(text: "Hello, world!", foreground: "boldForeground", bold: true),
      PreviewSpan(text: ". The test checks the new text.")])
  }

  static func header(_ theme: String) -> PreviewLine {
    let span = PreviewSpan(text: " pmai · \(theme) · local / swift", foreground: "infoForeground",
      background: "backgroundLine")
    return PreviewLine(spans: [span], fill: span)
  }

  static var prompt: PreviewLine {
    PreviewLine(spans: [PreviewSpan(text: "> ", foreground: "promptForeground", background: "promptBackground"),
      PreviewSpan(text: "Ask a follow-up…", background: "promptBackground", flag: "bold")],
      fill: PreviewSpan(text: "", background: "promptBackground"))
  }

  mutating func line(_ text: String, foreground: String = "foreground", background: String = "background",
    bold: Bool = false, italic: Bool = false) {
    let span = PreviewSpan(text: text, foreground: foreground, background: background, bold: bold,
      italic: italic)
    wrapped([span], fill: PreviewSpan(text: "", background: background))
  }

  mutating func wrapped(_ spans: [PreviewSpan], fill: PreviewSpan = PreviewSpan(text: "")) {
    var row = PreviewLine(fill: fill)
    var used = 0
    for span in spans {
      // Keep words together where possible, including across styled spans.
      let words = span.text.split(separator: " ", omittingEmptySubsequences: false)
      for (index, word) in words.enumerated() {
        var text = (index == 0 ? "" : " ") + word
        if used > 0 && used + text.count > width && text.count <= width {
          lines.append(row); row = PreviewLine(fill: fill); used = 0
          if text.first == " " { text.removeFirst() }
        }
        while !text.isEmpty {
          if used == width { lines.append(row); row = PreviewLine(fill: fill); used = 0 }
          var part = span
          part.text = String(text.prefix(width - used))
          row.spans.append(part)
          used += part.text.count
          text.removeFirst(part.text.count)
        }
      }
    }
    lines.append(row)
  }

  mutating func tool(_ name: String, parameter: String, value: String, extra: (String, String)? = nil) {
    var spans = [PreviewSpan(text: "→ \(name) ", foreground: "toolCallForeground",
      background: "toolCallBackground", flag: "toolCallBold"),
      PreviewSpan(text: extra == nil ? "" : "\(parameter)=", foreground: "infoForeground",
        background: "toolCallBackground", flag: "toolCallBold"),
      PreviewSpan(text: value.contains(" ") ? "\"\(value)\"" : value, background: "toolCallBackground", flag: "toolCallBold")]
    if let extra {
      spans += [PreviewSpan(text: " \(extra.0)=", foreground: "infoForeground", background: "toolCallBackground", flag: "toolCallBold"),
        PreviewSpan(text: extra.1, background: "toolCallBackground", flag: "toolCallBold")]
    }
    wrapped(spans,
      fill: PreviewSpan(text: "", background: "toolCallBackground"))
  }

  mutating func bubble(_ text: String) {
    line("")
    // Same four-cell reservation and filled/outlined geometry as the REPL.
    var body: [String] = []
    var rest = text[...]
    while !rest.isEmpty {
      var count = min(width - 4, rest.count)
      if count < rest.count, let space = rest.prefix(count).lastIndex(of: " ") {
        count = rest.distance(from: rest.startIndex, to: space)
      }
      body.append(String(rest.prefix(count)))
      rest = rest.dropFirst(count)
      if rest.first == " " { rest = rest.dropFirst() }
    }
    let size = body.map(\.count).max() ?? 0
    let filled = !palette["bubbleBackground", default: ""].isEmpty
    let edge = PreviewSpan(text: "", foreground: filled ? "bubbleBackground" : "foreground")
    func edgeSpan(_ text: String) -> PreviewSpan { var span = edge; span.text = text; return span }
    lines.append(PreviewLine(spans: [edgeSpan(filled ? " " + String(repeating: "▂", count: size + 2)
      : " ╭" + String(repeating: "─", count: size + 1) + "╮")]))
    for (index, text) in body.enumerated() {
      lines.append(PreviewLine(spans: [edgeSpan((index == body.count - 1 ? "◢" : " ") + (filled ? "█" : "│")),
        PreviewSpan(text: text + String(repeating: " ", count: size - text.count + 1),
          foreground: "bubbleForeground", background: "bubbleBackground", flag: "bold"),
        edgeSpan(filled ? "" : "│")]))
    }
    lines.append(PreviewLine(spans: [edgeSpan(filled ? " " + String(repeating: "▔", count: size + 2)
      : " ╰" + String(repeating: "─", count: size + 1) + "╯")]))
    line("")
  }
}
