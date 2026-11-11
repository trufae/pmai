import SwiftUI

struct MessageDetailsPopover: View {
  @Environment(\.dismiss) private var dismiss
  let message: ChatMessage
  let conversationCreatedAt: Date?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Details").font(.headline)
        Spacer()
        Button("Done") { dismiss() }
      }
      Divider()
      LabeledContent("Sender", value: message.role.displayName)
      LabeledContent("Sent", value: ConversationDatePresentation.timestamp(message.createdAt))
      if let conversationCreatedAt {
        LabeledContent("Chat started", value: ConversationDatePresentation.timestamp(conversationCreatedAt))
      }
      if let stats = message.stats {
        Divider()
        LabeledContent("Provider", value: stats.providerLabel)
        LabeledContent("Model", value: stats.modelID)
        Text(stats.summary)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      if !message.attachments.isEmpty {
        LabeledContent("Attachments", value: message.attachments.count.formatted())
      }
    }
    .font(.subheadline)
    .textSelection(.enabled)
    .padding(16)
    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
  }
}

struct MessageSpeechPopover: View {
  @Environment(\.dismiss) private var dismiss
  @State private var language: String?
  let onSpeakMessage: (String?) -> Void
  let onSpeakFromHere: ((String?) -> Void)?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Speak").font(.headline)
        Spacer()
        Button("Cancel") { dismiss() }
      }
      Picker("Language", selection: $language) {
        Text("Default Voices").tag(String?.none)
        Text("System Default").tag(String?.some(""))
        ForEach(SystemLanguageSupport.textToSpeechLanguageIdentifiers, id: \.self) { identifier in
          Text(SystemLanguageSupport.languageDisplayName(identifier)).tag(String?.some(identifier))
        }
      }
      .pickerStyle(.menu)
      .frame(maxWidth: .infinity, alignment: .leading)
      Divider()
      Button {
        onSpeakMessage(language)
      } label: {
        Label("Only This Message", systemImage: "text.bubble")
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 8)
          .contentShape(Rectangle())
      }
      if let onSpeakFromHere {
        Button {
          onSpeakFromHere(language)
        } label: {
          Label("All Messages From Here", systemImage: "text.bubble.fill")
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
      }
    }
    .buttonStyle(.plain)
    .padding(16)
    .frame(minWidth: 280, idealWidth: 320, maxWidth: 360)
  }
}
