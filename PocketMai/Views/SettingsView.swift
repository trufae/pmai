import MaiCore
import MaiOpenAI
import Speech
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import UserNotifications

private struct PendingSettingsDeletion: Identifiable {
  let id = UUID()
  let kind: SettingsDeletionKind
  let offsets: IndexSet
}

private enum SettingsRoute: Hashable {
  case endpoint(UUID)
  case mcpServer(UUID)
}

private enum SettingsDeletionKind {
  case endpoint
  case systemPrompt
  case userPrompt
  case file
  case mcpServer

  var title: String {
    switch self {
    case .endpoint: "Delete provider?"
    case .systemPrompt: "Delete system prompt?"
    case .userPrompt: "Delete user prompt?"
    case .file: "Delete file?"
    case .mcpServer: "Delete MCP server?"
    }
  }

  func buttonTitle(count: Int) -> String {
    switch self {
    case .endpoint: "Delete \(itemName("Provider", count: count))"
    case .systemPrompt: "Delete \(itemName("Prompt", count: count))"
    case .userPrompt: "Delete \(itemName("Prompt", count: count))"
    case .file: "Delete \(itemName("File", count: count))"
    case .mcpServer: "Delete \(itemName("Server", count: count))"
    }
  }

  func message(count: Int) -> String {
    switch self {
    case .endpoint:
      "\(count) provider\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .systemPrompt:
      "\(count) system prompt\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .userPrompt:
      "\(count) user prompt\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .file:
      "\(count) imported file\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    case .mcpServer:
      "\(count) MCP server\(count == 1 ? "" : "s") will be removed. This cannot be undone."
    }
  }

  private func itemName(_ singular: String, count: Int) -> String {
    count == 1 ? singular : "\(count) \(singular)s"
  }
}

private struct SettingsLazyDisclosureGroup<Label: View, Content: View>: View {
  @State private var isExpanded = false
  private let content: () -> Content
  private let label: () -> Label

  init(
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder label: @escaping () -> Label
  ) {
    self.content = content
    self.label = label
  }

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      if isExpanded {
        content()
      }
    } label: {
      label()
    }
  }
}

struct SettingsView: View {
  let store: AppStore
  @State private var expandedToolOptions: Set<BuiltInToolID> = []
  @AppStorage("thinkingDisplay") private var thinkingDisplay: ThinkingDisplay = .five
  @ObservedObject var storeObservation: AppStoreViewObservation
  @Environment(\.dismiss) private var dismiss
  @State private var showingToolFileImporter = false
  @State private var newTodoTitle = ""
  @State private var showingClearMemoryConfirmation = false
  @State private var showingBackgroundVoiceConfirmation = false
  @State private var notificationAuthorizationStatus: UNAuthorizationStatus?
  @State private var pendingDeletion: PendingSettingsDeletion?
  @State private var navigationPath: [SettingsRoute] = []
  @State private var draftEndpoint: OpenAIEndpoint?
  @State private var draftMCPServer: MCPServer?
  @State private var toastMessage: ToastNotice?
  @State private var corruptedConversationCount = 0
  @State private var showingCorruptedConversationActions = false
  @State private var showingCorruptedConversationReview = false
  @State private var corruptedConversationArchive: ExportedFile?

