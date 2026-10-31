import SwiftUI

/// A compact row below the chat title, with independent trailing controls.
struct ChatTitleBar<Actions: View>: View {
  let title: String
  var subtitle: String? = nil
  let systemImage: String
  var onTap: (() -> Void)? = nil
  @ViewBuilder var actions: () -> Actions

  var body: some View {
    HStack(spacing: 12) {
      Button(action: { onTap?() }) {
        HStack(spacing: 10) {
          Image(systemName: systemImage).foregroundStyle(.tint)
          VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
              Text(subtitle).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(onTap == nil)
      actions().buttonStyle(.borderless)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}
