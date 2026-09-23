import MaiCore
import MaiDocuments
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

private struct ConversationTimelineTimestamp: View {
  let label: String
  let date: Date

  var body: some View {
    Text("\(label) \(ConversationDatePresentation.timestamp(date))")
      .font(.caption2)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 4)
      .accessibilityElement(children: .combine)
  }
}

struct ChatView: View {
  struct RenderInvalidationKey: Equatable {
    var isLandscape: Bool
    var selectedConversationID: UUID?
    var selectedConversationIsLoading: Bool
    var appearance: AppearanceSettings
    var renderMarkdownInChat: Bool
    var renderMarkdownImagesInChat: Bool
  }

  private struct ConversationActivitySnapshot: Equatable {
    var conversationID: UUID?
    var updatedAt: Date?
    var isResponding: Bool
  }

  private struct UserMessageNavigationState: Equatable {
    var isAtBottom = true
    var previousID: UUID?
    var nextID: UUID?
  }

  private struct MessageListScrollMetrics: Equatable {
    var viewportMinY: CGFloat
    var contentHeight: CGFloat
    var isAtBottom: Bool
  }

  private enum UserMessageNavigationDirection {
    case previous
    case next
  }

  private enum UserMessageNavigationDestination: Equatable {
    case message(UUID)
    case bottom
  }

  @ObservedObject var storeObservation: AppStoreViewObservation
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @State private var showingRenameAlert = false
  @State private var showingProviderModelSheet = false
  @State private var showingCompactSheet = false
  @State private var messagePendingDeletion: ChatMessage?
  @State private var messageBatchPendingDeletion: PendingMessageBatchDeletion?
  @State private var messagePendingTrimAndResubmit: ChatMessage?
  @State private var messagePendingRestartFresh: ChatMessage?
  @State private var isMessageSelectionMode = false
  @State private var selectedMessageIDs: Set<UUID> = []
  @State private var renameDraft = ""
  @State private var userScrolledAfterLastMessage = false
  @State private var lastStreamingScrollAt: Date?
  @State private var streamingScrollTask: Task<Void, Never>?
  @State private var pendingScrollToMessageID: UUID?
  @State private var showingWebXDCRunnerFromBar = false
  @State private var showingWebXDCStopConfirmation = false
  @State private var showingSubagents = false
  @State private var chatSearch = ChatSearchState()
  @State private var messageFontPinchSession = MessageFontPinchSession()
  @State private var keyboardOverlap: CGFloat = 0
  @State private var lastUpdatedVisibleConversationID: UUID?
  @State private var queuedMessagePendingEdit: QueuedChatMessage?
  @State private var userMessageNavigation = UserMessageNavigationState()
  @State private var userMessageNavigationDestination: UserMessageNavigationDestination?
  @State private var userMessageNavigationHiddenBySwipe = false
  @State private var userMessageNavigationIndicatorVisible = false
  @State private var userMessageNavigationIndicatorTask: Task<Void, Never>?
  @StateObject private var exportCoordinator = ConversationExportCoordinator()
  @StateObject private var liveVoiceSession = LiveVoiceSession()
  private let messageListBottomID = "MessageListBottom"
  let store: AppStore
  let renderInvalidationKey: RenderInvalidationKey
  let onShowHistory: () -> Void

  var body: some View {
    chatViewWithAlerts
  }

