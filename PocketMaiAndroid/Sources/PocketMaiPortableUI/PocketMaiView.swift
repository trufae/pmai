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
///
/// On Android a NavigationStack renders as a Material top app bar, and its
/// bottom toolbar as a bottom app bar. The portable TabView only renders text
/// labels, so the icon navigation bar is built from bottom toolbar buttons.
/// Colors are translucent so they read on both light and dark surfaces.
@MainActor
public struct PocketMaiView: @preconcurrency View {
  @Bindable private var store: PortableChat
  @State private var tab = Tab.chat
  @State private var promptName = ""
  @State private var promptText = ""
  @State private var editingPromptID: UUID?

  public init(store: PortableChat) { self.store = store }

  enum Tab: Int, CaseIterable {
    case chat, provider, prompts, history

    var title: String {
      switch self {
      case .chat: "Chat"
      case .provider: "Provider"
      case .prompts: "Prompts"
      case .history: "History"
      }
    }

    // SF Symbol names; the Android renderer maps these to Material icons.
    var icon: String {
      switch self {
      case .chat: "house"
      case .provider: "gearshape"
      case .prompts: "person"
      case .history: "calendar"
      }
    }
  }

  private static let accent = Color(red: 0.40, green: 0.31, blue: 0.64, opacity: 0.16)
  private static let subtle = Color(red: 0.5, green: 0.5, blue: 0.55, opacity: 0.12)
  /// Space for the bottom composer row: an outlined field plus its padding.
  private static let composerHeight = 84.0

