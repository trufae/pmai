import Foundation

/// How styled spans map to SGR attributes.
public struct MarkdownTerminalTheme: Equatable, Sendable {
  /// Emit colours; without them only bold, italic, underline, and dim are used.
  public var colors: Bool
  /// Wrap links in OSC 8 hyperlink sequences.
  public var hyperlinks: Bool
  /// Optional SGR color replacements supplied by the terminal's active palette.
  public var colorOverrides: [String: String] = [:]
  /// Optional SGR foreground parameters for inline emphasis. Bold wins when both apply.
  public var boldColor: String = ""
  public var italicColor: String = ""

  public init(colors: Bool = true, hyperlinks: Bool = false) {
    self.colors = colors
    self.hyperlinks = hyperlinks
  }

  public static let plain = MarkdownTerminalTheme(colors: false, hyperlinks: false)

  /// SGR parameters for a style, joined with `;`. Empty means default text.
  public func parameters(for style: MarkdownSpanStyle) -> String {
    var parameters =
      (colors ? colorParameters(for: style.role) : attributeParameters(for: style.role))
      .map { colorOverrides[$0] ?? $0 }
    let inline = style.inline
    if inline.contains(.bold) { parameters.append("1") }
    if inline.contains(.italic) { parameters.append("3") }
    if colors {
      if inline.contains(.bold), !boldColor.isEmpty {
        parameters.append(boldColor)
      } else if inline.contains(.italic), !italicColor.isEmpty {
        parameters.append(italicColor)
      }
    }
    if inline.contains(.strikethrough) { parameters.append("9") }
    if inline.contains(.link) {
      parameters.append("4")
      if colors { parameters.append(colorOverrides["96"] ?? "96") }
    }
    if inline.contains(.code), colors { parameters.append(colorOverrides["32"] ?? "32") }
    return parameters.filter { !$0.isEmpty }.joined(separator: ";")
  }

  private func colorParameters(for role: MarkdownTextRole) -> [String] {
    switch role {
    case .body: []
    case .heading(let level):
      switch level {
      case 1: ["95", "1"]
      case 2: ["94", "1"]
      case 3: ["96", "1"]
      case 4: ["34", "1"]
      case 5: ["36", "1"]
      default: ["90", "1"]
      }
    case .quote: ["90", "3"]
    case .code: ["92"]
    case .fence: ["90"]
    case .listMarker: ["93"]
    case .taskMarker(let checked): checked ? ["92"] : ["93"]
    case .linkDestination: ["90"]
    case .tableBorder: ["90"]
    case .tableHeader: ["1"]
    case .rule: ["90"]
    case .footnoteLabel: ["93"]
    }
  }

  private func attributeParameters(for role: MarkdownTextRole) -> [String] {
    switch role {
    case .body, .code, .listMarker, .taskMarker: []
    case .heading, .tableHeader, .footnoteLabel: ["1"]
    case .quote: ["3"]
    case .fence, .linkDestination, .tableBorder, .rule: ["2"]
    }
  }
}

/// Serialises layout events as text with ANSI escapes. It remembers the
/// active style, so a line rendered in pieces gets the same bytes as the line
/// rendered at once, and every line ends with attributes reset.
public struct MarkdownANSIEncoder: Equatable, Sendable {
  public var theme: MarkdownTerminalTheme
  private var current = ""

  public init(theme: MarkdownTerminalTheme = MarkdownTerminalTheme()) {
    self.theme = theme
  }

  public mutating func encode(_ events: [MarkdownLayoutEvent]) -> String {
    var output = ""
    for event in events {
      switch event {
      case .spans(let spans):
        for span in spans where !span.text.isEmpty {
          output += transition(to: theme.parameters(for: span.style))
          if theme.hyperlinks, let destination = span.destination, isHyperlinkTarget(destination) {
            output += "\u{1B}]8;;\(destination)\u{1B}\\\(span.text)\u{1B}]8;;\u{1B}\\"
          } else {
            output += span.text
          }
        }
      case .lineBreak:
        output += transition(to: "") + "\n"
      }
    }
    return output
  }