  private var chatViewWithAlerts: some View {
    chatViewWithSheetsAndToolbar
      .onChange(of: store.pendingLaunchAction) { _, action in
        guard let action else { return }
        store.pendingLaunchAction = nil
        Task { await applyLaunchAction(action) }
      }
      .onAppear {
        // Catch a command that was already queued during a cold launch, before
        // onChange started observing.
        if let action = store.pendingLaunchAction {
          store.pendingLaunchAction = nil
          Task { await applyLaunchAction(action) }
        }
      }
      .onChange(of: store.selectedConversationID) { _, _ in
        cancelMessageSelection()
        withAnimation(.snappy) { chatSearch.cancel() }
      }
      .onChange(of: conversationActivitySnapshot) { old, new in
        if old.conversationID != new.conversationID {
          lastUpdatedVisibleConversationID = new.isResponding ? nil : new.conversationID
        } else if old.updatedAt != new.updatedAt || (!old.isResponding && new.isResponding) {
          lastUpdatedVisibleConversationID = nil
        }
      }
      .onChange(of: currentMessageIDs) { _, _ in
        pruneSelectedMessages()
        refreshUserMessageNavigation()
        if chatSearch.isActive {
          chatSearch.rebuild(messages: store.currentConversation?.messages ?? [])
        }
      }
      .onChange(of: chatSearch.query) { _, _ in
        chatSearch.refresh()
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)
      ) {
        updateKeyboardOverlap(from: $0)
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
      ) {
        updateKeyboardOverlap(from: $0)
      }
      .alert(
        "Delete this message?",
        isPresented: deleteMessageConfirmationBinding,
        presenting: messagePendingDeletion
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingDeletion = nil
        }
        Button("Delete Message", role: .destructive) {
          store.deleteMessage(message)
          messagePendingDeletion = nil
        }
      } message: { _ in
        Text("This message will be removed from the chat. This cannot be undone.")
      }
      .alert(
        messageBatchPendingDeletion?.title ?? "Delete selected messages?",
        isPresented: deleteMessageBatchConfirmationBinding,
        presenting: messageBatchPendingDeletion
      ) { deletion in
        Button("Cancel", role: .cancel) {
          messageBatchPendingDeletion = nil
        }
        Button(deletion.buttonTitle, role: .destructive) {
          confirmMessageBatchDeletion(deletion)
        }
      } message: { deletion in
        Text(deletion.message)
      }
      .alert(
        "Retry from here?",
        isPresented: trimAndResubmitConfirmationBinding,
        presenting: messagePendingTrimAndResubmit
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingTrimAndResubmit = nil
        }
        Button("Retry From Here", role: .destructive) {
          Task { await store.trimAndResubmit(from: message) }
          messagePendingTrimAndResubmit = nil
        }
      } message: { _ in
        Text("Messages after this point will be removed before the response is regenerated.")
      }
      .alert(
        "Restart from here?",
        isPresented: restartFreshConfirmationBinding,
        presenting: messagePendingRestartFresh
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingRestartFresh = nil
        }
        Button("Restart From Here", role: .destructive) {
          Task { await store.restartFromScratch(with: message) }
          messagePendingRestartFresh = nil
        }
      } message: { _ in
        Text("All current messages will be removed before starting again from this message.")
      }
  }

  private var chatViewWithSheetsAndToolbar: some View {
    chatViewWithToolbar
      .alert("Rename", isPresented: $showingRenameAlert) {
        TextField("Chat title", text: $renameDraft)
          .onSubmit {
            renameCurrentConversation()
          }
        Button("Cancel", role: .cancel) {}
        Button("Save") {
          renameCurrentConversation()
        }
      }
      .sheet(isPresented: $showingProviderModelSheet) {
        ConversationModelSettingsView()
          .environmentObject(store)
      }
      .sheet(isPresented: $showingCompactSheet) {
        CompactChatSheet()
          .environmentObject(store)
      }
      .sheet(isPresented: $showingSubagents) {
        SubagentProcessesSheet(
          store: store,
          storeObservation: storeObservation,
          conversationID: store.currentConversation?.id)
      }
      .modifier(ConversationExportPresentations(coordinator: exportCoordinator))
  }

  private var chatViewWithToolbar: some View {
    chatLayout
      .animation(.snappy, value: ttsPlayer.isSpeaking)
      .animation(.snappy, value: isMessageSelectionMode)
      .navigationTitle("")
      .navigationBarTitleDisplayMode(.inline)
      .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button(action: onShowHistory) {
            ZStack(alignment: .topTrailing) {
              Image(systemName: "sidebar.left")
              if hasUnreadConversations {
                Circle()
                  .fill(Color.accentColor)
                  .frame(width: 8, height: 8)
                  .offset(x: 4, y: -3)
                  .accessibilityHidden(true)
              }
            }
          }
          .accessibilityLabel(
            hasUnreadConversations
              ? "Show conversations, unread messages"
              : "Show conversations"
          )
          .help("Show conversations")
        }
        ToolbarItem(placement: .principal) {
          chatTitle
        }
        ToolbarItem(placement: .topBarTrailing) {
          trailingMenu
        }
      }
  }

  private var hasUnreadConversations: Bool {
    store.conversationSummaries.contains(where: \.isUnread)
  }

  /// The browser tool's picture-in-picture card. One page for the whole
  /// app, so it follows the user across conversations.
  @ViewBuilder
  private var browserCardOverlay: some View {
    if let session = store.browserSession {
      BrowserPiPCard(session: session) {
        store.closeBrowserSession()
      }
      .padding(.trailing, 12)
      .padding(.bottom, 12)
    }
  }

  private var chatLayout: some View {
    VStack(spacing: 0) {
      if let providerStatus {
        providerStatusBanner(providerStatus)
      }
      NowSpeakingBar { messageID in
        pendingScrollToMessageID = messageID
      }
      if let session = currentWebXDCSession {
        webxdcSessionBar(session)
      }
      if !currentSubagents.isEmpty {
        SubagentsBar(processes: currentSubagents) {
          showingSubagents = true
        }
      }
      messages
        .overlay(alignment: .bottomTrailing) {
          browserCardOverlay
        }
      bottomControls
    }
  }

  /// The child agents of the chat on screen, live or finished, so a turn
  /// that delegated work shows what it started.
  private var currentSubagents: [AgentProcessInfo] {
    store.agentChildren(of: store.currentConversation?.id)
  }

  private var currentWebXDCSession: WebXDCRunningSession? {
    guard let session = store.activeWebXDCSession,
      let conversationID = session.conversationID,
      conversationID == store.currentConversation?.id
    else { return nil }
    return session
  }

  private func webxdcSessionBar(_ session: WebXDCRunningSession) -> some View {
    HStack(spacing: 10) {
      WebXDCAppIcon(app: session.app, size: 26)
      Text(session.app.name)
        .font(.subheadline.weight(.medium))
        .lineLimit(1)
      if store.isResponding(in: session.conversationID ?? UUID()) {
        ProgressView()
          .controlSize(.small)
      } else {
        Text("Running")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      Button {
        showingWebXDCStopConfirmation = true
      } label: {
        Image(systemName: "xmark.circle.fill")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Stop app")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.thinMaterial)
    .contentShape(Rectangle())
    .onTapGesture {
      showingWebXDCRunnerFromBar = true
    }
    .fullScreenCover(isPresented: $showingWebXDCRunnerFromBar) {
      if let session = store.activeWebXDCSession {
        WebXDCRunnerSheet(session: session)
          .environmentObject(store)
      }
    }
    .alert("Stop '\(session.app.name)'?", isPresented: $showingWebXDCStopConfirmation) {
      Button("Cancel", role: .cancel) {}
      Button("Stop App", role: .destructive) {
        store.stopWebXDCSession()
      }
    } message: {
      Text("The app will be closed and its unsaved in-page state will be lost.")
    }
  }

  @ViewBuilder
  private var bottomControls: some View {
    if chatSearch.isActive {
      ChatSearchBar(search: $chatSearch)
    } else if store.selectedConversationIsLoading {
      Color.clear
        .frame(height: 82)
        .transition(.opacity)
    } else if isMessageSelectionMode {
      messageSelectionActions
    } else {
      composer
    }
  }

  private var chatTitle: some View {
    Menu {
      Button {
        beginRename()
      } label: {
        Label("Rename...", systemImage: "pencil")
      }
      Button {
        beginChatSearch()
      } label: {
        Label("Search...", systemImage: "magnifyingglass")
      }
      .disabled(currentConversationIsEmpty || liveVoiceSession.isActive)
      Button {
        showingCompactSheet = true
      } label: {
        Label("Compact...", systemImage: "rectangle.compress.vertical")
      }
      .disabled(!canCompactCurrentChat)
      ConversationExportMenu(
        conversationID: store.currentConversation?.id,
        coordinator: exportCoordinator,
        title: "Export...")
      Divider()
      Button {
        showingProviderModelSheet = true
      } label: {
        Label("Chat Settings", systemImage: "slider.horizontal.3")
      }
    } label: {
      VStack(spacing: 1) {
        Text(
          store.currentConversation?.displayTitle
            ?? store.selectedConversationSummary?.displayTitle
            ?? "Chat"
        )
        .font(.headline)
        .lineLimit(1)
        .foregroundStyle(.primary)
        HStack(spacing: 4) {
          if isLoadingCurrentLocalModel {
            ProgressView()
              .controlSize(.mini)
          }
          Text(providerSubtitle)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        if isLoadingCurrentLocalModel {
          ProgressView()
            .progressViewStyle(.linear)
            .frame(width: 150)
            .accessibilityLabel("Loading local model into memory")
        }
      }
      .frame(maxWidth: 240)
      .contentShape(Rectangle())
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .disabled(store.selectedConversationIsLoading)
    .accessibilityHint("Tap for chat options")
  }

  private var currentSystemPromptID: UUID? {
    store.currentConversation?.systemPromptID ?? store.settings.defaultSystemPromptID
  }

  private var systemPromptName: String? {
    guard let id = currentSystemPromptID,
      let prompt = store.settings.systemPrompts.first(where: { $0.id == id })
    else { return nil }
    return prompt.displayName
  }

  private var systemPromptTitle: String? {
    guard let systemPromptName else { return nil }
    return store.settings.airplaneModeEnabled ? "\(systemPromptName) (offline)" : systemPromptName
  }

  private var currentLanguageOverrideIdentifier: String? {
    store.currentConversation?.effectiveLanguageOverrideIdentifier
  }

  private var currentToolSettings: NativeToolSettings {
    store.effectiveToolSettings(for: store.currentConversation)
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

  private var composerPlaceholder: String {
    "Ask anything..."
  }

  private var currentChatIsResponding: Bool {
    guard let id = store.currentConversation?.id else { return false }
    return store.isResponding(in: id)
  }

  private var providerSubtitle: String {
    if store.isCompacting { return "Compacting…" }
    if store.selectedConversationIsLoading { return "Loading…" }
    if isLoadingCurrentLocalModel { return "Loading local model into memory…" }
    guard let conversation = store.currentConversation else { return "No conversation" }
    let providerName = providerLabel(for: conversation)
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = [providerName, model.isEmpty ? nil : model, systemPromptTitle].compactMap { $0 }
    return parts.joined(separator: " · ")
  }

  private var isLoadingCurrentLocalModel: Bool {
    guard let id = store.currentConversation?.id else { return false }
    return store.isLoadingLocalModel(in: id)
  }

  private func providerLabel(for conversation: Conversation) -> String {
    switch conversation.provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      let endpoint = conversation.endpointID.flatMap { id in
        store.settings.openAIEndpoints.first(where: { $0.id == id })
      }
      return endpoint?.displayName
        ?? AgentTooling.firstNonEmpty(URL(string: endpoint?.baseURL ?? "")?.host)
        ?? OpenAIEndpoint.defaultDisplayName
    }
  }

  private func providerStatusBanner(_ status: (message: String, systemImage: String, color: Color))
    -> some View
  {
    Label(status.message, systemImage: status.systemImage)
      .font(.caption)
      .foregroundStyle(status.color)
      .lineLimit(2)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal)
      .padding(.vertical, 10)
      .background(.ultraThinMaterial)
  }

  private func beginRename() {
    renameDraft = store.currentConversation?.displayTitle ?? ""
    showingRenameAlert = true
  }

  private func renameCurrentConversation() {
    store.renameCurrentConversation(to: renameDraft)
    showingRenameAlert = false
  }

  private var trailingMenu: some View {
    Button {
      store.newConversation()
    } label: {
      Image(systemName: "square.and.pencil")
    }
    .disabled(
      currentConversationIsEmpty || store.selectedConversationIsLoading || isMessageSelectionMode
    )
    .accessibilityLabel("New Chat")
    .help("New Chat")
  }

  private func speakFromHere(_ message: ChatMessage) {
    guard
      let conversation = store.currentConversation,
      let index = conversation.messages.firstIndex(where: { $0.id == message.id })
    else {
      return
    }
    ttsPlayer.speakFromHere(
      messages: Array(conversation.messages[index...]),
      voices: store.effectiveToolSettings(for: conversation).voices,
      openAIEndpoints: store.settings.airplaneModeEnabled ? [] : store.settings.openAIEndpoints,
      skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS
    )
  }

  private func editMessage(_ message: ChatMessage, text: String) {
    guard
      let currentText = store.currentConversation?.messages.first(where: { $0.id == message.id })?
        .presentationText,
      currentText != text
    else {
      return
    }
    store.updateCurrentConversation { conversation in
      guard let index = conversation.messages.firstIndex(where: { $0.id == message.id }) else {
        return
      }
      conversation.messages[index].text = text
      conversation.messages[index].displayText = nil
    }
    if chatSearch.isActive {
      chatSearch.rebuild(messages: store.currentConversation?.messages ?? [])
    }
  }

  private func editTextAttachment(_ message: ChatMessage, attachmentID: UUID, text: String) {
    guard
      let currentAttachment = store.currentConversation?.messages.first(where: {
        $0.id == message.id
      })?.attachments.first(where: { $0.id == attachmentID }),
      currentAttachment.text != text
    else {
      return
    }
    store.updateCurrentConversation { conversation in
      guard let messageIndex = conversation.messages.firstIndex(where: { $0.id == message.id }),
        let attachmentIndex = conversation.messages[messageIndex].attachments.firstIndex(where: {
          $0.id == attachmentID
        }),
        conversation.messages[messageIndex].attachments[attachmentIndex].kind == .textFile
      else {
        return
      }
      conversation.messages[messageIndex].attachments[attachmentIndex].text = text
    }
  }

  private var providerStatus: (message: String, systemImage: String, color: Color)? {
    if let conversation = store.currentConversation,
      store.settings.airplaneModeEnabled,
      !conversation.provider.isAirplaneModeEligible
    {
      return (
        store.appleIntelligenceIsAvailable
          ? "Airplane Mode is on. Switch this chat to Apple Intelligence or MLX Local."
          : "Airplane Mode is on. Switch this chat to MLX Local.",
        "airplane",
        .orange
      )
    }
    return nil
  }

  private var messages: some View {
    GeometryReader { scrollGeometry in
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          let conversation = store.currentConversation
          let isPreviewingConversation = store.selectedConversationIsLoading && conversation == nil
          let renderedMessages =
            conversation?.messages
            ?? store.selectedConversationPreviewMessages
          let firstUserMessageID = renderedMessages.first(where: { $0.role == .user })?.id
          // A single response can be several viewports tall and changes height while streaming.
          // LazyVStack can retain a stale row estimate and scroll past the rendered content.
          VStack(spacing: 14) {
            if !renderedMessages.isEmpty,
              let startedAt = conversation?.createdAt
                ?? store.selectedConversationSummary?.createdAt
            {
              ConversationTimelineTimestamp(label: "Chat Started", date: startedAt)
            }
            if isPreviewingConversation && renderedMessages.isEmpty {
              compactLoadingState
            } else if !isPreviewingConversation && currentConversationIsEmpty
              && liveVoiceSession.previewMessage == nil
            {
              emptyState
                .containerRelativeFrame(.vertical)
            } else {
              ForEach(renderedMessages) { message in
                let match = chatSearch.currentMatch
                let searchHighlight = match?.messageID == message.id ? match : nil
                MessageSelectionRow(
                  isSelectionMode: !isPreviewingConversation && isMessageSelectionMode,
                  isSelected: !isPreviewingConversation && selectedMessageIDs.contains(message.id)
                ) {
                  if !isPreviewingConversation {
                    toggleMessageSelection(message.id)
                  }
                } content: {
                  MessageBubble(
                    message: message,
                    toolSettings: currentToolSettings,
                    openAIEndpoints: store.settings.airplaneModeEnabled
                      ? [] : store.settings.openAIEndpoints,
                    skipTechnicalContentInTTS: store.settings.conversation
                      .skipTechnicalContentInTTS,
                    appearance: store.settings.appearance,
                    renderMarkdown: store.settings.renderMarkdownInChat,
                    renderImages: store.settings.renderMarkdownImagesInChat,
                    searchHighlight: searchHighlight,
                    isBookmarked: conversation.map {
                      store.isMessageBookmarked(message.id, in: $0.id)
                    } ?? false,
                    onDelete: { messagePendingDeletion = message },
                    onToggleBookmark: conversation.map { conversation in
                      { store.toggleMessageBookmark(message, in: conversation.id) }
                    },
                    onBeginSelection: { beginMessageSelection(with: message.id) },
                    onEdit: { editedText in editMessage(message, text: editedText) },
                    onEditAttachment: { attachmentID, editedText in
                      editTextAttachment(message, attachmentID: attachmentID, text: editedText)
                    },
                    onResubmit: message.role == .user
                      ? { Task { await store.resubmit(message) } }
                      : nil,
                    onTrimFromHere: { messagePendingTrimAndResubmit = message },
                    onRestartFresh: { messagePendingRestartFresh = message },
                    onNewChatWithMessage: {
                      Task { await store.startNewConversation(with: message) }
                    },
                    onSpeakFromHere: { speakFromHere(message) },
                    onReply: { reply in sendReply(reply) },
                    conversationCreatedAt: conversation?.createdAt
                      ?? store.selectedConversationSummary?.createdAt,
                    showUserTimestamp: message.role == .user && message.id != firstUserMessageID,
                    showThinking: store.effectiveShowThinking(for: store.currentConversation),
                    isWaitingForResponse: isWaitingForResponse(message),
                    onStreamingTextChange: { _ in
                      scheduleStreamingScroll(proxy)
                    }
                  )
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                  geometry.frame(in: .named(MessageFontPinchSession.coordinateSpaceName))
                } action: { frame in
                  messageFontPinchSession.updateFrame(frame, for: message.id)
                  if message.role == .user {
                    refreshUserMessageNavigation()
                  }
                }
                .onDisappear {
                  messageFontPinchSession.removeFrame(for: message.id)
                }
                .allowsHitTesting(!isPreviewingConversation)
                .opacity(isPreviewingConversation ? 0.82 : 1)
                .id(message.id)

                if !isPreviewingConversation,
                  !isMessageSelectionMode,
                  store.settings.followUps.isEnabled,
                  message.role == .assistant,
                  renderedMessages.last?.id == message.id,
                  !currentChatIsResponding,
                  let conversationID = conversation?.id
                {
                  let suggestions = store.followUpSuggestions(
                    in: conversationID,
                    after: message.id)
                  let isGenerating = store.isGeneratingFollowUpSuggestions(
                    in: conversationID,
                    after: message.id)
                  FollowUpSuggestionsCard(
                    suggestions: suggestions,
                    isGenerating: isGenerating,
                    autoSuggestEnabled: store.settings.followUps.autoGenerate,
                    onSend: { sendFollowUp($0, in: conversationID) },
                    onEdit: { submitFollowUp($0, in: conversationID) },
                    onRefresh: { store.regenerateFollowUpSuggestions(in: conversationID) },
                    onAutoSuggestChange: { isEnabled in
                      guard store.settings.followUps.autoGenerate != isEnabled else { return }
                      store.settings.followUps.autoGenerate = isEnabled
                      store.saveSettings()
                    }
                  )
                  .id("follow-ups-\(message.id.uuidString)")
                }
              }
              if isPreviewingConversation {
                compactLoadingFooter
              }
              if let preview = liveVoiceSession.previewMessage {
                MessageBubble(
                  message: preview,
                  toolSettings: currentToolSettings,
                  openAIEndpoints: store.settings.airplaneModeEnabled
                    ? [] : store.settings.openAIEndpoints,
                  appearance: store.settings.appearance,
                  renderMarkdown: store.settings.renderMarkdownInChat,
                  renderImages: store.settings.renderMarkdownImagesInChat,
                  onDelete: {},
                  conversationCreatedAt: conversation?.createdAt
                    ?? store.selectedConversationSummary?.createdAt,
                  showThinking: store.effectiveShowThinking(for: store.currentConversation),
                  isWaitingForResponse: false
                )
                .id(preview.id)
              }
              if !isPreviewingConversation {
                ForEach(currentQueuedUserMessages) { message in
                  QueuedMessageBubble(
                    message: message,
                    onEdit: { editQueuedMessage(message) },
                    onCancel: { cancelQueuedMessage(message) }
                  )
                  .id(message.id)
                }
              }
            }
            if !renderedMessages.isEmpty,
              lastUpdatedVisibleConversationID == store.selectedConversationID,
              let updatedAt = conversation?.updatedAt
                ?? store.selectedConversationSummary?.updatedAt
            {
              ConversationTimelineTimestamp(label: "Last Updated", date: updatedAt)
            }
            Color.clear
              .frame(height: 1)
          }
          .padding()
          .id(messageListBottomID)
          // Pin the scroll content to the viewport without using
          // containerRelativeFrame, which can create a layout cycle on rotation.
          .frame(width: scrollGeometry.size.width, alignment: .center)
          .frame(minHeight: scrollGeometry.size.height, alignment: .bottom)
          .background {
            MessageListPinchBridge(
              zoomMethod: store.settings.appearance.zoomMethod,
              baseFontSize: store.settings.appearance.fontSize,
              onBegan: { scrollView, contentPoint in
                messageFontPinchSession.isActive = true
                messageFontPinchSession.captureAnchor(in: scrollView, at: contentPoint)
                store.streamingTextStore.setPublishingSuspended(true)
              },
              onEnded: { magnification, scrollView, contentFraction, viewportY in
                endMessageFontSizePinch(
                  magnification: magnification,
                  in: scrollView,
                  contentFraction: contentFraction,
                  viewportY: viewportY,
                  proxy: proxy)
              },
              onCancelled: {
                messageFontPinchSession.isActive = false
                messageFontPinchSession.clearAnchor()
                store.streamingTextStore.setPublishingSuspended(false)
              },
              onRealtimeChanged: { magnification, scrollView, contentPoint in
                updateRealtimeMessageFontSize(
                  for: magnification,
                  in: scrollView,
                  at: contentPoint)
              },
              onRealtimeEnded: { scrollView in
                endRealtimeMessageFontSizePinch(in: scrollView, proxy: proxy)
              }
            )
          }
        }
        .coordinateSpace(name: MessageFontPinchSession.coordinateSpaceName)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
          MessageListScrollMetrics(
            viewportMinY: geometry.visibleRect.minY,
            contentHeight: geometry.contentSize.height,
            isAtBottom: geometry.contentSize.height <= geometry.containerSize.height
              || geometry.visibleRect.maxY >= geometry.contentSize.height - 2)
        } action: { _, metrics in
          refreshUserMessageNavigation(isAtBottom: metrics.isAtBottom)
        }
        .onScrollPhaseChange { _, phase in
          if phase == .interacting {
            userScrolledAfterLastMessage = true
            userMessageNavigationDestination = nil
            userMessageNavigationHiddenBySwipe = false
          } else if phase == .idle {
            userMessageNavigationDestination = nil
          }
        }
        .onAppear {
          scrollToBottomAfterLayout(proxy, animated: false)
          DispatchQueue.main.async {
            scrollToRequestedMessage(store.pendingMessageNavigation, proxy: proxy)
          }
        }
        .onChange(of: store.selectedConversationID) { _, _ in
          messageFontPinchSession.resetMetrics()
          userMessageNavigation = UserMessageNavigationState()
          userMessageNavigationDestination = nil
          userMessageNavigationHiddenBySwipe = false
          userMessageNavigationIndicatorVisible = false
          userMessageNavigationIndicatorTask?.cancel()
          userMessageNavigationIndicatorTask = nil
          userScrolledAfterLastMessage = false
          streamingScrollTask?.cancel()
          streamingScrollTask = nil
          lastStreamingScrollAt = nil
          scrollToBottomAfterLayout(proxy, animated: false)
        }
        .onChange(of: lastMessageSnapshot) { old, new in
          guard !messageFontPinchSession.isActive else { return }
          if old.conversationID != new.conversationID {
            userScrolledAfterLastMessage = false
            scrollToBottomAfterLayout(proxy, animated: false)
            return
          }
          if old.messageID != new.messageID {
            userScrolledAfterLastMessage = false
            scrollToBottomAfterLayout(proxy, animated: true)
            return
          }
          guard old.text != new.text, !userScrolledAfterLastMessage else { return }
          DispatchQueue.main.async {
            scrollToBottom(proxy, animated: false)
          }
        }
        .onChange(of: liveVoiceSession.transcript) { _, _ in
          guard !messageFontPinchSession.isActive, !userScrolledAfterLastMessage else { return }
          scrollToBottom(proxy, animated: false)
        }
        .onChange(of: currentQueuedUserMessageIDs) { _, _ in
          guard !messageFontPinchSession.isActive, !userScrolledAfterLastMessage else { return }
          scrollToBottomAfterLayout(proxy, animated: true)
        }
        .onChange(of: currentFollowUpPresentationSnapshot) { old, new in
          guard old != new,
            new != nil,
            !messageFontPinchSession.isActive,
            !userScrolledAfterLastMessage
          else { return }
          scrollToBottomAfterLayout(proxy, animated: true)
        }
        .onChange(of: pendingScrollToMessageID) { _, target in
          guard !messageFontPinchSession.isActive, let target else { return }
          withAnimation(.snappy) {
            proxy.scrollTo(target, anchor: .center)
          }
          pendingScrollToMessageID = nil
        }
        .onChange(of: store.pendingMessageNavigation) { _, request in
          scrollToRequestedMessage(request, proxy: proxy)
        }
        .onChange(of: chatSearch.currentMatch) { _, target in
          guard !messageFontPinchSession.isActive,
            let target
          else {
            return
          }
          DispatchQueue.main.async {
            withAnimation(.snappy) {
              proxy.scrollTo(target, anchor: .center)
            }
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if !userMessageNavigation.isAtBottom && !userMessageNavigationHiddenBySwipe {
            userMessageNavigationControls(proxy: proxy)
              .transition(.move(edge: .bottom).combined(with: .opacity))
          }
        }
        .animation(
          .snappy,
          value: userMessageNavigation.isAtBottom || userMessageNavigationHiddenBySwipe)
      }
    }
  }

  private func userMessageNavigationControls(proxy: ScrollViewProxy) -> some View {
    let previousDestination = userMessageNavigationTarget(for: .previous)
    let nextDestination = userMessageNavigationTarget(for: .next)

    return VStack(spacing: 8) {
      userMessageNavigationIndicator

      userMessageNavigationButton(
        systemImage: "chevron.up",
        label: "Previous user message",
        direction: .previous,
        destination: previousDestination,
        proxy: proxy)

      userMessageNavigationButton(
        systemImage: "chevron.down",
        label: nextDestination == .bottom ? "Bottom of conversation" : "Next user message",
        direction: .next,
        destination: nextDestination,
        proxy: proxy)
    }
    .fixedSize()
    .padding(.trailing, 12)
    .padding(.bottom, 12)
    .simultaneousGesture(
      DragGesture(minimumDistance: 16)
        .onEnded { value in
          let distance = hypot(value.translation.width, value.translation.height)
          guard distance >= 24 else { return }
          userMessageNavigationHiddenBySwipe = true
        }
    )
  }

  private var userMessageNavigationIndicator: some View {
    let (current, total) = userMessageNavigationPosition
    guard total > 0 else { return AnyView(EmptyView()) }

    return AnyView(
      Text("\(current)/\(total)")
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
          Capsule()
            .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
        }
        .opacity(userMessageNavigationIndicatorVisible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: userMessageNavigationIndicatorVisible)
        .accessibilityHidden(true)
    )
  }

  private var userMessageNavigationPosition: (current: Int, total: Int) {
    let ids = currentUserMessageIDs
    guard !ids.isEmpty else { return (0, 0) }
    if userMessageNavigation.isAtBottom {
      return (ids.count, ids.count)
    }
    if let destination = userMessageNavigationDestination,
      case .message(let id) = destination,
      let index = ids.firstIndex(of: id)
    {
      return (index + 1, ids.count)
    }
    if let nextID = userMessageNavigation.nextID,
      let index = ids.firstIndex(of: nextID)
    {
      return (index, ids.count)
    }
    return (ids.count, ids.count)
  }

  private func showUserMessageNavigationIndicator() {
    userMessageNavigationIndicatorVisible = true
    userMessageNavigationIndicatorTask?.cancel()
    userMessageNavigationIndicatorTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      withAnimation(.easeInOut(duration: 0.2)) {
        userMessageNavigationIndicatorVisible = false
      }
    }
  }

  @ViewBuilder
  private func userMessageNavigationButton(
    systemImage: String,
    label: String,
    direction: UserMessageNavigationDirection,
    destination: UserMessageNavigationDestination?,
    proxy: ScrollViewProxy
  ) -> some View {
    let button = Button {
      guard let destination = userMessageNavigationTarget(for: direction) else { return }
      userScrolledAfterLastMessage = true
      userMessageNavigationDestination = destination
      showUserMessageNavigationIndicator()
      withAnimation(.easeOut(duration: 0.16)) {
        switch destination {
        case .message(let id):
          proxy.scrollTo(id, anchor: .top)
        case .bottom:
          proxy.scrollTo(messageListBottomID, anchor: .bottom)
        }
      }
    } label: {
      Image(systemName: systemImage)
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(destination == nil ? Color.secondary.opacity(0.45) : Color.primary)
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }

    Group {
      if #available(iOS 26.0, *) {
        button
          .buttonStyle(.plain)
          .padding(8)
          .glassEffect(.clear.interactive(), in: Circle())
      } else {
        button
          .buttonStyle(.plain)
          .padding(8)
          .background(.ultraThinMaterial, in: Circle())
          .overlay {
            Circle()
              .strokeBorder(.primary.opacity(0.08), lineWidth: 0.5)
          }
          .shadow(color: .black.opacity(0.1), radius: 5, y: 2)
      }
    }
    .contentShape(Circle())
    .disabled(destination == nil)
    .accessibilityLabel(label)
  }

  private func userMessageNavigationTarget(
    for direction: UserMessageNavigationDirection
  ) -> UserMessageNavigationDestination? {
    let userMessageIDs = currentUserMessageIDs
    guard let destination = userMessageNavigationDestination else {
      switch direction {
      case .previous:
        return userMessageNavigation.previousID.map(UserMessageNavigationDestination.message)
      case .next:
        if let nextID = userMessageNavigation.nextID {
          return .message(nextID)
        }
        return userMessageNavigation.isAtBottom ? nil : .bottom
      }
    }

    switch destination {
    case .bottom:
      return direction == .previous
        ? userMessageIDs.last.map(UserMessageNavigationDestination.message)
        : nil
    case .message(let destinationID):
      guard let destinationIndex = userMessageIDs.firstIndex(of: destinationID) else { return nil }
      switch direction {
      case .previous:
        guard destinationIndex > userMessageIDs.startIndex else { return nil }
        return .message(userMessageIDs[userMessageIDs.index(before: destinationIndex)])
      case .next:
        let nextIndex = userMessageIDs.index(after: destinationIndex)
        return nextIndex < userMessageIDs.endIndex
          ? .message(userMessageIDs[nextIndex])
          : .bottom
      }
    }
  }

  private var currentUserMessageIDs: [UUID] {
    (store.currentConversation?.messages
      ?? store.selectedConversationPreviewMessages)
      .filter { $0.role == .user }
      .map(\.id)
  }

  private func refreshUserMessageNavigation(isAtBottom: Bool? = nil) {
    let atBottom = isAtBottom ?? userMessageNavigation.isAtBottom
    let userMessageIDs = currentUserMessageIDs
    let alignedTopTolerance: CGFloat = 4
    var previousID: UUID?
    var nextID: UUID?

    for id in userMessageIDs {
      guard let frame = messageFontPinchSession.frame(for: id) else { continue }
      if frame.minY < -alignedTopTolerance {
        previousID = id
      } else if frame.minY > alignedTopTolerance, nextID == nil {
        nextID = id
      }
    }

    let newState = UserMessageNavigationState(
      isAtBottom: atBottom,
      previousID: previousID,
      nextID: nextID)
    guard newState != userMessageNavigation else { return }
    userMessageNavigation = newState
  }

  private var deleteMessageConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingDeletion = nil
      }
    }
  }

  private var deleteMessageBatchConfirmationBinding: Binding<Bool> {
    Binding {
      messageBatchPendingDeletion != nil
    } set: { isPresented in
      if !isPresented {
        messageBatchPendingDeletion = nil
      }
    }
  }

  private var trimAndResubmitConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingTrimAndResubmit != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingTrimAndResubmit = nil
      }
    }
  }

  private var restartFreshConfirmationBinding: Binding<Bool> {
    Binding {
      messagePendingRestartFresh != nil
    } set: { isPresented in
      if !isPresented {
        messagePendingRestartFresh = nil
      }
    }
  }

  private var currentConversationIsEmpty: Bool {
    store.currentConversation?.messages.isEmpty ?? true
  }

  private var currentMessageIDs: [UUID] {
    store.currentConversation?.messages.map(\.id) ?? []
  }

  private var currentQueuedUserMessages: [QueuedChatMessage] {
    store.queuedUserMessages(in: store.currentConversation?.id)
  }

  private var currentQueuedUserMessageIDs: [UUID] {
    currentQueuedUserMessages.map(\.id)
  }

  private struct FollowUpPresentationSnapshot: Equatable {
    let sourceMessageID: UUID
    let isGenerating: Bool
    let optionCount: Int
  }

  private var currentFollowUpPresentationSnapshot: FollowUpPresentationSnapshot? {
    guard store.settings.followUps.isEnabled,
      let conversationID = store.currentConversation?.id,
      let lastMessageID = store.currentConversation?.messages.last?.id
    else {
      return nil
    }
    let state = store.followUpSuggestionsByConversationID[conversationID]
    let generatingSourceID =
      store.generatingFollowUpSourceMessageIDsByConversationID[conversationID]
    let sourceMessageID = state?.sourceMessageID ?? generatingSourceID
    guard sourceMessageID == lastMessageID else { return nil }
    return FollowUpPresentationSnapshot(
      sourceMessageID: lastMessageID,
      isGenerating: generatingSourceID == lastMessageID,
      optionCount: state?.options.count ?? 0)
  }

  private func submitFollowUp(_ suggestion: String, in conversationID: UUID) {
    store.dismissFollowUpSuggestions(in: conversationID)
    store.replaceComposerDraft(with: suggestion, in: conversationID)
  }

  private func sendFollowUp(_ suggestion: String, in conversationID: UUID) {
    let trimmed = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    store.dismissFollowUpSuggestions(in: conversationID)
    Task { _ = await store.send(prompt: suggestion) }
  }

  /// Sends a reply composed from an assistant message. While that conversation
  /// is still responding the reply is queued, exactly like a composer submit.
  private func sendReply(_ text: String) {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    if let conversationID = store.currentConversation?.id,
      store.isResponding(in: conversationID),
      store.enqueueUserMessage(prompt: text, in: conversationID)
    {
      return
    }
    Task { _ = await store.send(prompt: text) }
  }

  private func cancelQueuedMessage(_ message: QueuedChatMessage) {
    guard let conversationID = store.currentConversation?.id else { return }
    withAnimation(.snappy) {
      store.removeQueuedUserMessage(id: message.id, from: conversationID)
    }
  }

  private func editQueuedMessage(_ message: QueuedChatMessage) {
    guard let conversationID = store.currentConversation?.id,
      let message = store.takeQueuedUserMessageForEditing(
        id: message.id,
        from: conversationID)
    else {
      return
    }
    withAnimation(.snappy) {
      queuedMessagePendingEdit = message
    }
  }

  private var conversationActivitySnapshot: ConversationActivitySnapshot {
    let conversationID = store.selectedConversationID
    let updatedAt =
      store.currentConversation?.id == conversationID
      ? store.currentConversation?.updatedAt
      : store.selectedConversationSummary?.updatedAt
    return ConversationActivitySnapshot(
      conversationID: conversationID,
      updatedAt: updatedAt,
      isResponding: conversationID.map(store.isResponding(in:)) ?? false)
  }

  private func beginChatSearch() {
    cancelMessageSelection()
    userScrolledAfterLastMessage = true
    withAnimation(.snappy) {
      chatSearch.begin(messages: store.currentConversation?.messages ?? [])
    }
  }

  private var selectedMessages: [ChatMessage] {
    store.currentConversation?.messages.filter { selectedMessageIDs.contains($0.id) } ?? []
  }

  private struct LastMessageSnapshot: Equatable {
    var conversationID: UUID?
    var messageID: UUID?
    var text: String?
  }

  private var lastMessageSnapshot: LastMessageSnapshot {
    let convo = store.currentConversation
    let last = convo?.messages.last
    return LastMessageSnapshot(
      conversationID: convo?.id,
      messageID: last?.id,
      text: last?.presentationText)
  }

  private func isWaitingForResponse(_ message: ChatMessage) -> Bool {
    guard currentChatIsResponding, message.role == .assistant else { return false }
    return store.currentConversation?.messages.last?.id == message.id
  }

  // Applies a launch request from a widget tap or App Intent (Action Button /
  // Siri). Prompts with text are sent immediately; an empty prompt just opens a
  // fresh, focused composer; voice opens straight into a conversation.
  private func applyLaunchAction(_ action: LaunchCommand) async {
    switch action {
    case .newPrompt(let text):
      if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        _ = await store.send(prompt: text)
      } else {
        store.requestComposerFocus()
      }
    case .voice:
      if store.currentConversation == nil {
        store.newConversation()
      }
      guard !liveVoiceSession.isActive else { return }
      liveVoiceSession.start(store: store, ttsPlayer: ttsPlayer)
    case .openConversation(let id):
      await store.selectConversation(id: id)
    case .importSharedContent:
      store.drainSharedInbox()
      if store.hasQueuedSharedItems, store.currentConversation == nil {
        store.newConversation()
      }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    if animated {
      withAnimation(.snappy) {
        proxy.scrollTo(messageListBottomID, anchor: .bottom)
      }
    } else {
      proxy.scrollTo(messageListBottomID, anchor: .bottom)
    }
  }

  private func scrollToBottomAfterLayout(_ proxy: ScrollViewProxy, animated: Bool) {
    guard !userScrolledAfterLastMessage else { return }
    DispatchQueue.main.async {
      guard !userScrolledAfterLastMessage else { return }
      scrollToBottom(proxy, animated: animated)
    }
  }

  private func scrollToRequestedMessage(
    _ request: MessageNavigationRequest?,
    proxy: ScrollViewProxy
  ) {
    guard let request,
      request.conversationID == store.selectedConversationID,
      currentMessageIDs.contains(request.messageID)
    else { return }
    userScrolledAfterLastMessage = true
    userMessageNavigationDestination = nil
    DispatchQueue.main.async {
      withAnimation(.easeOut(duration: 0.18)) {
        proxy.scrollTo(request.messageID, anchor: .center)
      }
      store.consumeMessageNavigationRequest(id: request.id)
    }
  }

  // Streamed text lands ~8×/sec (StreamingTextStore's 0.12s throttle). Scrolling
  // the whole message list on every snapshot forces a full layout pass each time
  // and competes with the composer / any presented UI for the main thread. Cap
  // the auto-scroll cadence and coalesce bursts into a single trailing scroll.
  private static let streamingScrollInterval: TimeInterval = 0.35

  private func scheduleStreamingScroll(_ proxy: ScrollViewProxy) {
    guard !messageFontPinchSession.isActive, !userScrolledAfterLastMessage else { return }
    let now = Date()
    if let last = lastStreamingScrollAt,
      now.timeIntervalSince(last) < Self.streamingScrollInterval
    {
      guard streamingScrollTask == nil else { return }
      let delay = Self.streamingScrollInterval - now.timeIntervalSince(last)
      streamingScrollTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        streamingScrollTask = nil
        guard !Task.isCancelled,
          !messageFontPinchSession.isActive,
          !userScrolledAfterLastMessage
        else { return }
        lastStreamingScrollAt = Date()
        scrollToBottom(proxy, animated: false)
      }
      return
    }
    lastStreamingScrollAt = now
    scrollToBottom(proxy, animated: false)
  }

  private func beginMessageSelection(with id: UUID) {
    withAnimation(.snappy) {
      isMessageSelectionMode = true
      selectedMessageIDs = [id]
    }
  }

  private func toggleMessageSelection(_ id: UUID) {
    guard isMessageSelectionMode else { return }
    withAnimation(.snappy) {
      if selectedMessageIDs.contains(id) {
        selectedMessageIDs.remove(id)
      } else {
        selectedMessageIDs.insert(id)
      }
    }
  }

  private func cancelMessageSelection() {
    guard isMessageSelectionMode || !selectedMessageIDs.isEmpty else { return }
    withAnimation(.snappy) {
      isMessageSelectionMode = false
      selectedMessageIDs.removeAll()
      messageBatchPendingDeletion = nil
    }
  }

  private func pruneSelectedMessages() {
    let validIDs = Set(currentMessageIDs)
    selectedMessageIDs.formIntersection(validIDs)
    if currentMessageIDs.isEmpty {
      cancelMessageSelection()
    }
  }

  private func copySelectedMessages() {
    let text = selectedMessagesCopyText()
    guard !text.isEmpty else { return }
    UIPasteboard.general.string = text
    cancelMessageSelection()
  }

  private func selectedMessagesCopyText() -> String {
    selectedMessages.compactMap(copyBlock(for:)).joined(separator: "\n\n")
  }

  private func copyBlock(for message: ChatMessage) -> String? {
    let visibleText = MessageContentFilter.render(message.presentationText).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let attachmentLines = message.attachments.map { "[Attachment: \($0.displayName)]" }
    let body = ([visibleText].filter { !$0.isEmpty } + attachmentLines)
      .joined(separator: "\n")
    guard !body.isEmpty else { return nil }
    return "\(message.role.displayName):\n\(body)"
  }

  private func deleteSelectedMessages() {
    let ids = selectedMessageIDs.intersection(Set(currentMessageIDs))
    guard !ids.isEmpty else { return }
    messageBatchPendingDeletion = PendingMessageBatchDeletion(ids: ids)
  }

  private func confirmMessageBatchDeletion(_ deletion: PendingMessageBatchDeletion) {
    store.deleteMessages(deletion.ids)
    messageBatchPendingDeletion = nil
    cancelMessageSelection()
  }

  private func updateRealtimeMessageFontSize(
    for magnification: CGFloat,
    in scrollView: UIScrollView,
    at contentPoint: CGPoint
  ) {
    let currentSize = store.settings.appearance.fontSize
    let baseSize = messageFontPinchSession.realtimeBaseFontSize ?? currentSize
    let viewportY = contentPoint.y - scrollView.contentOffset.y

    if messageFontPinchSession.realtimeBaseFontSize == nil {
      messageFontPinchSession.isActive = true
      userScrolledAfterLastMessage = true
      messageFontPinchSession.captureAnchor(in: scrollView, at: contentPoint)
      messageFontPinchSession.beginRealtime(
        baseFontSize: baseSize,
        contentPointY: contentPoint.y,
        contentHeight: scrollView.contentSize.height,
        viewportY: viewportY)
    }

    let rawSize = baseSize * max(Double(magnification), 0.1)
    let steppedSize =
      (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
    let targetSize = AppearanceSettings.clampedFontSize(steppedSize)
    guard targetSize != currentSize else { return }

    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      store.settings.appearance.fontSize = targetSize
    }

    // Reflow is asynchronous. Coalesce position corrections so an older pinch tick cannot move
    // the viewport after a newer font size has already been applied.
    let revision = messageFontPinchSession.nextRealtimeRevision()
    Task { @MainActor in
      await Task.yield()
      guard messageFontPinchSession.isCurrentRealtimeRevision(revision) else { return }
      scrollView.layoutIfNeeded()
      await Task.yield()
      guard messageFontPinchSession.isCurrentRealtimeRevision(revision) else { return }

      if let textCorrection = messageFontPinchSession.textAnchorCorrection(in: scrollView) {
        scrollView.setContentOffset(
          CGPoint(
            x: 0,
            y: clampedScrollOffsetY(
              scrollView.contentOffset.y + textCorrection,
              in: scrollView)),
          animated: false)
      } else if let anchor = messageFontPinchSession.semanticAnchor,
        let frame = messageFontPinchSession.frame(for: anchor.messageID)
      {
        let measuredAnchorY = frame.minY + frame.height * anchor.rowFraction
        let correctedOffsetY = scrollView.contentOffset.y + measuredAnchorY - anchor.viewportY
        scrollView.setContentOffset(
          CGPoint(x: 0, y: clampedScrollOffsetY(correctedOffsetY, in: scrollView)),
          animated: false)
      } else {
        let targetContentY =
          max(scrollView.contentSize.height, 1)
          * messageFontPinchSession.realtimeContentFraction
        let targetY = targetContentY - messageFontPinchSession.realtimeViewportY
        scrollView.setContentOffset(
          CGPoint(x: 0, y: clampedScrollOffsetY(targetY, in: scrollView)),
          animated: false)
      }
    }
  }

  private func endRealtimeMessageFontSizePinch(
    in scrollView: UIScrollView,
    proxy: ScrollViewProxy
  ) {
    messageFontPinchSession.isActive = false
    messageFontPinchSession.invalidateRealtimeUpdates()
    guard let baseSize = messageFontPinchSession.realtimeBaseFontSize else {
      messageFontPinchSession.finishRealtime()
      return
    }
    guard store.settings.appearance.fontSize != baseSize else {
      messageFontPinchSession.finishRealtime()
      return
    }

    preservePinchPosition(
      in: scrollView,
      contentFraction: messageFontPinchSession.realtimeContentFraction,
      viewportY: messageFontPinchSession.realtimeViewportY,
      proxy: proxy
    ) {
      messageFontPinchSession.finishRealtime()
    }
    store.saveSettings()
  }

  private func endMessageFontSizePinch(
    magnification: CGFloat,
    in scrollView: UIScrollView,
    contentFraction: CGFloat,
    viewportY: CGFloat,
    proxy: ScrollViewProxy
  ) {
    messageFontPinchSession.isActive = false

    let baseSize = store.settings.appearance.fontSize
    let rawSize = AppearanceSettings.clampedFontSize(
      baseSize * max(Double(magnification), 0.1))
    let steppedSize =
      (rawSize / AppearanceSettings.fontSizeStep).rounded() * AppearanceSettings.fontSizeStep
    let targetSize = AppearanceSettings.clampedFontSize(steppedSize)
    guard targetSize != baseSize else {
      messageFontPinchSession.clearAnchor()
      store.streamingTextStore.setPublishingSuspended(false)
      return
    }

    userScrolledAfterLastMessage = true
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      store.settings.appearance.fontSize = targetSize
    }
    preservePinchPosition(
      in: scrollView,
      contentFraction: contentFraction,
      viewportY: viewportY,
      proxy: proxy
    ) {
      store.streamingTextStore.setPublishingSuspended(false)
    }
    store.saveSettings()
  }

  private func preservePinchPosition(
    in scrollView: UIScrollView,
    contentFraction: CGFloat,
    viewportY: CGFloat,
    proxy: ScrollViewProxy,
    completion: @escaping () -> Void
  ) {
    let anchor = messageFontPinchSession.semanticAnchor
    guard messageFontPinchSession.hasTextAnchor || anchor != nil else {
      preserveProportionalPinchPosition(
        in: scrollView,
        contentFraction: contentFraction,
        viewportY: viewportY,
        completion: completion)
      return
    }

    Task { @MainActor in
      await Task.yield()
      scrollView.layoutIfNeeded()
      await Task.yield()

      // The word under the initial two-finger midpoint is the primary anchor. Resolving it touches
      // only one existing TextKit layout and avoids scanning or re-tokenizing the message tree.
      if let textCorrection = messageFontPinchSession.textAnchorCorrection(in: scrollView) {
        scrollView.setContentOffset(
          CGPoint(
            x: 0,
            y: clampedScrollOffsetY(
              scrollView.contentOffset.y + textCorrection,
              in: scrollView)),
          animated: false)
        messageFontPinchSession.clearAnchor()
        completion()
        return
      }

      guard let anchor else {
        messageFontPinchSession.clearAnchor()
        preserveProportionalPinchPosition(
          in: scrollView,
          contentFraction: contentFraction,
          viewportY: viewportY,
          completion: completion)
        return
      }

      // If the UIKit text view was replaced, make the semantic row materialize and use its
      // proportional point. This is also the path for SwiftUI-only text blocks.
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        proxy.scrollTo(anchor.messageID, anchor: .center)
      }
      await Task.yield()
      scrollView.layoutIfNeeded()
      await Task.yield()

      guard let frame = messageFontPinchSession.frame(for: anchor.messageID) else {
        messageFontPinchSession.clearAnchor()
        preserveProportionalPinchPosition(
          in: scrollView,
          contentFraction: contentFraction,
          viewportY: viewportY,
          completion: completion)
        return
      }
      let measuredAnchorY = frame.minY + frame.height * anchor.rowFraction
      let correctedOffsetY = scrollView.contentOffset.y + measuredAnchorY - anchor.viewportY
      scrollView.setContentOffset(
        CGPoint(x: 0, y: clampedScrollOffsetY(correctedOffsetY, in: scrollView)),
        animated: false)
      messageFontPinchSession.clearAnchor()
      completion()
    }
  }

  private func preserveProportionalPinchPosition(
    in scrollView: UIScrollView,
    contentFraction: CGFloat,
    viewportY: CGFloat,
    completion: @escaping () -> Void
  ) {
    DispatchQueue.main.async {
      scrollView.layoutIfNeeded()
      let targetContentY = max(scrollView.contentSize.height, 1) * contentFraction
      let targetY = targetContentY - viewportY
      scrollView.setContentOffset(
        CGPoint(x: 0, y: clampedScrollOffsetY(targetY, in: scrollView)),
        animated: false)
      completion()
    }
  }

  private func clampedScrollOffsetY(_ y: CGFloat, in scrollView: UIScrollView) -> CGFloat {
    let minimumY = -scrollView.adjustedContentInset.top
    let maximumY = max(
      minimumY,
      scrollView.contentSize.height - scrollView.bounds.height
        + scrollView.adjustedContentInset.bottom
    )
    return min(max(y, minimumY), maximumY)
  }

  private var compactLoadingState: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.regular)
      Text(store.selectedConversationSummary?.displayTitle ?? "Loading conversation")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(2)
        .multilineTextAlignment(.center)
    }
    .padding(.horizontal, 24)
    .frame(maxWidth: 430)
    .frame(maxWidth: .infinity)
    .padding(.top, 34)
  }

  private var compactLoadingFooter: some View {
    HStack(spacing: 8) {
      ProgressView()
        .controlSize(.small)
      Text("Loading full chat...")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity)
  }

  private var emptyState: some View {
    GeometryReader { proxy in
      let suggestions = store.previousConversationSuggestions
      let showsLandscapeSuggestions = renderInvalidationKey.isLandscape && !suggestions.isEmpty

      Group {
        if showsLandscapeSuggestions {
          HStack(spacing: 32) {
            emptyStateBrand
              .frame(maxWidth: .infinity)

            PreviousConversationSuggestions(
              store: store,
              suggestions: suggestions,
              exportCoordinator: exportCoordinator
            ) { id in
              Task { await store.selectConversation(id: id) }
            }
            .frame(maxWidth: .infinity)
          }
          .frame(maxWidth: 900)
          .padding(.horizontal, 24)
        } else {
          VStack(spacing: 20) {
            emptyStateBrand

            if !suggestions.isEmpty {
              PreviousConversationSuggestions(
                store: store,
                suggestions: suggestions,
                exportCoordinator: exportCoordinator
              ) { id in
                Task { await store.selectConversation(id: id) }
              }
            }
          }
          .frame(maxWidth: 430)
          .padding(.horizontal, 24)
        }
      }
      .frame(width: proxy.size.width)
      .position(
        x: proxy.size.width / 2,
        y: emptyStateCenterY(
          in: proxy.size.height,
          hasSuggestions: !suggestions.isEmpty))
    }
    .frame(maxWidth: .infinity)
  }

  private var emptyStateBrand: some View {
    VStack(spacing: 12) {
      EmptyChatLogo()
      Text("Your pocket assistant")
        .font(.title3)
        .foregroundStyle(.primary)
        .multilineTextAlignment(.center)
    }
  }

  private func emptyStateCenterY(in height: CGFloat, hasSuggestions: Bool) -> CGFloat {
    let baseY = height / 2
    guard hasSuggestions, keyboardOverlap > 0 else { return baseY }
    let lift = min(keyboardOverlap * 0.18, 64)
    return max(height * 0.48, baseY - lift)
  }

  private func updateKeyboardOverlap(from notification: Notification) {
    withAnimation(keyboardAnimation(from: notification)) {
      keyboardOverlap = keyboardOverlap(from: notification)
    }
  }

  private func keyboardAnimation(from notification: Notification) -> Animation {
    let duration =
      notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    let rawCurve =
      (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?
      .intValue ?? UIView.AnimationCurve.easeInOut.rawValue

    if let curve = UIView.AnimationCurve(rawValue: rawCurve) {
      switch curve {
      case .easeInOut:
        return .easeInOut(duration: duration)
      case .easeIn:
        return .easeIn(duration: duration)
      case .easeOut:
        return .easeOut(duration: duration)
      case .linear:
        return .linear(duration: duration)
      @unknown default:
        return .smooth(duration: duration)
      }
    }
    return .smooth(duration: duration)
  }

  private func keyboardOverlap(from notification: Notification) -> CGFloat {
    if notification.name == UIResponder.keyboardWillHideNotification {
      return 0
    }
    guard
      let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
    else {
      return 0
    }
    let screenMaxY =
      UIApplication.shared.openSessions
      .compactMap { ($0.scene as? UIWindowScene)?.screen }
      .first { $0.bounds.intersects(frame) }?.bounds.maxY
      ?? frame.maxY
    return max(0, screenMaxY - frame.minY)
  }

  private var messageSelectionActions: some View {
    GeometryReader { proxy in
      let compact = proxy.size.width < 330
      let hasSelection = !selectedMessageIDs.isEmpty

      HStack(spacing: compact ? 6 : 10) {
        FloatingActionPill(title: "Cancel", prominent: true, compact: compact) {
          cancelMessageSelection()
        }
        Spacer(minLength: compact ? 0 : 4)
        FloatingActionIcon(
          systemImage: "doc.on.doc",
          accessibilityLabel: "Copy selected messages",
          compact: compact
        ) {
          copySelectedMessages()
        }
        .disabled(!hasSelection)
        .opacity(hasSelection ? 1 : 0.5)
        FloatingActionIcon(
          systemImage: "trash",
          accessibilityLabel: "Delete selected messages",
          destructive: true,
          compact: compact
        ) {
          deleteSelectedMessages()
        }
        .disabled(!hasSelection)
        .opacity(hasSelection ? 1 : 0.5)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(.horizontal, 18)
    }
    .frame(height: 82)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private var composer: some View {
    ChatComposer(
      store: store,
      placeholder: composerPlaceholder,
      conversationID: store.currentConversation?.id,
      isResponding: currentChatIsResponding,
      queuedMessagePendingEdit: $queuedMessagePendingEdit,
      liveVoiceSession: liveVoiceSession
    )
  }
}

private struct FollowUpSuggestionsCard: View {
  let suggestions: [String]
  let isGenerating: Bool
  let autoSuggestEnabled: Bool
  let onSend: (String) -> Void
  let onEdit: (String) -> Void
  let onRefresh: () -> Void
  let onAutoSuggestChange: (Bool) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label("Continue the conversation", systemImage: "sparkles")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button(action: onRefresh) {
          Image(systemName: "arrow.clockwise")
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isGenerating)
        .accessibilityLabel("Regenerate suggestions")
      }

      if isGenerating {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text("Generating suggestions…")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
      } else if suggestions.isEmpty {
        Button(action: onRefresh) {
          HStack(spacing: 8) {
            Image(systemName: "sparkles")
            Text("Suggest replies")
              .font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
          }
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 12)
          .padding(.vertical, 9)
          .background(Color.accentColor.opacity(0.09))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
          .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Generates messages you can send to continue the chat")
      } else {
        ForEach(Array(suggestions.enumerated()), id: \.offset) { _, suggestion in
          HStack(spacing: 0) {
            Button {
              onSend(suggestion)
            } label: {
              Text(suggestion)
                .font(.subheadline)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Sends this message")

            Rectangle()
              .fill(Color.secondary.opacity(0.18))
              .frame(width: 0.5)
              .padding(.vertical, 6)

            Button {
              onEdit(suggestion)
            } label: {
              Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 42)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit in composer")
            .accessibilityHint("Places this text in the composer for editing")
          }
          .background(Color.accentColor.opacity(0.09))
          .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
      }
    }
    .padding(10)
    .background(.thinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
    }
    .frame(maxWidth: 560, alignment: .leading)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.trailing, 38)
    .contentShape(Rectangle())
    .contextMenu {
      Button(action: onRefresh) {
        Label("Refresh Suggestions", systemImage: "arrow.clockwise")
      }
      .disabled(isGenerating)

      Button {
        onAutoSuggestChange(!autoSuggestEnabled)
      } label: {
        Label(
          "Auto-suggest",
          systemImage: autoSuggestEnabled ? "checkmark.circle.fill" : "circle")
      }
    }
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

private struct QueuedMessageBubble: View {
  let message: QueuedChatMessage
  let onEdit: () -> Void
  let onCancel: () -> Void

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      Spacer(minLength: 44)
      HStack(alignment: .top, spacing: 8) {
        Button(action: onEdit) {
          VStack(alignment: .leading, spacing: 6) {
            if !message.text.isEmpty {
              Text(message.text)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.attachments.isEmpty {
              Label(
                message.attachments.map(\.displayName).joined(separator: ", "),
                systemImage: "paperclip"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            }
            Label("Queued — tap to edit", systemImage: "clock.badge.checkmark")
              .font(.caption2.weight(.medium))
              .foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit queued message")

        Button(action: onCancel) {
          Image(systemName: "xmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.secondary)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cancel queued message")
      }
      .padding(.leading, 12)
      .padding(.trailing, 8)
      .padding(.vertical, 10)
      .background(Color.accentColor.opacity(0.12))
      .overlay {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(dash: [5, 3]))
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }
}

private struct EmptyChatLogo: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    logo
      .frame(width: 76, height: 76)
  }

  @ViewBuilder
  private var logo: some View {
    if colorScheme == .dark {
      Image("MaiLogoNoAI")
        .renderingMode(.original)
        .resizable()
        .scaledToFit()
        .colorInvert()
    } else {
      Image("MaiLogoNoAI")
        .renderingMode(.original)
        .resizable()
        .scaledToFit()
    }
  }
}

private struct PreviousConversationSuggestions: View {
  let store: AppStore
  let suggestions: [ConversationSummary]
  @ObservedObject var exportCoordinator: ConversationExportCoordinator
  let onSelect: (UUID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Continue previous conversations...")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

      VStack(spacing: 8) {
        ForEach(suggestions) { suggestion in
          PreviousConversationSuggestionButton(
            conversation: suggestion,
            folder: folder(for: suggestion),
            isMostRecent: suggestions.last?.id == suggestion.id,
            onSelect: { onSelect(suggestion.id) }
          )
          .modifier(
            ConversationSummaryActionsModifier(
              store: store,
              conversation: suggestion,
              isCurrent: store.selectedConversationID == suggestion.id,
              isEnabled: true,
              exportCoordinator: exportCoordinator)
          )
        }
      }
    }
  }

  private func folder(for conversation: ConversationSummary) -> ConversationFolder {
    store.conversationFolders.first { $0.id == conversation.folderID }
      ?? ConversationFolder.defaultFolder
  }
}

private struct PreviousConversationSuggestionButton: View {
  let conversation: ConversationSummary
  let folder: ConversationFolder
  let isMostRecent: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Image(systemName: folder.systemImage)
          .font(.body)
          .foregroundStyle(folder.tint?.swatchColor ?? Color.accentColor)
          .frame(width: 22, height: 22)

        VStack(alignment: .leading, spacing: 3) {
          Text(conversation.displayTitle)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)

          Text(recencyLabel)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 8)

        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(isMostRecent ? Color.accentColor.opacity(0.10) : Color.clear)
      }
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(
            isMostRecent ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.08),
            lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(conversation.displayTitle)
    .accessibilityHint(recencyLabel)
  }

  private var recencyLabel: String {
    let recency = ConversationRecencyLabel.text(for: conversation.updatedAt)
    return "\(recency) in \(folder.displayName)"
  }
}