  public var body: some View {
    NavigationStack {
      screen
        .navigationTitle(title)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            if tab == .chat {
              Button(action: { perform { try store.newChat() } }) {
                Image(systemName: "plus")
              }
              .buttonStyle(.borderless)
              .disabled(store.isGenerating)
              .accessibilityLabel("New chat")
            }
          }
          ToolbarItem(placement: .bottomBar) { tabBar }
        }
        .alert(
          "Something went wrong",
          isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }),
          message: store.errorMessage)
    }
  }

  private var title: String {
    guard tab == .chat else { return tab.title }
    let title = store.chat.displayTitle
    return title.count > 28 ? String(title.prefix(27)) + "…" : title
  }

  private var screen: some View {
    // The portable evaluator only flattens conditionals inside a container.
    VStack(alignment: .leading, spacing: 0) {
      switch tab {
      case .chat: chatView
      case .provider: providerView
      case .prompts: promptsView
      case .history: historyView
      }
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Navigation bar

  private var tabBar: some View {
    HStack(spacing: 0) {
      Spacer()
      ForEach(Tab.allCases, id: \.rawValue) { item in
        tabButton(item)
        Spacer()
      }
    }.frame(maxWidth: .infinity)
  }

  private func tabButton(_ item: Tab) -> some View {
    let selected = tab == item
    // Material 3 marks the active destination with a pill behind its icon.
    return Image(systemName: item.icon)
      .opacity(selected ? 1 : 0.7)
      .padding(EdgeInsets(top: 6, leading: 22, bottom: 6, trailing: 22))
      .background(selected ? Self.accent : .clear)
      .onTapGesture { tab = item }
      .cornerRadius(18)
      .accessibilityLabel(item.title)
  }

  // MARK: - Chat

  private var chatView: some View {
    // The renderer has no weighted stack sizing, so the message pane is sized
    // from the measured space to keep the composer pinned to the bottom.
    GeometryReader { proxy in
      VStack(alignment: .leading, spacing: 0) {
        if store.isGenerating || store.isLoadingModels {
          ProgressView().progressViewStyle(.linear).frame(height: 4)
        } else {
          Spacer().frame(height: 4)
        }
        ScrollView {
          VStack(alignment: .leading, spacing: 12) {
            chatHeader
            if store.messages.isEmpty && !store.isGenerating { emptyChat }
            ForEach(store.messages) { message in
              if message.role == .user {
                userBubble(message.text)
              } else {
                assistantText(message.text)
              }
            }
            if store.isGenerating {
              if store.streamedText.isEmpty {
                HStack(spacing: 12) {
                  ProgressView().progressViewStyle(.circular).frame(width: 20, height: 20)
                  Text("Thinking…").opacity(0.7)
                }
              } else {
                assistantText(store.streamedText)
              }
            }
          }.padding(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
        }.frame(maxWidth: .infinity)
          .frame(height: max(0, proxy.size.height - 4 - Self.composerHeight))
        composer(width: proxy.size.width)
      }
    }
  }

  private var chatHeader: some View {
    VStack(alignment: .leading, spacing: 0) {
      promptPicker().disabled(store.isGenerating)
      Text(store.model.isEmpty ? "No model selected" : store.model)
        .font(.caption)
        .opacity(0.7)
      if !store.status.isEmpty && !store.isGenerating {
        Text(store.status).font(.caption).opacity(0.7)
      }
    }
  }

  private var emptyChat: some View {
    VStack(spacing: 12) {
      Text("How can I help?").font(.title2)
      if store.model.isEmpty {
        Text("Set up a provider and choose a model to start chatting.")
          .multilineTextAlignment(.center)
          .opacity(0.7)
        Button("Set up provider") { tab = .provider }
      } else {
        Text("Send a message to start a conversation.").opacity(0.7)
      }
    }
    .padding(EdgeInsets(top: 48, leading: 16, bottom: 16, trailing: 16))
    .frame(maxWidth: .infinity)
  }

  private func userBubble(_ text: String) -> some View {
    HStack {
      Spacer()
      Text(text)
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Self.accent)
        .cornerRadius(20)
        .frame(maxWidth: 300)
    }
  }

  private func assistantText(_ text: String) -> some View {
    Text(text)
      .padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func composer(width: Double) -> some View {
    let canSend =
      !store.isGenerating && !store.isLoadingModels
      && !store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    // Room for the trailing button; text fields always fill their width.
    return HStack(spacing: 8) {
      TextField("Message", text: $store.draft)
        .submitLabel(.send)
        .onSubmit { store.sendDraft() }
        .frame(width: max(0, width - 124))
      if store.isGenerating {
        Button("Stop") { store.stop() }.buttonStyle(.bordered)
      } else {
        Button("Send") { store.sendDraft() }.disabled(!canSend)
      }
    }
    .padding(EdgeInsets(top: 4, leading: 12, bottom: 8, trailing: 12))
  }

  // MARK: - Provider

  private var providerView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        sectionHeader("OpenAI-compatible provider")
        TextField("Base URL (including /v1)", text: $store.baseURL).keyboardType(.URL)
        SecureField("API key (optional for local servers)", text: $store.apiKey)
        footnote(
          "For a local server, use an address your phone can reach. On the emulator, the host is http://10.0.2.2:PORT/v1."
        )
        sectionHeader("Model")
        TextField("Model ID", text: $store.model)
        if !store.models.isEmpty {
          Picker(
            "Available models",
            selection: Binding(
              get: { store.model },
              set: { id in perform { try store.chooseModel(id) } }
            )
          ) {
            ForEach(store.models) { model in
              Text(model.id).tag(model.id)
            }
          }
        }
        HStack(spacing: 12) {
          Button("List models") { store.discoverModels() }.buttonStyle(.bordered)
          if store.isLoadingModels {
            ProgressView().progressViewStyle(.circular).frame(width: 20, height: 20)
          }
        }
        footnote(
          store.models.isEmpty
            ? "List the server's models, or enter a model ID manually."
            : "\(store.models.count) models available.")
        Button("Save provider") { perform { try store.saveProvider() } }
          .frame(maxWidth: .infinity)
        if !store.status.isEmpty { footnote(store.status) }
      }
      .padding(16)
      .disabled(store.isGenerating || store.isLoadingModels)
    }
  }

  // MARK: - Prompts

  private func promptPicker(_ title: String = "System prompt") -> some View {
    Picker(
      title,
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
        sectionHeader("System prompts")
        // The section header already names the radio list.
        promptPicker("").pickerStyle(.inline)
        if let selected = store.selectedPrompt, !selected.text.isEmpty {
          Text(selected.text)
            .font(.callout)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Self.subtle)
            .cornerRadius(12)
        }
        HStack(spacing: 12) {
          Button("Edit selected") {
            guard let prompt = store.selectedPrompt else { return }
            editingPromptID = prompt.id
            promptName = prompt.name
            promptText = prompt.text
          }.buttonStyle(.bordered)
          Button("New prompt") {
            editingPromptID = nil
            promptName = ""
            promptText = ""
          }.buttonStyle(.bordered)
        }
        Divider()
        sectionHeader(editingPromptID == nil ? "New prompt" : "Edit prompt")
        TextField("Prompt name", text: $promptName)
        TextField("Instructions", text: $promptText)
        Button("Save prompt") {
          perform {
            let saved = try store.savePrompt(
              id: editingPromptID, name: promptName, text: promptText)
            editingPromptID = saved.id
          }
        }.frame(maxWidth: .infinity)
        if !store.status.isEmpty { footnote(store.status) }
      }
      .padding(16)
      .disabled(store.isGenerating)
    }
  }

  // MARK: - History

  private var historyView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if store.chats.isEmpty {
          VStack(spacing: 8) {
            Text("No saved chats").font(.title3)
            Text("Your conversations will appear here.").opacity(0.7)
          }
          .padding(EdgeInsets(top: 48, leading: 16, bottom: 16, trailing: 16))
          .frame(maxWidth: .infinity)
        }
        ForEach(store.chats) { chat in
          historyRow(chat)
          Divider()
        }
      }
    }
  }

  private func historyRow(_ chat: AgentChat) -> some View {
    let count = chat.conversationMessages.count
    return HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text(chat.displayTitle).lineLimit(1)
        Text(
          "\(count) message\(count == 1 ? "" : "s") · "
            + chat.updatedAt.formatted(date: .abbreviated, time: .shortened)
        )
        .font(.caption)
        .opacity(0.7)
      }
      Spacer()
      if chat.id == store.chat.id {
        Image(systemName: "checkmark").accessibilityLabel("Current chat")
      }
    }
    .padding(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
    .frame(maxWidth: .infinity, alignment: .leading)
    .onTapGesture {
      guard !store.isGenerating else { return }
      perform {
        try store.openChat(chat.id)
        tab = .chat
      }
    }
  }

  // MARK: - Helpers

  private func sectionHeader(_ text: String) -> some View {
    Text(text).font(.subheadline).fontWeight(.semibold).opacity(0.8)
  }

  private func footnote(_ text: String) -> some View {
    Text(text).font(.caption).opacity(0.7)
  }

  private func perform(_ operation: () throws -> Void) {
    do { try operation() } catch { store.errorMessage = error.localizedDescription }
  }
}
