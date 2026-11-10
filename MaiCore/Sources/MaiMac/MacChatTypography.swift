import AppKit
import SwiftUI

/// Saved message fonts and a shared size for Markdown and the composer.
struct MacChatTypography: DynamicProperty {
  // Match PocketMai's AppearanceSettings defaults.
  static let defaultSize = 17.0
  static let sizeRange = 10.0...36.0
  @AppStorage("mac.chat.fontSize") var size = defaultSize
  @AppStorage("mac.chat.userFont") var userFont = MacChatFont.rounded
  @AppStorage("mac.chat.assistantFont") var assistantFont = MacChatFont.serif

  private var scale: CGFloat {
    min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, size))
      / NSFont.preferredFont(forTextStyle: .body).pointSize
  }

  func font(_ style: NSFont.TextStyle = .body, design: Font.Design = .default) -> Font {
    .system(size: NSFont.preferredFont(forTextStyle: style).pointSize * scale, design: design)
  }

  func messageFont(for role: String, style: NSFont.TextStyle = .body) -> Font {
    let family = role == "user" ? userFont : assistantFont
    return family.font(size: NSFont.preferredFont(forTextStyle: style).pointSize * scale)
  }

  var editorFont: NSFont {
    userFont.nsFont(size: NSFont.preferredFont(forTextStyle: .body).pointSize * scale)
  }

  func resize(by delta: Double) {
    resize(to: size + delta)
  }

  func resize(to newSize: Double) {
    guard newSize.isFinite else { return }
    size = min(Self.sizeRange.upperBound, max(Self.sizeRange.lowerBound, (newSize * 2).rounded() / 2))
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