private enum ConversationRecencyLabel {
  static func text(
    for date: Date,
    relativeTo now: Date = Date(),
    calendar: Calendar = .current
  ) -> String {
    if date >= now {
      return "Recently"
    }

    if now.timeIntervalSince(date) < 30 * 60 {
      return "Recently"
    }

    if calendar.isDateInToday(date) {
      return "Today"
    }

    if calendar.isDateInYesterday(date) {
      return "Yesterday"
    }

    let startOfToday = calendar.startOfDay(for: now)
    let startOfDate = calendar.startOfDay(for: date)
    let dayCount = max(
      0,
      calendar.dateComponents([.day], from: startOfDate, to: startOfToday).day ?? 0)

    if dayCount < 7 {
      return "\(dayCount) days ago"
    }

    if dayCount < 14 {
      return "Last week"
    }

    if dayCount < 31 {
      let weeks = max(2, dayCount / 7)
      return "\(weeks) weeks ago"
    }

    let monthCount = max(
      1,
      calendar.dateComponents([.month], from: startOfDate, to: startOfToday).month ?? 1)
    if monthCount == 1 {
      return "Last month"
    }
    if monthCount < 12 {
      return "\(monthCount) months ago"
    }

    let yearCount = max(
      1,
      calendar.dateComponents([.year], from: startOfDate, to: startOfToday).year ?? 1)
    return yearCount == 1 ? "Last year" : "\(yearCount) years ago"
  }
}

