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
      ChatTitleBar(
        title: messages.count == 1 ? "Pinned message" : "Pinned messages · \(messages.count)",
        subtitle: preview(message), systemImage: "pin.fill",
        onTap: { onSelect(message.id) }
      ) {
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
    }
  }

  private func preview(_ message: ChatMessage) -> String {
    let text = MessageContentFilter.previewText(from: message.presentationText)
    let paragraph = TranscriptCopy.firstParagraph(text)
    return paragraph.isEmpty
      ? message.attachments.first?.filename ?? "\(message.role.displayName) message" : paragraph
  }
}
