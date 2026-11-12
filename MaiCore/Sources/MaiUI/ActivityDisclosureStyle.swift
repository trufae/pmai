import SwiftUI

/// Make the entire activity header a keyboard-accessible disclosure button.
public struct ActivityDisclosureStyle: DisclosureGroupStyle {
  public init() {}

  public func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        configuration.isExpanded.toggle()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          configuration.label
          Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
      if configuration.isExpanded {
        configuration.content
      }
    }
  }
}
