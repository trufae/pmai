import MaiCore
import SwiftUI

struct ConversationModelSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var showingNewFolder = false
  @State private var showingFolderManager = false
  @State private var showingCompactSheet = false
  @State private var newFolderName = ""
  @State private var folderErrorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        if store.currentConversation == nil {
          ContentUnavailableView("No Chat Selected", systemImage: "bubble.left")
        } else {
          Section {
            Picker("Agent", selection: agentBinding) {
              ForEach(store.settings.agents) { agent in
                Text(agent.name).tag(agent.id)
              }
            }
            .pickerStyle(.menu)
            .disabled(store.isResponding || store.isCompacting)
          }

          Section {
            HStack {
              Button {
                saveChatSettingsAsDefault()
              } label: {
                Label(
                  chatSettingsDefaultButtonTitle,
                  systemImage: isCurrentChatUsingDefaults ? "checkmark.circle" : "star"
                )
              }
              .disabled(!canSaveChatSettingsAsDefault)

              if !isCurrentChatUsingDefaults {
                Spacer()

                Button {
                  resetChatSettingsToDefaults()
                } label: {
                  Label("Reset defaults", systemImage: "arrow.counterclockwise")
                }
              }
            }
            .buttonStyle(.borderless)
          } footer: {
            Text(chatSettingsDefaultFooterText)
          }

          Section("Provider") {
            ProviderModelFields(
              selection: conversationBinding(
                \.providerModelSelection, fallback: store.defaultProviderModelSelection))
            Picker("Tool Calling", selection: conversationBinding(\.toolCallingMode, fallback: nil))
            {
              Text("App Default (\(store.settings.toolCallingMode.displayName))")
                .tag(ToolCallingMode?.none)
              ForEach(ToolCallingMode.allCases) { mode in
                Text(mode.displayName).tag(Optional(mode))
              }
            }
            .pickerStyle(.menu)
            Picker("System Prompt", selection: systemPromptBinding) {
              ForEach(store.settings.systemPrompts) { prompt in
                Text(prompt.displayName).tag(prompt.id)
              }
            }
            .pickerStyle(.menu)
            Picker("Language", selection: languageBinding) {
              Text("Defaults").tag("")
              ForEach(languageOptions, id: \.self) { identifier in
                Text(SystemLanguageSupport.languageDisplayName(identifier)).tag(identifier)
              }
            }
            .pickerStyle(.menu)
          }

          folderSection

          Section {
            ReasoningLevelControl(
              level: reasoningBinding,
              model: store.currentConversation?.modelID ?? "",
              endpointName: selectedEndpoint?.name ?? "", baseURL: selectedEndpoint?.baseURL ?? "")
          }

          Section("Context") {
            Picker(
              "Chat history", selection: conversationBinding(\.contextWindowMode, fallback: nil)
            ) {
              Text("App Default").tag(ContextWindowMode?.none)
              ForEach(ContextWindowMode.allCases) { mode in
                Text(mode.displayName).tag(Optional(mode))
              }
            }
            .pickerStyle(.menu)

            if provider == .mlx {
              Picker("MLX KV Cache", selection: conversationBinding(\.mlxMaxKVSize, fallback: nil))
              {
                Text("App Default").tag(MLXKVCacheSize?.none)
                ForEach(MLXKVCacheSize.allCases) { size in
                  Text(size.displayName).tag(Optional(size))
                }
              }
              .pickerStyle(.menu)
              Text(
                "Tool schemas and tool results use this budget too. Use a larger cache when memory allows, or keep fewer history messages for tool-heavy chats."
              )
              .font(.caption)
              .foregroundStyle(.secondary)
            }

            Button("Compact...", systemImage: "rectangle.compress.vertical") {
              showingCompactSheet = true
            }
            .disabled(!canCompactCurrentChat)
          }

          Section {
            Toggle("Show thinking", isOn: showThinkingBinding)
              .disabled(!store.settings.showThinkingByDefault)
            Toggle("Use memory", isOn: useMemoryBinding)
            Toggle("Stream responses", isOn: conversationBinding(\.usesStreaming, fallback: true))
            Toggle("Suggest follow-ups", isOn: followUpSuggestionsBinding)
            Toggle("Voiceover", isOn: conversationBinding(\.voiceoverEnabled, fallback: false))
          }
        }
      }
      .navigationTitle("Chat Settings")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }
        }
      }
    }
    .sheet(isPresented: $showingFolderManager) {
      ConversationFolderManagementView()
        .environmentObject(store)
    }
    .sheet(isPresented: $showingCompactSheet) {
      CompactChatSheet()
        .environmentObject(store)
    }
    .alert("New Folder", isPresented: $showingNewFolder) {
      TextField("Folder name", text: $newFolderName)
      Button("Cancel", role: .cancel) {}
      Button("Create & Move") {
        createFolderAndMoveConversation()
      }
      .disabled(ConversationFolder.normalizedCustomName(newFolderName).isEmpty)
    } message: {
      Text("Create a folder and move this chat into it.")
    }
  }

  private var canCompactCurrentChat: Bool {
    guard let conversation = store.currentConversation else { return false }
    if store.isCompacting || store.isResponding { return false }
    let substantive = conversation.messages.filter { msg in
      msg.role != .error
        && !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return substantive.count >= 2
  }

  private var folderSection: some View {
    Section("Folder") {
      Picker("Folder", selection: folderSelectionBinding) {
        ForEach(store.conversationFolders) { folder in
          Label(folder.displayName, systemImage: folder.systemImage)
            .tag(folder.id)
            .disabled(!store.canUseConversationFolder(folder.id))
        }
      }
      .pickerStyle(.menu)

      Button {
        newFolderName = ""
        folderErrorMessage = nil
        showingNewFolder = true
      } label: {
        Label("New Folder...", systemImage: "folder.badge.plus")
      }
      Button {
        showingFolderManager = true
      } label: {
        Label("Manage Folders...", systemImage: "folder.badge.gearshape")
      }
      if let folderErrorMessage {
        Text(folderErrorMessage)
          .foregroundStyle(.red)
      }
    }
  }

  private var folderSelectionBinding: Binding<String> {
    Binding {
      store.currentConversation?.folderID ?? ConversationFolder.defaultID
    } set: { folderID in
      guard let conversationID = store.currentConversation?.id else { return }
      folderErrorMessage = nil
      Task { await store.moveConversation(id: conversationID, to: folderID) }
    }
  }

  private func createFolderAndMoveConversation() {
    guard let conversationID = store.currentConversation?.id else { return }
    guard let folder = store.createConversationFolder(named: newFolderName) else {
      folderErrorMessage = store.errorMessage
      store.errorMessage = nil
      return
    }
    folderErrorMessage = nil
    Task { await store.moveConversation(id: conversationID, to: folder.id) }
  }

  private var provider: ProviderKind {
    guard let provider = store.currentConversation?.provider else { return .mlx }
    return provider
  }

  private var modelSelection: ProviderModelSelection {
    store.currentConversation?.providerModelSelection ?? store.defaultProviderModelSelection
  }

  private var selectedEndpoint: OpenAIEndpoint? {
    store.providerModelCatalog.endpoint(for: modelSelection)
  }

  private var canSaveChatSettingsAsDefault: Bool {
    store.currentConversation != nil && !isCurrentChatUsingDefaults
      && store.providerModelCatalog.validationMessage(for: modelSelection) == nil
  }

  private var agentBinding: Binding<UUID> {
    Binding(
      get: { store.settings.selectedAgentID },
      set: { id in
        store.selectAgent(id)
        resetChatSettingsToDefaults()
      })
  }

  private var isCurrentChatUsingDefaults: Bool {
    guard var conversation = store.currentConversation else { return true }
    conversation.systemPromptID = effectiveSystemPromptID(for: conversation)
    var defaults = Conversation()
    store.settings.applyAgentDefaults(to: &defaults)
    return store.settings.agentDefaults(from: conversation)
      == store.settings.agentDefaults(from: defaults)
  }

  private var chatSettingsDefaultButtonTitle: String {
    isCurrentChatUsingDefaults ? "Using agent defaults" : "Use as default"
  }

  private var chatSettingsDefaultFooterText: String {
    if isCurrentChatUsingDefaults {
      return "These chat settings match \(store.settings.selectedAgent.name)."
    }
    if let message = store.providerModelCatalog.validationMessage(for: modelSelection) {
      return message
    }
    return "Save these chat settings as the defaults for \(store.settings.selectedAgent.name)."
  }

  private func saveChatSettingsAsDefault() {
    guard var conversation = store.currentConversation else { return }
    conversation.systemPromptID = effectiveSystemPromptID(for: conversation)
    store.settings.agentSettings = store.settings.agentDefaults(from: conversation)
    store.saveSettings()
  }

  private func resetChatSettingsToDefaults() {
    let settings = store.settings
    store.updateCurrentConversationSettings { conversation in
      settings.applyAgentDefaults(to: &conversation)
    }
  }

  private func effectiveSystemPromptID(for conversation: Conversation) -> UUID {
    conversation.systemPromptID ?? store.effectiveSystemPromptID(forFolderID: conversation.folderID)
  }

  private func conversationBinding<Value>(
    _ keyPath: WritableKeyPath<Conversation, Value>, fallback: Value
  ) -> Binding<Value> {
    Binding(
      get: { store.currentConversation?[keyPath: keyPath] ?? fallback },
      set: { value in
        store.updateCurrentConversationSettings { $0[keyPath: keyPath] = value }
      })
  }

  private var followUpSuggestionsBinding: Binding<Bool> {
    Binding(
      get: { store.settings.followUps.isEnabled },
      set: { isEnabled in
        guard store.settings.followUps.isEnabled != isEnabled else { return }
        store.settings.followUps.isEnabled = isEnabled
        store.saveSettings()
      }
    )
  }

  private var showThinkingBinding: Binding<Bool> {
    Binding(
      get: { store.effectiveShowThinking(for: store.currentConversation) },
      set: { showThinking in
        store.updateCurrentConversationSettings { conversation in
          conversation.showThinking = showThinking
        }
      }
    )
  }

  private var systemPromptBinding: Binding<UUID> {
    Binding(
      get: {
        guard let conversation = store.currentConversation else {
          return store.settings.defaultSystemPromptID
        }
        return effectiveSystemPromptID(for: conversation)
      },
      set: { promptID in
        guard store.settings.systemPrompts.contains(where: { $0.id == promptID }) else { return }
        store.updateCurrentConversationSettings { conversation in
          conversation.systemPromptID = promptID
        }
      }
    )
  }

  private var languageOptions: [String] {
    SystemLanguageSupport.chatLanguageIdentifiers(
      including: store.currentConversation?.effectiveLanguageOverrideIdentifier
    )
  }

  private var languageBinding: Binding<String> {
    Binding(
      get: { store.currentConversation?.effectiveLanguageOverrideIdentifier ?? "" },
      set: { identifier in
        store.setCurrentConversationLanguageOverride(identifier.isEmpty ? nil : identifier)
      }
    )
  }

  private var useMemoryBinding: Binding<Bool> {
    Binding(
      get: { store.currentConversation?.enabledTools.contains(.memory) ?? false },
      set: { useMemory in
        store.updateCurrentConversationSettings { conversation in
          if useMemory {
            conversation.enabledTools.insert(.memory)
          } else {
            conversation.enabledTools.remove(.memory)
          }
        }
      }
    )
  }

  private var reasoningBinding: Binding<ReasoningLevel> {
    Binding(
      get: { store.currentConversation?.reasoningLevel ?? .automatic },
      set: { level in
        guard store.currentConversation?.reasoningLevel != level else { return }
        store.updateCurrentConversationSettings { conversation in
          conversation.reasoningLevel = level
        }
      }
    )
  }
}