  /// Resets attributes if any are active, for the end of a document.
  public mutating func finish() -> String {
    transition(to: "")
  }

  private mutating func transition(to parameters: String) -> String {
    guard parameters != current else { return "" }
    var output = current.isEmpty ? "" : "\u{1B}[0m"
    if !parameters.isEmpty { output += "\u{1B}[\(parameters)m" }
    current = parameters
    return output
  }

  private func isHyperlinkTarget(_ destination: String) -> Bool {
    let lowercased = destination.lowercased()
    guard
      !destination.contains(where: { $0.isWhitespace || $0.asciiValue.map { $0 < 0x20 } ?? false })
    else { return false }
    return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
      || lowercased.hasPrefix("mailto:") || lowercased.hasPrefix("file://")
  }
}

/// Streams markdown to a terminal: layout plus ANSI encoding, with the table
/// width refreshed from the terminal before each chunk.
public struct MarkdownTerminalRenderer: Sendable {
  private var layout: MarkdownStreamLayout
  private var encoder: MarkdownANSIEncoder
  private let widthProvider: (@Sendable () -> Int)?

  public init(
    theme: MarkdownTerminalTheme = MarkdownTerminalTheme(),
    options: MarkdownLayoutOptions = MarkdownLayoutOptions(),
    widthProvider: (@Sendable () -> Int)? = nil
  ) {
    layout = MarkdownStreamLayout(options: options)
    encoder = MarkdownANSIEncoder(theme: theme)
    self.widthProvider = widthProvider
  }

  public var theme: MarkdownTerminalTheme {
    get { encoder.theme }
    set { encoder.theme = newValue }
  }

  public var options: MarkdownLayoutOptions {
    get { layout.options }
    set { layout.options = newValue }
  }

  /// Renders a chunk of a streaming reply; returns what to write now.
  public mutating func feed(_ chunk: String) -> String {
    refreshWidth()
    return encoder.encode(layout.feed(chunk))
  }

  /// Ends the reply: writes what was buffered and resets for the next one.
  public mutating func flush() -> String {
    refreshWidth()
    let output = encoder.encode(layout.flush()) + encoder.finish()
    reset()
    return output
  }

  public mutating func reset() {
    layout.reset()
    encoder = MarkdownANSIEncoder(theme: encoder.theme)
  }

  /// Renders a complete text with this renderer's settings.
  public func render(_ text: String) -> String {
    var copy = self
    copy.reset()
    return copy.feed(text) + copy.flush()
  }

  public static func render(
    _ text: String,
    theme: MarkdownTerminalTheme = MarkdownTerminalTheme(),
    options: MarkdownLayoutOptions = MarkdownLayoutOptions()
  ) -> String {
    MarkdownTerminalRenderer(theme: theme, options: options).render(text)
  }

  private mutating func refreshWidth() {
    guard let widthProvider else { return }
    layout.options.width = max(20, widthProvider())
  }
}

/// What the process environment says about the terminal's abilities.
public struct MarkdownTerminalEnvironment: Equatable, Sendable {
  public var colors: Bool
  public var hyperlinks: Bool
  public var unicode: Bool

  public init(colors: Bool, hyperlinks: Bool, unicode: Bool) {
    self.colors = colors
    self.hyperlinks = hyperlinks
    self.unicode = unicode
  }

  /// Honours `NO_COLOR`, `TERM=dumb`, and the locale's encoding.
  public static func detect(_ environment: [String: String]) -> MarkdownTerminalEnvironment {
    let term = environment["TERM"] ?? ""
    let dumb = term == "dumb"
    let noColor = !(environment["NO_COLOR"] ?? "").isEmpty
    let locale = ["LC_ALL", "LC_CTYPE", "LANG"].lazy
      .compactMap { environment[$0] }
      .first { !$0.isEmpty }
    let unicode = locale.map { $0.lowercased().contains("utf") } ?? true
    return MarkdownTerminalEnvironment(
      colors: !noColor && !dumb,
      hyperlinks: !noColor && !dumb,
      unicode: unicode)
  }

  public var theme: MarkdownTerminalTheme {
    MarkdownTerminalTheme(colors: colors, hyperlinks: hyperlinks)
  }
}
