import AppKit
import SwiftUI

/// One saved size for conversation text, including Markdown and the composer.
struct MacChatTypography: DynamicProperty {
  static let defaultSize = NSFont.preferredFont(forTextStyle: .body).pointSize
  static let sizeRange = 10.0...36.0
  @AppStorage("mac.chat.fontSize") var size = defaultSize

  private var scale: CGFloat {
    min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size)) / Self.defaultSize
  }

  func font(_ style: NSFont.TextStyle = .body, design: Font.Design = .default) -> Font {
    .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * scale, design: design)
  }

  var editorFont: NSFont { .systemFont(ofSize: Self.defaultSize * scale) }

  func resize(by delta: Double) {
    size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size + delta))
  }
}

struct MacChatFontCommands: Commands {
  private var typography = MacChatTypography()

  var body: some Commands {
    CommandGroup(after: .sidebar) {
      Divider()
      Button("Bigger Chat Text") { typography.resize(by: 1) }
        .keyboardShortcut("+", modifiers: .command)
        .disabled(typography.size >= MacChatTypography.sizeRange.upperBound)
      Button("Smaller Chat Text") { typography.resize(by: -1) }
        .keyboardShortcut("-", modifiers: .command)
        .disabled(typography.size <= MacChatTypography.sizeRange.lowerBound)
      Button("Actual Chat Text Size") { typography.size = MacChatTypography.defaultSize }
        .keyboardShortcut("0", modifiers: .command)
    }
  }
}