private struct CompactChatSheet: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: AppStore
  @State private var conversationID: UUID?
  @State private var prompt = ""
  @State private var summary = ""
  @State private var statusText: String?
  @State private var isLoadingPrompt = false
  @State private var showingPromptEditor = false
  @State private var showingReplaceConfirmation = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button {
            showingPromptEditor.toggle()
          } label: {
            Label(
              showingPromptEditor ? "Hide Compact Prompt" : "Edit Compact Prompt",
              systemImage: showingPromptEditor ? "eye.slash" : "square.and.pencil")
          }
          .disabled(isLoadingPrompt || store.isCompacting || prompt.isEmpty)

          if showingPromptEditor {
            TextEditor(text: $prompt)
              .frame(minHeight: 220)
              .font(.callout.monospaced())
              .autocorrectionDisabled()
          }
        }

        Section {
          Button {
            Task { await generateSummary() }
          } label: {
            if store.isCompacting {
              HStack {
                ProgressView()
                Text("Compacting...")
              }
            } else {
              Label("Generate Compact Summary", systemImage: "rectangle.compress.vertical")
            }
          }
          .disabled(
            isLoadingPrompt || store.isCompacting
              || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

          TextEditor(text: $summary)
            .frame(minHeight: 260)
            .font(.callout)
            .autocorrectionDisabled()
            .overlay(alignment: .topLeading) {
              if summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Generated summary")
                  .foregroundStyle(.tertiary)
                  .padding(.top, 8)
                  .padding(.leading, 5)
                  .allowsHitTesting(false)
              }
            }

          if let statusText {
            Text(statusText)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        } footer: {
          Text("Review and edit the compacted summary before replacing the conversation.")
        }

        Section {
          Button(role: .destructive) {
            showingReplaceConfirmation = true
          } label: {
            Label("Replace Conversation With Summary", systemImage: "arrow.triangle.2.circlepath")
          }
          .disabled(
            conversationID == nil
              || summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("Compact Chat")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("Close")
        }
      }
      .task {
        await loadPrompt()
      }
      .alert("Replace conversation?", isPresented: $showingReplaceConfirmation) {
        Button("Cancel", role: .cancel) {}
        Button("Replace Conversation", role: .destructive) {
          replaceConversation()
        }
      } message: {
        Text(
          "All current messages in this conversation will be replaced by the compacted summary. This cannot be undone."
        )
      }
    }
  }

  private func loadPrompt() async {
    guard prompt.isEmpty, conversationID == nil else { return }
    isLoadingPrompt = true
    statusText = "Loading compact prompt..."
    defer { isLoadingPrompt = false }

    if let draft = await store.compactPromptForCurrentConversation() {
      conversationID = draft.conversationID
      prompt = draft.prompt
      statusText = nil
    } else {
      statusText = store.errorMessage ?? "Nothing to compact yet."
    }
  }

  private func generateSummary() async {
    guard let conversationID else { return }
    statusText = nil
    guard
      let generated = await store.generateCompactSummary(
        conversationID: conversationID,
        prompt: prompt
      )
    else {
      statusText = store.errorMessage ?? "Could not generate compact summary."
      return
    }
    summary = generated
    statusText = "Compact summary generated."
  }

  private func replaceConversation() {
    guard let conversationID else { return }
    store.replaceConversationWithCompactSummary(conversationID: conversationID, summary: summary)
    dismiss()
  }
}
