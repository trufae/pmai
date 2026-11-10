import AppKit
import SwiftUI

/// Appearance belongs to this Mac, independently of the connected workspace.
struct MacAppearance: DynamicProperty {
  @AppStorage("mac.appearance.accentColor") var accentHex = ""

  var accentColor: Color {
    guard accentHex.count == 6, let rgb = UInt32(accentHex, radix: 16) else {
      return Color(nsColor: .controlAccentColor)
    }
    return Color(.sRGB, red: Double((rgb >> 16) & 255) / 255,
      green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
  }

  var accentBinding: Binding<Color> {
    Binding(get: { accentColor }, set: { color in
      guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
      let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
        Int((min(1, max(0, $0)) * 255).rounded())
      }
      accentHex = String(format: "%02X%02X%02X",
        components[0], components[1], components[2])
    })
  }
}
