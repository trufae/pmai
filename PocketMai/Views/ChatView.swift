import MaiCore
import MaiUI
import SwiftUI
import UIKit

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
    var sidebarIsPinned = false
    var canPinSidebar = false
  }

  private struct ConversationActivitySnapshot: Equatable {
    var conversationID: UUID?
    var updatedAt: Date?
    var isResponding: Bool
  }

  private struct UserMessageNavigationState: Equatable {
    var isAtBottom = true
    var hasScrollableContent = false
    var previousID: UUID?
    var nextID: UUID?
  }

  private struct MessageListScrollMetrics: Equatable {
    var viewportMinY: CGFloat
    var contentHeight: CGFloat
    var hasScrollableContent: Bool
    var viewport: ConversationScrollViewport
  }

  private struct MessageHistoryLoadKey: Equatable {
    var conversationID: UUID?
    var firstMessageID: UUID?
    var lastMessageID: UUID?
    var isPreview: Bool
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
  @State var remoteChat: RemoteAgentChat? = nil
  @AppStorage(AwakeController.preferenceKey) private var keepAwake = false
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.verticalSizeClass) private var verticalSizeClass
  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  @State private var showingRenameAlert = false
  @State private var showingProviderModelSheet = false
  @State private var messagePendingDeletion: ChatMessage?
  @State private var messageBatchPendingDeletion: PendingMessageBatchDeletion?
  @State private var messagePendingTrimAndResubmit: ChatMessage?
  @State private var messagePendingRestartFresh: ChatMessage?
  @State private var isMessageSelectionMode = false
  @State private var selectedMessageIDs: Set<UUID> = []
  @State private var renameDraft = ""
  @State private var userScrolledAfterLastMessage = false
  @State private var followChatBottom = false
  @State private var responseScrollTargets: [UUID: ResponseScrollTarget] = [:]
  @State private var lastStreamingScrollAt: Date?
  @State private var streamingScrollTask: Task<Void, Never>?
  @State private var pendingScrollToMessageID: UUID?
  @State private var showingWebXDCRunnerFromBar = false
  @State private var showingWebXDCStopConfirmation = false
  @State private var showingSubagents = false
  @State private var chatSearch = ChatSearchState()
  @State private var messageFontPinchSession = MessageFontPinchSession()
  @State private var messageRenderWindow = ConversationMessageRenderWindow()
  @State private var historyScrollSession = ConversationHistoryScrollSession()
  @State private var messageListIsScrolling = false
  @State private var messageListScrollPhase = ScrollPhase.idle
  @State private var messageListIsDragging = false
  @State private var chatHeaderHidden = false
  @State private var chatHeaderHeight: CGFloat = 0
  @State private var headerScrollDistance: CGFloat = 0
  @State private var historyNearTop = false
  @State private var historyNearBottom = false
  @State private var historyPageIsLoading = false
  @State private var keyboardOverlap: CGFloat = 0
  @State private var landscapeComposerExpanded = false
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
  var remoteHosts: HostNavigationStore? = nil
  let onShowHistory: () -> Void
  let onNewChat: () -> Void
  var onRemoteChatReady: (RemoteAgentChat) -> Void = { _ in }
  var onShowRemoteFolders: () -> Void = {}
  var onBrowseFiles: () -> Void = {}
  var onShowRemoteTerminal: (RemoteAgentBookmark, String) -> Void = { _, _ in }

  var body: some View {
    chatViewWithAlerts
      .sheet(
        item: Binding(
          get: { remoteChat?.permissions.first },
          set: { value in
            if value == nil, let first = remoteChat?.permissions.first {
              remoteChat?.answer(first.id, optionID: nil)
            }
          })
      ) { permission in
        RemoteToolPermissionView(permission: permission) { optionID, rawInput in
          remoteChat?.answer(permission.id, optionID: optionID, rawInput: rawInput)
        }
        .interactiveDismissDisabled()
      }
      .task {
        if let remoteChat { onRemoteChatReady(remoteChat) }
        reconnectRemoteChat()
      }
      .onChange(of: remoteHosts?.selectedConversation?.cwd) { _, _ in
        guard let remoteHosts, let host = remoteHosts.selectedHost,
          let draft = remoteHosts.selectedConversation, let chat = remoteChat,
          chat.conversation.sessionID == nil, !chat.busy, chat.messages.isEmpty
        else { return }
        remoteChat = RemoteAgentChat(
          bookmark: host, conversation: draft, isOffline: { store.settings.isOffline })
        if let remoteChat { onRemoteChatReady(remoteChat) }
      }
      .onDisappear { remoteChat?.disconnect() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .background { remoteChat?.disconnect() }
        if phase == .active { reconnectRemoteChat() }
      }
      .onChange(of: store.settings.isOffline) { _, enabled in
        if enabled { remoteChat?.disconnect() } else { reconnectRemoteChat() }
      }
  }

  private func reconnectRemoteChat() {
    guard let remoteChat, !store.settings.isOffline,
      remoteChat.conversation.sessionID != nil || !remoteChat.messages.isEmpty
        || remoteChat.unsentPrompt != nil
    else { return }
    remoteChat.connect()
  }

  private var currentConversation: Conversation? {
    remoteChat?.presentation ?? store.currentConversation
  }
  private var currentConversationID: UUID? {
    remoteChat?.conversation.id ?? store.selectedConversationID
  }
  private var isLoadingConversation: Bool {
    remoteChat == nil && store.selectedConversationIsLoading
  }
  private var currentConversationSummary: ConversationSummary? {
    remoteChat == nil ? store.selectedConversationSummary : nil
  }

  private var chatViewWithAlerts: some View {
    chatViewWithSheetsAndToolbar
      .onChange(of: store.pendingLaunchAction) { _, action in
        guard remoteChat == nil, let action else { return }
        store.pendingLaunchAction = nil
        Task { await applyLaunchAction(action) }
      }
      .onAppear {
        // Catch a command that was already queued during a cold launch, before
        // onChange started observing.
        if remoteChat == nil, let action = store.pendingLaunchAction {
          store.pendingLaunchAction = nil
          Task { await applyLaunchAction(action) }
        }
      }
      .onChange(of: currentConversationID) { _, _ in
        chatHeaderHidden = false
        headerScrollDistance = 0
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
          chatSearch.rebuild(messages: currentConversation?.messages ?? [])
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
        isPresented: confirmationBinding($messagePendingDeletion),
        presenting: messagePendingDeletion
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingDeletion = nil
        }
        Button("Delete Message", role: .destructive) {
          if let remoteChat {
            remoteChat.delete(message.id)
          } else {
            store.deleteMessage(message)
          }
          messagePendingDeletion = nil
        }
      } message: { _ in
        Text("This message will be removed from the chat. This cannot be undone.")
      }
      .alert(
        messageBatchPendingDeletion?.title ?? "Delete selected messages?",
        isPresented: confirmationBinding($messageBatchPendingDeletion),
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
        "Rewind?",
        isPresented: confirmationBinding($messagePendingTrimAndResubmit),
        presenting: messagePendingTrimAndResubmit
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingTrimAndResubmit = nil
        }
        Button("Rewind", role: .destructive) {
          if let remoteChat {
            remoteChat.retry(message.id)
          } else {
            Task { await store.trimAndResubmit(from: message) }
          }
          messagePendingTrimAndResubmit = nil
        }
      } message: { _ in
        Text("Messages after this point will be removed before the response is regenerated.")
      }
      .alert(
        "Restart from here?",
        isPresented: confirmationBinding($messagePendingRestartFresh),
        presenting: messagePendingRestartFresh
      ) { message in
        Button("Cancel", role: .cancel) {
          messagePendingRestartFresh = nil
        }
        Button("Restart From Here", role: .destructive) {
          if let remoteChat {
            remoteChat.retry(message.id, restarting: true)
          } else {
            Task { await store.restartFromScratch(with: message) }
          }
          messagePendingRestartFresh = nil
        }
      } message: { _ in
        Text("All current messages will be removed before starting again from this message.")
      }
  }

  private var chatViewWithSheetsAndToolbar: some View {
    chatViewWithToolbar
      .alert("PocketMai Version", isPresented: Binding(
        get: { store.showingVersion }, set: { store.showingVersion = $0 }
      )) {
        Button("OK", role: .cancel) { store.showingVersion = false }
      } message: {
        Text(ConversationExportEnvelope.currentPocketMaiVersion)
      }
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
        if let remoteChat {
          RemoteChatSettingsView(chat: remoteChat).environmentObject(store)
        } else {
          ConversationModelSettingsView().environmentObject(store)
        }
      }
      .sheet(isPresented: $showingSubagents) {
        SubagentProcessesSheet(
          store: store,
          storeObservation: storeObservation,
          conversationID: currentConversation?.id)
      }
      .modifier(ConversationExportPresentations(coordinator: exportCoordinator))
  }

  private var chatViewWithToolbar: some View {
    chatLayout
      .overlay(alignment: .topTrailing) {
        if usesCompactLandscapeLayout {
          FloatingActionIcon(
            systemImage: "square.and.pencil", accessibilityLabel: "New Chat", compact: true,
            action: onNewChat
          )
          .disabled(!canStartNewChat)
          .padding(8)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
      }
      .overlay(alignment: .bottomTrailing) {
        if isComposerCollapsed, showsComposer {
          landscapeComposerToggle
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
      }
      .onChange(of: usesCompactLandscapeLayout) { _, _ in
        landscapeComposerExpanded = false
      }
      .onChange(of: store.composerFocusRequestID) { _, _ in
        chatHeaderHidden = false
        landscapeComposerExpanded = true
      }
      .onChange(of: store.sharedImportRequestID) { _, _ in
        if remoteChat == nil { landscapeComposerExpanded = true }
      }
      .onChange(of: queuedMessagePendingEdit) { _, message in
        if message != nil { landscapeComposerExpanded = true }
      }
      .animation(.snappy, value: ttsPlayer.isSpeaking)
      .animation(.snappy, value: isMessageSelectionMode)
      .toolbar(.hidden, for: .navigationBar)
      .onChange(of: ttsPlayer.isSpeaking) { _, speaking in
        if speaking { chatHeaderHidden = false }
      }
  }

  private var showsChatHeader: Bool {
    !chatHeaderHidden || voiceOverEnabled || currentConversationIsEmpty
      || isLoadingConversation || chatSearch.isActive || isMessageSelectionMode
      || ttsPlayer.errorMessage != nil
  }

  private var chatHeader: some View {
    VStack(spacing: 0) {
      if !usesCompactLandscapeLayout {
        HStack(spacing: 12) {
          FloatingActionIcon(
            systemImage: "line.3.horizontal.decrease",
            accessibilityLabel: hasUnreadConversations
              ? "Show conversations, unread messages" : "Show conversations",
            compact: true, action: onShowHistory
          )
          .overlay(alignment: .topTrailing) {
            if hasUnreadConversations {
              Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                .padding(8).accessibilityHidden(true)
            }
          }
          chatTitle.frame(maxWidth: .infinity)
          if remoteChat == nil, let session = store.browserSession {
            BrowserToolbarButton(session: session) { store.closeBrowserSession() }
              .buttonStyle(.plain)
              .font(.title3.weight(.semibold))
              .foregroundStyle(.primary)
              .frame(width: 48, height: 48)
              .modifier(FloatingGlassSurface(shape: Circle()))
          } else if remoteChat == nil, store.closedBrowserURL != nil {
            FloatingActionIcon(
              systemImage: "safari", accessibilityLabel: "Reopen browser", compact: true
            ) { store.reopenBrowserSession() }
          }
          FloatingActionIcon(
            systemImage: "square.and.pencil", accessibilityLabel: "New Chat", compact: true,
            action: onNewChat
          )
          .disabled(!canStartNewChat)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background { HeaderFadeBlur() }
      }
      chatHeaderRows
    }
    .padding(.bottom, 8)
    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { chatHeaderHeight = $0 }
    .offset(y: showsChatHeader ? 0 : -chatHeaderHeight - 24)
    .opacity(showsChatHeader ? 1 : 0)
    .allowsHitTesting(showsChatHeader)
    .accessibilityHidden(!showsChatHeader)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsChatHeader)
  }

  // Size classes follow rotation without mistaking a portrait keyboard for landscape.
  private var usesCompactLandscapeLayout: Bool {
    horizontalSizeClass == .compact && verticalSizeClass == .compact
  }

  private var isComposerCollapsed: Bool {
    usesCompactLandscapeLayout && !landscapeComposerExpanded && !liveVoiceSession.isActive
  }

  private var showsComposer: Bool {
    !chatSearch.isActive && !isLoadingConversation && !isMessageSelectionMode
  }

  private var landscapeComposerToggle: some View {
    FloatingActionIcon(
      systemImage: "bubble.left",
      accessibilityLabel: isComposerCollapsed ? "Show composer" : "Hide composer",
      isActive: !isComposerCollapsed, compact: true
    ) {
      withAnimation(.snappy) {
        landscapeComposerExpanded.toggle()
      }
    }
    .accessibilityValue(isComposerCollapsed ? "Collapsed" : "Expanded")
  }

  private var hasUnreadConversations: Bool {
    remoteChat == nil && store.conversationSummaries.contains(where: \.isUnread)
  }

  /// The browser tool's picture-in-picture card. One page for the whole
  /// app, so it follows the user across conversations.
  @ViewBuilder
  private var browserCardOverlay: some View {
    if remoteChat == nil, let session = store.browserSession {
      BrowserPresentationOverlay(session: session) {
        store.closeBrowserSession()
      }
    }
  }

  private var chatLayout: some View {
    VStack(spacing: 0) {
      messages
        .overlay(alignment: .bottomTrailing) { browserCardOverlay }
        .overlay(alignment: .top) { chatHeader }
      bottomControls
    }
    .background { ChatScreenBackground() }
  }

  private var chatHeaderRows: some View {
    VStack(spacing: 8) {
      NowSpeakingBar { messageID in
        pendingScrollToMessageID = messageID
      }
      if remoteChat == nil, let conversation = currentConversation,
        !conversation.messages.pinnedMessages.isEmpty
      {
        PinnedMessagesBar(
          messages: conversation.messages.pinnedMessages,
          onSelect: { pendingScrollToMessageID = $0 },
          onUnpin: { store.setMessagePinned(false, messageID: $0, in: conversation.id) }
        )
        .id(conversation.id)
      }
      if let providerStatus {
        providerStatusBanner(providerStatus)
      }
      if let session = currentWebXDCSession {
        webxdcSessionBar(session)
      }
      if !currentSubagents.isEmpty {
        SubagentsBar(processes: currentSubagents) {
          showingSubagents = true
        }
      }
      if !currentBTWQuestions.isEmpty {
        BTWQuestionsBar(
          questions: currentBTWQuestions,
          appearance: store.settings.appearance,
          renderMarkdown: store.settings.renderMarkdownInChat,
          renderImages: store.settings.renderMarkdownImagesInChat,
          onStop: { store.stopBTW($0) },
          onDismiss: { store.dismissBTW($0) })
          .id(currentConversationID)
      }
    }
    .padding(.horizontal, 12)
  }

  /// The child agents of the chat on screen, live or finished, so a turn
  /// that delegated work shows what it started.
  private var currentSubagents: [AgentProcessInfo] {
    remoteChat == nil ? store.agentChildren(of: currentConversation?.id) : []
  }

  private var currentWebXDCSession: WebXDCRunningSession? {
    guard remoteChat == nil, let session = store.activeWebXDCSession,
      let conversationID = session.conversationID,
      conversationID == currentConversation?.id
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
    } else if isLoadingConversation {
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
    Group {
      if let remoteChat, !remoteChat.connected {
        Menu(content: { chatTitleActions }, label: { chatTitleLabel }) {
          remoteChat.connect()
        }
        .accessibilityHint("Tap to connect. Touch and hold for chat options")
      } else {
        Menu(content: { chatTitleActions }, label: { chatTitleLabel })
          .accessibilityHint("Tap for chat options")
      }
    }
    .menuStyle(.button)
    .buttonStyle(.plain)
    .disabled(isLoadingConversation)
    .accessibilityValue(providerSubtitle)
  }

  @ViewBuilder
  private var chatTitleActions: some View {
    Text(providerSubtitle)
    if let error = remoteChat?.error { Text(error) }
    Divider()
    if currentConversation?.provider == .openAICompatible,
      let endpointID = currentConversation?.endpointID,
      store.settings.openAIEndpoints.first(where: { $0.id == endpointID })?.kind == .chatGPT {
      Link("Manage ChatGPT usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
    }
    Button("Rename...", systemImage: "pencil", action: beginRename)
      .disabled(remoteChat.map { !$0.canManage || $0.busy || store.settings.isOffline } ?? false)
    Button("Search...", systemImage: "magnifyingglass", action: beginChatSearch)
      .disabled(currentConversationIsEmpty || liveVoiceSession.isActive)
    ConversationShareButton(
      conversationID: currentConversation?.id,
      conversation: remoteChat?.presentation,
      coordinator: exportCoordinator)
    ConversationExportMenu(
      conversationID: currentConversation?.id,
      conversation: remoteChat?.presentation,
      coordinator: exportCoordinator)
    Divider()
    Button("Files…", systemImage: "folder", action: onBrowseFiles)
    if let remoteChat {
      Button("Terminal…", systemImage: "terminal") {
        onShowRemoteTerminal(remoteChat.bookmark, remoteChat.conversation.cwd)
      }
      .disabled(
        remoteChat.bookmark.requiresApproval == true
          || store.settings.isOffline)
    }
    Divider()
    Toggle(isOn: $keepAwake) { Label("Keep Awake", systemImage: "sun.max") }
    Button("Chat Settings", systemImage: "slider.horizontal.3", action: showChatSettings)
    if let remoteChat {
      Button("Connect", systemImage: "network") {
        remoteChat.connect()
      }
      .disabled(remoteChat.connected || store.settings.isOffline || remoteChat.busy)
    }
  }

  private var chatTitleLabel: some View {
    HStack(spacing: 6) {
      if keepAwake { AwakeIndicator() }
      Text(
        currentConversation?.displayTitle
          ?? currentConversationSummary?.displayTitle
          ?? "Chat"
      )
      .font(.headline)
      .lineLimit(1)
      .foregroundStyle(remoteChat.map { $0.connected ? Color.primary : .red } ?? .primary)
      if isLoadingCurrentLocalModel {
        ProgressView().controlSize(.mini)
          .accessibilityLabel("Loading local model into memory")
      }
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
  }

  private var systemPromptName: String? {
    let id = currentConversation?.systemPromptID ?? store.settings.defaultSystemPromptID
    guard let prompt = store.settings.systemPrompts.first(where: { $0.id == id })
    else { return nil }
    return prompt.displayName
  }

  private var systemPromptTitle: String? {
    guard let systemPromptName else { return nil }
    return store.settings.isOffline ? "\(systemPromptName) (offline)" : systemPromptName
  }

  private var currentToolSettings: NativeToolSettings {
    store.effectiveToolSettings(for: currentConversation)
  }

  private var currentChatIsResponding: Bool {
    if let remoteChat { return remoteChat.responding }
    guard let id = currentConversation?.id else { return false }
    return store.isResponding(in: id)
  }

  private var providerSubtitle: String {
    if let remoteChat { return "\(remoteChat.bookmark.name) · \(remoteChat.status)" }
    if store.isCompacting { return "Compacting…" }
    if isLoadingConversation { return "Loading…" }
    if isLoadingCurrentLocalModel { return "Loading local model into memory…" }
    guard let conversation = currentConversation else { return "No conversation" }
    let providerName = providerLabel(for: conversation)
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = [providerName, model.isEmpty ? nil : model, systemPromptTitle].compactMap { $0 }
    return parts.joined(separator: " · ")
  }

  private var isLoadingCurrentLocalModel: Bool {
    guard remoteChat == nil, let id = currentConversation?.id else { return false }
    return store.isLoadingLocalModel(in: id)
  }

  private func providerLabel(for conversation: Conversation) -> String {
    switch conversation.provider {
    case .apple:
      return "Apple Intelligence"
    case .mlx:
      return "MLX Local"
    case .openAICompatible:
      let endpoint = conversation.endpointID.flatMap { id in
        store.settings.openAIEndpoints.first(where: { $0.id == id })
      }
      if endpoint?.kind == .chatGPT { return "Using ChatGPT plan" }
      return endpoint?.displayName
        ?? AgentTooling.firstNonEmpty(URL(string: endpoint?.baseURL ?? "")?.host)
        ?? OpenAIEndpoint.defaultDisplayName
    }
  }

  private func providerStatusBanner(_ status: (message: String, systemImage: String, color: Color))
    -> some View
  {
    Button(action: showChatSettings) {
      HStack {
        Label(status.message, systemImage: status.systemImage)
          .lineLimit(2)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "chevron.right")
      }
      .font(.caption)
      .foregroundStyle(status.color)
      .padding(.horizontal)
      .padding(.vertical, 10)
    }
    .buttonStyle(.plain)
    .disabled(remoteChat != nil && store.settings.isOffline)
    .accessibilityHint("Open chat settings to choose a provider")
  }

  private func showChatSettings() {
    showingProviderModelSheet = true
  }

  private func beginRename() {
    renameDraft = currentConversation?.displayTitle ?? ""
    showingRenameAlert = true
  }

  private func renameCurrentConversation() {
    if let remoteChat {
      let title = renameDraft
      Task {
        do { try await remoteChat.manage(title: title) } catch {
          remoteChat.error = error.localizedDescription
        }
      }
    } else {
      store.renameCurrentConversation(to: renameDraft)
    }
    showingRenameAlert = false
  }

  private var canStartNewChat: Bool {
    !isLoadingConversation && !isMessageSelectionMode
      && remoteHosts?.selectedHost?.requiresApproval != true
  }

  private func speakFromHere(_ message: ChatMessage, language: String?) {
    guard
      let conversation = currentConversation,
      let index = conversation.messages.firstIndex(where: { $0.id == message.id })
    else {
      return
    }
    ttsPlayer.speakFromHere(
      messages: Array(conversation.messages[index...]),
      voices: store.effectiveToolSettings(for: conversation).voices,
      language: language,
      openAIEndpoints: store.settings.isOffline ? [] : store.settings.openAIEndpoints,
      skipTechnicalContent: store.settings.conversation.skipTechnicalContentInTTS
    )
  }

  private func editMessage(_ message: ChatMessage, text: String) {
    guard
      let currentText = currentConversation?.messages.first(where: { $0.id == message.id })?
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
      chatSearch.rebuild(messages: currentConversation?.messages ?? [])
    }
  }

  private func editTextAttachment(_ message: ChatMessage, attachmentID: UUID, text: String) {
    guard
      let currentAttachment = currentConversation?.messages.first(where: {
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
    guard remoteChat == nil else { return nil }
    if currentConversation?.provider == .mlx,
      let message = LocalMLXAvailability.current.unavailabilityMessage
    {
      return (message, "exclamationmark.triangle", .orange)
    }
    if let conversation = currentConversation, conversation.provider == .openAICompatible,
      OpenAICompatibleProvider.selectedEndpoint(for: conversation, settings: store.settings) == nil,
      !store.settings.isOffline
    {
      return (LocalMLXAvailability.providerSetupSuggestion, "network", .orange)
    }
    if let conversation = currentConversation,
      store.settings.isOffline,
      !conversation.provider.isAirplaneModeEligible
    {
      return (
        store.offlineProviderGuidance,
        "airplane",
        .orange
      )
    }
    return nil
  }

  private var currentBTWQuestions: [BTWQuestion] {
    guard remoteChat == nil else { return [] }
    return store.btwQuestions.filter { $0.conversationID == currentConversationID }
  }

  private var messages: some View {
    GeometryReader { scrollGeometry in
      ScrollViewReader { proxy in
        ScrollView(.vertical) {
          let conversation = currentConversation
          let isPreviewingConversation = isLoadingConversation && conversation == nil
          let allMessages = presentationMessages
          let startIndex = messageRenderWindow.startIndex(
            in: allMessages, conversationID: currentConversationID)
          let renderedMessages = allMessages.suffix(from: startIndex)
          let firstUserMessageID = allMessages.first(where: { $0.role == .user })?.id
          // A single response can be several viewports tall and changes height while streaming.
          // LazyVStack can retain a stale row estimate and scroll past the rendered content.
          VStack(spacing: 14) {
            if !renderedMessages.isEmpty, startIndex == 0,
              conversation?.historyWindow?.hasEarlier != true,
              let startedAt = conversation?.createdAt
                ?? currentConversationSummary?.createdAt
            {
              ConversationTimelineTimestamp(label: "Chat Started", date: startedAt)
            }
            if isPreviewingConversation && renderedMessages.isEmpty {
              compactLoadingState
            } else if !isPreviewingConversation && currentConversationIsEmpty
              && liveVoiceSession.previewMessage == nil
            {
              emptyState(in: CGSize(
                width: scrollGeometry.size.width,
                height: max(0, scrollGeometry.size.height - chatHeaderHeight)))
            } else {
              ForEach(ConversationMessageRun.grouped(
                renderedMessages, conversationID: currentConversationID)
              ) { run in
                MessageActivityGroup(
                  enabled: run.isActivity,
                  title: "Activity · \(run.messages.count) updates",
                  failedCount: run.isActivity
                    ? run.messages.reduce(0) { $0 + MessageRenderCache.failedToolCount($1) } : 0,
                  forceExpanded: isMessageSelectionMode
                ) {
                  ForEach(run.messages) { message in
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
                      VStack(alignment: .trailing, spacing: 4) {
                        MessageBubble(
                          message: message,
                          renderedPartStartIndex: messageRenderWindow.partStartIndex(
                            for: message.id, conversationID: currentConversationID),
                          toolSettings: currentToolSettings,
                          openAIEndpoints: store.settings.isOffline
                            ? [] : store.settings.openAIEndpoints,
                          skipTechnicalContentInTTS: store.settings.conversation
                            .skipTechnicalContentInTTS,
                          appearance: store.settings.appearance,
                          renderMarkdown: store.settings.renderMarkdownInChat,
                          renderImages: store.settings.renderMarkdownImagesInChat,
                          searchHighlight: searchHighlight,
                          actions: MessageBubbleActions(
                            allowsConversationMutation: remoteChat?.canDelete(message.id) ?? true,
                            canReply: remoteChat?.canSubmit ?? true,
                            canRetry: remoteChat?.canRetry(message.id) ?? true,
                            canResubmit: remoteChat?.canResubmit(message.id) ?? true,
                            onDelete: { messagePendingDeletion = message },
                            onToggleBookmark: conversation.map { conversation in
                              { store.toggleMessageBookmark(message, in: conversation.id) }
                            },
                            onTogglePin: remoteChat == nil ? conversation.map { conversation in
                              { store.setMessagePinned(!message.isPinned, messageID: message.id, in: conversation.id) }
                            } : nil,
                            onBeginSelection: { beginMessageSelection(with: message.id) },
                            onEdit: remoteChat == nil ? { editMessage(message, text: $0) } : nil,
                            onEditAttachment: remoteChat == nil
                              ? { attachmentID, editedText in
                                editTextAttachment(message, attachmentID: attachmentID, text: editedText)
                              } : nil,
                            onTrimFromHere: remoteChat == nil || remoteChat?.supportsHistoryRewind == true
                              ? { messagePendingTrimAndResubmit = message } : nil,
                            onRestartFresh: remoteChat == nil || remoteChat?.supportsHistoryRewind == true
                              ? { messagePendingRestartFresh = message } : nil,
                            onResubmit: remoteChat.map { chat in { chat.resubmit(message.id) } },
                            onSpeakFromHere: { speakFromHere(message, language: $0) },
                            onReply: { reply in sendReply(reply) }),
                          isBookmarked: conversation.map {
                            store.isMessageBookmarked(message.id, in: $0.id)
                          } ?? false,
                          conversationCreatedAt: conversation?.createdAt
                            ?? currentConversationSummary?.createdAt,
                          showUserTimestamp: message.role == .user && message.id != firstUserMessageID,
                          showThinking: remoteChat != nil
                            || store.effectiveShowThinking(for: currentConversation),
                          compactMetadata: remoteChat != nil,
                          isWaitingForResponse: isWaitingForResponse(message),
                          showsResponsePlaceholder: remoteChat == nil
                        )
                        if let chat = remoteChat, chat.isUnsent(message.id) {
                          Button {
                            chat.retryUnsent(message.id)
                          } label: {
                            Text(chat.isSendingUnsent(message.id)
                              ? "Connecting…" : "Not sent — tap to retry")
                              .font(.caption)
                              .foregroundStyle(.secondary)
                          }
                          .buttonStyle(.plain)
                          .disabled(chat.busy || !chat.canSubmit || isMessageSelectionMode)
                        }
                      }
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
                    .background(alignment: .bottom) {
                      ConversationHistoryScrollBridge(
                        session: historyScrollSession, revision: messageRenderWindow.revision,
                        messageID: message.id
                      )
                      .frame(height: 1)
                    }

                    if !isPreviewingConversation,
                      !isMessageSelectionMode,
                      remoteChat == nil, store.settings.followUps.isEnabled,
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
                }
                .messageScrollBounce()
              }
              if conversation?.historyWindow?.hasLater == true {
                Button("Newer messages") { Task { await loadHistoryAtEdge(forceLater: true) } }
                  .disabled(historyPageIsLoading)
              }
              if isPreviewingConversation {
                compactLoadingFooter
              }
              if let preview = liveVoiceSession.previewMessage {
                MessageBubble(
                  message: preview,
                  toolSettings: currentToolSettings,
                  openAIEndpoints: store.settings.isOffline
                    ? [] : store.settings.openAIEndpoints,
                  appearance: store.settings.appearance,
                  renderMarkdown: store.settings.renderMarkdownInChat,
                  renderImages: store.settings.renderMarkdownImagesInChat,
                  conversationCreatedAt: conversation?.createdAt
                    ?? currentConversationSummary?.createdAt,
                  showThinking: remoteChat != nil
                    || store.effectiveShowThinking(for: currentConversation),
                  compactMetadata: remoteChat != nil,
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
            if remoteChat?.responding == true {
              AssistantTypingIndicator(fontSize: store.settings.appearance.fontSize)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            }
            if !renderedMessages.isEmpty,
              lastUpdatedVisibleConversationID == currentConversationID,
              let updatedAt = conversation?.updatedAt
                ?? currentConversationSummary?.updatedAt
            {
              ConversationTimelineTimestamp(label: "Last Updated", date: updatedAt)
            }
            Color.clear
              .frame(height: 1)
              .background {
                ConversationHistoryScrollBridge(
                  session: historyScrollSession, revision: messageRenderWindow.revision,
                  onHistoryLayout: {
                    Task { await loadHistoryAtEdge() }
                  })
              }
          }
          .padding()
          .id(messageListBottomID)
          // Pin the scroll content to the viewport without using
          // containerRelativeFrame, which can create a layout cycle on rotation.
          .frame(width: scrollGeometry.size.width, alignment: .center)
          .frame(
            minHeight: max(0, scrollGeometry.size.height - chatHeaderHeight), alignment: .bottom)
          .background {
            MessageListPinchBridge(
              zoomMethod: store.settings.appearance.zoomMethod,
              baseFontSize: store.settings.appearance.fontSize,
              onBegan: { scrollView, contentPoint in
                historyScrollSession.cancel()
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
                historyScrollSession.cancel()
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
        .chatScrollBounce(phase: messageListScrollPhase,
          enabled: !messageFontPinchSession.isActive && !isMessageSelectionMode)
        .coordinateSpace(name: MessageFontPinchSession.coordinateSpaceName)
        .contentMargins(.top, chatHeaderHeight, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .contextMenu {
          if let remoteChat {
            Button("Terminal…", systemImage: "terminal") {
              onShowRemoteTerminal(remoteChat.bookmark, remoteChat.conversation.cwd)
            }
            .disabled(
              remoteChat.bookmark.requiresApproval == true
                || store.settings.isOffline)
          }
        }
        .onScrollGeometryChange(for: MessageListScrollMetrics.self) { geometry in
          let hasScrollableContent = geometry.contentSize.height > geometry.containerSize.height + 2
          return MessageListScrollMetrics(
            viewportMinY: geometry.visibleRect.minY,
            contentHeight: geometry.contentSize.height,
            hasScrollableContent: hasScrollableContent,
            viewport: ConversationScrollViewport(geometry))
        } action: { old, metrics in
          updateChatHeader(from: old, to: metrics)
          historyNearTop = metrics.viewportMinY < 160
          historyNearBottom = metrics.viewport.isAtBottom
          if !messageFontPinchSession.isActive {
            historyScrollSession.preserveBottomOnResize(from: old.viewport, to: metrics.viewport)
          }
          if old.contentHeight != metrics.contentHeight, currentChatIsResponding {
            // Wait for the bubble preferences from this layout before scrolling.
            DispatchQueue.main.async { scheduleStreamingScroll(proxy) }
          }
          refreshUserMessageNavigation(
            isAtBottom: metrics.viewport.isAtBottom,
            hasScrollableContent: metrics.hasScrollableContent)
          if remoteChat != nil, !metrics.hasScrollableContent {
            Task { await loadHistoryAtEdge() }
          }
        }
        .onPreferenceChange(ResponseScrollTargetsKey.self) { targets in
          responseScrollTargets = targets
          if currentChatIsResponding {
            DispatchQueue.main.async { scheduleStreamingScroll(proxy) }
          }
        }
        .onScrollPhaseChange { _, phase, context in
          messageListScrollPhase = phase
          messageListIsDragging = phase == .interacting
          if phase != .interacting { headerScrollDistance = 0 }
          messageListIsScrolling = phase != .idle
          if phase == .interacting {
            historyScrollSession.cancel()
            userScrolledAfterLastMessage = true
            userMessageNavigationDestination = nil
            userMessageNavigationHiddenBySwipe = false
          } else if phase == .idle {
            Task { await loadHistoryAtEdge() }
            if userMessageNavigationDestination == nil,
              userScrolledAfterLastMessage, !messageFontPinchSession.isActive,
              isAtChatBottom(context.geometry)
            {
              // Resume only after the gesture (including deceleration) finishes.
              userScrolledAfterLastMessage = false
              followChatBottom = true
            }
          }
        }
        .onAppear {
          scrollToBottomAfterLayout(proxy, animated: false)
          DispatchQueue.main.async {
            scrollToRequestedMessage(store.pendingMessageNavigation, proxy: proxy)
          }
        }
        .task(id: messageHistoryLoadKey) {
          await renderOlderMessages(for: messageHistoryLoadKey)
        }
        .onChange(of: currentConversationID) { _, _ in
          historyScrollSession.cancel()
          messageListIsScrolling = false
          messageListScrollPhase = .idle
          messageListIsDragging = false
          messageFontPinchSession.resetMetrics()
          userMessageNavigation = UserMessageNavigationState()
          userMessageNavigationDestination = nil
          userMessageNavigationHiddenBySwipe = false
          userMessageNavigationIndicatorVisible = false
          userMessageNavigationIndicatorTask?.cancel()
          userMessageNavigationIndicatorTask = nil
          userScrolledAfterLastMessage = false
          followChatBottom = false
          streamingScrollTask?.cancel()
          streamingScrollTask = nil
          lastStreamingScrollAt = nil
          scrollToBottomAfterLayout(proxy, animated: false)
        }
        .onChange(of: lastMessageSnapshot) { old, new in
          guard !messageFontPinchSession.isActive else { return }
          if old.conversationID != new.conversationID {
            userScrolledAfterLastMessage = false
            followChatBottom = false
            scrollToBottomAfterLayout(proxy, animated: false)
            return
          }
          if old.lastUserMessageID != new.lastUserMessageID {
            userScrolledAfterLastMessage = false
            followChatBottom = false
          }
          scrollToBottomAfterLayout(proxy, animated: false, followResponse: true)
        }
        .onChange(of: liveVoiceSession.transcript) { _, _ in
          guard !messageFontPinchSession.isActive, !userScrolledAfterLastMessage else { return }
          scrollToBottom(proxy, animated: false)
        }
        .onChange(of: currentQueuedUserMessageIDs) { _, _ in
          guard !messageFontPinchSession.isActive, !userScrolledAfterLastMessage else { return }
          scrollToBottomAfterLayout(proxy, animated: true, followResponse: true)
        }
        .onChange(of: currentFollowUpPresentationSnapshot) { old, new in
          guard old != new,
            new != nil,
            !messageFontPinchSession.isActive,
            !userScrolledAfterLastMessage
          else { return }
          scrollToBottomAfterLayout(proxy, animated: true, followResponse: true)
        }
        .onChange(of: pendingScrollToMessageID) { _, target in
          guard !messageFontPinchSession.isActive, let target else { return }
          prepareMessageNavigation(to: target)
          DispatchQueue.main.async {
            withAnimation(.snappy) {
              proxy.scrollTo(target, anchor: .center)
            }
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
          prepareMessageNavigation(to: target.messageID)
          DispatchQueue.main.async {
            withAnimation(.snappy) {
              proxy.scrollTo(target, anchor: .center)
            }
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if currentMessageIDs.count >= 2,
            userMessageNavigation.hasScrollableContent,
            !userMessageNavigation.isAtBottom,
            !userMessageNavigationHiddenBySwipe
          {
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

  private func updateChatHeader(
    from old: MessageListScrollMetrics, to new: MessageListScrollMetrics
  ) {
    guard messageListIsDragging, !messageFontPinchSession.isActive,
      !historyScrollSession.isRestoring, old.contentHeight == new.contentHeight,
      old.viewport.height == new.viewport.height, new.hasScrollableContent
    else { return }
    if new.viewportMinY <= 0 {
      chatHeaderHidden = false
      headerScrollDistance = 0
      return
    }
    // Ignore rubber-banding and use a small travel threshold to avoid flickering.
    let limit = max(0, new.contentHeight - new.viewport.height)
    let delta = min(max(new.viewportMinY, 0), limit) - min(max(old.viewportMinY, 0), limit)
    guard delta != 0 else { return }
    if (delta > 0) != (headerScrollDistance > 0) { headerScrollDistance = 0 }
    headerScrollDistance += delta
    if abs(headerScrollDistance) >= 24 {
      chatHeaderHidden = headerScrollDistance < 0
      headerScrollDistance = 0
    }
  }

  private func userMessageNavigationControls(proxy: ScrollViewProxy) -> some View {
    let previousDestination = userMessageNavigationTarget(for: .previous)
    let nextDestination = userMessageNavigationTarget(for: .next)

    let previousButton = userMessageNavigationButton(
      systemImage: "chevron.up",
      label: "Previous user message",
      direction: .previous,
      destination: previousDestination,
      proxy: proxy)

    let nextButton = userMessageNavigationButton(
      systemImage: "chevron.down",
      label: nextDestination == .bottom ? "Bottom of conversation" : "Next user message",
      direction: .next,
      destination: nextDestination,
      proxy: proxy)

    return Group {
      if usesCompactLandscapeLayout {
        // Keep the arrows in the corner gutter, away from text and the camera cutout.
        VStack(spacing: 8) {
          previousButton
          userMessageNavigationIndicator
          Spacer(minLength: 8)
          nextButton
        }
        .padding(.top, 64)
        .padding(.bottom, isComposerCollapsed ? 64 : 12)
        .padding(.trailing, 12)
      } else {
        VStack(spacing: 8) {
          userMessageNavigationIndicator
          previousButton
          nextButton
        }
        .fixedSize()
        .padding(.trailing, 12)
        .padding(.bottom, 12)
      }
    }
    .simultaneousGesture(
      DragGesture(minimumDistance: 16)
        .onEnded { value in
          let distance = hypot(value.translation.width, value.translation.height)
          guard distance >= 24 else { return }
          userMessageNavigationHiddenBySwipe = true
        }
    )
    .frame(
      maxWidth: usesCompactLandscapeLayout ? .infinity : nil,
      maxHeight: usesCompactLandscapeLayout ? .infinity : nil,
      alignment: .trailing)
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
      let conversationID = currentConversationID
      streamingScrollTask?.cancel()
      streamingScrollTask = nil
      historyScrollSession.stopScrolling()
      if case .message(let id) = destination {
        prepareMessageNavigation(to: id)
      } else {
        historyScrollSession.cancel()
      }
      userScrolledAfterLastMessage = true
      userMessageNavigationDestination = destination
      showUserMessageNavigationIndicator()
      // Let newly revealed history lay out, then jump without inheriting animations.
      DispatchQueue.main.async {
        guard currentConversationID == conversationID,
          userMessageNavigationDestination == destination
        else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          switch destination {
          case .message(let id):
            proxy.scrollTo(id, anchor: .top)
          case .bottom:
            followChatBottom = true
            userScrolledAfterLastMessage = false
            proxy.scrollTo(messageListBottomID, anchor: .bottom)
          }
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
    (currentConversation?.messages
      ?? store.selectedConversationPreviewMessages)
      .filter { $0.role == .user }
      .map(\.id)
  }

  private func refreshUserMessageNavigation(
    isAtBottom: Bool? = nil,
    hasScrollableContent: Bool? = nil
  ) {
    let atBottom = isAtBottom ?? userMessageNavigation.isAtBottom
    let scrollable = hasScrollableContent ?? userMessageNavigation.hasScrollableContent
    let userMessageIDs = currentUserMessageIDs
    let alignedTopTolerance: CGFloat = 4
    let startIndex = messageRenderWindow.startIndex(
      in: presentationMessages, conversationID: currentConversationID)
    var previousID = presentationMessages.prefix(startIndex).last(where: { $0.role == .user })?.id
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
      hasScrollableContent: scrollable,
      previousID: previousID,
      nextID: nextID)
    guard newState != userMessageNavigation else { return }
    userMessageNavigation = newState
  }

  private func confirmationBinding<Item>(_ item: Binding<Item?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
  }

  private var currentConversationIsEmpty: Bool {
    currentConversation?.messages.isEmpty ?? true
  }

  private var currentMessageIDs: [UUID] {
    currentConversation?.messages.map(\.id) ?? []
  }

  private var presentationMessages: [ChatMessage] {
    currentConversation?.messages ?? store.selectedConversationPreviewMessages
  }

  private var messageHistoryLoadKey: MessageHistoryLoadKey {
    MessageHistoryLoadKey(
      conversationID: currentConversationID,
      firstMessageID: presentationMessages.first?.id,
      lastMessageID: presentationMessages.last?.id,
      isPreview: isLoadingConversation && currentConversation == nil)
  }

  @MainActor
  private func renderOlderMessages(for key: MessageHistoryLoadKey) async {
    guard !Task.isCancelled, messageHistoryLoadKey == key, !key.isPreview else { return }
    if messageRenderWindow.conversationID != key.conversationID {
      if remoteChat != nil {
        messageRenderWindow.resetGrouped(in: presentationMessages, conversationID: key.conversationID)
      } else {
        messageRenderWindow.reset(in: presentationMessages, conversationID: key.conversationID)
      }
    }
    if let request = store.pendingMessageNavigation, request.conversationID == key.conversationID {
      messageRenderWindow.reveal(
        request.messageID, in: presentationMessages, conversationID: key.conversationID)
    }
    if let match = chatSearch.currentMatch {
      messageRenderWindow.reveal(
        match.messageID, in: presentationMessages, conversationID: key.conversationID)
    }
    prepareMessageParts(in: presentationMessages)
  }

  @MainActor
  private func loadHistoryAtEdge(forceLater: Bool = false) async {
    let needsMoreRemoteHistory = remoteChat != nil && !userMessageNavigation.hasScrollableContent
    guard !historyPageIsLoading, !messageFontPinchSession.isActive, !messageListIsScrolling,
      forceLater || userScrolledAfterLastMessage || needsMoreRemoteHistory
    else { return }
    let id = currentConversationID
    let earlier = !forceLater && (historyNearTop || needsMoreRemoteHistory)
    guard earlier || forceLater || historyNearBottom else { return }
    historyPageIsLoading = true
    defer { historyPageIsLoading = false }
    let messages = presentationMessages
    if earlier {
      guard historyScrollSession.prepareForPrepend(revision: messageRenderWindow.revision + 1)
      else { return }
      if let part = messageRenderWindow.messageWithEarlierParts(in: messages, conversationID: id) {
        messageRenderWindow.revealEarlierParts(for: part)
      } else if remoteChat != nil
        ? messageRenderWindow.revealEarlierGroups(in: messages, conversationID: id)
        : messageRenderWindow.revealEarlier(in: messages, conversationID: id)
      {
        prepareMessageParts(in: messages)
      } else if remoteChat == nil, !currentChatIsResponding,
        currentConversation?.historyWindow?.hasEarlier == true
      {
        await store.pageConversationHistory(earlier: true)
        guard currentConversationID == id, let first = presentationMessages.first else { return }
        messageRenderWindow.reveal(first.id, in: presentationMessages, conversationID: id)
        prepareMessageParts(in: presentationMessages)
      } else {
        historyScrollSession.cancel()
      }
    } else if remoteChat == nil, !currentChatIsResponding,
      currentConversation?.historyWindow?.hasLater == true
    {
      guard historyScrollSession.prepareForPrepend(revision: messageRenderWindow.revision + 1)
      else { return }
      await store.pageConversationHistory(earlier: false)
      guard currentConversationID == id, let first = presentationMessages.first else { return }
      messageRenderWindow.reveal(first.id, in: presentationMessages, conversationID: id)
      prepareMessageParts(in: presentationMessages)
    }
  }

  private func prepareMessageParts(in messages: [ChatMessage]) {
    let start = messageRenderWindow.startIndex(in: messages, conversationID: currentConversationID)
    for message in messages.suffix(from: start).reversed()
    where messageRenderWindow.partStartIndex(for: message.id) == nil {
      // Keep an active response intact as its tool/prose parts are appended.
      let count = currentChatIsResponding && message.id == messages.last?.id
        ? 0 : MessageRenderCache.partCount(for: message)
      messageRenderWindow.prepareParts(for: message.id, count: count)
    }
  }

  private func prepareMessageNavigation(to messageID: UUID) {
    historyScrollSession.cancel()
    userScrolledAfterLastMessage = true
    messageRenderWindow.reveal(
      messageID, in: presentationMessages, conversationID: currentConversationID)
    prepareMessageParts(in: presentationMessages)
  }

  private var currentQueuedUserMessages: [QueuedChatMessage] {
    remoteChat == nil ? store.queuedUserMessages(in: currentConversation?.id) : []
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
    guard remoteChat == nil, store.settings.followUps.isEnabled,
      let conversationID = currentConversation?.id,
      let lastMessageID = currentConversation?.messages.last?.id
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
    if let remoteChat {
      if remoteChat.canSubmit {
        remoteChat.send(text)
      } else {
        store.replaceComposerDraft(with: text, in: remoteChat.conversation.id)
      }
      return
    }
    if let conversationID = currentConversation?.id,
      store.isResponding(in: conversationID),
      store.enqueueUserMessage(prompt: text, in: conversationID)
    {
      return
    }
    Task { _ = await store.send(prompt: text) }
  }

  private func cancelQueuedMessage(_ message: QueuedChatMessage) {
    guard let conversationID = currentConversation?.id else { return }
    withAnimation(.snappy) {
      store.removeQueuedUserMessage(id: message.id, from: conversationID)
    }
  }

  private func editQueuedMessage(_ message: QueuedChatMessage) {
    guard let conversationID = currentConversation?.id,
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
    let conversationID = currentConversationID
    let updatedAt =
      currentConversation?.id == conversationID
      ? currentConversation?.updatedAt
      : currentConversationSummary?.updatedAt
    return ConversationActivitySnapshot(
      conversationID: conversationID,
      updatedAt: updatedAt,
      isResponding: currentChatIsResponding)
  }

  private func beginChatSearch() {
    cancelMessageSelection()
    userScrolledAfterLastMessage = true
    withAnimation(.snappy) {
      _ = Task {
        if let id = currentConversationID, remoteChat == nil {
          await store.preloadConversation(id: id)
        }
        chatSearch.begin(messages: currentConversation?.messages ?? [])
      }
    }
  }

  private var selectedMessages: [ChatMessage] {
    currentConversation?.messages.filter { selectedMessageIDs.contains($0.id) } ?? []
  }

  private struct LastMessageSnapshot: Equatable {
    var conversationID: UUID?
    var messageID: UUID?
    var lastUserMessageID: UUID?
    var text: String?
  }

  private var lastMessageSnapshot: LastMessageSnapshot {
    let convo = currentConversation
    let last = convo?.messages.last
    return LastMessageSnapshot(
      conversationID: convo?.id,
      messageID: last?.id,
      lastUserMessageID: convo?.messages.last(where: { $0.role == .user })?.id,
      text: last?.presentationText)
  }

  private func isWaitingForResponse(_ message: ChatMessage) -> Bool {
    guard currentChatIsResponding, message.role == .assistant else { return false }
    return currentConversation?.messages.last?.id == message.id
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
      if currentConversation == nil {
        store.newConversation()
      }
      guard !liveVoiceSession.isActive else { return }
      liveVoiceSession.start(store: store, ttsPlayer: ttsPlayer)
    case .openConversation(let id):
      await store.selectConversation(id: id)
    case .importSharedContent:
      store.drainSharedInbox()
      if store.hasQueuedSharedItems, currentConversation == nil {
        store.newConversation()
      }
    }
  }

  private func isAtChatBottom(_ geometry: ScrollGeometry) -> Bool {
    geometry.contentSize.height <= geometry.containerSize.height + 2
      || geometry.visibleRect.maxY >= geometry.contentSize.height - 2
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

  private func scrollFollowingResponse(_ proxy: ScrollViewProxy, animated: Bool = false) {
    // The setting or returning to the bottom follows the tail, even for a tall response.
    if !store.settings.appearance.scrollToFollowResponses, !followChatBottom,
      let id = currentConversation?.messages.last?.id,
      let target = responseScrollTargets[id]
    {
      // ScrollView clamps short answers to the bottom. Once the answer is
      // taller than the viewport, its beginning stays at the top.
      if animated {
        withAnimation(.snappy) { proxy.scrollTo(target, anchor: .top) }
      } else {
        proxy.scrollTo(target, anchor: .top)
      }
    } else {
      scrollToBottom(proxy, animated: animated)
    }
  }

  private func scrollToBottomAfterLayout(
    _ proxy: ScrollViewProxy, animated: Bool, followResponse: Bool = false
  ) {
    guard !userScrolledAfterLastMessage else { return }
    DispatchQueue.main.async {
      guard !userScrolledAfterLastMessage else { return }
      if followResponse {
        scrollFollowingResponse(proxy, animated: animated)
      } else {
        scrollToBottom(proxy, animated: animated)
      }
    }
  }

  private func scrollToRequestedMessage(
    _ request: MessageNavigationRequest?,
    proxy: ScrollViewProxy
  ) {
    guard let request,
      request.conversationID == currentConversationID,
      currentMessageIDs.contains(request.messageID)
    else { return }
    prepareMessageNavigation(to: request.messageID)
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
  // the whole message list on every size change forces a full layout pass each time
  // and competes with the composer / any presented UI for the main thread. Cap
  // the auto-scroll cadence and coalesce bursts into a single trailing scroll.
  private static let streamingScrollInterval: TimeInterval = 0.35

  private func scheduleStreamingScroll(_ proxy: ScrollViewProxy) {
    guard !messageFontPinchSession.isActive,
      !historyScrollSession.isRestoring,
      !userScrolledAfterLastMessage
    else { return }
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
          !historyScrollSession.isRestoring,
          !userScrolledAfterLastMessage
        else { return }
        lastStreamingScrollAt = Date()
        scrollFollowingResponse(proxy)
      }
      return
    }
    lastStreamingScrollAt = now
    scrollFollowingResponse(proxy)
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
            y: scrollView.clampedContentOffsetY(
              scrollView.contentOffset.y + textCorrection)),
          animated: false)
      } else if let anchor = messageFontPinchSession.semanticAnchor,
        let frame = messageFontPinchSession.frame(for: anchor.messageID)
      {
        let measuredAnchorY = frame.minY + frame.height * anchor.rowFraction
        let correctedOffsetY = scrollView.contentOffset.y + measuredAnchorY - anchor.viewportY
        scrollView.setContentOffset(
          CGPoint(x: 0, y: scrollView.clampedContentOffsetY(correctedOffsetY)),
          animated: false)
      } else {
        let targetContentY =
          max(scrollView.contentSize.height, 1)
          * messageFontPinchSession.realtimeContentFraction
        let targetY = targetContentY - messageFontPinchSession.realtimeViewportY
        scrollView.setContentOffset(
          CGPoint(x: 0, y: scrollView.clampedContentOffsetY(targetY)),
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
            y: scrollView.clampedContentOffsetY(
              scrollView.contentOffset.y + textCorrection)),
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
        CGPoint(x: 0, y: scrollView.clampedContentOffsetY(correctedOffsetY)),
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
        CGPoint(x: 0, y: scrollView.clampedContentOffsetY(targetY)),
        animated: false)
      completion()
    }
  }

  private var compactLoadingState: some View {
    VStack(spacing: 10) {
      ProgressView()
        .controlSize(.regular)
      Text(currentConversationSummary?.displayTitle ?? "Loading conversation")
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

  private func emptyState(in viewport: CGSize) -> some View {
    let suggestions = remoteChat == nil ? store.previousConversationSuggestions : []
    let hasSuggestions = !suggestions.isEmpty || remoteHosts?.recentConversations.isEmpty == false
    let showsColumns = viewport.width >= 700 && !dynamicTypeSize.isAccessibilitySize
      && (hasSuggestions || remoteChat != nil)
    let layout = showsColumns
      ? AnyLayout(HStackLayout(spacing: 40)) : AnyLayout(VStackLayout(spacing: 28))

    return layout {
      emptyStateBrand.frame(maxWidth: showsColumns ? .infinity : nil)
      if let remoteHosts, let remoteChat {
        VStack(spacing: 24) {
          remoteStartupActions(hosts: remoteHosts, chat: remoteChat)
          if !remoteHosts.recentConversations.isEmpty {
            remoteConversationSuggestions(hosts: remoteHosts)
          }
        }
        .frame(maxWidth: showsColumns ? .infinity : nil)
      } else if !suggestions.isEmpty {
        PreviousConversationSuggestions(
          store: store, suggestions: suggestions,
          exportCoordinator: exportCoordinator
        ) { id in
          Task { await store.selectConversation(id: id) }
        }
        .frame(maxWidth: showsColumns ? .infinity : nil)
      }
    }
    .frame(maxWidth: showsColumns ? 900 : 430)
    .padding(.horizontal, 8)
    .padding(.vertical, 24)
    .frame(maxWidth: .infinity)
    // A minimum height centers short content but lets large text and a short
    // multitasking window scroll, instead of positioning content offscreen.
    .frame(minHeight: max(0, viewport.height - 33))
  }

  private func remoteStartupActions(hosts: HostNavigationStore, chat: RemoteAgentChat) -> some View {
    VStack(spacing: 12) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) { remoteWorkspaceButtons(hosts: hosts, chat: chat) }
        VStack(spacing: 12) { remoteWorkspaceButtons(hosts: hosts, chat: chat) }
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(hosts.selectedHost?.requiresApproval == true || store.settings.isOffline)
      if hosts.waitingApproval {
        Text("Approve this device on the remote host to start chatting.")
          .font(.caption).foregroundStyle(.secondary)
      } else if hosts.loading {
        ProgressView("Loading conversations…").font(.caption)
      } else if let error = hosts.error {
        Text(error).font(.caption).foregroundStyle(.secondary)
        Button("Reconnect") { hosts.refresh(isOffline: store.settings.isOffline) }
      }
    }
  }

  @ViewBuilder
  private func remoteWorkspaceButtons(hosts: HostNavigationStore, chat: RemoteAgentChat) -> some View {
    Group {
      Button("Browse Files", systemImage: "folder", action: onBrowseFiles)
      Button("Terminal", systemImage: "terminal") {
        onShowRemoteTerminal(hosts.selectedHost ?? chat.bookmark, chat.conversation.cwd)
      }
    }
    .disabled(chat.conversation.cwd.isEmpty)
  }

  private func remoteConversationSuggestions(hosts: HostNavigationStore) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Pick up where you left off")
        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
        .padding(.horizontal, 4)
      ForEach(hosts.recentConversations) { chat in
        PreviousConversationSuggestionButton(
          title: chat.title, updatedAt: chat.updatedAt,
          folderName: hosts.folders.first { $0.cwd == chat.cwd }?.name ?? chat.cwd,
          systemImage: "folder", tint: .accentColor,
          isMostRecent: hosts.recentConversations.last?.id == chat.id
        ) {
          hosts.selectConversation(chat.id)
        }
        .disabled(hosts.selectedHost?.requiresApproval == true)
      }
    }
  }

  private var emptyStateBrand: some View {
    VStack(spacing: 14) {
      EmptyChatLogo()
        .padding(20)
        .background {
          RoundedRectangle(cornerRadius: 32, style: .continuous)
            .fill(.thinMaterial)
            .shadow(color: .accentColor.opacity(0.12), radius: 24, y: 10)
        }
        .overlay {
          RoundedRectangle(cornerRadius: 32, style: .continuous)
            .strokeBorder(.primary.opacity(0.06), lineWidth: 1)
        }
        .padding(.bottom, 4)
        .accessibilityHidden(true)
      Text("PocketMai")
        .font(.system(.largeTitle, design: .rounded, weight: .bold))
        .accessibilityAddTraits(.isHeader)
      Text(remoteHosts?.selectedHost?.name ?? "Your pocket assistant")
        .font(.title3.weight(.medium))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .multilineTextAlignment(.center)
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
        .disabled(!hasSelection || remoteChat != nil)
        .opacity(hasSelection && remoteChat == nil ? 1 : 0.5)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
      .padding(.horizontal, 18)
    }
    .frame(height: 82)
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 0) {
      ChatComposer(
        store: store,
        remoteChat: remoteChat,
        placeholder: "Ask anything… / commands, $ prompts & skills",
        conversationID: currentConversation?.id,
        isResponding: currentChatIsResponding,
        isKeyboardVisible: keyboardOverlap > 0,
        isCollapsed: isComposerCollapsed,
        onExpand: { landscapeComposerExpanded = true },
        queuedMessagePendingEdit: $queuedMessagePendingEdit,
        liveVoiceSession: liveVoiceSession
      )
      // Keep the composer mounted so rotation and toggling retain attachments and drafts.
      .frame(height: isComposerCollapsed ? 0 : nil)
      .clipped()
      .opacity(isComposerCollapsed ? 0 : 1)
      .allowsHitTesting(!isComposerCollapsed)
      .accessibilityHidden(isComposerCollapsed)

      if usesCompactLandscapeLayout, !isComposerCollapsed, !liveVoiceSession.isActive {
        landscapeComposerToggle
          .padding(.trailing, 8)
          .padding(.bottom, 8)
      }
    }
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
      Text("Pick up where you left off")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)

      VStack(spacing: 8) {
        ForEach(suggestions) { suggestion in
          PreviousConversationSuggestionButton(
            title: suggestion.displayTitle, updatedAt: suggestion.updatedAt,
            folderName: folder(for: suggestion).displayName,
            systemImage: folder(for: suggestion).systemImage,
            tint: folder(for: suggestion).tint?.swatchColor ?? .accentColor,
            isMostRecent: suggestions.last?.id == suggestion.id,
            onSelect: { onSelect(suggestion.id) }
          )
          .modifier(
            ConversationSummaryActionsModifier(
              store: store,
              conversation: suggestion,
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
  let title: String
  let updatedAt: Date
  let folderName: String
  let systemImage: String
  let tint: Color
  let isMostRecent: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(spacing: 10) {
        Image(systemName: systemImage)
          .font(.body)
          .foregroundStyle(tint)
          .frame(width: 22, height: 22)

        VStack(alignment: .leading, spacing: 3) {
          Text(title)
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
      .padding(.horizontal, 14)
      .padding(.vertical, 12)
      .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
      .background {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(isMostRecent ? Color.accentColor.opacity(0.10) : Color.clear)
      }
      .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .stroke(
            isMostRecent ? Color.accentColor.opacity(0.20) : Color.primary.opacity(0.08),
            lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    .buttonStyle(ConversationSuggestionButtonStyle())
    .accessibilityLabel(title)
    .accessibilityHint(recencyLabel)
  }

  private var recencyLabel: String {
    let recency = ConversationRecencyLabel.text(for: updatedAt)
    return "\(recency) in \(folderName)"
  }
}

/// A moved touch must not open a chat when a swipe ends inside its card.
private struct ConversationSuggestionButtonStyle: PrimitiveButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .onTapGesture {
        if isEnabled { configuration.trigger() }
      }
      .accessibilityAddTraits(.isButton)
      .accessibilityAction {
        if isEnabled { configuration.trigger() }
      }
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

// Compare before constructing ChatView, including its remote session and HTTP configuration.
struct ChatViewContent: View, Equatable {
  let key: ChatView.RenderInvalidationKey
  @ViewBuilder let content: () -> ChatView

  var body: some View { content() }

  nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
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

private struct AwakeIndicator: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Image(systemName: "circle.fill")
      .font(.system(size: 8))
      .foregroundStyle(.orange)
      .symbolEffect(.breathe, options: .repeating, isActive: !reduceMotion && scenePhase == .active)
      .accessibilityLabel("Keep awake enabled")
  }
}