// Suppresses unrelated parent-driven re-invalidation while allowing chat render settings
// to refresh cached message views immediately.
extension ChatView: Equatable {
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.renderInvalidationKey == rhs.renderInvalidationKey
  }
}

struct ReasoningLevelControl: View {
  @Binding var level: ReasoningLevel
  var model: String = ""
  var endpointName: String = ""
  var baseURL: String = ""
  @State private var dragValue: Double?

  private static let thumbSize: CGFloat = 26
  private static let trackHeight: CGFloat = 5
  private static let controlHeight: CGFloat = 34

  private var displayLevel: ReasoningLevel {
    level(for: currentValue)
  }

  private var currentValue: Double {
    dragValue ?? value(for: level)
  }

  private var maximumValue: Double {
    Double(ReasoningLevel.allCases.count - 1)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Label("Reasoning", systemImage: displayLevel.systemImage)
          .contentTransition(.symbolEffect(.replace))
        Spacer()
        Text(displayLevel.displayName)
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
          .animation(.snappy, value: displayLevel)
      }
      sliderTrack
        .accessibilityValue(displayLevel.displayName)
      if let note = displayLevel.limitation(model: model, provider: endpointName, baseURL: baseURL)
      {
        Text(note).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var sliderTrack: some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      let thumbCenterX = xPosition(for: currentValue, width: width)
      ZStack(alignment: .leading) {
        Capsule()
          .fill(.tertiary)
          .frame(height: Self.trackHeight)
          .position(x: width / 2, y: Self.controlHeight / 2)
        Capsule()
          .fill(Color.accentColor)
          .frame(width: max(0, thumbCenterX), height: Self.trackHeight)
          .position(x: thumbCenterX / 2, y: Self.controlHeight / 2)
        tickMarks(width: width)
        Circle()
          .fill(.background)
          .overlay {
            Circle()
              .stroke(Color.accentColor, lineWidth: 2)
          }
          .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
          .frame(width: Self.thumbSize, height: Self.thumbSize)
          .position(x: thumbCenterX, y: Self.controlHeight / 2)
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { gesture in
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
              dragValue = value(forLocationX: gesture.location.x, width: width)
            }
          }
          .onEnded { gesture in
            let finalLevel = level(
              for: value(forLocationX: gesture.location.x, width: width))
            level = finalLevel
            withAnimation(.snappy) {
              dragValue = nil
            }
          }
      )
    }
    .frame(height: Self.controlHeight)
    .accessibilityElement()
    .accessibilityLabel("Reasoning")
    .accessibilityValue(displayLevel.displayName)
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        commitLevel(offset: 1)
      case .decrement:
        commitLevel(offset: -1)
      default:
        break
      }
    }
  }

  private func tickMarks(width: CGFloat) -> some View {
    ForEach(ReasoningLevel.allCases.indices, id: \.self) { index in
      Circle()
        .fill(Color.accentColor.opacity(Double(index) <= currentValue.rounded() ? 0.55 : 0.25))
        .frame(width: 4, height: 4)
        .position(
          x: xPosition(for: Double(index), width: width),
          y: Self.controlHeight / 2)
    }
  }

  private func value(for level: ReasoningLevel) -> Double {
    Double(ReasoningLevel.allCases.firstIndex(of: level) ?? 0)
  }

  private func level(for value: Double) -> ReasoningLevel {
    let cases = ReasoningLevel.allCases
    let index = max(0, min(cases.count - 1, Int(value.rounded())))
    return cases[index]
  }

  private func xPosition(for value: Double, width: CGFloat) -> CGFloat {
    guard maximumValue > 0 else { return Self.thumbSize / 2 }
    let usableWidth = max(1, width - Self.thumbSize)
    let fraction = CGFloat(min(max(value / maximumValue, 0), 1))
    return Self.thumbSize / 2 + usableWidth * fraction
  }

  private func value(forLocationX x: CGFloat, width: CGFloat) -> Double {
    guard maximumValue > 0 else { return 0 }
    let usableWidth = max(1, width - Self.thumbSize)
    let fraction = min(max((x - Self.thumbSize / 2) / usableWidth, 0), 1)
    return Double(fraction) * maximumValue
  }

  private func commitLevel(offset: Int) {
    let cases = ReasoningLevel.allCases
    let currentIndex = cases.firstIndex(of: level) ?? 0
    let nextIndex = max(0, min(cases.count - 1, currentIndex + offset))
    level = cases[nextIndex]
  }
}

private struct PendingMessageBatchDeletion: Identifiable {
  let id = UUID()
  let ids: Set<UUID>

  var count: Int {
    ids.count
  }

  var title: String {
    count == 1 ? "Delete selected message?" : "Delete selected messages?"
  }

  var buttonTitle: String {
    "Delete \(count) Message\(count == 1 ? "" : "s")"
  }

  var message: String {
    "\(count) selected message\(count == 1 ? "" : "s") will be removed from the chat. This cannot be undone."
  }
}

private struct MessageSelectionRow<Content: View>: View {
  let isSelectionMode: Bool
  let isSelected: Bool
  let onToggle: () -> Void
  private let content: Content

  init(
    isSelectionMode: Bool,
    isSelected: Bool,
    onToggle: @escaping () -> Void,
    @ViewBuilder content: () -> Content
  ) {
    self.isSelectionMode = isSelectionMode
    self.isSelected = isSelected
    self.onToggle = onToggle
    self.content = content()
  }

  var body: some View {
    ZStack(alignment: .leading) {
      content
        .padding(.leading, isSelectionMode ? 34 : 0)

      if isSelectionMode {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
          .font(.title3)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .frame(width: 24, height: 24)
          .padding(.leading, 4)
          .transition(.opacity.combined(with: .move(edge: .leading)))
      }
    }
    .padding(.vertical, isSelectionMode ? 2 : 0)
    .background {
      if isSelectionMode && isSelected {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.accentColor.opacity(0.10))
      }
    }
    .contentShape(Rectangle())
    .overlay {
      if isSelectionMode {
        Button(action: onToggle) {
          Color.clear
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelected ? "Deselect message" : "Select message")
      }
    }
    .animation(.snappy, value: isSelectionMode)
    .animation(.snappy, value: isSelected)
  }
}

private struct PromptShortcutMenuOption: Identifiable, Equatable {
  var selection: PromptShortcutSelection
  var commandName: String
  var displayName: String
  var detail: String
  var systemImage: String

  var id: String {
    "\(selection.kind.rawValue):\(selection.id.uuidString)"
  }
}

private struct ChatComposer: View {
  private static let draftAutosaveDelayNanoseconds: UInt64 = 3_000_000_000

  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @Environment(\.scenePhase) private var scenePhase
  let store: AppStore
  let placeholder: String
  let conversationID: UUID?
  let isResponding: Bool
  @Binding var queuedMessagePendingEdit: QueuedChatMessage?
  @ObservedObject var liveVoiceSession: LiveVoiceSession
  @FocusState private var composerFocused: Bool
  @State private var showingToolMenu = false
  @State private var showingToolPicker = false
  @State private var showingTextFileImporter = false
  @State private var showingWorkingFolderMenu = false
  @State private var showingWorkingFolderImporter = false
  @State private var showingImagePicker = false
  @State private var showingCameraPicker = false
  @State private var showingWebXDCLauncher = false
  @State private var showingWebXDCRunner = false
  @State private var showingWebXDCStopConfirmation = false
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var draftText = ""
  @State private var pendingAttachments: [ChatAttachment] = []
  @State private var sharedImportQueue: [SharedInboxItem] = []
  @State private var sharedImportImages: [PendingImageAttachmentImport.Item] = []
  @State private var sharedImportFailures: [String] = []
  @State private var isImportingSharedItems = false
  @State private var isResumingSharedImport = false
  @State private var viewingPendingAttachment: ChatAttachment?
  @State private var viewingPendingImageAttachment: ChatAttachment?
  @State private var pendingImageSizePrompt: PendingImageAttachmentImport?
  @State private var pendingPDFImport: PendingPDFImport?
  @State private var pendingHTMLImport: PendingHTMLImport?
  @State private var attachmentConversionMessage: String?
  @State private var attachmentNotice: String?
  @State private var attachmentError: String?
  @State private var promptAutocompleteSuppressedCommand: String?
  @State private var pendingPromptCompletion: String?
  @State private var composerTextFieldRefreshID = UUID()
  @State private var focusComposerAfterTextFieldRefresh = false
  @State private var draftPersistenceTask: Task<Void, Never>?

  private var hasDraftText: Bool {
    !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var canSubmitDraft: Bool {
    !isResponding && hasDraftText
  }

  private var canQueueDraft: Bool {
    isResponding && hasDraftText
  }

  private var shouldShowPromptAutocomplete: Bool {
    pendingPromptCompletion == nil
      && draftText.hasPrefix("/")
      && !promptShortcutOptions.isEmpty
      && !isResponding
      && !promptAutocompleteIsSuppressed
  }

  private var promptAutocompleteBinding: Binding<Bool> {
    Binding(
      get: { shouldShowPromptAutocomplete },
      set: { isPresented in
        if !isPresented {
          promptAutocompleteSuppressedCommand = currentPromptCommandFragment
        }
      }
    )
  }

  private var currentPromptCommandFragment: String? {
    guard let first = draftText.first, PromptSlashCommand.prefixes.contains(first) else {
      return nil
    }
    return PromptSlashCommand.fragment(in: draftText)
  }

  private var promptAutocompleteIsSuppressed: Bool {
    guard let promptAutocompleteSuppressedCommand,
      let currentPromptCommandFragment
    else {
      return false
    }
    return PromptSlashCommand.normalized(currentPromptCommandFragment)
      == PromptSlashCommand.normalized(promptAutocompleteSuppressedCommand)
  }

  private var promptShortcutOptions: [PromptShortcutMenuOption] {
    let systemOptions = store.settings.systemPrompts.map { prompt in
      PromptShortcutMenuOption(
        selection: PromptShortcutSelection(kind: .system, id: prompt.id),
        commandName: prompt.commandName,
        displayName: prompt.displayName,
        detail: "System prompt",
        systemImage: "text.bubble")
    }
    let userOptions = store.settings.userPrompts.map { prompt in
      PromptShortcutMenuOption(
        selection: PromptShortcutSelection(kind: .user, id: prompt.id),
        commandName: prompt.commandName,
        displayName: prompt.displayName,
        detail: "User prompt",
        systemImage: "text.quote")
    }
    let options = systemOptions + userOptions
    guard let fragment = PromptSlashCommand.fragment(in: draftText),
      !fragment.isEmpty
    else {
      return options
    }
    return options.filter { option in
      option.commandName.localizedCaseInsensitiveContains(fragment)
        || option.displayName.localizedCaseInsensitiveContains(fragment)
    }
  }

  private var canAttachImage: Bool {
    ProviderVisionSupport.supportsImageInput(
      conversation: store.currentConversation,
      settings: store.settings)
  }

  private var canTakePicture: Bool {
    canAttachImage && UIImagePickerController.isSourceTypeAvailable(.camera)
  }

  var body: some View {
    composerControls
      .alert(
        "Import failed",
        isPresented: attachmentErrorBinding,
        presenting: attachmentError
      ) { _ in
        Button("OK", role: .cancel) { attachmentError = nil }
      } message: { message in
        Text(message)
      }
      .imageSizeConfirmationDialog(
        isPresented: imageSizePromptBinding,
        presenting: pendingImageSizePrompt,
        message: { pending in pending.imageSizePromptMessage },
        onSelect: { pending, size in attachSharedImages(pending, size: size) },
        onOCR: { pending in extractTextFromImages(pending) },
        onCancel: { dismissImageSizePrompt() }
      )
      .confirmationDialog(
        "Import PDF",
        isPresented: pdfImportBinding,
        titleVisibility: .visible,
        presenting: pendingPDFImport
      ) { pending in
        Button("Text as Markdown") { attachPDFAsMarkdown(pending) }
        Button("One Image per Page") { attachPDFAsImages(pending) }
        Button("Cancel", role: .cancel) { dismissPDFImport() }
      } message: { pending in
        Text("How should \(pending.name).pdf be attached?")
      }
      .confirmationDialog(
        "Import HTML",
        isPresented: htmlImportBinding,
        titleVisibility: .visible,
        presenting: pendingHTMLImport
      ) { pending in
        Button("Attach HTML Source") { attachHTML(pending, mode: .source) }
        Button("Convert to Markdown") { attachHTML(pending, mode: .markdown) }
        if store.currentConversation != nil {
          Button("Copy to \(currentWorkspaceName)") { copyHTMLToWorkspace(pending) }
        }
        Button("Cancel", role: .cancel) { dismissHTMLImport() }
      } message: { pending in
        Text("Choose how to import \(pending.filename).")
      }
  }

  /// The composer's questions live in `body`; everything else is built here, so
  /// neither chain grows past what the type checker will accept.
  private var composerControls: some View {
    Group {
      if liveVoiceSession.isActive {
        voiceControls
      } else {
        textControls
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .onAppear {
      draftText = store.draftText(for: conversationID)
      if let message = queuedMessagePendingEdit {
        restoreQueuedMessageToComposer(message)
        queuedMessagePendingEdit = nil
      }
      // A share that arrived before the composer was on screen, e.g. when the
      // share sheet launched the app.
      if store.hasQueuedSharedItems { beginSharedImport() }
    }
    .onChange(of: store.sharedImportRequestID) { _, _ in
      beginSharedImport()
    }
    .onChange(of: store.draftStorageRevision) { _, _ in
      let storedDraft = store.draftText(for: conversationID)
      if draftText.isEmpty, !storedDraft.isEmpty {
        draftText = storedDraft
      }
    }
    .onChange(of: store.composerFocusRequestID) { _, _ in
      guard !liveVoiceSession.isActive else { return }
      if let replacement = store.composerDraftReplacement,
        replacement.conversationID == conversationID
      {
        applyComposerDraftReplacement(replacement)
      } else {
        composerFocused = true
      }
    }
    .onChange(of: conversationID) { oldID, newID in
      if oldID != newID, liveVoiceSession.isActive {
        liveVoiceSession.stop(cancelResponse: false)
      }
      persistDraftTextNow(draftText, for: oldID)
      pendingPromptCompletion = nil
      focusComposerAfterTextFieldRefresh = false
      draftText = store.draftText(for: newID)
    }
    .onChange(of: queuedMessagePendingEdit) { _, message in
      guard let message else { return }
      restoreQueuedMessageToComposer(message)
      queuedMessagePendingEdit = nil
    }
    .onDisappear {
      persistDraftTextNow()
    }
    .onChange(of: scenePhase) { _, phase in
      guard phase == .background else { return }
      guard liveVoiceSession.isActive else { return }
      guard !store.settings.conversation.allowsBackgroundVoiceListening else { return }
      Task { @MainActor in
        if liveVoiceSession.mode == .voiceNoteAttachment {
          await stopVoiceAndAttachTranscript(focusComposer: false)
        } else {
          await stopVoiceAndKeepTranscript(cancelResponse: false, focusComposer: false)
        }
      }
    }
    .photosPicker(
      isPresented: $showingImagePicker,
      selection: $selectedPhotoItems,
      matching: .images
    )
    .onChange(of: selectedPhotoItems) { _, items in
      guard !items.isEmpty else { return }
      Task { await importImageAttachments(items) }
    }
    .sheet(isPresented: $showingCameraPicker) {
      CameraImagePicker(isPresented: $showingCameraPicker) { image in
        importCameraImageAttachment(image)
      }
      .ignoresSafeArea()
    }
    .sheet(item: $viewingPendingAttachment) { attachment in
      MessageTextSelectionSheet(
        title: attachment.displayName,
        text: attachment.text ?? "",
        appearance: store.settings.appearance,
        initialFontSize: store.settings.appearance.fontSize,
        initialLineSpacing: store.settings.appearance.lineSpacing,
        fontFamily: store.settings.appearance.fontFamily(for: .user),
        isEditable: true,
        onSave: { text in
          updatePendingAttachmentText(id: attachment.id, text: text)
        })
    }
    .fullScreenCover(item: $viewingPendingImageAttachment) { attachment in
      MessageImageFullscreenLoader(attachment: attachment)
    }
    .sheet(isPresented: $showingWebXDCLauncher) {
      WebXDCAppLauncherSheet { app in
        store.startWebXDCSession(app: app)
        showingWebXDCRunner = true
      }
      .environmentObject(store)
    }
    .fullScreenCover(isPresented: $showingWebXDCRunner) {
      if let session = store.activeWebXDCSession {
        WebXDCRunnerSheet(session: session)
          .environmentObject(store)
      }
    }
  }

  // MARK: - Import questions

  private var attachmentErrorBinding: Binding<Bool> {
    Binding(
      get: { attachmentError != nil },
      set: { isPresented in
        if !isPresented { attachmentError = nil }
      })
  }

  private var imageSizePromptBinding: Binding<Bool> {
    Binding(
      get: { pendingImageSizePrompt != nil },
      set: { isPresented in
        if !isPresented { dismissImageSizePrompt() }
      })
  }

  private var pdfImportBinding: Binding<Bool> {
    Binding(
      get: { pendingPDFImport != nil },
      set: { isPresented in
        if !isPresented { dismissPDFImport() }
      })
  }

  private var htmlImportBinding: Binding<Bool> {
    Binding(
      get: { pendingHTMLImport != nil },
      set: { isPresented in
        if !isPresented { dismissHTMLImport() }
      })
  }

  private func attachSharedImages(
    _ pending: PendingImageAttachmentImport,
    size: AttachmentImageSize
  ) {
    appendImageAttachment(pending, size: size)
    resumeSharedImportAfterAnswer()
  }

  private func extractTextFromImages(_ pending: PendingImageAttachmentImport) {
    convertImagesToText(pending)
    resumeSharedImportAfterAnswer()
  }

  private func dismissImageSizePrompt() {
    pendingImageSizePrompt = nil
    resumeSharedImportAfterAnswer()
  }

  private func attachPDFAsMarkdown(_ pending: PendingPDFImport) {
    convertPDFToMarkdown(pending)
    resumeSharedImportAfterAnswer()
  }

  private func attachPDFAsImages(_ pending: PendingPDFImport) {
    convertPDFToImages(pending)
    resumeSharedImportAfterAnswer()
  }

  private func dismissPDFImport() {
    pendingPDFImport = nil
    resumeSharedImportAfterAnswer()
  }

  private func attachHTML(_ pending: PendingHTMLImport, mode: HTMLAttachmentMode) {
    pendingHTMLImport = nil
    if case .failed(let message) = appendDocumentAttachment(
      data: pending.data,
      filename: pending.filename,
      mimeType: pending.mimeType,
      htmlMode: mode)
    {
      attachmentError = message
    }
    resumeSharedImportAfterAnswer()
  }

  private func copyHTMLToWorkspace(_ pending: PendingHTMLImport) {
    pendingHTMLImport = nil
    defer { resumeSharedImportAfterAnswer() }
    guard let conversation = store.currentConversation else {
      attachmentError = "No chat is selected."
      return
    }
    do {
      let resolved = try FileWorkspaceTool.context(for: conversation, settings: store.settings)
      if let bookmark = resolved.refreshedBookmarkData {
        store.refreshWorkingFolderBookmark(
          conversationID: conversation.id, bookmarkData: bookmark)
      }
      let destination = try FileWorkspaceService.importFile(
        data: pending.data, filename: pending.filename, in: resolved.context)
      showAttachmentNotice("Copied \(destination.lastPathComponent) to \(resolved.context.displayName).")
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  private func dismissHTMLImport() {
    pendingHTMLImport = nil
    resumeSharedImportAfterAnswer()
  }

  private var currentWorkspaceName: String {
    guard let conversation = store.currentConversation else {
      return FileWorkspaceService.defaultWorkspaceName
    }
    return store.workingFolderDisplayName(for: conversation)
  }

  private func showAttachmentNotice(_ message: String) {
    attachmentNotice = message
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      if attachmentNotice == message { attachmentNotice = nil }
    }
  }

  private var textControls: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let attachmentConversionMessage {
        HStack(spacing: 6) {
          ProgressView()
            .controlSize(.small)
          Text(attachmentConversionMessage)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 34)
      }
      if let attachmentNotice {
        Label(attachmentNotice, systemImage: "checkmark.circle.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 34)
      }
      if !pendingAttachments.isEmpty {
        pendingAttachmentStrip
      }
      HStack(alignment: .bottom, spacing: 10) {
        toolMenu

        TextField(
          isResponding ? "Queue a message..." : placeholder, text: draftBinding, axis: .vertical
        )
        .textFieldStyle(.plain)
        .lineLimit(1...3)
        .padding(.vertical, 5)
        .frame(minHeight: 32, alignment: .center)
        .focused($composerFocused)
        .onAppear {
          guard focusComposerAfterTextFieldRefresh else { return }
          focusComposerAfterTextFieldRefresh = false
          composerFocused = true
        }
        .id(composerTextFieldRefreshID)
        .popover(
          isPresented: promptAutocompleteBinding,
          attachmentAnchor: .rect(.bounds),
          arrowEdge: .bottom
        ) {
          promptAutocompletePopover
            .presentationCompactAdaptation(.popover)
        }
        .onKeyPress(.return, phases: .down) { press in
          // Only hardware keyboards reach onKeyPress, so the on-screen Return
          // always inserts a newline. With a hardware keyboard, Shift+Return
          // inserts a newline and a bare Return submits.
          guard !press.modifiers.contains(.shift) else { return .ignored }
          submitDraft()
          return .handled
        }

        Button {
          if let id = conversationID, isResponding {
            if canQueueDraft {
              queueDraft(in: id)
            } else {
              store.cancelResponse(in: id)
            }
          } else if canSubmitDraft {
            submitDraft()
          } else {
            liveVoiceSession.start(store: store, ttsPlayer: ttsPlayer)
          }
        } label: {
          Image(systemName: trailingActionSystemImage)
            .font(.title2)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(trailingActionColor)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .adaptiveGlassButtonStyle()
        .disabled(!isResponding && liveVoiceSession.isActive)
        .help(trailingActionHelp)
      }
    }
  }

  private var pendingAttachmentStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(pendingAttachments) { attachment in
          AttachmentPill(
            attachment: attachment,
            onOpen: {
              if attachment.kind == .image {
                viewingPendingImageAttachment = attachment
              } else {
                viewingPendingAttachment = attachment
              }
            },
            onRemove: {
              pendingAttachments.removeAll { $0.id == attachment.id }
            })
        }
        if pendingImageAttachmentCount > 1 {
          Button {
            pendingAttachments.removeAll { $0.kind == .image }
          } label: {
            Image(systemName: "trash")
              .font(.callout.weight(.semibold))
              .foregroundStyle(.secondary)
              .frame(width: 34, height: 34)
              .background(.regularMaterial)
              .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Remove all image attachments")
          .help("Remove all images")
        }
      }
      .padding(.horizontal, 34)
    }
  }

  private var pendingImageAttachmentCount: Int {
    pendingAttachments.filter { $0.kind == .image }.count
  }

  private func updatePendingAttachmentText(id: UUID, text: String) {
    guard let index = pendingAttachments.firstIndex(where: { $0.id == id }) else { return }
    pendingAttachments[index].text = text
  }

  private var trailingActionSystemImage: String {
    if isResponding {
      return canQueueDraft ? "arrow.up.to.line" : "stop.fill"
    }
    if canSubmitDraft {
      return "arrow.up"
    }
    return "mic"
  }

  private var trailingActionColor: Color {
    if isResponding {
      return canQueueDraft ? .orange : .red
    }
    return .accentColor
  }

  private var trailingActionHelp: String {
    if isResponding {
      return canQueueDraft ? "Queue message" : "Stop response"
    }
    if canSubmitDraft {
      return "Send message"
    }
    return "Start voice conversation"
  }

  private var voiceControls: some View {
    HStack(spacing: 12) {
      voiceLeadingControl

      VStack(alignment: .leading, spacing: 2) {
        Text(voiceStatusTitle)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.primary)
        Text(liveVoiceSession.errorMessage ?? voiceStatusDetail)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      voiceTrailingControl
    }
  }

  @ViewBuilder
  private var voiceLeadingControl: some View {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      Button {
        cancelVoiceNoteAttachment()
      } label: {
        voiceControlImage("xmark.circle.fill", color: .red)
      }
      .adaptiveGlassButtonStyle()
      .help("Cancel voice note")
    } else {
      Button {
        Task { @MainActor in
          await stopVoiceAndKeepTranscript()
        }
      } label: {
        voiceControlImage("stop.fill", color: .red)
      }
      .adaptiveGlassButtonStyle()
      .help("Stop conversation")
    }
  }

  @ViewBuilder
  private var voiceTrailingControl: some View {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      Button {
        Task { @MainActor in
          await stopVoiceAndAttachTranscript()
        }
      } label: {
        voiceControlImage("checkmark.circle.fill", color: .accentColor)
      }
      .adaptiveGlassButtonStyle()
      .disabled(liveVoiceSession.state == .requestingPermission)
      .help("Attach voice note")
    } else {
      Button {
        if hasVoiceTranscript {
          liveVoiceSession.submitCurrentTurn(store: store, ttsPlayer: ttsPlayer)
        } else {
          liveVoiceSession.togglePauseOrRecord(store: store, ttsPlayer: ttsPlayer)
        }
      } label: {
        voiceControlImage(voiceTrailingSystemImage, color: .accentColor)
      }
      .adaptiveGlassButtonStyle()
      .disabled(liveVoiceSession.state == .requestingPermission)
      .help(voiceTrailingHelp)
    }
  }

