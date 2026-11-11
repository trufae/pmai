import SwiftUI

struct MessageDetailsMenu: View {
  let message: ChatMessage
  let conversationCreatedAt: Date?

  var body: some View {
    Menu("Details", systemImage: "info.circle") {
      Text("Sender: \(message.role.displayName)")
      Text("Sent: \(ConversationDatePresentation.timestamp(message.createdAt))")
      if let conversationCreatedAt {
        Text("Chat started: \(ConversationDatePresentation.timestamp(conversationCreatedAt))")
      }
      if let stats = message.stats {
        Divider()
        Text("Provider: \(stats.providerLabel)")
        Text("Model: \(stats.modelID)")
        Text(stats.summary)
      }
      if !message.attachments.isEmpty {
        Text("Attachments: \(message.attachments.count.formatted())")
      }
    }
  }
}

struct MessageSpeechMenu: View {
  @State private var language: String?
  let onSpeakMessage: (String?) -> Void
  let onSpeakFromHere: ((String?) -> Void)?

  var body: some View {
    Menu("Speak", systemImage: "speaker.wave.2") {
      Picker("Language", selection: $language) {
        Text("Default Voices").tag(String?.none)
        Text("System Default").tag(String?.some(""))
        ForEach(SystemLanguageSupport.textToSpeechLanguageIdentifiers, id: \.self) { identifier in
          Text(SystemLanguageSupport.languageDisplayName(identifier)).tag(String?.some(identifier))
        }
      }
      .pickerStyle(.menu)
      .menuActionDismissBehavior(.disabled)
      Divider()
      Button("Only This Message", systemImage: "text.bubble") {
        onSpeakMessage(language)
      }
      if let onSpeakFromHere {
        Button("All Messages From Here", systemImage: "text.bubble.fill") {
          onSpeakFromHere(language)
        }
      }
    }
  }
}
