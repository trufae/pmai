import Foundation
import MaiChat
import MaiCore

#if os(iOS)
  import SwiftUI
#else
  import SwiftUICore
#endif

/// All screens are Swift. This intentionally uses the common SwiftUI subset,
/// so the same views can also be hosted by Apple's SwiftUI on iOS.
@MainActor
public struct PocketMaiView: @preconcurrency View {
  @Bindable private var store: PortableChat
  @State private var tab = 0
  @State private var promptName = ""
  @State private var promptText = ""
  @State private var editingPromptID: UUID?

  public init(store: PortableChat) { self.store = store }

  public var body: some View {
    VStack(spacing: 8) {
      Text("PocketMai").font(.title2)
      if let error = store.errorMessage {
        Text(error).foregroundColor(.red).font(.caption)
        Button("Dismiss") { store.errorMessage = nil }
      }
      if !store.status.isEmpty { Text(store.status).font(.caption) }
      TabView(selection: $tab) {
        chatView.tabItem { Text("Chat") }.tag(0)
        providerView.tabItem { Text("Provider") }.tag(1)
        promptsView.tabItem { Text("Prompts") }.tag(2)
        historyView.tabItem { Text("History") }.tag(3)
      }
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var chatView: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(store.chat.displayTitle).font(.headline)
        Spacer()
        Button("New chat") { perform { try store.newChat() } }
          .disabled(store.isGenerating)
      }
      Text(store.model.isEmpty ? "Set up a provider and choose a model" : store.model)
        .font(.caption)
      promptPicker.disabled(store.isGenerating)
      // Keep the composer before the expanding message pane. The portable
      // renderer does not yet implement SwiftUI's weighted stack sizing.
      TextField("Message", text: $store.draft)
        .submitLabel(.send)
        .onSubmit { store.sendDraft() }
      HStack {
        Button("Send") { store.sendDraft() }
          .disabled(
            store.isGenerating || store.isLoadingModels
              || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        if store.isGenerating { Button("Stop") { store.stop() } }
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          ForEach(store.messages) { message in
            VStack(alignment: .leading, spacing: 4) {
              Text(message.role == .user ? "You" : "Assistant").font(.headline)
              Text(message.text)
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          if store.isGenerating {
            VStack(alignment: .leading, spacing: 4) {
              Text(store.streamedText.isEmpty ? "Thinking…" : "Assistant").font(.headline)
              Text(store.streamedText)
            }
          }
        }
      }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var providerView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("OpenAI-compatible provider").font(.headline)
        TextField("Base URL (including /v1)", text: $store.baseURL).keyboardType(.URL)
        SecureField("API key (optional for local servers)", text: $store.apiKey)
        TextField("Model ID", text: $store.model)
        Button("Save provider") { perform { try store.saveProvider() } }
        Button(store.isLoadingModels ? "Loading models…" : "List models") {
          store.discoverModels()
        }
        if !store.models.isEmpty {
          Picker(
            "Model",
            selection: Binding(
              get: { store.model },
              set: { id in perform { try store.chooseModel(id) } }
            )
          ) {
            ForEach(store.models) { model in
              Text(model.id).tag(model.id)
            }
          }
          Text("\(store.models.count) models").font(.caption)
        }
        Text(
          "For a local server, use an address your phone can reach. You can also enter a model ID manually."
        )
        .font(.caption)
      }.disabled(store.isGenerating || store.isLoadingModels)
    }
  }

  private var promptPicker: some View {
    Picker(
      "System prompt",
      selection: Binding(
        get: { store.selectedPromptID },
        set: { id in perform { try store.selectPrompt(id) } }
      )
    ) {
      ForEach(store.prompts) { prompt in
        Text(prompt.displayName).tag(prompt.id.uuidString)
      }
    }
  }

  private var promptsView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("System prompts").font(.headline)
        promptPicker
        HStack {
          Button("Edit selected") {
            guard let prompt = store.selectedPrompt else { return }
            editingPromptID = prompt.id
            promptName = prompt.name
            promptText = prompt.text
          }
          Button("New prompt") {
            editingPromptID = nil
            promptName = ""
            promptText = ""
          }
        }
        TextField("Prompt name", text: $promptName)
        TextField("Instructions", text: $promptText)
        Button("Save prompt") {
          perform {
            let saved = try store.savePrompt(
              id: editingPromptID, name: promptName, text: promptText)
            editingPromptID = saved.id
          }
        }
        if let selected = store.selectedPrompt {
          Text(selected.text).font(.caption)
        }
      }.disabled(store.isGenerating)
    }
  }

  private var historyView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text("Saved chats").font(.headline)
        if store.chats.isEmpty { Text("Your conversations will appear here.") }
        ForEach(store.chats) { chat in
          Button(chat.displayTitle) {
            perform {
              try store.openChat(chat.id)
              tab = 0
            }
          }.disabled(store.isGenerating)
        }
      }
    }
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { store.errorMessage = error.localizedDescription }
  }
}
