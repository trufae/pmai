import AppKit
import SwiftUI

struct MacChatFont: RawRepresentable, Hashable, Identifiable {
  let rawValue: String
  var id: String { rawValue }

  static let system = Self(rawValue: "system")
  static let serif = Self(rawValue: "serif")
  static let rounded = Self(rawValue: "rounded")
  static let monospaced = Self(rawValue: "monospaced")
  static let presets: [Self] = [.system, .serif, .rounded, .monospaced]

  static func installed(_ name: String) -> Self { Self(rawValue: "installed:" + name) }

  var installedFont: NSFont? {
    guard rawValue.hasPrefix("installed:") else { return nil }
    return NSFont(name: String(rawValue.dropFirst("installed:".count)), size: MacChatTypography.defaultSize)
  }

  var displayName: String {
    if Self.presets.contains(self) { return rawValue.capitalized }
    return installedFont?.displayName ?? String(rawValue.dropFirst("installed:".count))
  }

  func font(size: CGFloat) -> Font {
    switch self {
    case .system: .system(size: size)
    case .serif: .system(size: size, design: .serif)
    case .rounded: .system(size: size, design: .rounded)
    case .monospaced: .system(size: size, design: .monospaced)
    default: Font(nsFont(size: size))
    }
  }

  func nsFont(size: CGFloat) -> NSFont {
    let system = NSFont.systemFont(ofSize: size)
    let design: NSFontDescriptor.SystemDesign
    switch self {
    case .system: return system
    case .serif: design = .serif
    case .rounded: design = .rounded
    case .monospaced: design = .monospaced
    default:
      guard let installedFont else { return system }
      return NSFont(descriptor: installedFont.fontDescriptor, size: size) ?? system
    }
    guard let descriptor = system.fontDescriptor.withDesign(design) else { return system }
    return NSFont(descriptor: descriptor, size: size) ?? system
  }
}

struct MacChatFontPicker: View {
  let title: String
  @Binding var selection: MacChatFont
  @State private var families = NSFontManager.shared.availableFontFamilies.sorted {
    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
  }

  private var family: String? { selection.installedFont?.familyName }

  private var faces: [MacChatFont] {
    guard let family else { return [] }
    return (NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []).compactMap {
      ($0.first as? String).map(MacChatFont.installed)
    }
  }

  private var familySelection: Binding<String> {
    Binding(get: { family.map { "family:" + $0 } ?? selection.rawValue }, set: { value in
      if value.hasPrefix("family:") {
        let name = String(value.dropFirst("family:".count))
        if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5,
          size: MacChatTypography.defaultSize) {
          selection = .installed(font.fontName)
        }
      } else {
        selection = MacChatFont(rawValue: value)
      }
    })
  }

  var body: some View {
    Picker(title, selection: familySelection) {
      ForEach(MacChatFont.presets) { font in Text(font.displayName).tag(font.rawValue) }
      Divider()
      ForEach(families, id: \.self) { name in Text(name).tag("family:" + name) }
      if family == nil, !MacChatFont.presets.contains(selection) {
        Text(selection.displayName + " (Unavailable)").tag(selection.rawValue)
      }
    }
    if !faces.isEmpty {
      Picker("\(title) style", selection: $selection) {
        ForEach(faces) { font in
          Text(font.installedFont?.fontDescriptor.object(forKey: .face) as? String ?? font.displayName)
            .tag(font)
        }
      }
    }
  }
}

struct MacChatFontSettings: View {
  private var typography = MacChatTypography()

  var body: some View {
    MacChatFontPicker(title: "User font", selection: typography.$userFont)
    MacChatFontPicker(title: "Assistant font", selection: typography.$assistantFont)
    Stepper(value: typography.$size, in: MacChatTypography.sizeRange, step: 0.5) {
      Text("Text size: \(typography.size.formatted(.number.precision(.fractionLength(0...1)))) pt")
    }
    VStack(alignment: .leading, spacing: 8) {
      Text("User: The quick brown fox jumps over the lazy dog.")
        .font(typography.messageFont(for: "user"))
      Text("Assistant: The quick brown fox jumps over the lazy dog.")
        .font(typography.messageFont(for: "assistant"))
    }
    .padding(.vertical, 4)
    Button("Reset Chat Fonts") {
      typography.userFont = .rounded
      typography.assistantFont = .serif
      typography.size = MacChatTypography.defaultSize
    }
  }
}