  var body: some View {
    NavigationStack(path: $navigationPath) {
      Form {
        inferenceSection
        agentSection
        appearanceSection
        toolsSection
        dangerSection
        aboutSection
      }
      .navigationDestination(for: SettingsRoute.self) { route in
        switch route {
        case .endpoint(let id):
          if let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == id }) {
            EndpointDetailView(endpoint: persistedEndpointBinding(at: index))
          } else if draftEndpoint?.id == id {
            EndpointDetailView(endpoint: draftEndpointBinding(for: id)) { endpoint in
              if let index = store.settings.openAIEndpoints.firstIndex(where: {
                $0.id == endpoint.id
              }) {
                store.settings.openAIEndpoints[index] = endpoint
              } else {
                store.settings.openAIEndpoints.append(endpoint)
              }
              store.settings.selectedEndpointID = endpoint.id
            }
          }
        case .mcpServer(let id):
          if let index = store.settings.mcpServers.firstIndex(where: { $0.id == id }) {
            MCPServerDetailView(server: persistedMCPServerBinding(at: index))
          } else if draftMCPServer?.id == id {
            MCPServerDetailView(server: draftMCPServerBinding(for: id), isNew: true) { server in
              if let index = store.settings.mcpServers.firstIndex(where: { $0.id == server.id }) {
                store.settings.mcpServers[index] = server
              } else {
                store.settings.mcpServers.append(server)
              }
              draftMCPServer = nil
            }
          }
        }
      }
      .alert(
        pendingDeletion?.kind.title ?? "Delete item?",
        isPresented: settingsDeletionConfirmationBinding,
        presenting: pendingDeletion
      ) { deletion in
        Button("Cancel", role: .cancel) {
          pendingDeletion = nil
        }
        Button(deletion.kind.buttonTitle(count: deletion.offsets.count), role: .destructive) {
          performSettingsDeletion(deletion)
        }
      } message: { deletion in
        Text(deletion.kind.message(count: deletion.offsets.count))
      }
      .alert(
        "Clear memory?",
        isPresented: $showingClearMemoryConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Clear Memory", role: .destructive) {
          store.settings.memory = ""
          store.saveSettings()
        }
      } message: {
        Text("Saved memory will be removed from this device. This cannot be undone.")
      }
      .alert(
        "Continue voice chat when locked?",
        isPresented: $showingBackgroundVoiceConfirmation
      ) {
        Button("Cancel", role: .cancel) {}
        Button("Enable") {
          enableBackgroundVoiceListening()
        }
      } message: {
        Text(
          "Voice capture can continue after the screen locks while an active voice conversation is running. Native iOS Live transcribes on device; raw microphone audio is not uploaded by PocketMai."
        )
      }
      .navigationTitle("Settings")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button {
            toggleAirplaneMode()
          } label: {
            Label(
              store.settings.isOffline ? "Offline" : "Online",
              systemImage: store.settings.isOffline
                ? "airplane.circle.fill" : "airplane.circle"
            )
          }
          .accessibilityLabel(
            store.settings.airplaneModeEnabled
              ? "Airplane Mode enabled. Tap to allow internet access."
              : !store.settings.networkAvailable
                ? "No internet connection. Tap to keep Airplane Mode enabled after reconnecting."
                : "Online. Tap to enable Airplane Mode."
          )
          .help(store.settings.airplaneModeEnabled ? "Allow internet access" : "Enable Airplane Mode")
        }

        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { saveAndDismiss() }
        }
      }
      .toast($toastMessage)
      .task {
        await refreshCorruptedConversationCount()
      }
      .confirmationDialog(
        "Corrupted Chats",
        isPresented: $showingCorruptedConversationActions,
        titleVisibility: .visible
      ) {
        Button("Review JSON Files") {
          showingCorruptedConversationReview = true
        }
        Button("Export Raw Files") {
          Task { await exportCorruptedConversations() }
        }
        Button("Try Recovery") {
          Task { await recoverCorruptedConversations() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text(
          "\(corruptedConversationCount) \(corruptedConversationCount == 1 ? "chat is" : "chats are") quarantined because they could not be decoded. Export saves the original files; recovery retries the current decoder."
        )
      }
      .sheet(item: $corruptedConversationArchive) { archive in
        ActivityShareSheet(activityItems: [archive.url])
      }
      .sheet(isPresented: $showingCorruptedConversationReview) {
        CorruptedConversationReviewView()
          .environmentObject(store)
          .onDisappear {
            Task { await refreshCorruptedConversationCount() }
          }
      }
      .fileImporter(
        isPresented: $showingToolFileImporter,
        allowedContentTypes: [.text, .plainText, .json, .sourceCode]
      ) { result in
        if case .success(let url) = result {
          store.importToolFile(from: url)
        }
      }
      .onAppear {
        store.refreshLocalMLXModelsInBackground()
      }
      .onChange(of: navigationPath) { _, path in
        discardDraftEndpointIfNeeded(path: path)
        discardDraftMCPServerIfNeeded(path: path)
      }
    }
    .preferredColorScheme(store.settings.appearance.theme.colorScheme)
    .tint(store.settings.appearance.tintColor)
    .accentColor(store.settings.appearance.tintColor)
  }

  @ViewBuilder
  private var advancedOptionsContent: some View {
    Toggle("Show thinking", isOn: settingsBinding(\.showThinkingByDefault))
    Picker("Thinking display", selection: $thinkingDisplay) {
      ForEach(ThinkingDisplay.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    Toggle("Stream responses", isOn: settingsBinding(\.streamByDefault))
    Picker("LLM Timeout", selection: llmRequestTimeoutBinding) {
      ForEach(AppSettings.llmRequestTimeoutChoices, id: \.self) { seconds in
        Text(llmTimeoutLabel(seconds)).tag(seconds)
      }
    }
    .pickerStyle(.menu)
    Picker("Chat Context", selection: settingsBinding(\.contextWindowMode)) {
      ForEach(ContextWindowMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.menu)
    Toggle(
      "Include assistant responses",
      isOn: settingsBinding(\.includeAssistantResponsesInContext))
    if !store.settings.includeAssistantResponsesInContext {
      Text(
        "Previous assistant replies are replaced with “(redacted)” context markers. Chats may become repetitive or confusing."
      )
      .font(.caption)
      .foregroundStyle(.orange)
    }
    Toggle(
      "Include reasoning content",
      isOn: settingsBinding(\.includeReasoningContentInContext))
    Text(
      "Send the think blocks of previous replies back to the model. Disabled by default, so reasoning is trimmed away."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    Picker("MLX KV Cache", selection: settingsBinding(\.mlxMaxKVSize)) {
      ForEach(MLXKVCacheSize.allCases) { size in
        Text(size.displayName).tag(size)
      }
    }
    .pickerStyle(.menu)
    Toggle("Auto-Compact MLX Context", isOn: settingsBinding(\.mlxAutoCompact))
    Picker("Image Attachments", selection: settingsBinding(\.attachmentImageSize)) {
      ForEach(AttachmentImageSize.allCases) { size in
        Text(size.displayName).tag(size)
      }
    }
    .pickerStyle(.menu)
  }

  @ViewBuilder
  private var followUpOptionsContent: some View {
    Toggle("Suggest follow-ups", isOn: settingsBinding(\.followUps.isEnabled))
    Text(
      "After each assistant response, generate short messages the user can tap to continue the chat. Disabled by default."
    )
    .font(.caption)
    .foregroundStyle(.secondary)

    if store.settings.followUps.isEnabled {
      Toggle("Generate automatically", isOn: settingsBinding(\.followUps.autoGenerate))
      Text(
        store.settings.followUps.autoGenerate
          ? "Suggestions appear on their own after each reply. Tap the refresh button in the box for a new set."
          : "The suggestion box appears after each reply but stays empty until you tap its refresh button."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Stepper(
        value: settingsBinding(\.followUps.suggestionCount),
        in: FollowUpSettings.suggestionCountRange
      ) {
        Text("Suggestions: \(store.settings.followUps.suggestionCount)")
      }

      Stepper(
        value: settingsBinding(\.followUps.contextMessageCount),
        in: FollowUpSettings.contextMessageCountRange
      ) {
        Text("Context Messages: \(store.settings.followUps.contextMessageCount)")
      }

      VStack(alignment: .leading, spacing: 6) {
        Text("Follow-up Prompt")
          .font(.subheadline.weight(.medium))
        TextEditor(text: followUpPromptBinding)
          .frame(minHeight: 120)
          .font(.callout)
      }

      Text(
        "PocketMai automatically adds the selected recent messages and requires a JSON options response."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Reset Follow-up Prompt") {
        followUpPromptBinding.wrappedValue = FollowUpSettings.defaultPrompt
      }
      .disabled(store.settings.followUpPromptText == FollowUpSettings.defaultPrompt)
    }
  }

  @ViewBuilder
  private var toolOptionsContent: some View {
    Picker("Tool Calling", selection: settingsBinding(\.toolCallingMode)) {
      ForEach(ToolCallingMode.allCases) { mode in
        Text(mode.displayName).tag(mode)
      }
    }
    .pickerStyle(.menu)
    Picker("Tool approval", selection: settingsBinding(\.toolApprovalMode)) {
      ForEach(ToolApprovalMode.allCases, id: \.rawValue) { mode in
        Text(mode.rawValue).tag(mode)
      }
    }
    .pickerStyle(.menu)
    Stepper(value: mcpRequestTimeoutBinding, in: AppSettings.mcpRequestTimeoutRange, step: 5) {
      Text("Tool Call Timeout: \(store.settings.mcpRequestTimeoutSeconds)s")
    }
    Stepper(value: settingsBinding(\.maxToolCallsPerTurn), in: AppSettings.maxToolCallsPerTurnRange)
    {
      Text("Max Tool Calls: \(store.settings.maxToolCallsPerTurn)")
    }
  }

  @ViewBuilder
  private var agentsContent: some View {
    NavigationLink {
      RemoteAgentsView()
    } label: {
      Label("Remote Hosts", systemImage: "network")
    }
    NavigationLink {
      AgentManagerView(store: store, storeObservation: storeObservation)
    } label: {
      LabeledContent {
        Text(store.settings.selectedAgent.name)
      } label: {
        Label("Manage Agents", systemImage: "person.2")
      }
    }
  }

  private var inferenceSection: some View {
    Section {
      SettingsLazyDisclosureGroup {
        endpointContent
      } label: {
        Label("Providers", systemImage: "network")
      }

      SettingsLazyDisclosureGroup {
        openAPIServerContent
      } label: {
        Label("OpenAPI Server", systemImage: "server.rack")
      }

      SettingsLazyDisclosureGroup {
        advancedOptionsContent
      } label: {
        Label("Advanced Options", systemImage: "slider.horizontal.3")
      }
    } header: {
      Text("Inference")
    }
  }

  private var agentSection: some View {
    Section {
      agentsContent

      SettingsLazyDisclosureGroup {
        agentPromptsContent
      } label: {
        Label("Prompts", systemImage: "text.bubble")
      }
    } header: {
      Text("Agent")
    }
  }

  @ViewBuilder
  private var agentPromptsContent: some View {
    NavigationLink {
      TextDocumentEditor(
        title: "SOUL.md", instructions: "Core personality instructions, applied on the next model request.",
        load: AgentSoul().load, save: AgentSoul().save)
    } label: {
      Label("SOUL.md", systemImage: "person.text.rectangle")
    }

    SettingsLazyDisclosureGroup {
      Toggle("Enable", isOn: settingsBinding(\.redaction.enabled))
      NavigationLink("Edit Entries") {
        TextDocumentEditor(
          title: "Redacted",
          instructions: "One keyword per line, case-insensitive. Use /pattern/ for regex; # starts a comment.",
          load: { store.settings.redaction.rules },
          save: { text in
            _ = try ContentRedactor.parse(text)
            settingsBinding(\.redaction.rules).wrappedValue = text
          })
      }
    } label: {
      Label("Redacted", systemImage: "eye.slash")
    }

    SettingsLazyDisclosureGroup {
      promptContent
    } label: {
      Label("System Prompts", systemImage: "text.bubble")
    }

    SettingsLazyDisclosureGroup {
      userPromptContent
    } label: {
      Label("User Prompts", systemImage: "text.quote")
    }

    if #available(iOS 26.4, *) {
      NavigationLink {
        CarPlayFavoritesView(prompts: store.settings.userPrompts)
      } label: {
        Label("CarPlay", systemImage: "car")
      }
    }

    NavigationLink {
      PebbleSettingsView(bridge: store.pebbleBridge, prompts: store.settings.userPrompts)
    } label: {
      Label("Pebble", systemImage: "applewatch")
    }

    SettingsLazyDisclosureGroup {
      followUpOptionsContent
    } label: {
      Label("Follow-up Suggestions", systemImage: "text.bubble.fill")
    }
  }

  @ViewBuilder
  private var openAPIServerContent: some View {
    Text("Ollama and OpenAI-compatible clients can connect to this port while serving is enabled.")
      .font(.caption)
      .foregroundStyle(.secondary)
    Toggle("Serve", isOn: openAPIServerServingBinding)

    LabeledContent("Port") {
      TextField(
        "\(OpenAPIServerSettings.defaultPort)",
        value: openAPIServerPortBinding,
        format: .number
      )
      .keyboardType(.numberPad)
      .multilineTextAlignment(.trailing)
    }

    Picker("Source", selection: settingsBinding(\.openAPIServer.conversationScope)) {
      ForEach(OpenAPIServerConversationScope.allCases) { scope in
        Text(scope.displayName).tag(scope)
      }
    }
    .pickerStyle(.menu)
    Text(store.settings.openAPIServer.conversationScope.summary)
      .font(.caption)
      .foregroundStyle(.secondary)

    Toggle(
      "Allow model overrides",
      isOn: settingsBinding(\.openAPIServer.allowClientOverrides))

    Toggle(
      "Run PocketMai tools",
      isOn: settingsBinding(\.openAPIServer.allowToolExecution))
    if let port = store.openAPIServerState.port {
      let configuredPort = store.settings.openAPIServer.port
      let statusText =
        store.isOpenAPIServerRunning && port != configuredPort
        ? "Serving on port \(port). Stop and start serving to use port \(configuredPort)."
        : (store.isOpenAPIServerRunning ? "Serving on port \(port)." : "Starting on port \(port)…")
      Text(statusText)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var toolProxySummary: String {
    "Off: inherited tools are described in each request. On: inherited tools use list-tools and call-tool. Use Tool list to pin each group or member to Direct, Proxy, Hidden, or Disabled. Hidden tools stay callable by name without being listed. Individual choices override groups and the proxy default."
  }

  private var appearanceSection: some View {
    Section {
      SettingsLazyDisclosureGroup {
        appearanceOptionsContent
      } label: {
        Label("Appearance", systemImage: "paintpalette")
      }

      SettingsLazyDisclosureGroup {
        fontOptionsContent
      } label: {
        Label("Fonts", systemImage: "textformat")
      }

      SettingsLazyDisclosureGroup {
        voicesContent
      } label: {
        Label("Voices", systemImage: "speaker.wave.2")
      }

      SettingsLazyDisclosureGroup {
        hapticsContent
      } label: {
        Label("Haptics", systemImage: "waveform.path")
      }

      SettingsLazyDisclosureGroup {
        conversationOptionsContent
      } label: {
        Label("Conversation", systemImage: "mic.badge.plus")
      }

      SettingsLazyDisclosureGroup {
        Toggle(
          "Include Tool Calls and Results", isOn: settingsBinding(\.documentExport.includeToolCalls))
        Toggle("Include Thinking", isOn: settingsBinding(\.documentExport.includeThinking))
        Text("Include technical content when exporting conversations to Markdown, HTML, EPUB, or Word.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } label: {
        Label("Document Exports", systemImage: "doc.text")
      }

      SettingsLazyDisclosureGroup {
        backgroundActivityContent
      } label: {
        Label("Background & Notifications", systemImage: "bell.badge")
      }
    } header: {
      Text("Look and Feel")
    }
  }

  @ViewBuilder
  private var backgroundActivityContent: some View {
    Toggle("Live Activity", isOn: settingsBinding(\.background.liveActivityEnabled))
      .task { await refreshNotificationAuthorizationStatus() }
    Text(
      "Show reply status on the Lock Screen and the Dynamic Island. This does not extend background runtime."
    )
      .font(.caption)
      .foregroundStyle(.secondary)
    Toggle(
      "Notify when a reply finishes",
      isOn: notificationBinding(\.background.notifyWhenResponseFinishes))
    Toggle(
      "Notify when a tool needs approval",
      isOn: notificationBinding(\.background.notifyWhenApprovalNeeded))
    if notificationAuthorizationStatus == .denied {
      Button("Allow Notifications in Settings") {
        openSystemSettings()
      }
      Text("Notifications are turned off for PocketMai in the system Settings.")
        .font(.caption)
        .foregroundStyle(.secondary)
    } else {
      Text("Sent only if a reply finishes or needs approval before iOS suspends PocketMai.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Text(
      "Replies can finish during a short background allowance. When it expires, PocketMai saves the partial reply and stops. Reopen the chat to continue with a new message."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var appearanceOptionsContent: some View {
    Picker("Accent", selection: settingsBinding(\.appearance.tint)) {
      ForEach(AppearanceTint.allCases) { tint in
        HStack {
          Circle()
            .fill(tint.swatchColor)
            .frame(width: 12, height: 12)
          Text(tint.displayName)
        }
        .tag(tint)
      }
    }
    .pickerStyle(.menu)

    Picker("App Theme", selection: settingsBinding(\.appearance.theme)) {
      ForEach(AppearanceTheme.allCases) { theme in
        Text(theme.displayName).tag(theme)
      }
    }
    .pickerStyle(.menu)

    Toggle("Render Markdown", isOn: settingsBinding(\.renderMarkdownInChat))
    Toggle("Live Markdown", isOn: settingsBinding(\.appearance.liveMarkdown))
    Toggle("Render images", isOn: settingsBinding(\.renderMarkdownImagesInChat))
    Toggle("Justify Text", isOn: settingsBinding(\.appearance.justifyText))
    Picker("Tables", selection: settingsBinding(\.appearance.tableLayout)) {
      ForEach(AppearanceTableLayout.allCases) { layout in
        Text(layout.displayName).tag(layout)
      }
    }
    .pickerStyle(.menu)
    Text(store.settings.appearance.tableLayout.detail)
      .font(.caption)
      .foregroundStyle(.secondary)
    Toggle(
      "Scroll to follow responses",
      isOn: settingsBinding(\.appearance.scrollToFollowResponses))
    Text(
      "Follows responses to the bottom as they stream. When off, long responses keep their beginning visible. Scrolling manually pauses following."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var fontOptionsContent: some View {
    fontPickerContent("User", selection: \.appearance.userFontFamily)
    fontPickerContent("Assistant", selection: \.appearance.assistantFontFamily)

    Picker("Pinch zoom", selection: settingsBinding(\.appearance.zoomMethod)) {
      ForEach(AppearanceZoomMethod.allCases) { method in
        Text(method.displayName).tag(method)
      }
    }
    .pickerStyle(.menu)

    Text(store.settings.appearance.zoomMethod.detail)
      .font(.caption)
      .foregroundStyle(.secondary)

    Stepper(
      value: settingsBinding(\.appearance.fontSize),
      in: AppearanceSettings.fontSizeRange,
      step: AppearanceSettings.fontSizeStep
    ) {
      Text(
        "Size \(store.settings.appearance.fontSize.formatted(.number.precision(.fractionLength(0...1)))) pt"
      )
    }

    Stepper(
      value: settingsBinding(\.appearance.lineSpacing),
      in: AppearanceSettings.lineSpacingRange,
      step: AppearanceSettings.lineSpacingStep
    ) {
      Text(
        "Line spacing \(store.settings.appearance.lineSpacing.formatted(.number.precision(.fractionLength(0...1)))) pt"
      )
    }

    VStack(alignment: .leading, spacing: 4) {
      Text("User: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.userSwiftUIFont)
        .lineSpacing(CGFloat(store.settings.appearance.lineSpacing))
        .foregroundStyle(.secondary)
      Text("Assistant: the quick brown fox jumps over the lazy dog.")
        .font(store.settings.appearance.assistantSwiftUIFont)
        .lineSpacing(CGFloat(store.settings.appearance.lineSpacing))
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private func fontPickerContent(
    _ title: String,
    selection keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>
  ) -> some View {
    Picker(title, selection: fontPickerGroupBinding(keyPath)) {
      ForEach(AppearanceFontFamily.fontPickerGroups) { group in
        Text(group.displayName).tag(group.id)
      }
    }
    .pickerStyle(.menu)

    if let group = AppearanceFontFamily.installedPickerGroup(
      for: store.settings[keyPath: keyPath].pickerGroupID)
    {
      Picker("\(title) Style", selection: fontPickerFaceBinding(keyPath, group: group)) {
        ForEach(group.faces) { face in
          Text(face.displayName).tag(face.fontName)
        }
      }
      .pickerStyle(.menu)
    }
  }

  @ViewBuilder
  private var voicesContent: some View {
    NavigationLink {
      RoleVoiceSettingsView(role: .user, voice: settingsBinding(\.toolSettings.voices.user))
    } label: {
      Text("User")
    }
    NavigationLink {
      RoleVoiceSettingsView(
        role: .assistant, voice: settingsBinding(\.toolSettings.voices.assistant))
    } label: {
      Text("Assistant")
    }
    NavigationLink {
      VoiceoverSettingsView(store: store, storeObservation: storeObservation)
    } label: {
      Text("Voiceover")
    }
    Text("Voices are used by voiceover, Speak Message, and the assistant's text-to-speech tool.")
      .font(.caption)
      .foregroundStyle(.secondary)

    Picker("File / Recorded Audio Provider", selection: settingsBinding(\.transcriptionEndpointID))
    {
      Text("On-device Apple Speech").tag(Optional<UUID>.none)
      ForEach(
        store.settings.openAIEndpoints.filter { $0.isEnabled && $0.kind == .openAICompatible }
      ) { endpoint in
        Text(endpoint.displayName).tag(Optional(endpoint.id))
      }
    }
    .disabled(store.settings.isOffline)
    if let id = store.settings.transcriptionEndpointID {
      TextField("Transcription Model", text: settingsBinding(\.transcriptionModel))
        .textInputAutocapitalization(.never).autocorrectionDisabled()
      if store.settings.openAIEndpoints.first(where: { $0.id == id })?.isDirectGroq == true {
        Menu("Choose Transcription Model") {
          ForEach(GroqSpeech.transcriptionModels, id: \.self) { model in
            Button(model) {
              store.settings.transcriptionModel = model
              store.saveSettings()
            }
          }
        }
      }
      Text(
        "Recordings and imported audio are sent to this provider. Voice input records a file before transcription. Airplane Mode blocks provider transcription."
      )
      .font(.caption).foregroundStyle(.secondary)
    }

    Toggle(
      "Allow Apple Server Transcription",
      isOn: Binding(
        get: { store.settings.appleServerTranscriptionAllowed },
        set: { value in
          store.settings.allowAppleServerTranscription = value
          store.saveSettings()
        })
    )
    .disabled(store.settings.isOffline)
    Text(
      store.settings.isOffline
        ? "Offline mode requires on-device transcription, even when Apple server transcription is permitted."
        : "Off by default. Allows recordings and imported audio to be sent to Apple if on-device transcription fails or is unavailable. Native iOS Live always stays on device."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    Text("Transcription uses installed speech models only; PocketMai does not download them.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var hapticsContent: some View {
    Toggle("Enable Haptics", isOn: settingsBinding(\.appearance.hapticsEnabled))
    Text(
      store.settings.appearance.hapticsEnabled
        ? "Irregular typing-like taps play while the assistant streams; a vibration pulse plays when it ends."
        : "Assistant response haptics are disabled."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var conversationOptionsContent: some View {
    Stepper(
      value: settingsBinding(\.conversation.silenceTimeoutSeconds),
      in: ConversationSettings.silenceTimeoutRange,
      step: ConversationSettings.silenceTimeoutStep
    ) {
      Text(
        "Silence \(store.settings.conversation.silenceTimeoutSeconds.formatted(.number.precision(.fractionLength(0...2)))) sec"
      )
    }

    Picker("Speech to Text", selection: settingsBinding(\.conversation.speechRecognitionBackend)) {
      ForEach(LiveSpeechRecognitionBackend.allCases) { backend in
        Label(
          backend.displayName,
          systemImage: backend.systemImage
        )
        .tag(backend)
        .disabled(!backend.isRuntimeAvailable)
      }
    }
    .pickerStyle(.menu)
    .disabled(store.settings.transcriptionEndpointID != nil)
    .onChange(of: store.settings.conversation.speechRecognitionBackend) { _, backend in
      guard backend != .nativeIOSSpeechTranscriber,
        store.settings.conversation.backgroundVoiceListeningEnabled
      else {
        return
      }
      store.settings.conversation.backgroundVoiceListeningEnabled = false
      store.saveSettings()
    }
    if let reason = store.settings.conversation.speechRecognitionBackend.unavailableReason {
      Text(reason)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Picker("Language", selection: speechRecognitionPrimaryLanguageBinding) {
      ForEach(speechRecognitionPrimaryLanguages, id: \.self) { primary in
        Text(SystemLanguageSupport.primaryLanguageDisplayName(primary)).tag(primary)
      }
    }
    .pickerStyle(.menu)

    let variants = speechRecognitionVariants(
      forPrimary: speechRecognitionPrimaryLanguageBinding.wrappedValue)
    if variants.count > 1 {
      Picker(
        "Region",
        selection: settingsBinding(\.conversation.speechRecognitionLanguageIdentifier)
      ) {
        ForEach(variants, id: \.self) { id in
          Text(SystemLanguageSupport.variantDisplayName(id)).tag(id)
        }
      }
      .pickerStyle(.menu)
    }

    Toggle("Continue Voice Chat When Locked", isOn: backgroundVoiceListeningBinding)
      .disabled(!store.settings.conversation.canUseBackgroundVoiceListening)

    Toggle("StreamTTS", isOn: settingsBinding(\.conversation.streamTTS))

    Toggle(
      "Skip Code and Links in TTS",
      isOn: settingsBinding(\.conversation.skipTechnicalContentInTTS))

  }

  private var speechRecognitionLocaleIdentifiers: [String] {
    let selected = store.settings.conversation.speechRecognitionLanguageIdentifier
      .trimmingCharacters(in: .whitespacesAndNewlines)
    var ids = SystemLanguageSupport.speechRecognitionLocaleIdentifiers
    if !selected.isEmpty, !ids.contains(selected) {
      ids.append(selected)
    }
    return SystemLanguageSupport.sortedLanguageIdentifiers(ids)
  }

  private var speechRecognitionPrimaryLanguages: [String] {
    let primaries = Set(
      speechRecognitionLocaleIdentifiers.compactMap {
        SystemLanguageSupport.primaryLanguageCode($0)
      })
    return Array(primaries).sorted {
      SystemLanguageSupport.primaryLanguageDisplayName($0)
        .localizedCaseInsensitiveCompare(SystemLanguageSupport.primaryLanguageDisplayName($1))
        == .orderedAscending
    }
  }

  private func speechRecognitionVariants(forPrimary primary: String) -> [String] {
    speechRecognitionLocaleIdentifiers
      .filter { SystemLanguageSupport.primaryLanguageCode($0) == primary }
      .sorted {
        SystemLanguageSupport.variantDisplayName($0)
          .localizedCaseInsensitiveCompare(SystemLanguageSupport.variantDisplayName($1))
          == .orderedAscending
      }
  }

  private var speechRecognitionPrimaryLanguageBinding: Binding<String> {
    Binding(
      get: {
        let id = store.settings.conversation.speechRecognitionLanguageIdentifier
        return SystemLanguageSupport.primaryLanguageCode(id) ?? id
      },
      set: { newPrimary in
        let variants = speechRecognitionVariants(forPrimary: newPrimary)
        let current = store.settings.conversation.speechRecognitionLanguageIdentifier
        if variants.contains(current) { return }
        store.settings.conversation.speechRecognitionLanguageIdentifier =
          variants.first ?? newPrimary
        store.saveSettings()
      }
    )
  }

  private var backgroundVoiceListeningBinding: Binding<Bool> {
    Binding(
      get: { store.settings.conversation.allowsBackgroundVoiceListening },
      set: { enabled in
        guard store.settings.conversation.canUseBackgroundVoiceListening else {
          store.settings.conversation.backgroundVoiceListeningEnabled = false
          store.saveSettings()
          return
        }
        guard enabled else {
          store.settings.conversation.backgroundVoiceListeningEnabled = false
          store.saveSettings()
          return
        }
        guard !store.settings.conversation.backgroundVoiceListeningEnabled else { return }
        showingBackgroundVoiceConfirmation = true
      }
    )
  }

  /// Like `settingsBinding`, but turning a notification on also asks the system
  /// for permission so the toggle is not silently ineffective.
  private func notificationBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
    Binding(
      get: { store.settings[keyPath: keyPath] },
      set: { enabled in
        store.settings[keyPath: keyPath] = enabled
        store.saveSettings()
        guard enabled else { return }
        Task {
          await ResponseNotificationService.shared.requestAuthorizationIfNeeded()
          await refreshNotificationAuthorizationStatus()
        }
      }
    )
  }

  private func refreshNotificationAuthorizationStatus() async {
    notificationAuthorizationStatus = await ResponseNotificationService.shared.authorizationStatus()
  }

  private func openSystemSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
  }

  private func enableBackgroundVoiceListening() {
    guard store.settings.conversation.canUseBackgroundVoiceListening else {
      store.settings.conversation.backgroundVoiceListeningEnabled = false
      store.saveSettings()
      return
    }
    store.settings.conversation.backgroundVoiceListeningEnabled = true
    store.saveSettings()
  }

  @ViewBuilder
  private var endpointContent: some View {
    NavigationLink {
      AppleIntelligenceDetailView()
    } label: {
      appleIntelligenceProviderRow
    }

    NavigationLink {
      LocalLLMView()
    } label: {
      mlxProviderRow
    }

    ForEach(store.settings.openAIEndpoints) { endpoint in
      NavigationLink(value: SettingsRoute.endpoint(endpoint.id)) {
        endpointRow(endpoint)
      }
      .disabled(store.settings.isOffline)
      .opacity(store.settings.isOffline ? 0.5 : 1)
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .endpoint, offsets: offsets)
    }
    Button {
      let endpoint = OpenAIEndpoint(baseURL: "", authMethod: .apiKey)
      draftEndpoint = endpoint
      navigationPath.append(.endpoint(endpoint.id))
    } label: {
      Label("Add Provider", systemImage: "plus")
    }
    .disabled(store.settings.isOffline)
    Text(
      store.settings.isOffline
        ? store.offlineProviderGuidance
        : "OpenAI-compatible providers can be added, edited, or removed. On-device providers depend on this device's hardware."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var appleIntelligenceProviderRow: some View {
    let report = store.appleAvailabilityReport
    let enabled = store.settings.appleProviderEnabled
    let deviceOnlyReady = store.settings.isOffline && report.kind == .available
    return providerStatusRow(
      title: "Apple Intelligence",
      subtitle: enabled
        ? (deviceOnlyReady ? "Ready: device-only on this device" : report.providerListSubtitle)
        : "Disabled in app",
      systemImage: appleIntelligenceStatusIcon(report.kind),
      color: enabled ? appleIntelligenceStatusColor(report.kind) : .secondary,
      badge: enabled ? (deviceOnlyReady ? "Device" : report.statusLabel) : "Off"
    )
  }

  private var mlxProviderRow: some View {
    let modelID = store.settings.localMLXModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let downloadedCount = store.localMLXModelIDs.count
    let subtitle: String = {
      if !store.localMLXIsAvailable {
        return "Unsupported on this device. Tap for requirements and alternatives."
      }
      if downloadedCount == 0 {
        return "No downloaded models"
      }
      let countText = "\(downloadedCount) downloaded"
      guard !modelID.isEmpty else {
        return countText
      }
      guard store.localMLXModelIDs.contains(modelID) else {
        return "\(countText). Select a downloaded model"
      }
      return "\(countText). \(modelID)"
    }()
    return providerStatusRow(
      title: "Local MLX LLM",
      subtitle: subtitle,
      systemImage: "cpu",
      color: store.localMLXIsAvailable ? .green : .secondary,
      badge: store.localMLXIsAvailable ? "Built-in" : "Unavailable"
    )
  }

  private func providerStatusRow(
    title: String,
    subtitle: String,
    systemImage: String,
    color: Color,
    badge: String
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .imageScale(.medium)
        .foregroundStyle(color)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Text(badge)
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
    }
    .padding(.vertical, 2)
  }

  private func appleIntelligenceStatusIcon(_ kind: AppleFoundationAvailabilityKind) -> String {
    switch kind {
    case .checking:
      return "arrow.triangle.2.circlepath"
    case .available:
      return "checkmark.circle.fill"
    case .deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady, .unavailable:
      return "exclamationmark.circle.fill"
    }
  }

  private func appleIntelligenceStatusColor(_ kind: AppleFoundationAvailabilityKind) -> Color {
    switch kind {
    case .checking:
      return .orange
    case .available:
      return .green
    case .modelNotReady:
      return .orange
    case .deviceNotEligible, .appleIntelligenceNotEnabled, .unavailable:
      return .red
    }
  }

  private func endpointRow(_ endpoint: OpenAIEndpoint) -> some View {
    let status = store.endpointStatuses[endpoint.id] ?? .unknown
    let subtitle: String = {
      let trimmedModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedModel.isEmpty {
        return trimmedModel
      }
      let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
      return host.isEmpty ? "No model selected" : host
    }()
    return HStack(spacing: 12) {
      Image(systemName: endpointStatusIcon(status))
        .imageScale(.medium)
        .foregroundStyle(status.statusColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(endpoint.displayName)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if store.settings.isOffline {
        Text("Offline")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      } else if !endpoint.isEnabled {
        Text("Off")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  private func endpointStatusIcon(_ status: EndpointConnectionState) -> String {
    switch status {
    case .unknown: "circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .available: "checkmark.circle.fill"
    case .failed: "exclamationmark.circle.fill"
    }
  }

  @ViewBuilder
  private var promptContent: some View {
    Text(
      "System prompts modify the nature of the personality and responses behaviour of the assistant."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
    NavigationLink {
      TextDocumentEditor(
        title: "Compact Prompt",
        instructions: "Use {{transcript}} where the conversation transcript should be inserted. If omitted, the transcript is appended after the prompt.",
        defaultText: AppSettings.defaultCompactPrompt,
        load: { store.settings.compactPrompt },
        save: { text in
          settingsBinding(\.compactPrompt).wrappedValue =
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppSettings.defaultCompactPrompt : text
        })
    } label: {
      compactPromptRow
    }
    ForEach(store.settings.systemPrompts) { prompt in
      NavigationLink {
        PromptDetailView(.init(
          systemPrompt: prompt,
          isDefault: prompt.id == store.settings.defaultSystemPromptID))
      } label: {
        promptRow(prompt)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .systemPrompt, offsets: offsets)
    }
    NavigationLink {
      PromptDetailView(.init())
    } label: {
      Label("Add Prompt", systemImage: "plus")
    }
  }

  @ViewBuilder
  private var userPromptContent: some View {
    Text(
      "User prompts can be used when prefixing the message with '/' or '$'"
    )
    ForEach(store.settings.userPrompts) { prompt in
      NavigationLink {
        PromptDetailView(.init(userPrompt: prompt))
      } label: {
        userPromptRow(prompt)
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .userPrompt, offsets: offsets)
    }
    NavigationLink {
      PromptDetailView(.init(userPrompt: nil))
    } label: {
      Label("Add User Prompt", systemImage: "plus")
    }
  }

  private var compactPromptRow: some View {
    let trimmed = store.settings.compactPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: "rectangle.compress.vertical")
        .imageScale(.medium)
        .foregroundStyle(Color.accentColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text("Compact Prompt")
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private func promptRow(_ prompt: SystemPrompt) -> some View {
    let isDefault = prompt.id == store.settings.defaultSystemPromptID
    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: isDefault ? "star.fill" : "text.bubble")
        .imageScale(.medium)
        .foregroundStyle(isDefault ? Color.accentColor : .secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.displayName)
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private func userPromptRow(_ prompt: UserPrompt) -> some View {
    let trimmed = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let preview = trimmed.split(separator: "\n").first.map(String.init) ?? ""
    return HStack(spacing: 12) {
      Image(systemName: "text.quote")
        .imageScale(.medium)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(prompt.displayName)
          .font(.body)
        Text(preview.isEmpty ? "Empty" : preview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
    .padding(.vertical, 2)
  }

  private var toolsSection: some View {
    Section {
      ToolCatalogSettingsButton()
      SettingsLazyDisclosureGroup {
        contextToolsContent
      } label: {
        Label("Contextual", systemImage: "text.append")
      }

      SettingsLazyDisclosureGroup {
        builtInToolsContent
      } label: {
        Label("Native", systemImage: "wrench.and.screwdriver")
      }

      SettingsLazyDisclosureGroup {
        externalToolsContent
      } label: {
        Label("MCPs", systemImage: "server.rack")
      }

      SettingsLazyDisclosureGroup {
        SkillsSettingsView()
      } label: {
        Label("Skills", systemImage: "sparkles")
      }

      SettingsLazyDisclosureGroup {
        toolOptionsContent
      } label: {
        Label("Options", systemImage: "slider.horizontal.3")
      }
    } header: {
      Text("Tools")
    }
  }

  @ViewBuilder
  private var builtInToolsContent: some View {
    ForEach(BuiltInToolID.allCases.filter(\.isCallableTool)) { tool in
      toolRow(tool)
    }
  }

  @ViewBuilder
  private var contextToolsContent: some View {
    ForEach(BuiltInToolID.allCases.filter(\.isContextSource)) { tool in
      toolRow(tool)
    }
    Text(
      "Context tools are rendered into the system prompt instead of being called on-demand. Toggle each tool to include its content in every chat."
    )
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private func toolRow(_ tool: BuiltInToolID) -> some View {
    NativeToolSettingsRow(
      tool: tool,
      isEnabled: store.settings.defaultEnabledTools.contains(tool),
      isUnavailable: store.settings.isOffline && tool.isDisabledInAirplaneMode,
      isExpanded: Binding(
        get: { expandedToolOptions.contains(tool) },
        set: { expanded in
          if expanded { expandedToolOptions.insert(tool) }
          else { expandedToolOptions.remove(tool) }
        }),
      toggle: { store.setNativeTool(tool, enabled: !store.settings.defaultEnabledTools.contains(tool), in: .agentDefaults) }
    ) {
      toolOptions(tool)
    }
  }

  @ViewBuilder
  private func toolOptions(_ tool: BuiltInToolID) -> some View {
    switch tool {
    case .prompts:
      Toggle("Read-only", isOn: settingsBinding(\.toolSettings.promptsReadOnly))
      Text("Lists and reads saved system and user prompts. Turn off Read-only to expose the tool for creating and editing prompts. Applies to all agents.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .datetime:
      Toggle("Include time zone", isOn: settingsBinding(\.toolSettings.includeTimeZone))
      Toggle("Include moon phase", isOn: settingsBinding(\.toolSettings.includeMoonPhase))
    case .language:
      Text(
        "Adds the chat language preference to the prompt. Chats set to Defaults use the language from Conversation settings, then voice settings."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .location:
      Toggle("Use GPS location", isOn: settingsBinding(\.toolSettings.useGPSLocation))
        .onChange(of: store.settings.toolSettings.useGPSLocation) { _, enabled in
          if enabled {
            store.locationService.requestAuthorization(precise: store.settings.toolSettings.preciseLocation)
          }
        }
      if store.settings.toolSettings.useGPSLocation {
        Toggle("Precise location", isOn: settingsBinding(\.toolSettings.preciseLocation))
          .onChange(of: store.settings.toolSettings.preciseLocation) { _, enabled in
            store.locationService.requestAuthorization(precise: enabled)
          }
        Text("When enabled, requests precise GPS coordinates. Turn off to share an approximate position.")
          .font(.caption)
          .foregroundStyle(.secondary)
        LocationPermissionStatusView(service: store.locationService)
      } else {
        TextField("Manual location", text: settingsBinding(\.toolSettings.manualLocation))
      }
      Text("Adds a fresh location to each message while this tool is enabled in the chat. Coordinates are shared with the selected AI provider. Enable Web Search or Browser for nearby maps and information.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .weather:
      TextField("Weather location", text: settingsBinding(\.toolSettings.weatherLocation))
    case .webSearch:
      Picker("Provider", selection: settingsBinding(\.toolSettings.webSearchProvider)) {
        ForEach(availableWebSearchProviders, id: \.rawValue) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      if showsSearXNGSettings {
        TextField("SearXNG URL", text: settingsBinding(\.toolSettings.webSearchSearXNGURL))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
        TextField(
          "SearXNG username", text: settingsBinding(\.toolSettings.webSearchSearXNGUsername)
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        SecureField(
          "SearXNG password", text: settingsBinding(\.toolSettings.webSearchSearXNGPassword))
      }
      Toggle(
        "Fetching data",
        isOn: settingsBinding(\.toolSettings.webSearchFetchingEnabled))
    case .todo:
      HStack {
        TextField("New todo", text: $newTodoTitle)
          .submitLabel(.done)
          .onSubmit {
            addTodo()
          }
        Button {
          addTodo()
        } label: {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
      }
      ForEach(todosBinding) { $todo in
        HStack(spacing: 10) {
          Button {
            todo.isDone.toggle()
            store.saveSettings()
          } label: {
            Image(systemName: todo.isDone ? "checkmark.circle.fill" : "circle")
              .imageScale(.large)
              .foregroundStyle(todo.isDone ? Color.accentColor : .secondary)
          }
          .buttonStyle(.borderless)
          TextField("Todo", text: $todo.title)
            .foregroundStyle(todo.isDone ? .secondary : .primary)
        }
      }
      .onDelete { offsets in
        deleteTodos(at: offsets)
      }
    case .calculator:
      Text("Evaluates local arithmetic with parentheses, +, -, *, and /.")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .textToSpeech:
      Text("Configure user and assistant voices in Look and Feel.")
        .font(.footnote)
        .foregroundStyle(.secondary)
    case .calendar:
      Toggle(
        "Allow creating events",
        isOn: settingsBinding(\.toolSettings.calendarEventCreationEnabled))
      Text(
        "Off exposes only calendar_read_events. On also exposes calendar_create_event. Reads request full Calendar access only when called; event creation requests write-only Calendar access when possible."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .vdb:
      Toggle(
        "Enable workspace access",
        isOn: settingsBinding(\.toolSettings.filesWorkspaceAccessEnabled))
      Text(
        "Indexes documents and source code in this chat's working folder for local search. Ask to index a file or folder, then ask questions about it. Results include source paths and line ranges. The index persists in the working folder and works offline, even with a single document. Ask to reindex after changing files."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .files:
      Toggle(
        "Enable Files tools",
        isOn: settingsBinding(\.toolSettings.filesWorkspaceAccessEnabled))
      Text(
        "The assistant can create folders, list and find files, read and edit text, rename entries, and delete files of any type in the chat's working folder. Creating nested folders and deleting non-empty folders are supported by the basic tools. The working folder is FilesData unless the chat selects another folder, such as iCloud Drive, from the + menu or inherits one from Manage Folders. Documents can be read as Markdown and images as text using OCR. Downloaded MLX models are visible in the iOS Files app under Models, but unavailable to FilesData tools."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Toggle(
        "Enable advanced file tools",
        isOn: settingsBinding(\.toolSettings.filesAdvancedToolsEnabled))
      Text(
        "Off keeps the basic file management tools only. On adds coding-oriented tools: files_read_index lists function and type names in source files (C, Java, Python, Swift, and more) and section headings in Markdown or converted documents with line numbers; files_read_range reads line ranges; files_patch edits matching text; and files_get_function with files_set_function reads and replaces complete function bodies with revision checks. Prefer literal files_patch replacements for small edits."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button {
        showingToolFileImporter = true
      } label: {
        Label("Import Text File", systemImage: "doc.badge.plus")
      }
      .buttonStyle(.borderless)
      ForEach(store.settings.toolSettings.files) { file in
        VStack(alignment: .leading) {
          Text(file.name)
            .font(.body.weight(.medium))
          Text(file.excerpt)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
        }
      }
      .onDelete { offsets in
        pendingDeletion = PendingSettingsDeletion(kind: .file, offsets: offsets)
      }
    case .clipboard:
      Text(
        "Lets the assistant read and replace the text on the system clipboard. Disabled by default because the clipboard may contain sensitive data such as passwords; each call asks for confirmation."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .webxdc:
      Text(
        "Lets the assistant create, edit, and roll back webxdc mini apps (HTML/CSS/JS) stored on this device. Every change makes a numbered revision. Safe defaults keep apps offline and deny device resources; changing runtime options applies to newly opened app sessions. Manage apps from Apps in the folders menu."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        webXDCToggle("Internet and WebSockets", \.toolSettings.webxdcAllowInternet)
        webXDCToggle("Chat bridge", \.toolSettings.webxdcChatInteractionEnabled)
        webXDCToggle("Inference and speech APIs", \.toolSettings.webxdcAllowProviderAPIs)
        Text(
          "Each app asks for access to inference or speech. Manage its grants with the Permissions button while the app is open."
        )
          .font(.caption)
          .foregroundStyle(.secondary)
        webXDCToggle("GPS location", \.toolSettings.webxdcAllowGPSLocation)
        webXDCToggle("Accelerometer and gyroscope", \.toolSettings.webxdcAllowMotionSensors)
        webXDCToggle("WebAssembly", \.toolSettings.webxdcAllowWASM)
        webXDCToggle("WebGL", \.toolSettings.webxdcAllowWebGL)
        webXDCToggle("Canvas 2D", \.toolSettings.webxdcAllowCanvas2D)
        webXDCToggle("Audio playback", \.toolSettings.webxdcAllowAudioPlayback)
        webXDCToggle("Camera", \.toolSettings.webxdcAllowCamera)
        webXDCToggle("Microphone", \.toolSettings.webxdcAllowMicrophone)
        webXDCToggle("Clipboard", \.toolSettings.webxdcAllowClipboard)
        webXDCToggle("File import", \.toolSettings.webxdcAllowFileImport)
        webXDCToggle("Local storage", \.toolSettings.webxdcAllowLocalStorage)
        webXDCToggle("Service workers", \.toolSettings.webxdcAllowServiceWorkers)
        webXDCToggle("Notifications", \.toolSettings.webxdcAllowNotifications)
        webXDCToggle("Realtime channels", \.toolSettings.webxdcAllowRealtimeChannels)
        Button {
          resetWebXDCOptions()
        } label: {
          Label("Reset WebXDC Options", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .padding(.top, 6)
      }
    case .alarms:
      Text(
        "Lets the assistant schedule, list, and cancel real alarms on this device, such as 'in 5 minutes' or at a specific time or weekday. Disabled by default; each call asks for confirmation, requires the AlarmKit permission, and needs iOS 26.1 or later."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .github:
      Text(
        "Browse GitHub repositories, files, commits, PRs, discussions, issues, releases, and CI results. With a writable token, post comments, submit reviews with inline code suggestions, and create PRs from pushed branches. Leave the token empty for public reads. For a fine-grained token, select repositories and grant read access as needed to Contents, Pull requests, Issues, Checks, and Actions; grant Pull requests write access for reviews/PR creation, and Issues or Pull requests write access for comments. Disabled by default; calls follow your tool approval settings."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      SecureField(
        "GitHub personal access token (optional)",
        text: settingsBinding(\.toolSettings.githubAPIKey)
      )
      .textInputAutocapitalization(.never)
      .autocorrectionDisabled()
    case .browser:
      Text(
        "Opens web pages in a small in-app browser card. The model can read the page, click, type, scroll, and run JavaScript; tap the card to enlarge it and take over by hand, for example to sign in, then tell the model to continue. Website data such as cookies stays on this device. Calls ask for confirmation."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      Button("Clear Website Data") {
        Task {
          await BrowserSession.clearWebsiteData()
          toastMessage = ToastNotice("Website data cleared", style: .success)
        }
      }
    case .mastodon:
      Text(
        "Connects to one Mastodon instance for searching posts, reading a user's recent posts, and posting or replying. Search is public where the instance allows it; posting requires an API key. Calls ask for confirmation."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      TextField("Mastodon instance", text: settingsBinding(\.toolSettings.mastodonInstance))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      SecureField("Mastodon API key", text: settingsBinding(\.toolSettings.mastodonAPIKey))
      Toggle(
        "Allow posting and replying",
        isOn: settingsBinding(\.toolSettings.mastodonWriteEnabled))
    case .memory:
      TextEditor(text: settingsBinding(\.memory))
        .frame(minHeight: 140)
        .font(.callout)
      Button {
        Task { await store.updateMemoryFromConversations() }
      } label: {
        if store.isUpdatingMemory {
          ProgressView()
        } else {
          Label("Update From Conversations", systemImage: "wand.and.sparkles")
        }
      }
      .disabled(store.isUpdatingMemory || !hasConversationContent)
      Button {
        showingClearMemoryConfirmation = true
      } label: {
        let memoryEmpty =
          store.settings.memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let active = hasConversationContent && !memoryEmpty
        Label("Clear Memory", systemImage: "trash")
          .foregroundStyle(active ? Color.red : Color.secondary)
      }
      .disabled(
        !hasConversationContent
          || store.settings.memory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      Text(
        "Memory is added to the system prompt as durable context when the Memory context tool is enabled."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    case .remote:
      NavigationLink("Configure Remote Hosts") { RemoteAgentsView() }
      Text("Enable agent access for each host, then enable Remote Hosts in a conversation to use its files, programs and terminals.")
        .font(.caption).foregroundStyle(.secondary)
    case .context:
      Picker(
        "Chat access",
        selection: settingsBinding(\.toolSettings.conversationSearchScope)
      ) {
        ForEach(ConversationSearchScope.allCases) { scope in
          Text(scope.displayName).tag(scope)
        }
      }
      Text(
        "Lets the assistant list, search, and read saved chats and their attached documents. This access setting applies to all chats with Context enabled in the chat's tool picker. Current Chat limits context to this chat; Current Folder allows other chats in the same conversation folder; All Folders allows chats across conversation folders."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var externalToolsContent: some View {
    Toggle("Use tool proxy (list / call)", isOn: settingsBinding(\.useToolProxy))
    Toggle("System One tool decisions", isOn: settingsBinding(\.useSystemOne))
    Text(
      "Assign a System One provider and model to Tool decisions in Manage Agents. The chat model fills tool arguments."
    )
    .font(.caption).foregroundStyle(.secondary)
    Text(toolProxySummary)
      .font(.caption)
      .foregroundStyle(.secondary)
    ForEach(store.settings.mcpServers) { server in
      HStack(spacing: 12) {
        NavigationLink(value: SettingsRoute.mcpServer(server.id)) {
          mcpRow(server)
        }
        ToolCatalogSettingsButton(groupID: "mcp/\(server.portableID ?? server.id.uuidString.lowercased())")
      }
    }
    .onDelete { offsets in
      pendingDeletion = PendingSettingsDeletion(kind: .mcpServer, offsets: offsets)
    }
    Button {
      let server = MCPServer(name: "", baseURL: "")
      draftMCPServer = server
      navigationPath.append(.mcpServer(server.id))
    } label: {
      Label("Add MCP Server", systemImage: "plus")
    }
    Text("Streamable HTTP MCP endpoints are supported. Legacy /sse endpoints are rejected.")
      .font(.caption)
      .foregroundStyle(.secondary)
  }

  private func mcpRow(_ server: MCPServer) -> some View {
    let transport = server.transport?.displayName
    let subtitle: String = {
      if let tools = store.mcpTools[server.id], !tools.isEmpty {
        let resources = store.mcpResources[server.id] ?? []
        let resourceText =
          resources.isEmpty ? "" : ", \(resources.count) resource\(resources.count == 1 ? "" : "s")"
        let catalogText = "\(tools.count) tool\(tools.count == 1 ? "" : "s")\(resourceText)"
        return [transport, catalogText].compactMap { $0 }.joined(separator: " • ")
      }
      if let resources = store.mcpResources[server.id], !resources.isEmpty {
        let resourceText = "\(resources.count) resource\(resources.count == 1 ? "" : "s")"
        return [transport, resourceText].compactMap { $0 }.joined(separator: " • ")
      }
      let url = server.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
      if url.isEmpty || url == "https://" {
        return transport ?? "No URL set"
      }
      let endpointText = URL(string: url)?.host ?? url
      return [transport, endpointText].compactMap { $0 }.joined(separator: " • ")
    }()
    let icon: String = {
      if server.isHTTPS && server.hasValidEndpointURL { return "lock.fill" }
      if server.hasValidEndpointURL { return "globe" }
      return "lock.trianglebadge.exclamationmark"
    }()
    let iconColor: Color = {
      if server.isHTTPS && server.hasValidEndpointURL { return .green }
      if server.hasValidEndpointURL { return .orange }
      return .red
    }()
    return HStack(spacing: 12) {
      Image(systemName: icon)
        .imageScale(.medium)
        .foregroundStyle(iconColor)
        .frame(width: 18)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.name.isEmpty ? "Untitled Server" : server.name)
          .font(.body)
          .foregroundStyle(.primary)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      if !server.isEnabled {
        Text("Off")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
    }
    .padding(.vertical, 2)
  }

  private var aboutSection: some View {
    Section {
      HStack {
        Text("Author")
        Spacer()
        Text("pancake").foregroundStyle(.secondary)
      }
      HStack {
        Text("Version")
        Spacer()
        Text(appVersionString).foregroundStyle(.secondary)
      }
      Link(destination: URL(string: "https://github.com/trufae/mai")!) {
        HStack {
          Label("GitHub", systemImage: "link")
          Spacer()
          Image(systemName: "arrow.up.right")
            .imageScale(.small)
            .foregroundStyle(.tertiary)
        }
      }
      NavigationLink {
        UsageStatsView()
      } label: {
        Label("Statistics", systemImage: "chart.bar")
      }
      NavigationLink {
        LicensesView()
      } label: {
        Label("Licenses", systemImage: "doc.text")
      }
    } header: {
      Text("About")
    }
  }

  private var appVersionString: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    if let build = info?["CFBundleVersion"] as? String, build != short {
      return "\(short) (\(build))"
    }
    return short
  }

  private var dangerSection: some View {
    Section {
      NavigationLink {
        SettingsImportView()
          .environmentObject(store)
      } label: {
        Label("Import...", systemImage: "square.and.arrow.down")
      }

      NavigationLink {
        SettingsExportView()
          .environmentObject(store)
      } label: {
        Label("Export...", systemImage: "square.and.arrow.up")
      }

      if corruptedConversationCount > 0 {
        Button {
          showingCorruptedConversationActions = true
        } label: {
          Label(
            "Recover \(corruptedConversationCount) Corrupted \(corruptedConversationCount == 1 ? "Chat" : "Chats")",
            systemImage: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90"
          )
          .foregroundStyle(Color.orange)
        }
      }

      NavigationLink {
        SettingsDestroyView { dismiss() }
          .environmentObject(store)
      } label: {
        Label("Destroy...", systemImage: "exclamationmark.triangle")
          .foregroundStyle(Color.red)
      }
    } header: {
      Text("Danger Zone")
    } footer: {
      Text(
        "Move data between devices with Import and Export, or clear local data from Destroy. Destructive actions still require confirmation."
      )
    }
  }

  private var hasConversationContent: Bool {
    store.conversationSummaries.contains(where: \.hasMessages)
  }

  private func refreshCorruptedConversationCount() async {
    corruptedConversationCount = await store.corruptedConversationCount()
  }

  private func exportCorruptedConversations() async {
    let result = await store.exportCorruptedConversationsArchive()
    if let url = result.url {
      corruptedConversationArchive = ExportedFile(url: url)
    } else {
      toastMessage = ToastNotice(result.errorMessage ?? "Could not export corrupted chats.")
    }
  }

  private func recoverCorruptedConversations() async {
    let result = await store.recoverCorruptedConversations()
    corruptedConversationCount = result.remainingCount
    if result.recoveredConversations.isEmpty {
      toastMessage = ToastNotice("No corrupted chats could be recovered.")
    } else {
      let count = result.recoveredConversations.count
      toastMessage = ToastNotice("Recovered \(count) \(count == 1 ? "chat" : "chats").", style: .success)
    }
  }

  private var settingsDeletionConfirmationBinding: Binding<Bool> {
    Binding {
      pendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        pendingDeletion = nil
      }
    }
  }

  private func performSettingsDeletion(_ deletion: PendingSettingsDeletion) {
    defer { pendingDeletion = nil }

    switch deletion.kind {
    case .endpoint:
      guard deletion.offsets.allSatisfy({ store.settings.openAIEndpoints.indices.contains($0) })
      else { return }
      let removedIDs = deletion.offsets.map { store.settings.openAIEndpoints[$0].id }
      store.settings.openAIEndpoints.remove(atOffsets: deletion.offsets)
      for id in removedIDs {
        store.resetEndpointStatus(id)
      }
      if let selected = store.settings.selectedEndpointID, removedIDs.contains(selected) {
        store.settings.selectedEndpointID = store.settings.openAIEndpoints.first?.id
        if store.settings.selectedEndpointID == nil {
          store.settings.defaultProvider = .mlx
        }
      }
      navigationPath.removeAll { route in
        if case .endpoint(let id) = route {
          return removedIDs.contains(id)
        }
        return false
      }
      store.saveSettings()
    case .systemPrompt:
      guard deletion.offsets.allSatisfy({ store.settings.systemPrompts.indices.contains($0) })
      else { return }
      store.settings.systemPrompts.remove(atOffsets: deletion.offsets)
      if !store.settings.systemPrompts.contains(where: {
        $0.id == store.settings.defaultSystemPromptID
      }) {
        store.settings.defaultSystemPromptID =
          store.settings.systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id
      }
      if store.settings.systemPrompts.isEmpty {
        store.settings.systemPrompts = [AppSettings.defaultSystemPrompt]
        store.settings.defaultSystemPromptID = AppSettings.defaultSystemPrompt.id
      }
      store.saveSettings()
    case .userPrompt:
      guard deletion.offsets.allSatisfy({ store.settings.userPrompts.indices.contains($0) })
      else { return }
      store.settings.userPrompts.remove(atOffsets: deletion.offsets)
      store.saveSettings()
    case .file:
      guard deletion.offsets.allSatisfy({ store.settings.toolSettings.files.indices.contains($0) })
      else { return }
      store.settings.toolSettings.files.remove(atOffsets: deletion.offsets)
      store.saveSettings()
    case .mcpServer:
      guard deletion.offsets.allSatisfy({ store.settings.mcpServers.indices.contains($0) })
      else { return }
      let removedIDs = deletion.offsets.map { store.settings.mcpServers[$0].id }
      store.settings.mcpServers.remove(atOffsets: deletion.offsets)
      for id in removedIDs {
        store.settings.toolSelection.setServer(id, enabled: false)
        store.mcpStatuses[id] = nil
        store.mcpTools[id] = nil
        store.mcpResources[id] = nil
        Task { await MCPHTTPClient.resetSession(for: id) }
      }
      navigationPath.removeAll { route in
        if case .mcpServer(let id) = route {
          return removedIDs.contains(id)
        }
        return false
      }
      store.saveSettings()
    }
  }

  private func deleteTodos(at offsets: IndexSet) {
    guard offsets.allSatisfy({ store.settings.toolSettings.todos.indices.contains($0) }) else {
      return
    }
    store.settings.toolSettings.todos.remove(atOffsets: offsets)
    store.saveSettings()
  }

  private func addTodo() {
    let trimmed = newTodoTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.settings.toolSettings.todos.append(TodoItem(title: trimmed))
    newTodoTitle = ""
    store.saveSettings()
  }

  private func saveAndDismiss() {
    guard finalizeEmptyEndpointNames() else { return }
    store.saveSettings()
    dismiss()
  }

  private func finalizeEmptyEndpointNames() -> Bool {
    for index in store.settings.openAIEndpoints.indices {
      let endpoint = store.settings.openAIEndpoints[index]
      let trimmedName = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmedName.isEmpty else { continue }

      if let message = EndpointNameResolution.nameValidationMessage(
        for: endpoint,
        in: store.settings.openAIEndpoints)
      {
        toastMessage = ToastNotice(message)
        return false
      }

      if let name = EndpointNameResolution.savedName(for: endpoint) {
        store.settings.openAIEndpoints[index].name = name
      }
    }
    return true
  }

  private func draftEndpointBinding(for id: UUID) -> Binding<OpenAIEndpoint> {
    Binding(
      get: {
        draftEndpoint ?? OpenAIEndpoint(id: id, baseURL: "", authMethod: .apiKey)
      },
      set: { endpoint in
        draftEndpoint = endpoint
      }
    )
  }

  private func discardDraftEndpointIfNeeded(path: [SettingsRoute]) {
    guard let draftEndpoint, !path.contains(.endpoint(draftEndpoint.id)) else { return }
    self.draftEndpoint = nil
  }

  private func draftMCPServerBinding(for id: UUID) -> Binding<MCPServer> {
    Binding(
      get: {
        draftMCPServer ?? MCPServer(id: id, name: "", baseURL: "")
      },
      set: { server in
        draftMCPServer = server
      }
    )
  }

  private func discardDraftMCPServerIfNeeded(path: [SettingsRoute]) {
    guard let draftMCPServer, !path.contains(.mcpServer(draftMCPServer.id)) else { return }
    store.mcpStatuses[draftMCPServer.id] = nil
    store.mcpTools[draftMCPServer.id] = nil
    store.mcpResources[draftMCPServer.id] = nil
    Task { await MCPHTTPClient.resetSession(for: draftMCPServer.id) }
    self.draftMCPServer = nil
  }

  private func toggleAirplaneMode() {
    store.toggleAirplaneMode()
  }

  private func settingsBinding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { store.settings[keyPath: keyPath] },
      set: { value in
        store.settings[keyPath: keyPath] = value
        store.saveSettings()
      }
    )
  }

  private var followUpPromptBinding: Binding<String> {
    Binding(
      get: { store.settings.followUpPromptText },
      set: { text in
        store.settings.followUps.prompt = text
        if let index = store.settings.userPrompts.firstIndex(where: {
          $0.id == AppSettings.followUpUserPrompt.id
            || PromptSlashCommand.normalized($0.commandName) == "followup"
        }) {
          store.settings.userPrompts[index].text = text
        } else {
          var prompt = AppSettings.followUpUserPrompt
          prompt.text = text
          store.settings.userPrompts.append(prompt)
        }
        store.saveSettings()
      }
    )
  }

  // Manual bindings replace `$store.settings...` projections, which are
  // unavailable now that `store` is a plain reference (observation is scoped via
  // `storeObservation`). Persistence stays with the detail views / row actions,
  // matching the previous projection-binding semantics.
  private func persistedEndpointBinding(at index: Int) -> Binding<OpenAIEndpoint> {
    Binding(
      get: { store.settings.openAIEndpoints[index] },
      set: { store.settings.openAIEndpoints[index] = $0 }
    )
  }

  private func persistedMCPServerBinding(at index: Int) -> Binding<MCPServer> {
    Binding(
      get: { store.settings.mcpServers[index] },
      set: { store.settings.mcpServers[index] = $0 }
    )
  }

  private var todosBinding: Binding<[TodoItem]> {
    Binding(
      get: { store.settings.toolSettings.todos },
      set: { store.settings.toolSettings.todos = $0 }
    )
  }

  private func resetWebXDCOptions() {
    store.settings.toolSettings.webxdcAllowInternet = false
    store.settings.toolSettings.webxdcChatInteractionEnabled = true
    store.settings.toolSettings.webxdcAllowProviderAPIs = true
    store.settings.toolSettings.webxdcAllowGPSLocation = false
    store.settings.toolSettings.webxdcAllowMotionSensors = false
    store.settings.toolSettings.webxdcAllowWASM = true
    store.settings.toolSettings.webxdcAllowWebGL = true
    store.settings.toolSettings.webxdcAllowCanvas2D = true
    store.settings.toolSettings.webxdcAllowAudioPlayback = true
    store.settings.toolSettings.webxdcAllowCamera = false
    store.settings.toolSettings.webxdcAllowMicrophone = false
    store.settings.toolSettings.webxdcAllowClipboard = false
    store.settings.toolSettings.webxdcAllowFileImport = false
    store.settings.toolSettings.webxdcAllowLocalStorage = true
    store.settings.toolSettings.webxdcAllowServiceWorkers = false
    store.settings.toolSettings.webxdcAllowNotifications = false
    store.settings.toolSettings.webxdcAllowRealtimeChannels = false
    store.saveSettings()
  }

  private func webXDCToggle(
    _ title: String,
    _ keyPath: WritableKeyPath<AppSettings, Bool>
  ) -> some View {
    Toggle(title, isOn: settingsBinding(keyPath))
      .frame(maxWidth: .infinity, minHeight: 38, alignment: .center)
  }

  private var mcpRequestTimeoutBinding: Binding<Int> {
    Binding(
      get: { AppSettings.clampedMCPRequestTimeoutSeconds(store.settings.mcpRequestTimeoutSeconds) },
      set: { value in
        store.settings.mcpRequestTimeoutSeconds = AppSettings.clampedMCPRequestTimeoutSeconds(value)
        store.saveSettings()
      }
    )
  }

  private var llmRequestTimeoutBinding: Binding<Int> {
    Binding(
      get: {
        AppSettings.normalizedLLMRequestTimeoutSeconds(store.settings.llmRequestTimeoutSeconds)
      },
      set: { value in
        store.settings.llmRequestTimeoutSeconds =
          AppSettings.normalizedLLMRequestTimeoutSeconds(value)
        store.saveSettings()
      }
    )
  }

  private func llmTimeoutLabel(_ seconds: Int) -> String {
    if seconds >= 60, seconds.isMultiple(of: 60) {
      return "\(seconds / 60) min"
    }
    return "\(seconds)s"
  }

  private var openAPIServerPortBinding: Binding<Int> {
    Binding(
      get: { store.settings.openAPIServer.port },
      set: { value in
        store.settings.openAPIServer.port = OpenAPIServerSettings.clampedPort(value)
        store.saveSettings()
      }
    )
  }

  private var openAPIServerServingBinding: Binding<Bool> {
    Binding(
      get: { store.isOpenAPIServerActive },
      set: { isServing in
        if isServing {
          store.startOpenAPIServer()
        } else {
          store.stopOpenAPIServer()
        }
      }
    )
  }

  private func fontPickerGroupBinding(
    _ keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>
  ) -> Binding<String> {
    Binding(
      get: { store.settings[keyPath: keyPath].pickerGroupID },
      set: { groupID in
        store.settings[keyPath: keyPath] = AppearanceFontFamily.font(
          forPickerGroupID: groupID,
          current: store.settings[keyPath: keyPath])
        store.saveSettings()
      }
    )
  }

  private func fontPickerFaceBinding(
    _ keyPath: WritableKeyPath<AppSettings, AppearanceFontFamily>,
    group: AppearanceFontPickerGroup
  ) -> Binding<String> {
    Binding(
      get: {
        let current = store.settings[keyPath: keyPath].installedFontName
        return group.preferredFace(currentFontName: current)?.fontName ?? ""
      },
      set: { fontName in
        guard group.faces.contains(where: { $0.fontName == fontName }) else { return }
        store.settings[keyPath: keyPath] = .installed(fontName)
        store.saveSettings()
      }
    )
  }

  private var availableWebSearchProviders: [WebSearchProvider] {
    let hasOllama = store.settings.hasOllamaWebSearchConfiguration
    return WebSearchProvider.allCases.filter { provider in
      provider != .ollama || hasOllama
    }
  }

  private var showsSearXNGSettings: Bool {
    let provider = store.settings.toolSettings.webSearchProvider
    return provider == .searXNG || provider == .all
  }
}

private struct LocationPermissionStatusView: View {
  @ObservedObject var service: LocationService

  var body: some View {
    Text(service.permissionText)
      .font(.caption)
      .foregroundStyle(.secondary)
    if service.authorizationStatus == .denied || service.accuracyAuthorization == .reducedAccuracy {
      Button("Open iOS Settings") {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
      }
    }
  }
}