  private var hasVoiceTranscript: Bool {
    !liveVoiceSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private var voiceTrailingSystemImage: String {
    hasVoiceTranscript ? "arrow.up" : liveVoiceSession.primaryControlSystemImage
  }

  private var voiceTrailingHelp: String {
    hasVoiceTranscript ? "Send message" : liveVoiceSession.primaryControlHelp
  }

  private func voiceControlImage(_ systemImage: String, color: Color) -> some View {
    Image(systemName: systemImage)
      .font(.title2)
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
      .frame(width: 28, height: 28)
      .contentShape(Circle())
  }

  private func cancelVoiceNoteAttachment() {
    liveVoiceSession.stop(cancelResponse: false)
    composerFocused = true
  }

  private var voiceStatusTitle: String {
    guard liveVoiceSession.mode == .voiceNoteAttachment else {
      return liveVoiceSession.state.statusText
    }
    switch liveVoiceSession.state {
    case .idle:
      return "Voice note off"
    case .requestingPermission:
      return "Requesting access"
    case .listening:
      return "Recording voice note"
    case .paused:
      return "Voice note ready"
    case .thinking:
      return "Processing voice note"
    case .speaking:
      return "Voice note ready"
    case .error:
      return "Voice note error"
    }
  }

  @MainActor
  private func stopVoiceAndKeepTranscript(
    cancelResponse: Bool = true,
    focusComposer: Bool = true
  ) async {
    if liveVoiceSession.mode == .voiceNoteAttachment {
      await stopVoiceAndAttachTranscript(focusComposer: focusComposer)
      return
    }
    let text = await liveVoiceSession.stopForDraft(cancelResponse: cancelResponse)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    draftText = mergedDraftText(appending: text)
    persistDraftTextNow()
    if focusComposer {
      composerFocused = true
    }
  }

  @MainActor
  private func stopVoiceAndAttachTranscript(focusComposer: Bool = true) async {
    let text = await liveVoiceSession.stopForDraft(cancelResponse: false)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      if focusComposer {
        composerFocused = true
      }
      return
    }
    pendingAttachments.append(
      .textFile(
        filename: voiceNoteAttachmentFilename(),
        text: text,
        mimeType: "text/plain"))
    if focusComposer {
      composerFocused = true
    }
  }

  private func mergedDraftText(appending text: String) -> String {
    let current = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty else { return text }
    return "\(current)\n\(text)"
  }

  private var voiceStatusDetail: String {
    let trimmed = liveVoiceSession.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty {
      return trimmed
    }
    return
      "\(store.settings.conversation.speechRecognitionBackend.displayName) · \(liveVoiceSession.languageIdentifier)"
  }

  private var draftBinding: Binding<String> {
    Binding(
      get: { draftText },
      set: { newText in
        draftText = newText
        scheduleDraftPersistence(newText, for: conversationID)
      }
    )
  }

