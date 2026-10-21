import MaiCore
import SwiftUI

/// Conversation pins navigate the complete transcript, including unloaded history.
struct PinnedMessagesBar: View {
  let messages: [ChatMessage]
  let onSelect: (UUID) -> Void
  let onUnpin: (UUID) -> Void
  @State private var selectedID: UUID?

  var body: some View {
    if let message = messages.first(where: { $0.id == selectedID }) ?? messages.first {
      HStack(spacing: 12) {
        Button {
          onSelect(message.id)
        } label: {
          HStack(spacing: 10) {
            Text("📌").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
              Text(messages.count == 1 ? "Pinned message" : "Pinned messages · \(messages.count)")
                .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
              Text(preview(message)).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Go to pinned message: \(preview(message))")
        Menu {
          ForEach(messages) { pinned in
            Button("📌 \(preview(pinned))") {
              selectedID = pinned.id
              onSelect(pinned.id)
            }
          }
          Divider()
          Button("Unpin Message", systemImage: "pin.slash") { onUnpin(message.id) }
        } label: {
          Image(systemName: "ellipsis").frame(width: 32, height: 32).contentShape(Rectangle())
        }
        .accessibilityLabel("Pinned message actions")
      }
      .padding(.horizontal, 16).padding(.vertical, 8)
      .background(.bar)
    }
  }

  private func preview(_ message: ChatMessage) -> String {
    let text = MessageContentFilter.previewText(from: message.presentationText)
    let paragraph = TranscriptCopy.firstParagraph(text)
    return paragraph.isEmpty
      ? message.attachments.first?.filename ?? "\(message.role.displayName) message" : paragraph
  }
}