  private func scheduleDraftPersistence(_ text: String, for conversationID: UUID?) {
    draftPersistenceTask?.cancel()
    let store = store
    draftPersistenceTask = Task.detached(priority: .utility) {
      do {
        try await Task.sleep(nanoseconds: Self.draftAutosaveDelayNanoseconds)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await store.setDraftText(text, for: conversationID)
    }
  }

  private func persistDraftTextNow(_ text: String? = nil, for conversationID: UUID? = nil) {
    draftPersistenceTask?.cancel()
    draftPersistenceTask = nil
    store.setDraftText(text ?? draftText, for: conversationID ?? self.conversationID)
  }

  private func submitDraft() {
    if isResponding, let conversationID, canQueueDraft {
      queueDraft(in: conversationID)
      return
    }
    guard canSubmitDraft else { return }
    let submitted = draftText
    let submittedAttachments = pendingAttachments
    let submittedConversationID = conversationID
    draftText = ""
    pendingAttachments = []
    persistDraftTextNow("", for: submittedConversationID)
    Task {
      let sent = await store.send(
        prompt: submitted,
        attachments: submittedAttachments)
      if !sent {
        draftText = submitted
        pendingAttachments = submittedAttachments
        persistDraftTextNow(submitted, for: submittedConversationID)
      }
    }
  }

  private func queueDraft(in conversationID: UUID) {
    guard canQueueDraft else { return }
    let submitted = draftText
    let submittedAttachments = pendingAttachments
    draftText = ""
    pendingAttachments = []
    persistDraftTextNow("", for: conversationID)
    guard
      !store.enqueueUserMessage(
        prompt: submitted,
        attachments: submittedAttachments,
        in: conversationID)
    else {
      return
    }

    // The provider may have completed between the button rendering and this
    // tap. In that race, submit it as the next ordinary turn instead.
    Task {
      let sent = await store.send(
        prompt: submitted,
        attachments: submittedAttachments)
      if !sent {
        draftText = submitted
        pendingAttachments = submittedAttachments
        persistDraftTextNow(submitted, for: conversationID)
      }
    }
  }

  private func restoreQueuedMessageToComposer(_ message: QueuedChatMessage) {
    let current = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    if current.isEmpty {
      draftText = message.text
    } else if !message.text.isEmpty {
      draftText = "\(message.text)\n\(current)"
    }
    pendingAttachments = message.attachments + pendingAttachments
    persistDraftTextNow()
    composerFocused = true
  }

  private func applyComposerDraftReplacement(_ replacement: ComposerDraftReplacement) {
    Task { @MainActor in
      // A follow-up tap removes its suggestion card in the same update that
      // requests this replacement. Let that teardown finish before changing
      // the native text field, otherwise it keeps displaying its cached text
      // until the user types.
      await Task.yield()
      guard !liveVoiceSession.isActive,
        conversationID == store.currentConversation?.id,
        store.composerDraftReplacement?.id == replacement.id
      else {
        return
      }
      composerFocused = false
      draftText = replacement.text
      promptAutocompleteSuppressedCommand = nil
      focusComposerAfterTextFieldRefresh = true
      composerTextFieldRefreshID = replacement.id
      store.consumeComposerDraftReplacement(replacement.id)
    }
  }

  private var promptAutocompletePopover: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(promptShortcutOptions) { option in
          Button {
            autocompletePrompt(option)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: option.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
              VStack(alignment: .leading, spacing: 2) {
                Text("/\(option.commandName)")
                  .font(.callout.weight(.semibold))
                  .foregroundStyle(.primary)
                HStack(spacing: 6) {
                  Text(option.displayName)
                    .lineLimit(1)
                  Text(option.detail)
                    .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              }
              Spacer(minLength: 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.vertical, 6)
    }
    .frame(minWidth: 280, idealWidth: 340, maxWidth: 380, maxHeight: 280)
  }

  private func autocompletePrompt(_ option: PromptShortcutMenuOption) {
    let remainder = PromptSlashCommand.parse(draftText)?.remainder ?? ""
    let completed =
      remainder.isEmpty
      ? "/\(option.commandName) "
      : PromptSlashCommand.visualText(commandName: option.commandName, remainder: remainder)
    // Rewriting the draft in the same update that dismisses the popover leaves
    // the composer's text view showing the typed fragment until it is tapped
    // again: the text change is swallowed by the presentation teardown. Close
    // the popover first (pendingPromptCompletion keeps it closed without
    // touching the draft, so the half-typed command cannot re-open it), then
    // apply the completion on the next runloop turn.
    promptAutocompleteSuppressedCommand = option.commandName
    pendingPromptCompletion = completed
    Task { @MainActor in
      guard pendingPromptCompletion == completed else { return }
      pendingPromptCompletion = nil
      draftText = completed
      persistDraftTextNow(completed)
      composerFocused = true
    }
  }

  private var toolMenu: some View {
    Button {
      showingToolMenu.toggle()
    } label: {
      Image(systemName: "plus")
        .font(.title2)
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color.accentColor)
        .frame(width: 24, height: 24)
        .contentShape(Circle())
    }
    .adaptiveGlassButtonStyle()
    .popover(isPresented: $showingToolMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
      toolMenuPopover
        .presentationCompactAdaptation(.popover)
    }
    .popover(isPresented: $showingToolPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom)
    {
      ToolPickerPopover()
        .environmentObject(store)
        .presentationCompactAdaptation(.popover)
    }
    .popover(
      isPresented: $showingWorkingFolderMenu, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom
    ) {
      workingFolderMenuPopover
        .presentationCompactAdaptation(.popover)
    }
    .help("Tools")
  }

  private var toolMenuPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Toggle(isOn: toolsEnabledBinding) {
        toolMenuRowLabel("Enable Tools", systemImage: "wrench.and.screwdriver")
      }
      .toggleStyle(.switch)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        openToolPicker()
      } label: {
        toolMenuRowLabel(
          "Select Tools...",
          systemImage: "checklist",
          trailingText: "(\(enabledToolSelectionCount))")
      }
      .disabled(!toolsEnabled)
      .opacity(toolsEnabled ? 1 : 0.45)
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        openWorkingFolderMenu()
      } label: {
        toolMenuRowLabel(
          "Working Folder...",
          systemImage: "folder.badge.gearshape",
          trailingText: workingFolderMenuText)
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

      Button {
        openTextFileImporter()
      } label: {
        toolMenuRowLabel("Attach Document", systemImage: "doc.text")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        showingToolMenu = false
        liveVoiceSession.startVoiceNoteAttachment(store: store, ttsPlayer: ttsPlayer)
      } label: {
        toolMenuRowLabel("Record voice", systemImage: "mic.badge.plus")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        showingToolMenu = false
        showingImagePicker = true
      } label: {
        toolMenuRowLabel("Add images", systemImage: "photo")
      }
      .disabled(!canAttachImage)
      .opacity(canAttachImage ? 1 : 0.45)
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Button {
        showingToolMenu = false
        showingCameraPicker = true
      } label: {
        toolMenuRowLabel("Take picture", systemImage: "camera")
      }
      .disabled(!canTakePicture)
      .opacity(canTakePicture ? 1 : 0.45)
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)

      Divider()

      Button {
        showingToolMenu = false
        showingWebXDCLauncher = true
      } label: {
        toolMenuRowLabel("Start App", systemImage: "square.grid.2x2")
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
    }
    .padding(8)
    .frame(minWidth: 240)
    .background(.regularMaterial)
    .fileImporter(
      isPresented: $showingTextFileImporter,
      allowedContentTypes: Self.documentAttachmentTypes
    ) { result in
      showingToolMenu = false
      importTextAttachment(result)
    }
  }

  /// The three ways a chat can resolve its working folder, shown as a popup
  /// from the "Working Folder..." row of the (+) menu.
  private var workingFolderMenuPopover: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Working Folder")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.bottom, 2)

      workingFolderMenuRow("Disable", systemImage: "folder.badge.minus", mode: .disabled) {
        store.disableCurrentConversationWorkingFolder()
      }

      workingFolderMenuRow(
        "Use Default Folder",
        systemImage: "arrow.uturn.backward",
        mode: .inherited,
        trailingText: defaultWorkingFolderName
      ) {
        store.clearCurrentConversationWorkingFolder()
      }

      workingFolderMenuRow(
        "Set Custom Folder...",
        systemImage: "folder.badge.gearshape",
        mode: .custom,
        trailingText: store.currentConversation?.workingFolder?.displayName,
        dismissesMenu: false
      ) {
        openWorkingFolderImporter()
      }
    }
    .padding(8)
    .frame(minWidth: 260)
    .background(.regularMaterial)
    .fileImporter(
      isPresented: $showingWorkingFolderImporter,
      allowedContentTypes: [.folder]
    ) { result in
      showingWorkingFolderMenu = false
      importWorkingFolder(result)
    }
  }

  private func workingFolderMenuRow(
    _ title: String,
    systemImage: String,
    mode: ConversationWorkingFolderMode,
    trailingText: String? = nil,
    dismissesMenu: Bool = true,
    action: @escaping () -> Void
  ) -> some View {
    Button {
      if dismissesMenu {
        showingWorkingFolderMenu = false
      }
      action()
    } label: {
      HStack(spacing: 10) {
        Image(systemName: workingFolderMode == mode ? "checkmark.circle.fill" : "circle")
          .foregroundStyle(workingFolderMode == mode ? Color.accentColor : Color.secondary)
        toolMenuRowLabel(title, systemImage: systemImage, trailingText: trailingText)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
  }

  private func toolMenuRowLabel(
    _ title: String,
    systemImage: String,
    trailingText: String? = nil
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title)
        .foregroundStyle(.primary)
      Spacer()
      if let trailingText {
        Text(trailingText)
          .foregroundStyle(.secondary)
      }
    }
    .contentShape(Rectangle())
  }

  private func openToolPicker() {
    guard toolsEnabled else { return }
    showingToolMenu = false
    showingToolPicker = true
  }

  private func openWorkingFolderMenu() {
    showingToolMenu = false
    showingWorkingFolderMenu = true
  }

  private func openTextFileImporter() {
    showingTextFileImporter = true
  }

  private func openWorkingFolderImporter() {
    showingWorkingFolderImporter = true
  }

  private var workingFolderMode: ConversationWorkingFolderMode {
    guard let conversation = store.currentConversation else { return .inherited }
    return store.workingFolderMode(for: conversation)
  }

  private var defaultWorkingFolderName: String? {
    guard let conversation = store.currentConversation else { return nil }
    return store.conversationFolderDefaults(for: conversation.folderID).workingFolder?.displayName
      ?? FileWorkspaceService.defaultWorkspaceName
  }

  private var workingFolderMenuText: String? {
    guard let conversation = store.currentConversation else { return nil }
    guard workingFolderMode != .disabled else { return "Off" }
    return store.workingFolderDisplayName(for: conversation)
  }

  private func importWorkingFolder(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let reference = try WorkingFolderAccess.makeReference(from: url)
      store.setCurrentConversationWorkingFolder(reference)
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  private var toolsEnabled: Bool {
    store.currentConversation?.toolsEnabled ?? true
  }

  private var enabledToolSelectionCount: Int {
    let builtInToolCount = BuiltInToolID.allCases.filter {
      $0 != .memory && (store.currentConversation?.enabledTools.contains($0) ?? false)
    }.count
    let enabledMCPTools =
      store.currentConversation?.enabledMCPTools ?? store.settings.defaultEnabledMCPTools
    let mcpToolCount = store.mcpTools.reduce(0) { count, entry in
      count
        + entry.value.filter {
          enabledMCPTools.contains(MCPToolSelection.key(serverID: entry.key, toolName: $0.name))
        }.count
    }
    return builtInToolCount + mcpToolCount
  }

  private var toolsEnabledBinding: Binding<Bool> {
    Binding(
      get: { toolsEnabled },
      set: { enabled in
        showingToolPicker = false
        store.updateCurrentConversation { conversation in
          conversation.toolsEnabled = enabled
        }
      }
    )
  }

  private static let textAttachmentByteLimit = 1_500_000

  /// Let Files offer any data file. MaiDocuments inspects its MIME type and
  /// bytes after selection, accepting arbitrary UTF-8 source/text files and
  /// rejecting unsupported binary data with a useful error.
  private static let documentAttachmentTypes: [UTType] = [.data]

  private func importTextAttachment(_ result: Result<URL, Error>) {
    do {
      let url = try result.get()
      let access = url.startAccessingSecurityScopedResource()
      defer {
        if access { url.stopAccessingSecurityScopedResource() }
      }
      guard !AudioTranscriptionService.isAudioFile(url) else {
        transcribePickedAudio(at: url, filename: url.lastPathComponent)
        return
      }
      if case .failed(let message) = importDocument(at: url, filename: url.lastPathComponent) {
        attachmentError = message
      }
    } catch {
      attachmentError = error.localizedDescription
    }
  }

  /// Converts a document into a text attachment, the same way for a file picked
  /// in the app and for one shared from another app: Word, EPUB and JSON become
  /// Markdown or an outline, text files travel as they are. A PDF is worth
  /// reading either way, so it asks first and the caller waits for the answer.
  private func importDocument(at url: URL, filename: String) -> DocumentImportOutcome {
    do {
      let data = try DocumentAttachmentImporter.data(at: url)
      let mimeType = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)?
        .preferredMIMEType
      switch DocumentAttachmentImporter.kind(
        for: data, filename: filename, mimeType: mimeType)
      {
      case .pdf:
        let pending = PendingPDFImport(
          name: (filename as NSString).deletingPathExtension,
          data: data,
          canAttachImages: canAttachImage)
        guard pending.canAttachImages else {
          convertPDFToMarkdown(pending)
          return .attached
        }
        pendingPDFImport = pending
        return .awaitingAnswer
      case .html:
        pendingHTMLImport = PendingHTMLImport(
          data: data, filename: filename, mimeType: mimeType)
        return .awaitingAnswer
      default:
        break
      }
      return appendDocumentAttachment(data: data, filename: filename, mimeType: mimeType)
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  @discardableResult
  private func appendDocumentAttachment(
    data: Data,
    filename: String,
    mimeType: String?,
    htmlMode: HTMLAttachmentMode = .source
  ) -> DocumentImportOutcome {
    do {
      let imported = try DocumentAttachmentImporter.attachment(
        data: data, filename: filename, mimeType: mimeType, htmlMode: htmlMode)
      guard case .file(let file) = imported.content, let text = file.text else {
        return .failed("\(filename) does not contain any text.")
      }
      pendingAttachments.append(
        .textFile(filename: imported.name, text: text, mimeType: file.mimeType))
      composerFocused = true
      return .attached
    } catch {
      return .failed(error.localizedDescription)
    }
  }

  /// Transcribes a recording picked with "Attach Document" and attaches the
  /// text under the recording's own name, the same way a shared voice message
  /// is handled. The file is copied first: recognition outlives the picker's
  /// access to it.
  private func transcribePickedAudio(at url: URL, filename: String) {
    let staged: URL
    do {
      staged = try AudioTranscriptionService.stagedCopy(of: url)
    } catch {
      attachmentError = error.localizedDescription
      return
    }
    attachmentConversionMessage = "Transcribing audio..."
    let localeIdentifier = store.settings.conversation.speechRecognitionLanguageIdentifier
    Task { @MainActor in
      defer {
        attachmentConversionMessage = nil
        try? FileManager.default.removeItem(at: staged)
      }
      do {
        let transcript = try await AudioTranscriptionService.transcribe(
          fileURL: staged,
          localeIdentifier: localeIdentifier)
        pendingAttachments.append(
          .textFile(
            filename: transcriptAttachmentFilename(for: filename),
            text: transcript,
            mimeType: "text/plain"))
        composerFocused = true
      } catch {
        attachmentError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
      }
    }
  }

  /// Converts the PDF's text off the main thread: a scanned document has to be
  /// run through OCR, which takes a moment.
  private func convertPDFToMarkdown(_ pending: PendingPDFImport) {
    pendingPDFImport = nil
    attachmentConversionMessage = "Converting PDF..."
    let data = pending.data
    let name = pending.name
    Task {
      let outcome = await Task.detached(priority: .userInitiated) {
        PDFTextImportOutcome.convert(data)
      }.value
      attachmentConversionMessage = nil
      switch outcome {
      case .markdown(let markdown):
        guard markdown.utf8.count <= Self.textAttachmentByteLimit else {
          attachmentError = "Text attachments are limited to 1.5 MB."
          return
        }
        pendingAttachments.append(
          .textFile(filename: name + ".md", text: markdown, mimeType: "text/markdown"))
        composerFocused = true
      case .failure(let message):
        attachmentError = message
      }
    }
  }

  private func convertPDFToImages(_ pending: PendingPDFImport) {
    pendingPDFImport = nil
    attachmentConversionMessage = "Converting PDF..."
    let data = pending.data
    let name = pending.name
    Task {
      let outcome = await Task.detached(priority: .userInitiated) {
        PDFPageImportOutcome.render(data)
      }.value
      attachmentConversionMessage = nil
      switch outcome {
      case .pages(let pages, let truncated):
        await appendPDFPageAttachments(pages, name: name, truncated: truncated)
      case .failure(let message):
        attachmentError = message
      }
    }
  }

  @MainActor
  private func appendPDFPageAttachments(
    _ pages: [Data], name: String, truncated: Bool
  ) async {
    var items: [PendingImageAttachmentImport.Item] = []
    for (index, page) in pages.enumerated() {
      guard let image = await AttachmentImageLoader.decodeImageData(page) else { continue }
      items.append(
        PendingImageAttachmentImport.Item(
          filename: "\(name)-page-\(index + 1).jpg", image: image))
    }
    guard !items.isEmpty else {
      attachmentError = "The PDF pages could not be rendered."
      return
    }

    let note: String? =
      truncated
      ? "Only the first \(PDFImporter.maximumImagePages) pages were attached." : nil
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: items, failedCount: 0, note: note)
      return
    }
    appendImageAttachments(items, size: imageSize)
    if let note { attachmentError = note }
  }

  @MainActor
  private func importImageAttachments(_ items: [PhotosPickerItem]) async {
    defer { selectedPhotoItems = [] }
    guard !items.isEmpty else { return }
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }

    var imports: [PendingImageAttachmentImport.Item] = []
    var failedCount = 0
    let timestamp = Int(Date().timeIntervalSince1970)

    for (index, item) in items.enumerated() {
      do {
        guard let data = try await item.loadTransferable(type: Data.self),
          let image = await AttachmentImageLoader.decodeImageData(data)
        else {
          failedCount += 1
          continue
        }
        imports.append(
          PendingImageAttachmentImport.Item(
            filename: imageAttachmentFilename(
              prefix: "image",
              timestamp: timestamp,
              index: items.count == 1 ? nil : index + 1),
            image: image))
      } catch {
        failedCount += 1
      }
    }

    guard !imports.isEmpty else {
      attachmentError =
        items.count == 1
        ? "Could not read the selected image." : "Could not read the selected images."
      return
    }

    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: imports,
        failedCount: failedCount)
      return
    }
    appendImageAttachments(imports, size: imageSize)
    if failedCount > 0 {
      attachmentError = imageImportFailureMessage(count: failedCount)
    }
  }

  @MainActor
  private func importCameraImageAttachment(_ image: UIImage) {
    guard canAttachImage else {
      attachmentError = "The selected provider or model does not support image input."
      return
    }
    let filename = imageAttachmentFilename(
      prefix: "photo",
      timestamp: Int(Date().timeIntervalSince1970))
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: [.init(filename: filename, image: image)],
        failedCount: 0)
      return
    }
    appendImageAttachment(image, filename: filename, size: imageSize)
  }

  /// Extracts the text instead of attaching the pixels: each image is run
  /// through Vision's on-device recogniser off the main thread and lands as a
  /// Markdown text attachment.
  private func convertImagesToText(_ pending: PendingImageAttachmentImport) {
    pendingImageSizePrompt = nil
    attachmentConversionMessage = "Recognizing text..."
    let items = pending.items
    Task {
      var attachments: [ChatAttachment] = []
      var unreadableCount = 0
      let ocrProvider = try? await PocketMaiPluginHost.shared.makeOCRProvider()
      for item in items {
        let imageData = item.image.jpegData(compressionQuality: 0.95)
        let markdown: String?
        if let imageData, let ocrProvider {
          markdown = try? await ocrProvider.recognize(
            MaiCore.OCRRequest(
              imageData: imageData,
              mimeType: "image/jpeg",
              filename: item.filename)
          ).markdown
        } else {
          markdown = nil
        }
        guard let markdown, markdown.utf8.count <= Self.textAttachmentByteLimit else {
          unreadableCount += 1
          continue
        }
        attachments.append(
          .textFile(
            filename: (item.filename as NSString).deletingPathExtension + ".md",
            text: markdown,
            mimeType: "text/markdown"))
      }
      attachmentConversionMessage = nil
      pendingAttachments.append(contentsOf: attachments)
      if !attachments.isEmpty {
        composerFocused = true
      }
      if unreadableCount > 0 {
        attachmentError =
          items.count == 1
          ? "No text could be recognized in the image."
          : "No text could be recognized in \(unreadableCount) of \(items.count) images."
      } else if pending.failedCount > 0 {
        attachmentError = imageImportFailureMessage(count: pending.failedCount)
      } else if let note = pending.note {
        attachmentError = note
      }
    }
  }

  private func appendImageAttachment(
    _ pending: PendingImageAttachmentImport,
    size: AttachmentImageSize
  ) {
    appendImageAttachments(pending.items, size: size)
    pendingImageSizePrompt = nil
    if pending.failedCount > 0 {
      attachmentError = imageImportFailureMessage(count: pending.failedCount)
    } else if let note = pending.note {
      attachmentError = note
    }
  }

  private func appendImageAttachments(
    _ items: [PendingImageAttachmentImport.Item],
    size: AttachmentImageSize
  ) {
    for item in items {
      appendImageAttachment(item.image, filename: item.filename, size: size)
    }
  }

  private func appendImageAttachment(_ image: UIImage, filename: String, size: AttachmentImageSize)
  {
    let resized = resizeImage(image, maxDimension: size.maxDimension)
    guard let output = resized.image.jpegData(compressionQuality: 0.82) else {
      attachmentError = "Could not encode the selected image."
      return
    }
    pendingAttachments.append(
      .image(
        filename: filename,
        data: output,
        width: Int(resized.size.width.rounded()),
        height: Int(resized.size.height.rounded())))
    composerFocused = true
  }

  private func resizeImage(_ image: UIImage, maxDimension: Int?) -> (image: UIImage, size: CGSize) {
    let pixelSize = CGSize(
      width: image.size.width * image.scale,
      height: image.size.height * image.scale)
    guard let maxDimension, max(pixelSize.width, pixelSize.height) > CGFloat(maxDimension) else {
      return (image, pixelSize)
    }
    let scale = CGFloat(maxDimension) / max(pixelSize.width, pixelSize.height)
    let target = CGSize(
      width: max(1, floor(pixelSize.width * scale)),
      height: max(1, floor(pixelSize.height * scale)))
    let renderer = UIGraphicsImageRenderer(size: target)
    let resized = renderer.image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return (resized, target)
  }

  private func imageAttachmentFilename(prefix: String, timestamp: Int, index: Int? = nil) -> String
  {
    guard let index else { return "\(prefix)-\(timestamp).jpg" }
    return "\(prefix)-\(timestamp)-\(index).jpg"
  }

  // MARK: - Shared content

  /// Imports what another app sent to PocketMai through the share sheet.
  ///
  /// Each item follows the same path it would have taken inside the app: a
  /// picture asks for its size or offers OCR, a PDF asks how it should be
  /// attached, a voice message is transcribed, a document is converted to text,
  /// and shared text or a link is appended to the draft.
  private func beginSharedImport() {
    let items = store.takeQueuedSharedItems()
    guard !items.isEmpty else { return }
    sharedImportQueue.append(contentsOf: items)
    Task { await processSharedImportQueue() }
  }

  @MainActor
  private func processSharedImportQueue() async {
    guard !isImportingSharedItems else { return }
    isImportingSharedItems = true
    defer { isImportingSharedItems = false }
    while !sharedImportQueue.isEmpty {
      let item = sharedImportQueue.removeFirst()
      // An item that puts a question on screen stops the queue; the answer
      // starts it again.
      if await importSharedItem(item) { return }
    }
    finishSharedImport()
  }

  private var hasPendingSharedImports: Bool {
    !sharedImportQueue.isEmpty || !sharedImportImages.isEmpty || !sharedImportFailures.isEmpty
  }

  /// Continues the import once a confirmation dialog has been answered, after
  /// the dialog has had time to dismiss. Dismissing a dialog reports both the
  /// button and the binding, so a resume already on its way is left alone.
  private func resumeSharedImportAfterAnswer() {
    guard hasPendingSharedImports, !isResumingSharedImport else { return }
    isResumingSharedImport = true
    Task { @MainActor in
      try? await Task.sleep(for: .milliseconds(400))
      isResumingSharedImport = false
      await processSharedImportQueue()
    }
  }

  /// Returns true when the item is waiting on a dialog.
  @MainActor
  private func importSharedItem(_ item: SharedInboxItem) async -> Bool {
    defer { SharedInbox.discard(item) }
    switch item.kind {
    case .text, .link:
      let text = (item.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { return false }
      draftText = mergedDraftText(appending: text)
      persistDraftTextNow()
      composerFocused = true
      return false
    case .image:
      await collectSharedImage(item)
      return false
    case .audio:
      await transcribeSharedAudio(item)
      return false
    case .document:
      guard let url = SharedInbox.fileURL(for: item) else {
        sharedImportFailures.append("\(item.filename) could not be read.")
        return false
      }
      switch importDocument(at: url, filename: item.filename) {
      case .attached:
        return false
      case .awaitingAnswer:
        return true
      case .failed(let message):
        sharedImportFailures.append(message)
        return false
      }
    }
  }

  @MainActor
  private func collectSharedImage(_ item: SharedInboxItem) async {
    guard let url = SharedInbox.fileURL(for: item),
      let data = try? Data(contentsOf: url),
      let image = await AttachmentImageLoader.decodeImageData(data)
    else {
      sharedImportFailures.append("\(item.filename) could not be read.")
      return
    }
    // The attachment is re-encoded as JPEG, so the name follows.
    let name = (item.filename as NSString).deletingPathExtension
    sharedImportImages.append(
      PendingImageAttachmentImport.Item(
        filename: (name.isEmpty ? "shared-image" : name) + ".jpg",
        image: image))
  }

  @MainActor
  private func transcribeSharedAudio(_ item: SharedInboxItem) async {
    guard let url = SharedInbox.fileURL(for: item) else {
      sharedImportFailures.append("\(item.filename) could not be read.")
      return
    }
    attachmentConversionMessage = "Transcribing audio..."
    defer { attachmentConversionMessage = nil }
    do {
      let transcript = try await AudioTranscriptionService.transcribe(
        fileURL: url,
        localeIdentifier: store.settings.conversation.speechRecognitionLanguageIdentifier)
      pendingAttachments.append(
        .textFile(
          filename: transcriptAttachmentFilename(for: item.filename),
          text: transcript,
          mimeType: "text/plain"))
      composerFocused = true
    } catch {
      sharedImportFailures.append(
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }
  }

  /// Pictures are attached together at the end, the way a multiple-photo pick
  /// asks for one size for the whole batch.
  @MainActor
  private func finishSharedImport() {
    let images = sharedImportImages
    let note = sharedImportFailures.isEmpty ? nil : sharedImportFailures.joined(separator: "\n")
    sharedImportImages = []
    sharedImportFailures = []

    guard !images.isEmpty else {
      if let note { attachmentError = note }
      return
    }
    guard canAttachImage else {
      // The chosen model cannot read pictures, so their text is read instead of
      // dropping the share.
      convertImagesToText(
        PendingImageAttachmentImport(
          items: images,
          failedCount: 0,
          note: note
            ?? "The selected model does not accept images, so their text was attached instead."))
      return
    }
    let imageSize = store.settings.attachmentImageSize
    guard imageSize != .prompt else {
      pendingImageSizePrompt = PendingImageAttachmentImport(
        items: images,
        failedCount: 0,
        note: note)
      return
    }
    appendImageAttachments(images, size: imageSize)
    if let note { attachmentError = note }
  }

  private func transcriptAttachmentFilename(for filename: String) -> String {
    let stem = (filename as NSString).deletingPathExtension
    let base = stem.isEmpty ? "voice-message" : stem
    var name = "\(base).txt"
    var suffix = 2
    while pendingAttachments.contains(where: { $0.filename == name }) {
      name = "\(base)-\(suffix).txt"
      suffix += 1
    }
    return name
  }

  private func voiceNoteAttachmentFilename() -> String {
    let base = "voice-note-\(Int(Date().timeIntervalSince1970))"
    var filename = "\(base).txt"
    var suffix = 2
    while pendingAttachments.contains(where: { $0.filename == filename }) {
      filename = "\(base)-\(suffix).txt"
      suffix += 1
    }
    return filename
  }

  private func imageImportFailureMessage(count: Int) -> String {
    count == 1 ? "1 image could not be read." : "\(count) images could not be read."
  }
}

/// What happened to a document handed to `importDocument`.
private enum DocumentImportOutcome {
  case attached
  /// A dialog is on screen asking how the document should be attached.
  case awaitingAnswer
  case failed(String)
}

private struct PendingPDFImport {
  let name: String
  let data: Data
  let canAttachImages: Bool
}

private struct PendingHTMLImport {
  let data: Data
  let filename: String
  let mimeType: String?
}

/// The importers run off the main actor, so their results travel as values.
private enum PDFTextImportOutcome: Sendable {
  case markdown(String)
  case failure(String)

  static func convert(_ data: Data) -> PDFTextImportOutcome {
    do {
      return .markdown(try PDFImporter.markdown(from: data))
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private enum PDFPageImportOutcome: Sendable {
  case pages([Data], truncated: Bool)
  case failure(String)

  static func render(_ data: Data) -> PDFPageImportOutcome {
    do {
      let rendered = try PDFImporter.pageImages(from: data)
      return .pages(rendered.images, truncated: rendered.truncated)
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

private struct PendingImageAttachmentImport {
  struct Item {
    let filename: String
    let image: UIImage
  }

  let items: [Item]
  let failedCount: Int
  /// Shown once the attachments land, e.g. when a long PDF was truncated.
  var note: String?

  var imageSizePromptMessage: String {
    guard items.count != 1 else {
      return "Choose the image size for \(items[0].filename)."
    }
    return "Choose the image size for \(items.count) images."
  }
}

private struct CameraImagePicker: UIViewControllerRepresentable {
  @Binding var isPresented: Bool
  let onImagePicked: (UIImage) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(isPresented: $isPresented, onImagePicked: onImagePicked)
  }

  func makeUIViewController(context: Context) -> UIImagePickerController {
    let picker = UIImagePickerController()
    picker.sourceType = .camera
    picker.mediaTypes = [UTType.image.identifier]
    picker.allowsEditing = false
    picker.delegate = context.coordinator
    return picker
  }

  func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

  final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate
  {
    @Binding private var isPresented: Bool
    private let onImagePicked: (UIImage) -> Void

    init(isPresented: Binding<Bool>, onImagePicked: @escaping (UIImage) -> Void) {
      _isPresented = isPresented
      self.onImagePicked = onImagePicked
    }

    func imagePickerController(
      _ picker: UIImagePickerController,
      didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
      isPresented = false
      guard let image = info[.originalImage] as? UIImage else { return }
      onImagePicked(image)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
      isPresented = false
    }
  }
}

private struct AttachmentPill: View {
  let attachment: ChatAttachment
  let onOpen: (() -> Void)?
  let onRemove: () -> Void

  var body: some View {
    if attachment.kind == .image {
      imageAttachmentPill
    } else {
      textAttachmentPill
    }
  }

  private var textAttachmentPill: some View {
    HStack(spacing: 6) {
      Image(systemName: "doc.text")
        .foregroundStyle(.secondary)
      Text(attachment.displayName)
        .font(.caption)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 6)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      onOpen?()
    }
    .accessibilityHint(onOpen == nil ? "" : "Tap to view and edit the file contents")
  }

  private var imageAttachmentPill: some View {
    HStack(spacing: 7) {
      imageThumbnail
      Text(dimensionsLabel)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
      removeButton
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 5)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .onTapGesture {
      onOpen?()
    }
    .accessibilityLabel("\(attachment.displayName), \(dimensionsLabel)")
    .accessibilityHint(onOpen == nil ? "" : "Tap to preview the image")
  }

  @ViewBuilder
  private var imageThumbnail: some View {
    AttachmentImageThumbnail(attachment: attachment, side: 40, cornerRadius: 6)
  }

  private var removeButton: some View {
    Button(action: onRemove) {
      Image(systemName: "xmark.circle.fill")
        .foregroundStyle(.secondary)
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Remove attachment")
  }

  private var dimensionsLabel: String {
    if let width = attachment.width, let height = attachment.height {
      return "\(width)x\(height)"
    }
    return "Image"
  }
}

@MainActor
private final class MessageFontPinchSession {
  struct SemanticAnchor {
    let messageID: UUID
    let rowFraction: CGFloat
    let viewportY: CGFloat
  }

  nonisolated static let coordinateSpaceName = "ChatMessageViewport"

  var isActive = false
  private(set) var semanticAnchor: SemanticAnchor?
  private(set) var realtimeBaseFontSize: Double?
  private(set) var realtimeContentFraction: CGFloat = 0
  private(set) var realtimeViewportY: CGFloat = 0
  private var rowFrames: [UUID: CGRect] = [:]
  private weak var textAnchorView: UITextView?
  private var textAnchorRange: NSRange?
  private var textAnchorValue: String?
  private var textAnchorUnitY: CGFloat = 0.5
  private var textAnchorViewportY: CGFloat?
  private var realtimeRevision = 0

  var hasTextAnchor: Bool {
    textAnchorView != nil && textAnchorRange != nil && textAnchorViewportY != nil
  }

  func updateFrame(_ frame: CGRect, for messageID: UUID) {
    guard frame.height.isFinite, frame.height > 0, frame.minY.isFinite else { return }
    rowFrames[messageID] = frame
  }

  func removeFrame(for messageID: UUID) {
    rowFrames.removeValue(forKey: messageID)
  }

  func captureAnchor(in scrollView: UIScrollView, at contentPoint: CGPoint) {
    let viewportY = contentPoint.y - scrollView.contentOffset.y
    captureSemanticAnchor(at: viewportY, viewportHeight: scrollView.bounds.height)
    captureTextAnchor(in: scrollView, at: contentPoint, viewportY: viewportY)
  }

  private func captureSemanticAnchor(at viewportY: CGFloat, viewportHeight: CGFloat) {
    let visibleFrames = rowFrames.filter { _, frame in
      frame.maxY >= 0 && frame.minY <= viewportHeight
    }
    guard
      let (messageID, frame) = visibleFrames.min(by: { lhs, rhs in
        lhs.value.distance(toY: viewportY) < rhs.value.distance(toY: viewportY)
      })
    else {
      semanticAnchor = nil
      return
    }
    semanticAnchor = SemanticAnchor(
      messageID: messageID,
      rowFraction: min(max((viewportY - frame.minY) / max(frame.height, 1), 0), 1),
      viewportY: viewportY)
  }

  func frame(for messageID: UUID) -> CGRect? {
    rowFrames[messageID]
  }

  func clearAnchor() {
    semanticAnchor = nil
    textAnchorView = nil
    textAnchorRange = nil
    textAnchorValue = nil
    textAnchorUnitY = 0.5
    textAnchorViewportY = nil
  }

  func textAnchorCorrection(in scrollView: UIScrollView) -> CGFloat? {
    guard let targetViewportY = textAnchorViewportY,
      let resolvedViewportY = resolvedTextAnchorViewportY(in: scrollView)
    else { return nil }
    return resolvedViewportY - targetViewportY
  }

  func beginRealtime(
    baseFontSize: Double,
    contentPointY: CGFloat,
    contentHeight: CGFloat,
    viewportY: CGFloat
  ) {
    guard realtimeBaseFontSize == nil else { return }
    realtimeBaseFontSize = baseFontSize
    realtimeContentFraction = min(max(contentPointY / max(contentHeight, 1), 0), 1)
    realtimeViewportY = viewportY
  }

  func nextRealtimeRevision() -> Int {
    realtimeRevision += 1
    return realtimeRevision
  }

  func isCurrentRealtimeRevision(_ revision: Int) -> Bool {
    realtimeRevision == revision
  }

  func invalidateRealtimeUpdates() {
    realtimeRevision += 1
  }

  func finishRealtime() {
    realtimeRevision += 1
    realtimeBaseFontSize = nil
    realtimeContentFraction = 0
    realtimeViewportY = 0
    clearAnchor()
  }

  func resetMetrics() {
    finishRealtime()
    rowFrames.removeAll(keepingCapacity: true)
  }

  private func captureTextAnchor(
    in scrollView: UIScrollView,
    at contentPoint: CGPoint,
    viewportY: CGFloat
  ) {
    textAnchorView = nil
    textAnchorRange = nil
    textAnchorValue = nil
    textAnchorViewportY = nil

    guard let textView = textView(at: contentPoint, in: scrollView),
      textView.textStorage.length > 0
    else { return }

    textView.layoutIfNeeded()
    let layoutManager = textView.layoutManager
    layoutManager.ensureLayout(for: textView.textContainer)
    let localPoint = textView.convert(contentPoint, from: scrollView)
    let textContainerPoint = CGPoint(
      x: localPoint.x - textView.textContainerInset.left,
      y: localPoint.y - textView.textContainerInset.top)
    let characterIndex = layoutManager.characterIndex(
      for: textContainerPoint,
      in: textView.textContainer,
      fractionOfDistanceBetweenInsertionPoints: nil)
    let clampedIndex = min(max(characterIndex, 0), textView.textStorage.length - 1)
    let range = wordRange(at: clampedIndex, in: textView.textStorage.string as NSString)
    guard let rect = textRect(for: range, in: textView), rect.height > 0 else { return }

    let wordTop = textView.textContainerInset.top + rect.minY
    textAnchorView = textView
    textAnchorRange = range
    textAnchorValue = (textView.textStorage.string as NSString).substring(with: range)
    textAnchorUnitY = min(max((localPoint.y - wordTop) / rect.height, 0), 1)
    textAnchorViewportY = viewportY
  }

  private func resolvedTextAnchorViewportY(in scrollView: UIScrollView) -> CGFloat? {
    guard let textView = textAnchorView,
      textView.isDescendant(of: scrollView),
      let range = textAnchorRange,
      let value = textAnchorValue,
      range.location >= 0,
      NSMaxRange(range) <= textView.textStorage.length,
      (textView.textStorage.string as NSString).substring(with: range) == value
    else { return nil }

    textView.layoutIfNeeded()
    guard let rect = textRect(for: range, in: textView), rect.height > 0 else { return nil }
    let localPoint = CGPoint(
      x: textView.textContainerInset.left + rect.midX,
      y: textView.textContainerInset.top + rect.minY + rect.height * textAnchorUnitY)
    let contentPoint = textView.convert(localPoint, to: scrollView)
    return contentPoint.y - scrollView.contentOffset.y
  }

  private func textView(at contentPoint: CGPoint, in scrollView: UIScrollView) -> UITextView? {
    func find(in view: UIView) -> UITextView? {
      for subview in view.subviews.reversed()
      where !subview.isHidden && subview.alpha > 0.01 {
        let localPoint = subview.convert(contentPoint, from: scrollView)
        guard subview.bounds.insetBy(dx: -4, dy: -4).contains(localPoint) else { continue }
        if let textView = subview as? UITextView, textView.textStorage.length > 0 {
          return textView
        }
        if let nested = find(in: subview) {
          return nested
        }
      }
      return nil
    }
    return find(in: scrollView)
  }

  private func wordRange(at characterIndex: Int, in string: NSString) -> NSRange {
    guard string.length > 0 else { return NSRange(location: 0, length: 0) }
    let wordCharacters = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: "_'’"))

    func composedRange(at index: Int) -> NSRange {
      string.rangeOfComposedCharacterSequence(at: min(max(index, 0), string.length - 1))
    }

    func isWord(at index: Int) -> Bool {
      let range = composedRange(at: index)
      return string.substring(with: range).rangeOfCharacter(from: wordCharacters) != nil
    }

    var seed = min(max(characterIndex, 0), string.length - 1)
    if !isWord(at: seed) {
      for distance in 1...32 {
        let left = seed - distance
        let right = seed + distance
        if left >= 0, isWord(at: left) {
          seed = left
          break
        }
        if right < string.length, isWord(at: right) {
          seed = right
          break
        }
      }
    }
    guard isWord(at: seed) else { return composedRange(at: seed) }

    var range = composedRange(at: seed)
    while range.location > 0 {
      let previous = composedRange(at: range.location - 1)
      guard isWord(at: previous.location) else { break }
      range = NSUnionRange(range, previous)
    }
    while NSMaxRange(range) < string.length {
      let next = composedRange(at: NSMaxRange(range))
      guard isWord(at: next.location) else { break }
      range = NSUnionRange(range, next)
    }
    return range
  }

  private func textRect(for range: NSRange, in textView: UITextView) -> CGRect? {
    guard range.length > 0, NSMaxRange(range) <= textView.textStorage.length else { return nil }
    let layoutManager = textView.layoutManager
    layoutManager.ensureLayout(for: textView.textContainer)
    let glyphRange = layoutManager.glyphRange(
      forCharacterRange: range,
      actualCharacterRange: nil)
    guard glyphRange.length > 0 else { return nil }
    return layoutManager.boundingRect(forGlyphRange: glyphRange, in: textView.textContainer)
  }
}

extension CGRect {
  fileprivate func distance(toY y: CGFloat) -> CGFloat {
    if y < minY { return minY - y }
    if y > maxY { return y - maxY }
    return 0
  }
}

private struct MessageListPinchBridge: UIViewRepresentable {
  let zoomMethod: AppearanceZoomMethod
  let baseFontSize: Double
  var onBegan: (UIScrollView, CGPoint) -> Void
  var onEnded: (CGFloat, UIScrollView, CGFloat, CGFloat) -> Void
  var onCancelled: () -> Void
  var onRealtimeChanged: (CGFloat, UIScrollView, CGPoint) -> Void
  var onRealtimeEnded: (UIScrollView) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      zoomMethod: zoomMethod,
      baseFontSize: baseFontSize,
      onBegan: onBegan,
      onEnded: onEnded,
      onCancelled: onCancelled,
      onRealtimeChanged: onRealtimeChanged,
      onRealtimeEnded: onRealtimeEnded)
  }

  func makeUIView(context: Context) -> UIView {
    let view = MessageListPinchHostView()
    view.backgroundColor = .clear
    view.isUserInteractionEnabled = false
    view.onHierarchyChange = { [weak coordinator = context.coordinator] view in
      coordinator?.installIfNeeded(from: view)
    }
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.onBegan = onBegan
    context.coordinator.onEnded = onEnded
    context.coordinator.onCancelled = onCancelled
    context.coordinator.onRealtimeChanged = onRealtimeChanged
    context.coordinator.onRealtimeEnded = onRealtimeEnded
    context.coordinator.setZoomMethod(zoomMethod)
    context.coordinator.baseFontSize = baseFontSize
    DispatchQueue.main.async {
      context.coordinator.installIfNeeded(from: view)
    }
  }

  static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
    (view as? MessageListPinchHostView)?.onHierarchyChange = nil
    coordinator.uninstall()
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    private(set) var zoomMethod: AppearanceZoomMethod
    var baseFontSize: Double
    var onBegan: (UIScrollView, CGPoint) -> Void
    var onEnded: (CGFloat, UIScrollView, CGFloat, CGFloat) -> Void
    var onCancelled: () -> Void
    var onRealtimeChanged: (CGFloat, UIScrollView, CGPoint) -> Void
    var onRealtimeEnded: (UIScrollView) -> Void

    private weak var hostView: UIView?
    private weak var scrollView: UIScrollView?
    private weak var transformView: UIView?
    private var pinchGesture: UIPinchGestureRecognizer?
    private var pinchBaseFontSize: Double?
    private var pinchAnchor = CGPoint.zero
    private var originalTransform = CGAffineTransform.identity
    private var originalCenter = CGPoint.zero
    private var initialViewportMidpoint = CGPoint.zero
    private var contentFraction: CGFloat?
    private var viewportY: CGFloat?
    private var isPinching = false
    private var showsVerticalScrollIndicator = true

    init(
      zoomMethod: AppearanceZoomMethod,
      baseFontSize: Double,
      onBegan: @escaping (UIScrollView, CGPoint) -> Void,
      onEnded: @escaping (CGFloat, UIScrollView, CGFloat, CGFloat) -> Void,
      onCancelled: @escaping () -> Void,
      onRealtimeChanged: @escaping (CGFloat, UIScrollView, CGPoint) -> Void,
      onRealtimeEnded: @escaping (UIScrollView) -> Void
    ) {
      self.zoomMethod = zoomMethod
      self.baseFontSize = baseFontSize
      self.onBegan = onBegan
      self.onEnded = onEnded
      self.onCancelled = onCancelled
      self.onRealtimeChanged = onRealtimeChanged
      self.onRealtimeEnded = onRealtimeEnded
    }

    func setZoomMethod(_ zoomMethod: AppearanceZoomMethod) {
      guard self.zoomMethod != zoomMethod else { return }
      cancelActivePinch()
      self.zoomMethod = zoomMethod
    }

    func installIfNeeded(from view: UIView) {
      guard zoomMethod != .disabled else {
        uninstall()
        return
      }
      guard let target = findScrollView(from: view) else { return }
      guard target !== scrollView || pinchGesture == nil else { return }

      uninstall()

      let gesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      gesture.cancelsTouchesInView = false
      gesture.delaysTouchesBegan = false
      gesture.delaysTouchesEnded = false
      gesture.delegate = self
      target.addGestureRecognizer(gesture)
      hostView = view
      scrollView = target
      pinchGesture = gesture
    }

    func uninstall() {
      cancelActivePinch()
      if let pinchGesture, let scrollView {
        scrollView.removeGestureRecognizer(pinchGesture)
      }
      pinchGesture = nil
      scrollView = nil
      hostView = nil
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
      guard let scrollView else { return }
      switch recognizer.state {
      case .began:
        switch zoomMethod {
        case .tiled:
          beginPinch(recognizer, in: scrollView)
        case .realtime:
          beginRealtimePinch(recognizer, in: scrollView)
        case .disabled:
          break
        }
      case .changed:
        switch zoomMethod {
        case .tiled:
          applyTransform(for: recognizer, in: scrollView)
        case .realtime:
          sendRealtimeChange(recognizer, in: scrollView)
        case .disabled:
          break
        }
      case .ended:
        switch zoomMethod {
        case .tiled:
          finishPinch(recognizer, in: scrollView)
        case .realtime:
          sendRealtimeChange(recognizer, in: scrollView)
          finishRealtimePinch(in: scrollView)
        case .disabled:
          break
        }
      case .cancelled, .failed:
        cancelActivePinch()
      default:
        break
      }
    }

    private func beginPinch(_ recognizer: UIPinchGestureRecognizer, in scrollView: UIScrollView) {
      guard !isPinching else { return }
      let contentPoint = touchMidpoint(of: recognizer, in: scrollView)
      let contentHeight = max(scrollView.contentSize.height, 1)

      isPinching = true
      pinchBaseFontSize = baseFontSize
      initialViewportMidpoint = contentPoint
      contentFraction = min(max(contentPoint.y / contentHeight, 0), 1)
      viewportY = contentPoint.y - scrollView.contentOffset.y
      transformView = scrollContentView(containing: hostView, inside: scrollView)
      if let transformView {
        originalTransform = transformView.transform
        originalCenter = transformView.center
        pinchAnchor = touchMidpoint(of: recognizer, in: transformView)
      }
      scrollView.panGestureRecognizer.isEnabled = false
      onBegan(scrollView, contentPoint)
      applyTransform(for: recognizer, in: scrollView)
    }

    private func beginRealtimePinch(
      _ recognizer: UIPinchGestureRecognizer,
      in scrollView: UIScrollView
    ) {
      guard !isPinching else { return }
      isPinching = true
      showsVerticalScrollIndicator = scrollView.showsVerticalScrollIndicator
      scrollView.showsVerticalScrollIndicator = false
      scrollView.panGestureRecognizer.isEnabled = false
      sendRealtimeChange(recognizer, in: scrollView)
    }

    private func sendRealtimeChange(
      _ recognizer: UIPinchGestureRecognizer,
      in scrollView: UIScrollView
    ) {
      guard isPinching else { return }
      onRealtimeChanged(
        recognizer.scale,
        scrollView,
        touchMidpoint(of: recognizer, in: scrollView))
    }

    private func finishRealtimePinch(in scrollView: UIScrollView) {
      guard isPinching else { return }
      isPinching = false
      scrollView.panGestureRecognizer.isEnabled = true
      scrollView.showsVerticalScrollIndicator = showsVerticalScrollIndicator
      onRealtimeEnded(scrollView)
    }

    private func applyTransform(
      for recognizer: UIPinchGestureRecognizer,
      in scrollView: UIScrollView
    ) {
      guard isPinching, let transformView else { return }
      let scale = clampedMagnification(recognizer.scale)
      let currentMidpoint = touchMidpoint(of: recognizer, in: scrollView)
      // Font reflow is vertically scrollable only. Preserve the initial horizontal anchor instead
      // of treating a two-finger sideways movement as image panning.
      let desiredMidpoint = CGPoint(x: initialViewportMidpoint.x, y: currentMidpoint.y)

      CATransaction.begin()
      CATransaction.setDisableActions(true)
      transformView.center = originalCenter
      transformView.transform = originalTransform.scaledBy(x: scale, y: scale)
      let transformedAnchor = transformView.convert(pinchAnchor, to: scrollView)
      transformView.center = CGPoint(
        x: originalCenter.x + desiredMidpoint.x - transformedAnchor.x,
        y: originalCenter.y + desiredMidpoint.y - transformedAnchor.y)
      CATransaction.commit()
    }

    private func finishPinch(_ recognizer: UIPinchGestureRecognizer, in scrollView: UIScrollView) {
      guard isPinching else { return }
      let magnification = clampedMagnification(recognizer.scale)
      let savedContentFraction = contentFraction
      let savedViewportY = viewportY
      resetTransform()
      resetPinchState(in: scrollView)

      guard let savedContentFraction, let savedViewportY else {
        onCancelled()
        return
      }
      onEnded(magnification, scrollView, savedContentFraction, savedViewportY)
    }

    private func cancelActivePinch() {
      guard isPinching else { return }
      let activeScrollView = scrollView
      if zoomMethod == .realtime {
        if let activeScrollView {
          finishRealtimePinch(in: activeScrollView)
        } else {
          isPinching = false
        }
        return
      }
      resetTransform()
      if let activeScrollView {
        resetPinchState(in: activeScrollView)
      } else {
        clearPinchState()
      }
      onCancelled()
    }

    private func resetTransform() {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      transformView?.transform = originalTransform
      transformView?.center = originalCenter
      CATransaction.commit()
    }

    private func resetPinchState(in scrollView: UIScrollView) {
      scrollView.panGestureRecognizer.isEnabled = true
      clearPinchState()
    }

    private func clearPinchState() {
      isPinching = false
      transformView = nil
      pinchBaseFontSize = nil
      pinchAnchor = .zero
      originalTransform = .identity
      originalCenter = .zero
      initialViewportMidpoint = .zero
      contentFraction = nil
      viewportY = nil
    }

    private func clampedMagnification(_ magnification: CGFloat) -> CGFloat {
      let baseSize = max(pinchBaseFontSize ?? baseFontSize, 0.1)
      let targetSize = AppearanceSettings.clampedFontSize(
        baseSize * max(Double(magnification), 0.1))
      return CGFloat(targetSize / baseSize)
    }

    private func touchMidpoint(of recognizer: UIPinchGestureRecognizer, in view: UIView) -> CGPoint
    {
      guard recognizer.numberOfTouches >= 2 else { return recognizer.location(in: view) }
      let first = recognizer.location(ofTouch: 0, in: view)
      let second = recognizer.location(ofTouch: 1, in: view)
      return CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private func scrollContentView(containing view: UIView?, inside scrollView: UIScrollView)
      -> UIView?
    {
      var current = view
      var contentView: UIView?
      while let candidate = current, candidate !== scrollView {
        contentView = candidate
        current = candidate.superview
      }
      return current === scrollView ? contentView : scrollView.subviews.first
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      zoomMethod != .disabled && gestureRecognizer.numberOfTouches >= 2
    }

    private func ancestorScrollView(from view: UIView) -> UIScrollView? {
      var current = view.superview
      while let candidate = current {
        if let scrollView = candidate as? UIScrollView {
          return scrollView
        }
        current = candidate.superview
      }
      return nil
    }

    private func findScrollView(from view: UIView) -> UIScrollView? {
      if let ancestor = ancestorScrollView(from: view) {
        return ancestor
      }
      guard let window = view.window else { return nil }
      let center = view.convert(
        CGPoint(x: view.bounds.midX, y: view.bounds.midY),
        to: window)
      return largestScrollView(containing: center, in: window)
    }

    private func largestScrollView(containing point: CGPoint, in root: UIView) -> UIScrollView? {
      var best: (view: UIScrollView, area: CGFloat)?

      func visit(_ view: UIView) {
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if let scrollView = view as? UIScrollView {
          let frame = scrollView.convert(scrollView.bounds, to: root)
          if frame.contains(point) {
            let area = frame.width * frame.height
            if best == nil || area > best!.area {
              best = (scrollView, area)
            }
          }
        }
        view.subviews.forEach(visit)
      }

      visit(root)
      return best?.view
    }
  }
}

private final class MessageListPinchHostView: UIView {
  var onHierarchyChange: ((UIView) -> Void)?

  override func didMoveToSuperview() {
    super.didMoveToSuperview()
    notifyHierarchyChange()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    notifyHierarchyChange()
  }

  private func notifyHierarchyChange() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      onHierarchyChange?(self)
    }
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

private struct ToolPickerPopover: View {
  @EnvironmentObject private var store: AppStore
  @State private var expandedServerIDs: Set<UUID> = []

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(BuiltInToolID.allCases.filter { $0 != .memory }) { tool in
          Button {
            toggleBuiltInTool(tool)
          } label: {
            HStack(spacing: 10) {
              Image(
                systemName: isBuiltInToolEnabled(tool) ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(isBuiltInToolEnabled(tool) ? Color.accentColor : Color.secondary)
              Image(systemName: tool.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
              Text(tool.displayName)
                .foregroundStyle(.primary)
              Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode)
          .opacity(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode ? 0.5 : 1)
        }

        if !store.settings.mcpServers.isEmpty {
          Divider().padding(.vertical, 4)
          Text("MCP Servers")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

          ForEach(store.settings.mcpServers) { server in
            mcpServerRow(server)
          }
        }
      }
      .padding(8)
      .disabled(!toolsEnabled)
      .opacity(toolsEnabled ? 1 : 0.5)
    }
    .frame(minWidth: 260, maxHeight: 480)
    .background(.regularMaterial)
  }

  private var toolsEnabled: Bool {
    store.currentConversation?.toolsEnabled ?? true
  }

  @ViewBuilder
  private func mcpServerRow(_ server: MCPServer) -> some View {
    let tools = store.mcpTools[server.id] ?? []
    let resources = store.mcpResources[server.id] ?? []
    let status = store.mcpStatuses[server.id] ?? .unknown
    let expanded = expandedServerIDs.contains(server.id)
    let itemCount = tools.count + resources.count

    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 10) {
        Button {
          toggleServer(server.id)
        } label: {
          Image(systemName: isMCPServerEnabled(server.id) ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isMCPServerEnabled(server.id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)

        Image(systemName: serverStatusIcon(status))
          .imageScale(.small)
          .foregroundStyle(serverStatusColor(status))
          .frame(width: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text(server.name.isEmpty ? "Untitled MCP" : server.name)
            .foregroundStyle(.primary)
            .lineLimit(1)
          if let transport = server.transport {
            Text(transport.displayName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer()

        if itemCount > 0 {
          Text("\(itemCount)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Button {
          if itemCount == 0 {
            Task { await store.refreshMCP(server, force: true) }
          } else {
            withAnimation(.snappy) {
              if expanded {
                expandedServerIDs.remove(server.id)
              } else {
                expandedServerIDs.insert(server.id)
              }
            }
          }
        } label: {
          if isCheckingServer(server.id) {
            ProgressView().controlSize(.small)
          } else if itemCount == 0 {
            Image(systemName: "arrow.clockwise")
              .imageScale(.small)
              .foregroundStyle(.secondary)
          } else {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .imageScale(.small)
              .foregroundStyle(.tertiary)
          }
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .contentShape(Rectangle())

      if expanded && itemCount > 0 {
        VStack(alignment: .leading, spacing: 2) {
          if !tools.isEmpty {
            Text("Tools")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.top, 4)
            ForEach(tools) { tool in
              Button {
                toggleMCPTool(serverID: server.id, toolName: tool.name)
              } label: {
                HStack(spacing: 8) {
                  Image(
                    systemName: isMCPToolEnabled(serverID: server.id, toolName: tool.name)
                      ? "checkmark.circle.fill" : "circle"
                  )
                  .imageScale(.small)
                  .foregroundStyle(
                    isMCPToolEnabled(serverID: server.id, toolName: tool.name)
                      ? Color.accentColor : Color.secondary
                  )
                  Text(tool.name)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  Spacer()
                }
                .padding(.leading, 38)
                .padding(.trailing, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
          if !resources.isEmpty {
            Text("Resources")
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.top, tools.isEmpty ? 4 : 8)
            ForEach(resources) { resource in
              HStack(spacing: 8) {
                Image(systemName: "doc.text")
                  .imageScale(.small)
                  .foregroundStyle(Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                  Text(resource.uri)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                  if !resource.name.isEmpty {
                    Text(resource.name)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                      .lineLimit(1)
                  }
                }
                Spacer()
              }
              .padding(.leading, 38)
              .padding(.trailing, 12)
              .padding(.vertical, 6)
              .contentShape(Rectangle())
            }
          }
        }
      }
    }
  }

  // MARK: - Native tool helpers

  private func isBuiltInToolEnabled(_ tool: BuiltInToolID) -> Bool {
    store.currentConversation?.enabledTools.contains(tool) ?? false
  }

  private func toggleBuiltInTool(_ tool: BuiltInToolID) {
    guard toolsEnabled else { return }
    guard !(store.settings.airplaneModeEnabled && tool.isDisabledInAirplaneMode) else {
      return
    }
    let nextValue = !isBuiltInToolEnabled(tool)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledTools.insert(tool)
      } else {
        conversation.enabledTools.remove(tool)
      }
    }
    if nextValue {
      store.settings.defaultEnabledTools.insert(tool)
    } else {
      store.settings.defaultEnabledTools.remove(tool)
    }
    store.saveSettings()
  }

  // MARK: - MCP server helpers

  private func toggleServer(_ id: UUID) {
    guard toolsEnabled else { return }
    let nextValue = !isMCPServerEnabled(id)
    let keys = mcpToolKeys(serverID: id)
    let prefix = MCPToolSelection.prefix(serverID: id)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledMCPServers.insert(id)
        conversation.enabledMCPTools.formUnion(keys)
      } else {
        conversation.enabledMCPServers.remove(id)
        conversation.enabledMCPTools = Set(
          conversation.enabledMCPTools.filter { !$0.hasPrefix(prefix) })
      }
    }
    if nextValue {
      store.settings.defaultEnabledMCPServers.insert(id)
      store.settings.defaultEnabledMCPTools.formUnion(keys)
    } else {
      store.settings.defaultEnabledMCPServers.remove(id)
      store.settings.defaultEnabledMCPTools = Set(
        store.settings.defaultEnabledMCPTools.filter { !$0.hasPrefix(prefix) })
    }
    store.saveSettings()
  }

  private func isMCPServerEnabled(_ id: UUID) -> Bool {
    store.currentConversation?.enabledMCPServers.contains(id)
      ?? store.settings.defaultEnabledMCPServers.contains(id)
  }

  private func isCheckingServer(_ id: UUID) -> Bool {
    if case .checking = store.mcpStatuses[id] {
      return true
    }
    return false
  }

  private func serverStatusIcon(_ status: EndpointConnectionState) -> String {
    switch status {
    case .unknown: return "circle"
    case .checking: return "arrow.triangle.2.circlepath"
    case .available: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.circle.fill"
    }
  }

  private func serverStatusColor(_ status: EndpointConnectionState) -> Color {
    switch status {
    case .unknown: return .secondary
    case .checking: return .orange
    case .available: return .green
    case .failed: return .red
    }
  }

  private func mcpToolKey(serverID: UUID, toolName: String) -> String {
    MCPToolSelection.key(serverID: serverID, toolName: toolName)
  }

  private func mcpToolKeys(serverID: UUID) -> Set<String> {
    Set(
      (store.mcpTools[serverID] ?? []).map {
        mcpToolKey(serverID: serverID, toolName: $0.name)
      })
  }

  private func isMCPToolEnabled(serverID: UUID, toolName: String) -> Bool {
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    return store.currentConversation?.enabledMCPTools.contains(key)
      ?? store.settings.defaultEnabledMCPTools.contains(key)
  }

  private func toggleMCPTool(serverID: UUID, toolName: String) {
    guard toolsEnabled else { return }
    let key = mcpToolKey(serverID: serverID, toolName: toolName)
    let prefix = MCPToolSelection.prefix(serverID: serverID)
    let nextValue = !isMCPToolEnabled(serverID: serverID, toolName: toolName)
    store.updateCurrentConversation { conversation in
      if nextValue {
        conversation.enabledMCPServers.insert(serverID)
        conversation.enabledMCPTools.insert(key)
      } else {
        conversation.enabledMCPTools.remove(key)
        if !conversation.enabledMCPTools.contains(where: { $0.hasPrefix(prefix) }) {
          conversation.enabledMCPServers.remove(serverID)
        }
      }
    }
    if nextValue {
      store.settings.defaultEnabledMCPServers.insert(serverID)
      store.settings.defaultEnabledMCPTools.insert(key)
    } else {
      store.settings.defaultEnabledMCPTools.remove(key)
      if !store.settings.defaultEnabledMCPTools.contains(where: { $0.hasPrefix(prefix) }) {
        store.settings.defaultEnabledMCPServers.remove(serverID)
      }
    }
    store.saveSettings()
  }
}

private struct ConversationModelSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var didSaveDefaults = false
  @State private var modelFilter = ""
  @State private var showingNewFolder = false
  @State private var showingFolderManager = false
  @State private var newFolderName = ""
  @State private var folderErrorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        if store.currentConversation == nil {
          ContentUnavailableView("No Chat Selected", systemImage: "bubble.left")
        } else {
          folderSection

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
            Menu {
              if store.appleIntelligenceIsAvailable {
                Button {
                  providerSelectionBinding.wrappedValue = .apple
                } label: {
                  Label("Apple Intelligence", systemImage: "apple.logo")
                }
              }
              Button {
                providerSelectionBinding.wrappedValue = .mlx
              } label: {
                Label("MLX Local", systemImage: "cpu")
              }
              if !store.settings.airplaneModeEnabled {
                ForEach(store.settings.openAIEndpoints.filter(\.isEnabled)) { endpoint in
                  Button {
                    providerSelectionBinding.wrappedValue = .endpoint(endpoint.id)
                  } label: {
                    Label(endpoint.displayName, systemImage: "network")
                  }
                }
              }
            } label: {
              HStack {
                Text("Provider")
                Spacer()
                Label(providerMenuTitle, systemImage: providerMenuIcon)
                  .foregroundStyle(
                    selectedProviderIsBlockedByAirplaneMode ? .secondary : Color.accentColor)
              }
            }
            providerModelControls
          }

          Section {
            ReasoningLevelControl(
              level: reasoningBinding,
              model: store.currentConversation?.modelID ?? "",
              endpointName: selectedEndpoint?.name ?? "", baseURL: selectedEndpoint?.baseURL ?? "")
          }

          Section("System Prompt") {
            Picker("Prompt", selection: systemPromptBinding) {
              ForEach(store.settings.systemPrompts) { prompt in
                Text(prompt.displayName).tag(prompt.id)
              }
            }
            .pickerStyle(.menu)
          }

          Section("Language") {
            Picker("Language", selection: languageBinding) {
              Text("Defaults").tag("")
              ForEach(languageOptions, id: \.self) { identifier in
                Text(SystemLanguageSupport.languageDisplayName(identifier)).tag(identifier)
              }
            }
            .pickerStyle(.menu)
          }

          Section("Context") {
            Picker("Chat history", selection: contextWindowModeBinding) {
              Text("App Default").tag(ContextWindowMode?.none)
              ForEach(ContextWindowMode.allCases) { mode in
                Text(mode.displayName).tag(Optional(mode))
              }
            }
            .pickerStyle(.menu)

            if provider == .mlx {
              Picker("MLX KV Cache", selection: mlxKVCacheSizeBinding) {
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
          }

          Section {
            Toggle("Show thinking", isOn: showThinkingBinding)
              .disabled(!store.settings.showThinkingByDefault)
            Toggle("Use memory", isOn: useMemoryBinding)
            Toggle("Stream responses", isOn: streamingBinding)
            Toggle("Suggest follow-ups", isOn: followUpSuggestionsBinding)
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
    if provider == .apple, !store.appleIntelligenceIsAvailable {
      return .mlx
    }
    return provider
  }

  private var selectedProviderIsBlockedByAirplaneMode: Bool {
    store.settings.airplaneModeEnabled && !provider.isAirplaneModeEligible
  }

  private var providerMenuTitle: String {
    if selectedProviderIsBlockedByAirplaneMode {
      return "Unavailable Offline"
    }
    switch provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      return selectedEndpoint?.displayName ?? "OpenAI Compatible"
    }
  }

  private var providerMenuIcon: String {
    if selectedProviderIsBlockedByAirplaneMode { return "network.slash" }
    switch provider {
    case .apple:
      return store.appleIntelligenceIsAvailable ? "apple.logo" : "cpu"
    case .mlx:
      return "cpu"
    case .openAICompatible:
      return "network"
    }
  }

  @ViewBuilder
  private var providerModelControls: some View {
    if provider == .apple {
      EmptyView()
    } else if provider == .mlx {
      mlxModelControls
    } else if selectedProviderIsBlockedByAirplaneMode {
      Text(
        store.appleIntelligenceIsAvailable
          ? "Airplane Mode is on. Switch to Apple Intelligence or MLX Local."
          : "Airplane Mode is on. Switch to MLX Local."
      )
      .foregroundStyle(.secondary)
    } else if let endpoint = selectedEndpoint {
      let models = store.endpointModels[endpoint.id] ?? []
      if models.isEmpty {
        TextField("Model", text: modelBinding(default: endpoint.defaultModel))
          .textInputAutocapitalization(.never)
      } else {
        FilteredModelPicker(
          selection: modelBinding(default: endpoint.defaultModel),
          filter: $modelFilter,
          models: models
        )
      }

      HStack {
        endpointStatusLabel(store.endpointStatuses[endpoint.id] ?? .unknown)
        Spacer()
        Button {
          Task { await store.refreshEndpoint(endpoint, force: true) }
        } label: {
          Label("Refresh Models", systemImage: "arrow.clockwise")
        }
        .disabled(isChecking(endpoint))
      }
    } else {
      Text("Add and enable an endpoint in Settings.")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var mlxModelControls: some View {
    let modelIDs = store.localMLXModelIDs
    Group {
      if modelIDs.isEmpty {
        Text("No downloaded MLX models")
          .foregroundStyle(.secondary)
      } else {
        Picker("Model", selection: mlxModelBinding) {
          ForEach(modelIDs, id: \.self) { modelID in
            Text(modelID).tag(modelID)
          }
        }
        .pickerStyle(.menu)
      }

      Button {
        store.refreshLocalMLXModelsInBackground()
        ensureCurrentMLXModelSelectionIsAvailable()
      } label: {
        Label("Refresh Models", systemImage: "arrow.clockwise")
      }

      Text(
        "Only downloaded MLX models are shown. Manage downloads in Settings > Providers "
          + "> Local MLX LLM."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onAppear {
      store.refreshLocalMLXModelsInBackground()
      ensureCurrentMLXModelSelectionIsAvailable()
    }
    .onChange(of: store.localMLXModelIDs) { _, _ in
      ensureCurrentMLXModelSelectionIsAvailable()
    }
  }

  private var selectedEndpoint: OpenAIEndpoint? {
    guard let conversation = store.currentConversation else { return nil }
    return OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: store.settings)
  }

  private var canSaveChatSettingsAsDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    if isCurrentChatUsingDefaults { return false }
    switch conversation.provider {
    case .apple:
      return store.appleIntelligenceIsAvailable
    case .mlx:
      return !store.localMLXModelIDs.isEmpty
    case .openAICompatible:
      guard !store.settings.airplaneModeEnabled else { return false }
      return selectedEndpoint != nil
    }
  }

  private var isCurrentProviderModelDefault: Bool {
    guard let conversation = store.currentConversation else { return false }
    let defaults = store.effectiveDefaultProviderConfiguration
    let reasoningMatches = conversation.reasoningLevel == store.settings.defaultReasoningLevel
    switch conversation.provider {
    case .apple:
      return defaults.provider == .apple
        && normalizedModel(conversation.modelID) == normalizedModel(defaults.modelID)
        && reasoningMatches
    case .mlx:
      let model =
        store.availableLocalMLXModelID(preferred: effectiveMLXModel(conversation))
        ?? effectiveMLXModel(conversation)
      return defaults.provider == .mlx
        && normalizedModel(model) == normalizedModel(defaults.modelID)
        && reasoningMatches
    case .openAICompatible:
      guard let endpoint = selectedEndpoint else { return false }
      let model = effectiveConversationModel(conversation, endpoint: endpoint)
      return defaults.provider == .openAICompatible
        && defaults.endpointID == endpoint.id
        && normalizedModel(model) == normalizedModel(defaults.modelID)
        && reasoningMatches
    }
  }

  private var isCurrentChatUsingDefaults: Bool {
    guard let conversation = store.currentConversation else { return true }
    let defaults = store.effectiveProviderConfiguration(forFolderID: conversation.folderID)
    let defaultModel =
      defaults.provider == .mlx
      ? (store.availableLocalMLXModelID(preferred: defaults.modelID)
        ?? normalizedModel(defaults.modelID))
      : defaults.modelID
    let memoryMatches =
      conversation.enabledTools.contains(.memory)
      == store.settings.defaultEnabledTools.contains(.memory)
    return conversation.provider == defaults.provider
      && conversation.endpointID == defaults.endpointID
      && normalizedModel(conversation.modelID) == normalizedModel(defaultModel)
      && conversation.reasoningLevel == store.settings.defaultReasoningLevel
      && effectiveSystemPromptID(for: conversation)
        == store.effectiveSystemPromptID(forFolderID: conversation.folderID)
      && conversation.effectiveLanguageOverrideIdentifier == nil
      && conversation.showThinking == store.settings.showThinkingByDefault
      && conversation.usesStreaming == store.settings.streamByDefault
      && conversation.contextWindowMode == nil
      && conversation.mlxMaxKVSize == nil
      && memoryMatches
  }

  private var chatSettingsDefaultButtonTitle: String {
    isCurrentChatUsingDefaults ? "Using app defaults" : "Use as default"
  }

  private var chatSettingsDefaultFooterText: String {
    if isCurrentChatUsingDefaults {
      return "These chat settings already match the app defaults."
    }
    guard let conversation = store.currentConversation else { return "" }
    if conversation.provider == .openAICompatible && store.settings.airplaneModeEnabled {
      return "Airplane Mode is on. OpenAI-compatible providers cannot be used as defaults."
    }
    if conversation.provider == .openAICompatible && selectedEndpoint == nil {
      return "Choose an enabled endpoint before using these settings as the default."
    }
    if conversation.provider == .mlx && store.localMLXModelIDs.isEmpty {
      return "Download an MLX model before using MLX as the default."
    }
    if didSaveDefaults {
      return "Future chats will use these settings."
    }
    return "Make these chat settings the default for new chats."
  }

  private func saveChatSettingsAsDefault() {
    guard let conversation = store.currentConversation else { return }
    switch conversation.provider {
    case .apple:
      guard store.appleIntelligenceIsAvailable else {
        return
      }
      store.settings.defaultProvider = .apple
      store.settings.appleModelID = conversation.modelID
    case .mlx:
      let model =
        store.availableLocalMLXModelID(preferred: effectiveMLXModel(conversation))
        ?? effectiveMLXModel(conversation)
      store.settings.defaultProvider = .mlx
      if !model.isEmpty {
        store.settings.localMLXModelID = model
      }
    case .openAICompatible:
      guard !store.settings.airplaneModeEnabled else { return }
      guard let endpoint = selectedEndpoint,
        let index = store.settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id })
      else { return }
      let model = effectiveConversationModel(conversation, endpoint: endpoint)
      store.settings.defaultProvider = .openAICompatible
      store.settings.selectedEndpointID = endpoint.id
      if !model.isEmpty {
        store.settings.openAIEndpoints[index].defaultModel = model
      }
    }
    store.settings.defaultReasoningLevel = conversation.reasoningLevel
    store.settings.defaultSystemPromptID = effectiveSystemPromptID(for: conversation)
    if let identifier = conversation.effectiveLanguageOverrideIdentifier {
      store.settings.conversation.speechRecognitionLanguageIdentifier = identifier
      store.settings.recordRecentChatLanguage(identifier)
    }
    store.settings.streamByDefault = conversation.usesStreaming
    store.settings.showThinkingByDefault = conversation.showThinking
    if let contextWindowMode = conversation.contextWindowMode {
      store.settings.contextWindowMode = contextWindowMode
    }
    if let mlxMaxKVSize = conversation.mlxMaxKVSize {
      store.settings.mlxMaxKVSize = mlxMaxKVSize
    }
    if conversation.enabledTools.contains(.memory) {
      store.settings.defaultEnabledTools.insert(.memory)
    } else {
      store.settings.defaultEnabledTools.remove(.memory)
    }
    store.saveSettings()
    didSaveDefaults = true
  }

  private func resetChatSettingsToDefaults() {
    guard let source = store.currentConversation else { return }
    let defaults = store.effectiveProviderConfiguration(forFolderID: source.folderID)
    let defaultModel: String = {
      guard defaults.provider == .mlx else { return defaults.modelID }
      return store.availableLocalMLXModelID(preferred: defaults.modelID)
        ?? normalizedModel(defaults.modelID)
    }()
    store.updateCurrentConversationSettings { conversation in
      conversation.provider = defaults.provider
      conversation.endpointID = defaults.endpointID
      conversation.modelID = defaultModel
      conversation.reasoningLevel = store.settings.defaultReasoningLevel
      conversation.systemPromptID = store.effectiveSystemPromptID(forFolderID: source.folderID)
      conversation.languageOverrideIdentifier = nil
      conversation.showThinking = store.settings.showThinkingByDefault
      conversation.usesStreaming = store.settings.streamByDefault
      conversation.contextWindowMode = nil
      conversation.mlxMaxKVSize = nil
      if store.settings.defaultEnabledTools.contains(.memory) {
        conversation.enabledTools.insert(.memory)
      } else {
        conversation.enabledTools.remove(.memory)
      }
    }
    didSaveDefaults = false
  }

  private func effectiveConversationModel(
    _ conversation: Conversation, endpoint: OpenAIEndpoint
  ) -> String {
    let model = normalizedModel(conversation.modelID)
    return model.isEmpty ? normalizedModel(endpoint.defaultModel) : model
  }

  private func effectiveMLXModel(_ conversation: Conversation) -> String {
    let model = normalizedModel(conversation.modelID)
    return model.isEmpty ? normalizedModel(store.settings.localMLXModelID) : model
  }

  private func effectiveSystemPromptID(for conversation: Conversation) -> UUID {
    conversation.systemPromptID ?? store.effectiveSystemPromptID(forFolderID: conversation.folderID)
  }

  private func normalizedModel(_ model: String) -> String {
    model.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var providerSelectionBinding: Binding<DefaultProviderSelection> {
    Binding(
      get: {
        guard let conversation = store.currentConversation else { return .mlx }
        switch conversation.provider {
        case .apple:
          return store.appleIntelligenceIsAvailable ? .apple : .mlx
        case .mlx:
          return .mlx
        case .openAICompatible:
          if let id = conversation.endpointID,
            store.settings.openAIEndpoints.contains(where: { $0.id == id })
          {
            return .endpoint(id)
          }
          if let first = store.settings.openAIEndpoints.first(where: \.isEnabled) {
            return .endpoint(first.id)
          }
          return .mlx
        }
      },
      set: { newSelection in
        let needsMLXModel: Bool = {
          switch newSelection {
          case .apple:
            return !store.appleIntelligenceIsAvailable
          case .mlx:
            return true
          case .endpoint:
            return false
          }
        }()
        let selectedMLXModelID: String? = {
          guard needsMLXModel else { return nil }
          store.refreshLocalMLXModelsInBackground()
          return store.availableLocalMLXModelID(preferred: store.settings.localMLXModelID)
            ?? normalizedModel(store.settings.localMLXModelID)
        }()
        store.updateCurrentConversationSettings { conversation in
          switch newSelection {
          case .apple:
            guard store.appleIntelligenceIsAvailable else {
              conversation.provider = .mlx
              conversation.endpointID = nil
              conversation.modelID = selectedMLXModelID ?? ""
              didSaveDefaults = false
              return
            }
            conversation.provider = .apple
            conversation.endpointID = nil
            conversation.modelID = store.settings.appleModelID
            didSaveDefaults = false
          case .mlx:
            conversation.provider = .mlx
            conversation.endpointID = nil
            conversation.modelID = selectedMLXModelID ?? ""
            didSaveDefaults = false
          case .endpoint(let id):
            guard !store.settings.airplaneModeEnabled else {
              didSaveDefaults = false
              return
            }
            conversation.provider = .openAICompatible
            conversation.endpointID = id
            if let endpoint = store.settings.openAIEndpoints.first(where: { $0.id == id }),
              !endpoint.defaultModel.isEmpty
            {
              conversation.modelID = endpoint.defaultModel
            }
            didSaveDefaults = false
          }
        }
      }
    )
  }

  private var mlxModelBinding: Binding<String> {
    Binding(
      get: {
        let model = normalizedModel(store.currentConversation?.modelID ?? "")
        return store.availableLocalMLXModelID(preferred: model) ?? ""
      },
      set: { model in
        guard store.localMLXModelIDs.contains(model) else { return }
        store.updateCurrentConversationSettings { conversation in
          conversation.modelID = model
        }
        didSaveDefaults = false
      }
    )
  }

  private func ensureCurrentMLXModelSelectionIsAvailable() {
    guard provider == .mlx else {
      return
    }
    let currentModel = normalizedModel(store.currentConversation?.modelID ?? "")
    guard
      let model = store.availableLocalMLXModelID(preferred: store.currentConversation?.modelID)
    else {
      guard !currentModel.isEmpty else { return }
      store.updateCurrentConversationSettings { conversation in
        conversation.modelID = ""
      }
      return
    }
    guard currentModel != model else { return }
    store.updateCurrentConversationSettings { conversation in
      conversation.modelID = model
    }
  }

  private func modelBinding(default defaultModel: String) -> Binding<String> {
    Binding(
      get: {
        let model = store.currentConversation?.modelID ?? ""
        return model.isEmpty ? defaultModel : model
      },
      set: { model in
        store.updateCurrentConversationSettings { conversation in
          conversation.modelID = model
        }
        didSaveDefaults = false
      }
    )
  }

  private var streamingBinding: Binding<Bool> {
    Binding(
      get: { store.currentConversation?.usesStreaming ?? true },
      set: { usesStreaming in
        store.updateCurrentConversationSettings { conversation in
          conversation.usesStreaming = usesStreaming
        }
        didSaveDefaults = false
      }
    )
  }

  private var contextWindowModeBinding: Binding<ContextWindowMode?> {
    Binding(
      get: { store.currentConversation?.contextWindowMode },
      set: { mode in
        store.updateCurrentConversationSettings { conversation in
          conversation.contextWindowMode = mode
        }
        didSaveDefaults = false
      }
    )
  }

  private var mlxKVCacheSizeBinding: Binding<MLXKVCacheSize?> {
    Binding(
      get: { store.currentConversation?.mlxMaxKVSize },
      set: { size in
        store.updateCurrentConversationSettings { conversation in
          conversation.mlxMaxKVSize = size
        }
        didSaveDefaults = false
      }
    )
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
        didSaveDefaults = false
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
        didSaveDefaults = false
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
        didSaveDefaults = false
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
        didSaveDefaults = false
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

  private func endpointStatusLabel(_ status: EndpointConnectionState) -> some View {
    let icon = status == .checking ? "arrow.triangle.2.circlepath" : "circle.fill"
    return Label(status.statusText, systemImage: icon)
      .foregroundStyle(status.statusColor)
  }

  private func isChecking(_ endpoint: OpenAIEndpoint) -> Bool {
    if case .checking = store.endpointStatuses[endpoint.id] {
      return true
    }
    return false
  }
}
