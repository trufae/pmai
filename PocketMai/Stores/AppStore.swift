import Combine
import Foundation
import MaiCore
import MaiDocuments
import SwiftUI
import UIKit
import WidgetKit

enum EndpointConnectionState: Equatable, Sendable {
  case unknown
  case checking
  case available
  case failed(String)

  var statusText: String {
    switch self {
    case .unknown: "Not checked"
    case .checking: "Checking"
    case .available: "Connected"
    case .failed: "Failed"
    }
  }

  var statusColor: Color {
    switch self {
    case .unknown: .secondary
    case .checking: .orange
    case .available: .green
    case .failed: .red
    }
  }

  var isAvailable: Bool {
    if case .available = self {
      return true
    }
    return false
  }
}

private enum ConversationImportError: LocalizedError {
  case unreadableFile
  case invalidJSON
  case folderNameRequired
  case folderAlreadyExists(String)
  case missingFolder
  case titleRequired
  case titleAlreadyExists(String)
  case missingExistingConversation
  case updateNotAvailable

  var errorDescription: String? {
    switch self {
    case .unreadableFile:
      return "Could not read the selected file."
    case .invalidJSON:
      return "The selected file is not a valid PocketMai conversation export."
    case .folderNameRequired:
      return "Specify a folder name for the imported conversations."
    case .folderAlreadyExists(let name):
      return "A folder named \"\(name)\" already exists."
    case .missingFolder:
      return "The selected destination folder is no longer available."
    case .titleRequired:
      return "Specify a title for the imported conversation."
    case .titleAlreadyExists(let title):
      return "A conversation named \"\(title)\" already exists."
    case .missingExistingConversation:
      return "The matching conversation no longer exists."
    case .updateNotAvailable:
      return "This import cannot update an existing conversation."
    }
  }
}

enum ToolCallApprovalDecision: Sendable {
  case approved(ParsedToolCall)
  case cancelled
  case interrupted
}

private enum OpenAPIServerAppError: LocalizedError {
  case emptyPrompt
  case unavailable(String)

  var statusCode: Int {
    switch self {
    case .emptyPrompt:
      return 400
    case .unavailable:
      return 503
    }
  }

  var errorDescription: String? {
    switch self {
    case .emptyPrompt:
      return "The request did not include a prompt or user message."
    case .unavailable(let message):
      return message
    }
  }
}

private enum ToolCallApprovalParseResult {
  case success(ParsedToolCall)
  case failure(String)
}

private struct PromptShortcutTarget {
  var selection: PromptShortcutSelection
  var commandName: String
  var text: String
}

private struct ResolvedPromptSubmission {
  var prompt: String
  var displayText: String?
  var systemPromptID: UUID?
}

struct ToolCallApprovalRequest: Identifiable {
  let id: UUID
  let callName: String
  let originalText: String
  let mode: ToolCallingMode
  let definitions: [ToolDefinition]
  let conversationTitle: String?

  private let continuation: CheckedContinuation<ToolCallApprovalDecision, Never>

  init(
    id: UUID,
    callName: String,
    originalText: String,
    mode: ToolCallingMode,
    definitions: [ToolDefinition],
    conversationTitle: String?,
    continuation: CheckedContinuation<ToolCallApprovalDecision, Never>
  ) {
    self.id = id
    self.callName = callName
    self.originalText = originalText
    self.mode = mode
    self.definitions = definitions
    self.conversationTitle = conversationTitle
    self.continuation = continuation
  }

  func resume(returning decision: ToolCallApprovalDecision) {
    continuation.resume(returning: decision)
  }
}

struct LongRunningOperationTimeoutRequest: Identifiable {
  let id: UUID
  let context: LongRunningOperationContext

  private let continuation: CheckedContinuation<LongRunningOperationDecision, Never>

  init(
    id: UUID,
    context: LongRunningOperationContext,
    continuation: CheckedContinuation<LongRunningOperationDecision, Never>
  ) {
    self.id = id
    self.context = context
    self.continuation = continuation
  }

  func resume(returning decision: LongRunningOperationDecision) {
    continuation.resume(returning: decision)
  }
}

struct FollowUpSuggestionState: Equatable, Sendable {
  let sourceMessageID: UUID
  let options: [String]
}

struct ComposerDraftReplacement: Equatable, Sendable {
  let id = UUID()
  let conversationID: UUID
  let text: String
}

@MainActor
final class AppStore: ObservableObject {
  private static let openAPIServerSystemPromptID = UUID(
    uuidString: "00000000-0000-0000-0000-000000011434")!

  /// Loaded full conversations are an internal cache. The UI observes only `activeConversation`
  /// and lightweight summaries, so loading or mutating an unrelated cached chat cannot invalidate
  /// the active message hierarchy.
  private(set) var conversations: [Conversation] {
    didSet { publishActiveConversationIfNeeded() }
  }
  @Published private(set) var activeConversation: Conversation? = nil
  @Published var conversationSummaries: [ConversationSummary] = []
  @Published private(set) var recentConversationSummaries: [ConversationSummary] = []
  @Published private(set) var messageBookmarks: [MessageBookmark] = []
  @Published var selectedConversationID: UUID?
  @Published var selectedConversationIDs: Set<UUID> = []
  @Published var settings: AppSettings
  @Published var respondingConversationIDs: Set<UUID> = []
  @Published private(set) var loadingLocalModelConversationIDs: Set<UUID> = []
  @Published private(set) var queuedUserMessagesByConversationID: [UUID: [QueuedChatMessage]] = [:]
  @Published private(set) var followUpSuggestionsByConversationID: [UUID: FollowUpSuggestionState] =
    [:]
  @Published private(set) var generatingFollowUpSourceMessageIDsByConversationID: [UUID: UUID] = [:]

  /// Remembers the last successful MCP catalog / endpoint model fetch so repeated
  /// automatic refreshes (every chat turn, conversation switches, view appears)
  /// reuse a warm connection instead of re-hitting the network. Keyed by the
  /// server/endpoint id; invalidated when the connection signature changes.
  private struct RemoteFetchCacheEntry {
    let signature: String
    let fetchedAt: Date
  }
  private var mcpCatalogCache: [UUID: RemoteFetchCacheEntry] = [:]
  private var endpointModelCache: [UUID: RemoteFetchCacheEntry] = [:]
  private static let remoteFetchCacheTTL: TimeInterval = 300

  private var responseTasks: [UUID: Task<Void, Never>] = [:]
  private var responseTaskTokens: [UUID: UUID] = [:]
  /// The process table for child agents, one for the whole app the way pmai
  /// keeps one per session. Runtime state stays transient; durable child
  /// records and transcripts live with their conversations.
  let agentSupervisor = AgentSupervisor()
  /// Written only by the supervisor feed; views read it.
  @Published var agentProcesses: [AgentProcessInfo] = []
  /// The process a conversation runs as — the root its children hang off —
  /// and, while a child runs, the process its own conversation is.
  var agentProcessIDs: [UUID: AgentPID] = [:]
  private var followUpTasks: [UUID: Task<Void, Never>] = [:]
  private var followUpTaskTokens: [UUID: UUID] = [:]
  var responseBackgroundTasks: [UUID: ResponseBackgroundTask] = [:]
  let assistantActivity = AssistantActivityController()
  let backgroundKeepAlive = BackgroundKeepAlive()
  /// Recorded by the turn runner so the finish hook can tell a failed or
  /// stopped reply from a completed one.
  var responseOutcomes: [UUID: AssistantActivityTask.Phase] = [:]
  private var cancelledToolCallApprovalIDs: Set<UUID> = []
  private var cancelledLongRunningOperationTimeoutIDs: Set<UUID> = []
  private var toolCallingDebugIterations: [UUID: [ConversationDebugToolIteration]] = [:]

  var isResponding: Bool { !respondingConversationIDs.isEmpty }

  func isResponding(in conversationID: UUID) -> Bool {
    respondingConversationIDs.contains(conversationID)
  }

  func isLoadingLocalModel(in conversationID: UUID) -> Bool {
    loadingLocalModelConversationIDs.contains(conversationID)
  }

  func cancelResponse(in conversationID: UUID) {
    responseTasks[conversationID]?.cancel()
  }

  func queuedUserMessages(in conversationID: UUID?) -> [QueuedChatMessage] {
    guard let conversationID else { return [] }
    return queuedUserMessagesByConversationID[conversationID] ?? []
  }

  func hasQueuedUserMessages(in conversationID: UUID) -> Bool {
    queuedUserMessagesByConversationID[conversationID]?.isEmpty == false
  }

  @discardableResult
  func enqueueUserMessage(
    prompt rawPrompt: String,
    attachments: [ChatAttachment] = [],
    in conversationID: UUID
  ) -> Bool {
    guard respondingConversationIDs.contains(conversationID),
      indexedConversationIndex(for: conversationID) != nil
    else {
      return false
    }
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || !attachments.isEmpty else { return false }
    queuedUserMessagesByConversationID[conversationID, default: []].append(
      QueuedChatMessage(text: prompt, attachments: attachments))
    return true
  }

  func removeQueuedUserMessage(id: UUID, from conversationID: UUID) {
    guard var queued = queuedUserMessagesByConversationID[conversationID] else { return }
    queued.removeAll { $0.id == id }
    if queued.isEmpty {
      queuedUserMessagesByConversationID[conversationID] = nil
    } else {
      queuedUserMessagesByConversationID[conversationID] = queued
    }
  }

  func takeQueuedUserMessageForEditing(
    id: UUID,
    from conversationID: UUID
  ) -> QueuedChatMessage? {
    guard var queued = queuedUserMessagesByConversationID[conversationID],
      let index = queued.firstIndex(where: { $0.id == id })
    else {
      return nil
    }
    let message = queued.remove(at: index)
    if queued.isEmpty {
      queuedUserMessagesByConversationID[conversationID] = nil
    } else {
      queuedUserMessagesByConversationID[conversationID] = queued
    }
    return message
  }

  /// Moves every pending user turn into conversation history and appends the
  /// assistant placeholder that will receive the loop's next provider response.
  func injectQueuedUserMessagesAndAppendAssistant(in conversationID: UUID) -> UUID? {
    guard let queued = queuedUserMessagesByConversationID[conversationID], !queued.isEmpty,
      let index = indexedConversationIndex(for: conversationID)
    else {
      return nil
    }
    queuedUserMessagesByConversationID[conversationID] = nil
    conversations[index].messages.append(
      contentsOf: queued.map {
        ChatMessage(
          role: .user,
          text: $0.text,
          createdAt: $0.createdAt,
          attachments: $0.attachments)
      })
    let assistantMessage = ChatMessage(role: .assistant, text: "")
    conversations[index].messages.append(assistantMessage)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    return assistantMessage.id
  }

  /// Appends what reached the chat mid-turn from elsewhere — the answers its
  /// child agents delivered — as user messages with a fresh assistant message
  /// after them, the way queued user messages are folded in. Nil for nothing.
  func appendUserMessagesAndAssistant(_ texts: [String], in conversationID: UUID) -> UUID? {
    guard !texts.isEmpty, let index = indexedConversationIndex(for: conversationID) else {
      return nil
    }
    conversations[index].messages.append(
      contentsOf: texts.map { ChatMessage(role: .user, text: $0) })
    let assistantMessage = ChatMessage(role: .assistant, text: "")
    conversations[index].messages.append(assistantMessage)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    return assistantMessage.id
  }

  private func abandonResponse(in conversationID: UUID) {
    responseTasks[conversationID]?.cancel()
    responseTasks[conversationID] = nil
    responseTaskTokens[conversationID] = nil
    respondingConversationIDs.remove(conversationID)
    endResponseBackgroundTask(for: conversationID)
    clearFollowUpSuggestions(in: conversationID)
    activityTurnAbandoned(conversationID: conversationID)
    stopAgentProcesses(for: conversationID, reason: "Reply abandoned")
  }

  func followUpSuggestions(
    in conversationID: UUID,
    after sourceMessageID: UUID
  ) -> [String] {
    guard settings.followUps.isEnabled,
      let state = followUpSuggestionsByConversationID[conversationID],
      state.sourceMessageID == sourceMessageID,
      conversation(withID: conversationID)?.messages.last?.id == sourceMessageID
    else {
      return []
    }
    return state.options
  }

  func dismissFollowUpSuggestions(in conversationID: UUID) {
    clearFollowUpSuggestions(in: conversationID)
  }

  func isGeneratingFollowUpSuggestions(
    in conversationID: UUID,
    after sourceMessageID: UUID
  ) -> Bool {
    settings.followUps.isEnabled
      && generatingFollowUpSourceMessageIDsByConversationID[conversationID] == sourceMessageID
  }

  private func clearFollowUpSuggestions(in conversationID: UUID) {
    followUpTasks[conversationID]?.cancel()
    followUpTasks[conversationID] = nil
    followUpTaskTokens[conversationID] = nil
    followUpSuggestionsByConversationID[conversationID] = nil
    generatingFollowUpSourceMessageIDsByConversationID[conversationID] = nil
  }

  private func clearAllFollowUpSuggestions() {
    for task in followUpTasks.values {
      task.cancel()
    }
    followUpTasks.removeAll()
    followUpTaskTokens.removeAll()
    followUpSuggestionsByConversationID.removeAll()
    generatingFollowUpSourceMessageIDsByConversationID.removeAll()
  }

  @Published var errorMessage: String?
  @Published var isUpdatingMemory = false
  @Published var isCompacting = false
  @Published var endpointStatuses: [UUID: EndpointConnectionState] = [:]
  @Published var endpointModels: [UUID: [String]] = [:]
  @Published var endpointVoices: [UUID: [String]] = [:]
  @Published var localMLXModelIDs: [String] = []
  @Published var mcpStatuses: [UUID: EndpointConnectionState] = [:]
  @Published var mcpTools: [UUID: [MCPToolDescriptor]] = [:]
  @Published var mcpResources: [UUID: [MCPResourceDescriptor]] = [:]
  @Published private(set) var toolCallApprovalRequests: [ToolCallApprovalRequest] = []
  @Published private(set) var longRunningOperationTimeoutRequests:
    [LongRunningOperationTimeoutRequest] = []
  @Published private(set) var draftStorageRevision = 0
  /// Cached Apple Intelligence availability message; nil means available.
  /// Refreshed on app launch and on scene activation, not per-render.
  @Published var appleAvailabilityReport: AppleFoundationAvailabilityReport
  @Published var appleAvailabilityMessage: String?
  @Published var openAPIServerState: OpenAPIServerRuntimeState = .stopped

  /// A launch request from a widget tap or App Intent (Action Button / Siri),
  /// consumed by the chat UI. Cleared once handled.
  @Published var pendingLaunchAction: LaunchCommand?
  /// Bumped when the share extension left pictures, voice messages or documents
  /// for the composer to import.
  @Published private(set) var sharedImportRequestID = 0
  private var queuedSharedItems: [SharedInboxItem] = []
  /// Conversation export files opened by iOS or handed over by the share
  /// extension. ContentView presents them one at a time.
  @Published private(set) var pendingConversationImportFiles: [PendingConversationImportFile] = []
  /// Bumped to ask the composer to take keyboard focus (e.g. after a widget tap).
  @Published private(set) var composerFocusRequestID = 0
  @Published private(set) var composerDraftReplacement: ComposerDraftReplacement?
  @Published private(set) var pendingMessageNavigation: MessageNavigationRequest?

  let streamingTextStore: StreamingTextStore
  lazy var locationService = LocationService()
  lazy var webxdcHub = WebXDCUpdateHub()
  @Published var activeWebXDCSession: WebXDCRunningSession?
  /// The in-app browser page behind the browser tools; nil until first used.
  @Published var browserSession: BrowserSession?
  private let responseHaptics = ResponseHaptics()
  private let openAPIServer = OpenAPIServer()
  private let persistence: PersistenceStore
  private var conversationDrafts: [UUID: String] = [:]
  private var conversationIndexByID: [UUID: Int] = [:]
  private var activeConversationPublicationKey: ActiveConversationPublicationKey?
  private(set) var hasLoadedPersistedSettings = false
  private var pendingSettingsSave = false
  private var pendingRememberedConversationIDBeforeSettingsLoad: UUID?
  private var hasLoadedPersistedDrafts = false
  private var pendingDraftSave = false
  private var dirtyDraftIDsBeforeLoad: Set<UUID> = []
  private var deletedDraftIDsBeforeLoad: Set<UUID> = []
  private var hasLoadedPersistedBookmarks = false
  private var pendingBookmarkSave = false
  private var dirtyBookmarkKeysBeforeLoad: Set<String> = []
  private var deletedBookmarkKeysBeforeLoad: Set<String> = []
  private var deletedBookmarkConversationIDsBeforeLoad: Set<UUID> = []
  private var clearedBookmarksBeforeLoad = false
  private var hasLoadedPersistedConversations = false
  private var pendingConversationSave = false
  private var dirtyConversationIDsBeforeLoad: Set<UUID> = []
  private var deletedConversationIDsBeforeLoad: Set<UUID> = []
  private var launchPlaceholderConversationID: UUID?
  private var conversationSelectionGeneration = 0
  private var conversationLoadTasks: [UUID: Task<Conversation?, Never>] = [:]
  private var dataGeneration = 0
  private var hasLoadedLocalMLXModels = false

  init(
    persistence: PersistenceStore = PersistenceStore(),
    streamingTextStore: StreamingTextStore = StreamingTextStore()
  ) {
    self.persistence = persistence
    self.streamingTextStore = streamingTextStore
    settings = .defaults
    conversations = []
    appleAvailabilityReport = .checking
    appleAvailabilityMessage = nil
    startFreshConversationForLaunch()
    startAgentSupervisorFeed()
    ResponseNotificationService.shared.openConversationHandler = { [weak self] conversationID in
      self?.handleLaunchCommand(.openConversation(id: conversationID))
    }
    Task { await loadStartupData() }
  }

  var currentConversation: Conversation? {
    activeConversation
  }

  var selectedConversationSummary: ConversationSummary? {
    guard let selectedConversationID else { return nil }
    return conversationSummary(withID: selectedConversationID)
  }

  var selectedConversationIsLoading: Bool {
    guard let selectedConversationID else { return false }
    return indexedConversationIndex(for: selectedConversationID) == nil
      && conversationSummaries.contains { $0.id == selectedConversationID }
  }

  var selectedConversationPreviewMessages: [ChatMessage] {
    selectedConversationSummary?.previewMessages.map(\.chatMessage) ?? []
  }

  var previousConversationSuggestions: [ConversationSummary] {
    guard settings.startupBehavior == .continueChats else { return [] }
    let suggestions =
      recentConversationSummaries
      .filter { $0.id != selectedConversationID && $0.hasMessages }
      .prefix(ConversationSummary.recentCacheLimit)
    return Array(suggestions.reversed())
  }

  var conversationFolders: [ConversationFolder] {
    [
      ConversationFolder.defaultFolder,
      ConversationFolder.iCloudFolder,
      ConversationFolder.archivedFolder,
    ] + settings.conversationFolders
  }

  var customConversationFolders: [ConversationFolder] {
    settings.conversationFolders
  }

  var selectedConversationFolderID: String {
    availableConversationFolderID(
      normalizedExistingConversationFolderID(settings.selectedConversationFolderID))
  }

  var selectedConversationFolder: ConversationFolder {
    conversationFolders.first { $0.id == selectedConversationFolderID }
      ?? ConversationFolder.defaultFolder
  }

  var iCloudConversationFolderIsAvailable: Bool {
    !settings.airplaneModeEnabled
  }

  func canUseConversationFolder(_ folderID: String) -> Bool {
    conversationFolderIsAvailable(normalizedExistingConversationFolderID(folderID))
  }

  func folderDisplayName(for folderID: String) -> String {
    conversationFolders.first { $0.id == folderID }?.displayName ?? "Default"
  }

  func conversationFolderDefaults(for folderID: String) -> ConversationFolderDefaults {
    let normalized = normalizedExistingConversationFolderID(folderID)
    return settings.conversationFolderDefaults[normalized] ?? ConversationFolderDefaults()
  }

  func setConversationFolderDefaults(_ defaults: ConversationFolderDefaults, for folderID: String) {
    let normalized = normalizedExistingConversationFolderID(folderID)
    let folderDefaults = normalizedConversationFolderDefaults(defaults)
    if folderDefaults.usesAppDefaults {
      settings.conversationFolderDefaults.removeValue(forKey: normalized)
    } else {
      settings.conversationFolderDefaults[normalized] = folderDefaults
    }
    if folderDefaults.workingFolder != nil, !settings.toolSettings.filesWorkspaceAccessEnabled {
      settings.toolSettings.filesWorkspaceAccessEnabled = true
    }
    saveSettings()
  }

  func clearConversationFolderDefaults(for folderID: String) {
    let normalized = normalizedExistingConversationFolderID(folderID)
    guard settings.conversationFolderDefaults.removeValue(forKey: normalized) != nil else { return }
    saveSettings()
  }

  func workingFolderReference(for conversation: Conversation) -> WorkingFolderReference? {
    FileWorkspaceTool.workingFolderReference(for: conversation, settings: settings)
  }

  func workingFolderDisplayName(for conversation: Conversation) -> String {
    FileWorkspaceTool.workspaceName(for: conversation, settings: settings)
  }

  /// Which of the three working folder choices the chat currently sits on.
  func workingFolderMode(for conversation: Conversation) -> ConversationWorkingFolderMode {
    guard conversation.enabledTools.contains(.files) else { return .disabled }
    return conversation.workingFolder == nil ? .inherited : .custom
  }

  /// Gives the current chat its own working folder. Selecting a folder also
  /// turns the Files tools on so the choice takes effect immediately; the user
  /// can still opt out from the tool picker later.
  func setCurrentConversationWorkingFolder(_ reference: WorkingFolderReference) {
    enableFilesTools { conversation in
      conversation.workingFolder = reference
    }
  }

  /// Drops the current chat's own folder so it falls back to its chat folder's
  /// default, else the built-in workspace, and makes sure the Files tools are
  /// on so that folder is actually reachable.
  func clearCurrentConversationWorkingFolder() {
    enableFilesTools { conversation in
      conversation.workingFolder = nil
    }
  }

  /// Turns the working folder off for the current chat by dropping its own
  /// folder and taking the Files tools out of the chat, so neither a custom
  /// folder nor the chat folder's default is reachable from it.
  func disableCurrentConversationWorkingFolder() {
    updateCurrentConversation { conversation in
      conversation.workingFolder = nil
      conversation.enabledTools.remove(.files)
    }
  }

  private func enableFilesTools(_ update: (inout Conversation) -> Void) {
    updateCurrentConversation { conversation in
      update(&conversation)
      conversation.toolsEnabled = true
      conversation.enabledTools.insert(.files)
    }
    guard !settings.toolSettings.filesWorkspaceAccessEnabled else { return }
    settings.toolSettings.filesWorkspaceAccessEnabled = true
    saveSettings()
  }

  /// Persists a re-created bookmark after the stored one went stale, wherever
  /// the working folder reference came from (chat override or folder default).
  func refreshWorkingFolderBookmark(conversationID: UUID, bookmarkData: Data) {
    if let index = conversations.firstIndex(where: { $0.id == conversationID }),
      conversations[index].workingFolder != nil
    {
      conversations[index].workingFolder?.bookmarkData = bookmarkData
      saveConversations()
      return
    }
    guard let conversation = conversation(withID: conversationID) else { return }
    let folderID = Conversation.normalizedFolderID(conversation.folderID)
    guard settings.conversationFolderDefaults[folderID]?.workingFolder != nil else { return }
    settings.conversationFolderDefaults[folderID]?.workingFolder?.bookmarkData = bookmarkData
    saveSettings()
  }

  func effectiveProviderConfiguration(forFolderID folderID: String)
    -> (provider: ProviderKind, endpointID: UUID?, modelID: String)
  {
    let normalized = normalizedExistingConversationFolderID(folderID)
    guard let defaults = settings.conversationFolderDefaults[normalized],
      let provider = defaults.provider
    else {
      return effectiveDefaultProviderConfiguration
    }

    let modelID = normalizedModelID(defaults.modelID)
    switch provider {
    case .apple:
      guard appleIntelligenceIsAvailable else {
        return (.mlx, nil, availableLocalMLXModelID(preferred: settings.localMLXModelID) ?? "")
      }
      return (.apple, nil, modelID)
    case .mlx:
      return (.mlx, nil, availableLocalMLXModelID(preferred: modelID) ?? "")
    case .openAICompatible:
      guard !settings.airplaneModeEnabled,
        let endpointID = defaults.endpointID,
        let endpoint = settings.openAIEndpoints.first(where: { $0.id == endpointID && $0.isEnabled })
      else {
        return effectiveDefaultProviderConfiguration
      }
      return (
        .openAICompatible,
        endpoint.id,
        modelID.isEmpty ? endpoint.defaultModel : modelID
      )
    }
  }

  func effectiveSystemPromptID(forFolderID folderID: String) -> UUID {
    let normalized = normalizedExistingConversationFolderID(folderID)
    let fallback =
      settings.systemPrompts.contains(where: { $0.id == settings.defaultSystemPromptID })
      ? settings.defaultSystemPromptID
      : (settings.systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id)
    guard let id = settings.conversationFolderDefaults[normalized]?.systemPromptID,
      settings.systemPrompts.contains(where: { $0.id == id })
    else {
      return fallback
    }
    return id
  }

  func selectConversationFolder(_ folderID: String) {
    let normalized = normalizedExistingConversationFolderID(folderID)
    guard conversationFolderIsAvailable(normalized) else { return }
    guard settings.selectedConversationFolderID != normalized else { return }
    settings.selectedConversationFolderID = normalized
    selectedConversationIDs.removeAll()
    saveSettings()
    if normalized == ConversationFolder.iCloudID {
      Task { await refreshPersistedConversationSummaries() }
    }
  }

  func ensureSelectedConversationFolderIsAvailable() {
    let normalized = normalizedExistingConversationFolderID(settings.selectedConversationFolderID)
    guard conversationFolderIsAvailable(normalized) else {
      settings.selectedConversationFolderID = ConversationFolder.defaultID
      selectedConversationIDs.removeAll()
      return
    }
    settings.selectedConversationFolderID = normalized
  }

  @discardableResult
  func createConversationFolder(named rawName: String) -> ConversationFolder? {
    guard let name = validatedConversationFolderName(rawName, excluding: nil) else { return nil }
    let folder = ConversationFolder(name: name)
    settings.conversationFolders.append(folder)
    saveSettings()
    return folder
  }

  func renameConversationFolder(id: String, to rawName: String) {
    guard let index = settings.conversationFolders.firstIndex(where: { $0.id == id }) else {
      errorMessage = "This folder no longer exists."
      return
    }
    guard let name = validatedConversationFolderName(rawName, excluding: id) else { return }
    settings.conversationFolders[index].name = name
    saveSettings()
  }

  func setConversationFolderIcon(id: String, to icon: String?) {
    guard let index = settings.conversationFolders.firstIndex(where: { $0.id == id }) else {
      errorMessage = "This folder no longer exists."
      return
    }
    settings.conversationFolders[index].icon = ConversationFolder.normalizedIcon(icon)
    saveSettings()
  }

  func setConversationFolderTint(id: String, to tint: ConversationFolderTint?) {
    guard let index = settings.conversationFolders.firstIndex(where: { $0.id == id }) else {
      errorMessage = "This folder no longer exists."
      return
    }
    guard settings.conversationFolders[index].tint != tint else { return }
    settings.conversationFolders[index].tint = tint
    saveSettings()
  }

  func deleteConversationFolder(id: String) async {
    guard !ConversationFolder.reservedIDs.contains(id) else { return }
    guard settings.conversationFolders.contains(where: { $0.id == id }) else {
      errorMessage = "This folder no longer exists."
      return
    }
    await loadStoredConversationsForSearch()
    settings.conversationFolders.removeAll { $0.id == id }
    settings.conversationFolderDefaults.removeValue(forKey: id)
    if settings.selectedConversationFolderID == id {
      settings.selectedConversationFolderID = ConversationFolder.defaultID
    }
    var changedConversations = false
    for index in conversations.indices where conversations[index].folderID == id {
      conversations[index].folderID = ConversationFolder.defaultID
      conversations[index].updatedAt = Date()
      changedConversations = true
    }
    if changedConversations {
      sortConversations()
      saveConversations()
    }
    saveSettings()
  }

  private func validatedConversationFolderName(_ rawName: String, excluding id: String?)
    -> String?
  {
    let name = ConversationFolder.normalizedCustomName(rawName)
    guard !name.isEmpty else {
      errorMessage = "Specify a folder name."
      return nil
    }
    let normalizedName = normalizedConversationFolderName(name)
    if conversationFolders.contains(where: { folder in
      folder.id != id && normalizedConversationFolderName(folder.displayName) == normalizedName
    }) {
      errorMessage = "A folder named \"\(name)\" already exists."
      return nil
    }
    return name
  }

  private func normalizedConversationFolderName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private func normalizedExistingConversationFolderID(_ folderID: String?) -> String {
    let normalized = Conversation.normalizedFolderID(folderID)
    return Set(conversationFolders.map(\.id)).contains(normalized)
      ? normalized : ConversationFolder.defaultID
  }

  private func availableConversationFolderID(_ folderID: String) -> String {
    conversationFolderIsAvailable(folderID) ? folderID : ConversationFolder.defaultID
  }

  private func conversationFolderIsAvailable(_ folderID: String) -> Bool {
    folderID != ConversationFolder.iCloudID || iCloudConversationFolderIsAvailable
  }

  private func normalizeConversationFoldersForCurrentData() {
    var knownIDs = Set(
      [ConversationFolder.defaultID, ConversationFolder.iCloudID, ConversationFolder.archivedID]
        + settings.conversationFolders.map(\.id))
    var existingNames = Set(
      conversationFolders.map { normalizedConversationFolderName($0.displayName) })
    let folderIDs = Set(conversations.map(\.folderID) + conversationSummaries.map(\.folderID))
    var changed = false

    for folderID in folderIDs.sorted()
    where !folderID.isEmpty
      && !ConversationFolder.reservedIDs.contains(folderID)
      && !knownIDs.contains(folderID) {
      let name = nextImportedConversationFolderName(existingNames: &existingNames)
      settings.conversationFolders.append(ConversationFolder(id: folderID, name: name))
      knownIDs.insert(folderID)
      changed = true
    }

    let selectedFolderID = Conversation.normalizedFolderID(settings.selectedConversationFolderID)
    if !knownIDs.contains(selectedFolderID) || !conversationFolderIsAvailable(selectedFolderID) {
      settings.selectedConversationFolderID = ConversationFolder.defaultID
      changed = true
    }

    let normalizedDefaults = AppSettings.normalizedConversationFolderDefaults(
      settings.conversationFolderDefaults,
      knownFolderIDs: knownIDs)
    if normalizedDefaults != settings.conversationFolderDefaults {
      settings.conversationFolderDefaults = normalizedDefaults
      changed = true
    }

    if changed {
      saveSettings()
    }
  }

  private func nextImportedConversationFolderName(existingNames: inout Set<String>) -> String {
    var index = 1
    while true {
      let name = index == 1 ? "Imported Folder" : "Imported Folder \(index)"
      if existingNames.insert(normalizedConversationFolderName(name)).inserted {
        return name
      }
      index += 1
    }
  }

  private func normalizedConversationFolderDefaults(
    _ defaults: ConversationFolderDefaults
  ) -> ConversationFolderDefaults {
    var normalized = defaults
    normalized.modelID = normalizedModelID(normalized.modelID)
    if let id = normalized.systemPromptID,
      !settings.systemPrompts.contains(where: { $0.id == id })
    {
      normalized.systemPromptID = nil
    }
    switch normalized.provider {
    case nil:
      normalized.endpointID = nil
      normalized.modelID = ""
    case .apple:
      normalized.endpointID = nil
    case .mlx:
      normalized.endpointID = nil
      normalized.modelID = availableLocalMLXModelID(preferred: normalized.modelID)
        ?? normalized.modelID
    case .openAICompatible:
      guard let endpointID = normalized.endpointID,
        settings.openAIEndpoints.contains(where: { $0.id == endpointID && $0.isEnabled })
      else {
        normalized.provider = nil
        normalized.endpointID = nil
        normalized.modelID = ""
        break
      }
    }
    return normalized
  }

  var appleIntelligenceIsAvailable: Bool {
    appleAvailabilityReport.isAvailable
  }

  var effectiveDefaultProviderConfiguration:
    (provider: ProviderKind, endpointID: UUID?, modelID: String)
  {
    let configuration = settings.defaultProviderConfiguration
    guard configuration.provider == .apple, !appleIntelligenceIsAvailable else {
      return configuration
    }
    return (.mlx, nil, settings.localMLXModelID)
  }

  func newConversation() {
    let inheritedLanguageOverride = currentConversation?.effectiveLanguageOverrideIdentifier
    if let current = currentConversation,
      current.messages.isEmpty
    {
      selectedConversationIDs.removeAll()
      if isDisposableNewConversation(current),
        !conversationUsesNewConversationDefaults(current)
      {
        discardSelectedDisposableConversation()
        createAndSelectNewConversation(languageOverrideIdentifier: inheritedLanguageOverride)
      }
      return
    }
    discardSelectedDisposableConversation()
    createAndSelectNewConversation(languageOverrideIdentifier: inheritedLanguageOverride)
  }

  private func startFreshConversationForLaunch() {
    let conversation = makeNewConversation()
    launchPlaceholderConversationID = conversation.id
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id, remember: false)
    selectedConversationIDs.removeAll()
  }

  private func loadStartupData() async {
    let generation = dataGeneration
    await Task.yield()

    let persistence = self.persistence
    let settingsTask = Task.detached(priority: .userInitiated) {
      persistence.loadSettings()
    }
    let draftsTask = Task.detached(priority: .utility) {
      persistence.loadDrafts()
    }
    let bookmarksTask = Task.detached(priority: .utility) {
      persistence.loadBookmarks()
    }

    let loadedSettings = await settingsTask.value
    guard generation == dataGeneration else { return }
    applyLoadedSettings(loadedSettings)

    // Publish the tiny device-local cache before touching iCloud or the full conversation index.
    // The complete summary load below will merge cloud and local results afterward.
    let recentSummaries = await Task.detached(priority: .userInitiated) {
      persistence.loadLocalRecentConversationSummaries()
    }.value
    guard generation == dataGeneration else { return }
    mergeLoadedSummaries(recentSummaries)

    refreshLocalMLXModelsInBackground()
    refreshConfiguredEndpointsInBackground()

    let summaries = await Task.detached(priority: .utility) {
      persistence.loadConversationSummaries()
    }.value
    guard generation == dataGeneration else { return }
    mergeLoadedSummaries(summaries)

    await loadStartupConversationIfNeeded()
    guard generation == dataGeneration else { return }
    warmEnabledMCPServersInBackground(for: selectedConversationID)

    let loadedDrafts = await draftsTask.value
    guard generation == dataGeneration else { return }
    applyLoadedDrafts(loadedDrafts)

    let loadedBookmarks = await bookmarksTask.value
    guard generation == dataGeneration else { return }
    applyLoadedBookmarks(loadedBookmarks)

    let deviceOnlyApple = settings.airplaneModeEnabled
    let availabilityTask = Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport(deviceOnly: deviceOnlyApple)
    }
    guard generation == dataGeneration else { return }
    let availabilityReport = await availabilityTask.value
    applyAppleAvailabilityReport(availabilityReport)
  }

  private func applyLoadedSettings(_ loadedSettings: AppSettings) {
    guard !hasLoadedPersistedSettings else { return }
    settings = loadedSettings
    if let pendingRememberedConversationIDBeforeSettingsLoad {
      settings.lastSelectedConversationID = pendingRememberedConversationIDBeforeSettingsLoad
      self.pendingRememberedConversationIDBeforeSettingsLoad = nil
    }
    hasLoadedPersistedSettings = true
    applyBackgroundActivitySettings()
    refreshLaunchPlaceholderDefaultsIfNeeded()
    if pendingSettingsSave {
      pendingSettingsSave = false
      saveSettings()
    }
  }

  private func applyLoadedDrafts(_ loadedDrafts: [UUID: String]) {
    guard !hasLoadedPersistedDrafts else { return }
    var mergedDrafts = loadedDrafts
    for id in deletedDraftIDsBeforeLoad {
      mergedDrafts.removeValue(forKey: id)
    }
    for id in dirtyDraftIDsBeforeLoad {
      if let text = conversationDrafts[id], !text.isEmpty {
        mergedDrafts[id] = text
      } else {
        mergedDrafts.removeValue(forKey: id)
      }
    }
    conversationDrafts = mergedDrafts
    hasLoadedPersistedDrafts = true
    dirtyDraftIDsBeforeLoad.removeAll()
    deletedDraftIDsBeforeLoad.removeAll()
    draftStorageRevision += 1
    if pendingDraftSave {
      pendingDraftSave = false
      persistDrafts()
    }
  }

  private func applyLoadedBookmarks(_ loadedBookmarks: [MessageBookmark]) {
    guard !hasLoadedPersistedBookmarks else { return }
    var byKey: [String: MessageBookmark] = [:]
    if !clearedBookmarksBeforeLoad {
      for bookmark in loadedBookmarks
      where !deletedBookmarkConversationIDsBeforeLoad.contains(bookmark.conversationID)
        && !deletedBookmarkKeysBeforeLoad.contains(bookmark.storageKey)
      {
        byKey[bookmark.storageKey] = bookmark
      }
    }
    for bookmark in messageBookmarks
    where dirtyBookmarkKeysBeforeLoad.contains(bookmark.storageKey)
    {
      byKey[bookmark.storageKey] = bookmark
    }
    messageBookmarks = Self.sortedMessageBookmarks(Array(byKey.values))
    hasLoadedPersistedBookmarks = true
    dirtyBookmarkKeysBeforeLoad.removeAll()
    deletedBookmarkKeysBeforeLoad.removeAll()
    deletedBookmarkConversationIDsBeforeLoad.removeAll()
    clearedBookmarksBeforeLoad = false
    if pendingBookmarkSave {
      pendingBookmarkSave = false
      saveBookmarks()
    }
  }

  private func refreshLaunchPlaceholderDefaultsIfNeeded() {
    guard let placeholderID = launchPlaceholderConversationID,
      let index = indexedConversationIndex(for: placeholderID),
      isDisposableNewConversation(conversations[index])
    else {
      return
    }

    rebuildConversationFromDefaults(at: index)
    if selectedConversationID == placeholderID {
      setSelectedConversationID(placeholderID, remember: false)
    }
  }

  /// Replaces an empty conversation with one made from the current defaults,
  /// keeping its identity and dates.
  private func rebuildConversationFromDefaults(at index: Int) {
    let previous = conversations[index]
    var refreshed = makeNewConversation()
    refreshed.id = previous.id
    refreshed.title = previous.title
    refreshed.createdAt = previous.createdAt
    refreshed.updatedAt = previous.updatedAt
    refreshed.languageOverrideIdentifier = previous.languageOverrideIdentifier
    conversations[index] = refreshed
    sortConversations()
  }

  private func loadStartupConversationIfNeeded() async {
    let placeholderID = launchPlaceholderConversationID
    launchPlaceholderConversationID = nil
    guard settings.startupBehavior == .lastConversation,
      selectedConversationID == placeholderID,
      startupPlaceholderIsStillDisposable(placeholderID),
      let id = startupConversationID(excluding: placeholderID)
    else {
      return
    }
    await ensureConversationLoaded(id)
    guard conversation(withID: id) != nil else { return }
    setSelectedConversationID(id)
    selectedConversationIDs.removeAll()
    _ = discardDisposableConversation(id: placeholderID)
  }

  private func startupPlaceholderIsStillDisposable(_ id: UUID?) -> Bool {
    guard let id,
      let conversation = conversation(withID: id)
    else {
      return true
    }
    return isDisposableNewConversation(conversation)
  }

  private func startupConversationID(excluding excludedID: UUID?) -> UUID? {
    if let rememberedID = settings.lastSelectedConversationID,
      let remembered = conversationSummary(withID: rememberedID),
      isStartupConversationCandidate(remembered, excluding: excludedID, allowArchived: true)
    {
      return rememberedID
    }

    return
      conversationSummaries
      .filter { isStartupConversationCandidate($0, excluding: excludedID, allowArchived: false) }
      .max { lhs, rhs in
        if lhs.updatedAt != rhs.updatedAt {
          return lhs.updatedAt < rhs.updatedAt
        }
        return lhs.createdAt < rhs.createdAt
      }?
      .id
  }

  private func conversationSummary(withID id: UUID) -> ConversationSummary? {
    if let conversation = conversation(withID: id) {
      return ConversationSummary(conversation: conversation)
    }
    return conversationSummaries.first { $0.id == id }
  }

  private func isStartupConversationCandidate(
    _ summary: ConversationSummary,
    excluding excludedID: UUID?,
    allowArchived: Bool
  ) -> Bool {
    summary.id != excludedID
      && summary.hasMessages
      && (allowArchived || !summary.isArchived)
  }

  private func makeNewConversation() -> Conversation {
    let folderID = selectedConversationFolderID
    let defaultProvider = effectiveProviderConfiguration(forFolderID: folderID)
    var conversation = Conversation()
    conversation.folderID = folderID
    conversation.provider = defaultProvider.provider
    if defaultProvider.provider == .mlx {
      conversation.modelID = fallbackLocalMLXModelID(preferred: defaultProvider.modelID)
    } else {
      conversation.modelID = defaultProvider.modelID
    }
    conversation.endpointID = defaultProvider.endpointID
    conversation.reasoningLevel = settings.defaultReasoningLevel
    conversation.systemPromptID = effectiveSystemPromptID(forFolderID: folderID)
    conversation.enabledTools = settings.defaultEnabledTools
    conversation.enabledMCPServers = settings.defaultEnabledMCPServers
    conversation.enabledMCPTools = settings.defaultEnabledMCPTools
    conversation.usesStreaming = settings.streamByDefault
    conversation.showThinking = settings.showThinkingByDefault
    return conversation
  }

  private func createAndSelectNewConversation(languageOverrideIdentifier: String? = nil) {
    var conversation = makeNewConversation()
    conversation.languageOverrideIdentifier = Conversation.normalizedLanguageOverride(
      languageOverrideIdentifier)
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id)
    selectedConversationIDs.removeAll()
    saveConversations()
  }

  private func setSelectedConversationID(_ id: UUID?, remember: Bool = true) {
    selectedConversationID = id
    if let id {
      updateConversationUnreadState(id: id, isUnread: false)
    }
    publishActiveConversationIfNeeded(force: true)
    if remember {
      rememberSelectedConversationID(id)
    }
  }

  private func rememberSelectedConversationID(_ id: UUID?) {
    guard settings.lastSelectedConversationID != id else { return }
    settings.lastSelectedConversationID = id
    if !hasLoadedPersistedSettings {
      pendingRememberedConversationIDBeforeSettingsLoad = id
    }
    saveSettings()
  }

  private func conversationUsesNewConversationDefaults(_ conversation: Conversation) -> Bool {
    let defaults = makeNewConversation()
    return conversation.provider == defaults.provider
      && conversation.endpointID == defaults.endpointID
      && normalizedModelID(conversation.modelID) == normalizedModelID(defaults.modelID)
      && conversation.systemPromptID == defaults.systemPromptID
      && conversation.folderID == defaults.folderID
      && conversation.toolsEnabled == defaults.toolsEnabled
      && conversation.enabledTools == defaults.enabledTools
      && conversation.enabledMCPServers == defaults.enabledMCPServers
      && conversation.enabledMCPTools == defaults.enabledMCPTools
      && conversation.usesStreaming == defaults.usesStreaming
      && conversation.showThinking == defaults.showThinking
      && conversation.reasoningLevel == defaults.reasoningLevel
      && conversation.disabledMCPTools == defaults.disabledMCPTools
      && conversation.effectiveLanguageOverrideIdentifier
        == defaults.effectiveLanguageOverrideIdentifier
  }

  private func normalizedModelID(_ modelID: String) -> String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func selectConversation(id: UUID) async {
    conversationSelectionGeneration += 1
    let selectionGeneration = conversationSelectionGeneration
    let previousID = selectedConversationID
    if indexedConversationIndex(for: id) == nil,
      let summary = conversationSummaries.first(where: { $0.id == id })
    {
      setSelectedConversationID(id)
      selectedConversationIDs.removeAll()
      selectConversationFolder(summary.folderID)
    }
    await ensureConversationLoaded(id)
    guard selectionGeneration == conversationSelectionGeneration else { return }
    guard let index = indexedConversationIndex(for: id) else {
      if previousID != id, selectedConversationID == id {
        setSelectedConversationID(previousID)
      }
      return
    }
    setSelectedConversationID(id)
    selectConversationFolder(conversations[index].folderID)
    await restoreAgentProcessRecordsIfNeeded(for: conversations[index])
    ResponseNotificationService.shared.clearNotifications(for: id)
    if previousID != id, discardDisposableConversation(id: previousID) {
      saveConversations()
    }
    if previousID != id {
      warmEnabledMCPServersInBackground(for: id)
    }
  }

  func preloadConversation(id: UUID) async {
    await ensureConversationLoaded(id)
  }

  func loadStoredConversationsForSearch() async {
    guard !hasLoadedPersistedConversations else { return }
    let generation = dataGeneration
    let persistence = self.persistence
    let loadedConversations = await Task.detached(priority: .userInitiated) {
      persistence.loadConversations()
    }.value
    guard generation == dataGeneration, !hasLoadedPersistedConversations else { return }
    mergeLoadedConversations(loadedConversations)
  }

  private func refreshPersistedConversationSummaries() async {
    let generation = dataGeneration
    let persistence = self.persistence
    let summaries = await Task.detached(priority: .userInitiated) {
      persistence.loadConversationSummaries()
    }.value
    guard generation == dataGeneration else { return }
    mergeLoadedSummaries(summaries)
  }

  func toggleArchive(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let index = indexedConversationIndex(for: id) else { return }
    let destination =
      conversations[index].isArchived ? ConversationFolder.defaultID : ConversationFolder.archivedID
    moveLoadedConversations(Set([id]), to: destination)
  }

  func moveConversation(id: UUID, to folderID: String) async {
    await ensureConversationLoaded(id)
    guard indexedConversationIndex(for: id) != nil else { return }
    moveLoadedConversations(Set([id]), to: folderID)
  }

  func moveConversations(_ ids: Set<UUID>, to folderID: String) async {
    guard !ids.isEmpty else { return }
    for id in ids {
      await ensureConversationLoaded(id)
    }
    moveLoadedConversations(ids, to: folderID)
  }

  private func moveLoadedConversations(_ ids: Set<UUID>, to folderID: String) {
    let destination = normalizedExistingConversationFolderID(folderID)
    guard conversationFolderIsAvailable(destination) else { return }
    var changed = false
    for index in conversations.indices where ids.contains(conversations[index].id) {
      guard conversations[index].folderID != destination else { continue }
      conversations[index].folderID = destination
      conversations[index].updatedAt = Date()
      changed = true
    }
    guard changed else { return }
    sortConversations()
    saveConversations()

    // Keep the sidebar focused on the active chat after it is moved; otherwise
    // the displayed conversation would disappear from the selected folder.
    if let activeConversationID = activeConversation?.id, ids.contains(activeConversationID) {
      selectConversationFolder(destination)
    }
  }

  func togglePin(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let index = indexedConversationIndex(for: id) else { return }
    conversations[index].isPinned.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  var bookmarkedMessages: [BookmarkedMessage] {
    let conversationsByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    let summariesByID = Dictionary(uniqueKeysWithValues: conversationSummaries.map { ($0.id, $0) })
    return messageBookmarks.compactMap { bookmark in
      guard let conversation = conversationsByID[bookmark.conversationID],
        let message = conversation.messages.first(where: { $0.id == bookmark.messageID })
      else {
        return nil
      }
      return BookmarkedMessage(
        bookmark: bookmark,
        message: message,
        conversationTitle: summariesByID[bookmark.conversationID]?.displayTitle
          ?? conversation.displayTitle)
    }
  }

  func isMessageBookmarked(_ messageID: UUID, in conversationID: UUID) -> Bool {
    messageBookmarks.contains {
      $0.conversationID == conversationID && $0.messageID == messageID
    }
  }

  func toggleMessageBookmark(_ message: ChatMessage, in conversationID: UUID) {
    if let index = messageBookmarks.firstIndex(where: {
      $0.conversationID == conversationID && $0.messageID == message.id
    }) {
      let removed = messageBookmarks.remove(at: index)
      noteDeletedBookmarkBeforeLoad(removed)
    } else {
      let bookmark = MessageBookmark(
        conversationID: conversationID,
        messageID: message.id,
        createdAt: message.createdAt)
      messageBookmarks.append(bookmark)
      noteDirtyBookmarkBeforeLoad(bookmark)
    }
    messageBookmarks = Self.sortedMessageBookmarks(messageBookmarks)
    saveBookmarks()
  }

  func toggleBookmarkPin(conversationID: UUID, messageID: UUID) {
    guard
      let index = messageBookmarks.firstIndex(where: {
        $0.conversationID == conversationID && $0.messageID == messageID
      })
    else { return }
    messageBookmarks[index].isPinned.toggle()
    noteDirtyBookmarkBeforeLoad(messageBookmarks[index])
    messageBookmarks = Self.sortedMessageBookmarks(messageBookmarks)
    saveBookmarks()
  }

  func removeMessageBookmark(conversationID: UUID, messageID: UUID) {
    guard
      let bookmark = messageBookmarks.first(where: {
        $0.conversationID == conversationID && $0.messageID == messageID
      })
    else { return }
    messageBookmarks.removeAll { $0.storageKey == bookmark.storageKey }
    noteDeletedBookmarkBeforeLoad(bookmark)
    saveBookmarks()
  }

  func requestNavigationToMessage(_ messageID: UUID, in conversationID: UUID) {
    pendingMessageNavigation = MessageNavigationRequest(
      conversationID: conversationID,
      messageID: messageID)
  }

  func consumeMessageNavigationRequest(id: UUID) {
    guard pendingMessageNavigation?.id == id else { return }
    pendingMessageNavigation = nil
  }

  func setConversationUnread(id: UUID, isUnread: Bool) async {
    await ensureConversationLoaded(id)
    updateConversationUnreadState(id: id, isUnread: isUnread)
  }

  func markConversationRead(id: UUID) {
    updateConversationUnreadState(id: id, isUnread: false)
    ResponseNotificationService.shared.clearNotifications(for: id)
  }

  private func updateConversationUnreadState(id: UUID, isUnread: Bool) {
    if let index = indexedConversationIndex(for: id) {
      guard conversations[index].isUnread != isUnread else { return }
      conversations[index].isUnread = isUnread
      upsertSummary(for: conversations[index])
      saveConversations()
      return
    }

    guard let index = conversationSummaries.firstIndex(where: { $0.id == id }),
      conversationSummaries[index].isUnread != isUnread
    else {
      return
    }
    conversationSummaries[index].isUnread = isUnread
    refreshRecentConversationSummaries()
    persistence.saveConversationSummaries(conversationSummaries)
  }

  func cloneConversation(id: UUID) async {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return }
    cloneConversation(conversation)
  }

  private func ensureConversationLoaded(_ id: UUID) async {
    guard indexedConversationIndex(for: id) == nil else { return }
    let loadTask: Task<Conversation?, Never>
    if let existingTask = conversationLoadTasks[id] {
      loadTask = existingTask
    } else {
      let persistence = self.persistence
      let task = Task.detached(priority: .userInitiated) {
        persistence.loadConversation(id: id)
      }
      conversationLoadTasks[id] = task
      loadTask = task
    }

    let loadedConversation = await loadTask.value
    conversationLoadTasks[id] = nil
    guard var conversation = loadedConversation else {
      return
    }
    guard indexedConversationIndex(for: id) == nil else { return }
    let normalizedProvider = normalizeUnavailableAppleProviderIfNeeded(in: &conversation)
    let insertionIndex = conversations.firstIndex {
      Self.conversationPrecedes(conversation, $0)
    } ?? conversations.endIndex
    conversations.insert(conversation, at: insertionIndex)
    rebuildConversationIndexes()
    if normalizedProvider {
      saveConversations()
    }

    guard !conversationSummaries.contains(where: { $0.id == id }) else { return }
    let summary = ConversationSummary(conversation: conversation)
    let summaryInsertionIndex = conversationSummaries.firstIndex {
      Self.summaryPrecedes(summary, $0)
    } ?? conversationSummaries.endIndex
    conversationSummaries.insert(summary, at: summaryInsertionIndex)
    refreshRecentConversationSummaries()
    persistence.saveConversationSummaries(conversationSummaries)
  }

  private func normalizeUnavailableAppleProviderIfNeeded(
    in conversation: inout Conversation
  ) -> Bool {
    guard appleAvailabilityReport.kind != .checking,
      !appleIntelligenceIsAvailable,
      conversation.provider == .apple
    else {
      return false
    }
    conversation.provider = .mlx
    conversation.endpointID = nil
    conversation.modelID = fallbackLocalMLXModelID(preferred: settings.localMLXModelID)
    return true
  }

  func draftText(for conversationID: UUID?) -> String {
    guard let conversationID else { return "" }
    return conversationDrafts[conversationID] ?? ""
  }

  func setDraftText(_ text: String, for conversationID: UUID?) {
    guard let conversationID else { return }
    let previous = conversationDrafts[conversationID] ?? ""
    guard previous != text else { return }
    if text.isEmpty {
      conversationDrafts.removeValue(forKey: conversationID)
      if !hasLoadedPersistedDrafts {
        deletedDraftIDsBeforeLoad.insert(conversationID)
        dirtyDraftIDsBeforeLoad.remove(conversationID)
      }
    } else {
      conversationDrafts[conversationID] = text
      if !hasLoadedPersistedDrafts {
        dirtyDraftIDsBeforeLoad.insert(conversationID)
        deletedDraftIDsBeforeLoad.remove(conversationID)
      }
    }
    persistDrafts()
    if previous.isEmpty {
      // A draft keeps its conversation from being disposable, so make sure the
      // conversation reaches disk too; otherwise a restored draft could point
      // at a conversation that never existed there.
      saveConversations()
    }
  }

  private func persistDrafts() {
    guard hasLoadedPersistedDrafts else {
      pendingDraftSave = true
      return
    }
    persistence.saveDrafts(conversationDrafts)
  }

  func updateCurrentConversation(_ update: (inout Conversation) -> Void) {
    guard let index = currentConversationIndex else { return }
    update(&conversations[index])
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
  }

  func updateCurrentConversationSettings(_ update: (inout Conversation) -> Void) {
    guard let index = currentConversationIndex else { return }
    var conversation = conversations[index]
    update(&conversation)
    conversations[index] = conversation
    saveConversations()
  }

  func renameCurrentConversation(to rawTitle: String) {
    guard let id = selectedConversationID else { return }
    renameLoadedConversation(id: id, to: rawTitle)
  }

  func renameConversation(id: UUID, to rawTitle: String) async {
    await ensureConversationLoaded(id)
    renameLoadedConversation(id: id, to: rawTitle)
  }

  private func renameLoadedConversation(id: UUID, to rawTitle: String) {
    guard let index = indexedConversationIndex(for: id) else { return }
    conversations[index].title = savedConversationTitle(rawTitle)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
  }

  private func savedConversationTitle(_ rawTitle: String) -> String {
    let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? AgentChat.placeholderTitle : trimmed
  }

  func setCurrentConversationLanguageOverride(_ identifier: String?) {
    guard currentConversationIndex != nil else { return }
    let normalized = Conversation.normalizedLanguageOverride(identifier)
    updateCurrentConversation { conversation in
      conversation.languageOverrideIdentifier = normalized
    }
    if let normalized {
      settings.recordRecentChatLanguage(normalized)
      saveSettings()
    }
  }

  func deleteMessage(_ message: ChatMessage) {
    guard let index = currentConversationIndex else { return }
    let conversationID = conversations[index].id
    let removedMessages = conversations[index].messages.filter { $0.id == message.id }
    guard !removedMessages.isEmpty else { return }
    clearStreamingText(for: removedMessages)
    conversations[index].messages.removeAll { $0.id == message.id }
    removeBookmarks(for: removedMessages, in: conversationID)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
    clearFollowUpSuggestions(in: conversationID)
  }

  func deleteMessages(_ ids: Set<UUID>) {
    guard let index = currentConversationIndex, !ids.isEmpty else { return }
    let conversationID = conversations[index].id
    let removedMessages = conversations[index].messages.filter { ids.contains($0.id) }
    guard !removedMessages.isEmpty else { return }
    clearStreamingText(for: removedMessages)
    conversations[index].messages.removeAll { ids.contains($0.id) }
    removeBookmarks(for: removedMessages, in: conversationID)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
    clearFollowUpSuggestions(in: conversationID)
  }

  func clearAllConversations() {
    let removedIDs = Set(conversationSummaries.map(\.id))
    let removedMessages = voiceRecordingMessages(in: removedIDs)
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.formUnion(removedIDs)
    }
    for id in removedIDs {
      responseTasks[id]?.cancel()
      responseTasks[id] = nil
      responseTaskTokens[id] = nil
      endResponseBackgroundTask(for: id)
      respondingConversationIDs.remove(id)
      activityTurnAbandoned(conversationID: id)
    }
    stopAllAgentProcesses()
    clearAllFollowUpSuggestions()
    conversationDrafts.removeAll()
    queuedUserMessagesByConversationID.removeAll()
    if !hasLoadedPersistedDrafts {
      deletedDraftIDsBeforeLoad.formUnion(removedIDs)
      dirtyDraftIDsBeforeLoad.subtract(removedIDs)
    }
    draftStorageRevision += 1
    persistDrafts()
    streamingTextStore.removeAll()
    clearMessageBookmarks()
    conversations.removeAll()
    rebuildConversationIndexes()
    conversationSummaries.removeAll()
    refreshRecentConversationSummaries()
    setSelectedConversationID(nil)
    selectedConversationIDs.removeAll()
    persistence.deleteConversationFiles(ids: removedIDs)
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
    newConversation()
  }

  func factoryReset() {
    dataGeneration += 1
    for task in responseTasks.values {
      task.cancel()
    }
    responseTasks.removeAll()
    responseTaskTokens.removeAll()
    clearAllFollowUpSuggestions()
    endAllResponseBackgroundTasks()
    for id in respondingConversationIDs {
      activityTurnAbandoned(conversationID: id)
    }
    stopAllAgentProcesses(reason: "Factory reset")
    respondingConversationIDs.removeAll()
    queuedUserMessagesByConversationID.removeAll()
    conversationDrafts.removeAll()
    messageBookmarks.removeAll()
    streamingTextStore.removeAll()
    settings = .defaults
    conversations.removeAll()
    conversationSummaries.removeAll()
    refreshRecentConversationSummaries()
    setSelectedConversationID(nil)
    selectedConversationIDs.removeAll()
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
    errorMessage = nil
    isUpdatingMemory = false
    isCompacting = false
    hasLoadedPersistedSettings = true
    pendingSettingsSave = false
    pendingRememberedConversationIDBeforeSettingsLoad = nil
    hasLoadedPersistedDrafts = true
    pendingDraftSave = false
    dirtyDraftIDsBeforeLoad.removeAll()
    deletedDraftIDsBeforeLoad.removeAll()
    draftStorageRevision += 1
    hasLoadedPersistedBookmarks = true
    pendingBookmarkSave = false
    dirtyBookmarkKeysBeforeLoad.removeAll()
    deletedBookmarkKeysBeforeLoad.removeAll()
    deletedBookmarkConversationIDsBeforeLoad.removeAll()
    clearedBookmarksBeforeLoad = false
    hasLoadedPersistedConversations = true
    pendingConversationSave = false
    dirtyConversationIDsBeforeLoad.removeAll()
    deletedConversationIDsBeforeLoad.removeAll()
    rebuildConversationIndexes()
    persistence.factoryReset()
    createInitialConversationIfNeeded()
  }

  func toggleArchive(_ conversation: Conversation) {
    guard let index = indexedConversationIndex(for: conversation.id) else { return }
    let destination =
      conversations[index].isArchived ? ConversationFolder.defaultID : ConversationFolder.archivedID
    moveLoadedConversations(Set([conversation.id]), to: destination)
  }

  func resubmit(_ message: ChatMessage) async {
    guard message.role == .user, !isResponding else { return }
    let cleaned = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty || !message.attachments.isEmpty else { return }
    _ = await send(
      prompt: cleaned,
      displayText: message.displayText,
      attachments: message.attachments)
  }

  func restartFromScratch(with message: ChatMessage) async {
    guard let index = currentConversationIndex else { return }
    let conversationID = conversations[index].id
    guard let source = restartSourceMessage(for: message),
      let prompt = restartPrompt(from: source)
    else { return }

    abandonResponse(in: conversationID)

    guard let currentIndex = indexedConversationIndex(for: conversationID) else { return }
    let removedMessages = conversations[currentIndex].messages
    clearStreamingText(for: removedMessages)
    conversations[currentIndex].messages.removeAll()
    removeBookmarks(for: removedMessages, in: conversationID)
    conversations[currentIndex].title = AgentChat.placeholderTitle
    conversations[currentIndex].updatedAt = Date()
    upsertSummary(for: conversations[currentIndex])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)

    _ = await send(prompt: prompt, displayText: source.displayText, attachments: source.attachments)
  }

  func startNewConversation(with message: ChatMessage) async {
    guard let prompt = restartPrompt(from: message) else { return }

    let source = currentConversation
    discardSelectedDisposableConversation()
    var conversation = makeNewConversation()
    if let source {
      conversation.provider = source.provider
      conversation.modelID = source.modelID
      conversation.endpointID = source.endpointID
      conversation.systemPromptID = source.systemPromptID
      conversation.toolsEnabled = source.toolsEnabled
      conversation.enabledTools = source.enabledTools
      conversation.enabledMCPServers = source.enabledMCPServers
      conversation.enabledMCPTools = source.enabledMCPTools
      conversation.usesStreaming = source.usesStreaming
      conversation.disabledMCPTools = source.disabledMCPTools
      conversation.reasoningLevel = source.reasoningLevel
      conversation.showThinking = source.showThinking
      conversation.languageOverrideIdentifier = source.effectiveLanguageOverrideIdentifier
    }
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id)
    selectedConversationIDs.removeAll()
    saveConversations()

    _ = await send(prompt: prompt, displayText: message.displayText, attachments: message.attachments)
  }

  private func restartPrompt(from message: ChatMessage) -> String? {
    let visible = MessageContentFilter.render(message.text).visibleText
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = MessageContentFilter.promptSafeText(from: message.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let prompt = visible.isEmpty ? fallback : visible
    return prompt.isEmpty && message.attachments.isEmpty ? nil : prompt
  }

  private func restartSourceMessage(for message: ChatMessage) -> ChatMessage? {
    if message.role == .user {
      return message
    }
    guard let location = messageLocation(for: message.id) else {
      return message
    }
    let messages = conversations[location.conversationIndex].messages
    guard location.messageIndex > 0 else {
      return message
    }
    return messages[..<location.messageIndex].last(where: { $0.role == .user }) ?? message
  }

  func deleteConversations(_ ids: Set<UUID>) {
    guard !ids.isEmpty else { return }
    let replacementID = replacementConversationID(afterDeleting: ids)
    let removedMessages = voiceRecordingMessages(in: ids)
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.formUnion(ids)
    }
    for id in ids {
      abandonResponse(in: id)
      queuedUserMessagesByConversationID[id] = nil
      conversationDrafts.removeValue(forKey: id)
      if !hasLoadedPersistedDrafts {
        deletedDraftIDsBeforeLoad.insert(id)
        dirtyDraftIDsBeforeLoad.remove(id)
      }
    }
    draftStorageRevision += 1
    persistDrafts()
    conversations.filter { ids.contains($0.id) }.forEach {
      clearStreamingText(for: $0.messages)
    }
    conversations.removeAll { ids.contains($0.id) }
    removeBookmarks(in: ids)
    rebuildConversationIndexes()
    removeSummaries(for: ids)
    selectedConversationIDs.removeAll()
    if let selectedConversationID, ids.contains(selectedConversationID) {
      if let replacementID {
        setSelectedConversationID(replacementID)
        Task { await selectConversation(id: replacementID) }
      } else {
        setSelectedConversationID(nil)
        createInitialConversationIfNeeded()
      }
    }
    persistence.deleteConversationFiles(ids: ids)
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
  }

  private func replacementConversationID(afterDeleting ids: Set<UUID>) -> UUID? {
    guard let selectedConversationID, ids.contains(selectedConversationID) else { return nil }
    let visibleIDs = conversationSummaries
      .filter { $0.folderID == selectedConversationFolderID }
      .map(\.id)
    if let index = visibleIDs.firstIndex(of: selectedConversationID) {
      return visibleIDs[(index + 1)...].first { !ids.contains($0) }
        ?? visibleIDs[..<index].last { !ids.contains($0) }
        ?? conversationSummaries.first { !ids.contains($0.id) }?.id
    }
    return conversationSummaries.first { !ids.contains($0.id) }?.id
  }

  private func voiceRecordingMessages(in conversationIDs: Set<UUID>) -> [ChatMessage] {
    guard !conversationIDs.isEmpty else { return [] }
    return conversationIDs.flatMap { id -> [ChatMessage] in
      if let index = indexedConversationIndex(for: id) {
        return conversations[index].messages
      }
      return persistence.loadConversation(id: id)?.messages ?? []
    }
  }

  private func deleteUnreferencedVoiceRecordings(from messages: [ChatMessage]) {
    let candidates = Set(messages.compactMap(Self.normalizedVoiceRecordingFilename))
    guard !candidates.isEmpty else { return }

    let referenced = referencedVoiceRecordingFilenames()
    for filename in candidates.subtracting(referenced) {
      guard let url = PocketMaiDirectories.voiceRecordingURL(filename: filename) else { continue }
      try? FileManager.default.removeItem(at: url)
    }
  }

  private func referencedVoiceRecordingFilenames() -> Set<String> {
    var filenames = Set(
      conversations.flatMap { conversation in
        conversation.messages.compactMap(Self.normalizedVoiceRecordingFilename)
      })
    let loadedIDs = Set(conversations.map(\.id))
    for summary in conversationSummaries where !loadedIDs.contains(summary.id) {
      guard let conversation = persistence.loadConversation(id: summary.id) else { continue }
      filenames.formUnion(conversation.messages.compactMap(Self.normalizedVoiceRecordingFilename))
    }
    return filenames
  }

  private static func normalizedVoiceRecordingFilename(from message: ChatMessage) -> String? {
    guard
      let filename = message.voiceRecordingFilename?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      PocketMaiDirectories.voiceRecordingURL(filename: filename) != nil
    else {
      return nil
    }
    return filename
  }

  func cloneConversation(_ conversation: Conversation) {
    let now = Date()
    let copyTitle: String = {
      let trimmed = conversation.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      if AgentChat.isPlaceholderTitle(trimmed) {
        return "\(AgentChat.placeholderTitle) (Copy)"
      }
      return "\(trimmed) (Copy)"
    }()
    var cloned = conversation
    cloned.id = UUID()
    cloned.title = copyTitle
    cloned.messages = conversation.messages.map {
      ChatMessage(
        id: UUID(),
        role: $0.role,
        text: $0.text,
        displayText: $0.displayText,
        createdAt: $0.createdAt,
        voiceRecordingFilename: $0.voiceRecordingFilename,
        attachments: $0.attachments)
    }
    cloned.createdAt = now
    cloned.updatedAt = now
    cloned.isPinned = false
    cloned.isUnread = false
    cloned.lastContextSignature = nil
    if let index = indexedConversationIndex(for: conversation.id) {
      conversations.insert(cloned, at: index)
    } else {
      conversations.insert(cloned, at: 0)
    }
    sortConversations()
    setSelectedConversationID(cloned.id)
    saveConversations()
  }

  func effectiveConversationSettings(for conversation: Conversation?) -> ConversationSettings {
    settings.conversation.applyingLanguageOverride(from: conversation)
  }

  func effectiveToolSettings(for conversation: Conversation?) -> NativeToolSettings {
    var toolSettings = settings.toolSettings.applyingLanguageOverride(from: conversation)
    if settings.airplaneModeEnabled {
      toolSettings.voices.user = toolSettings.voices.user.withoutOnlineProvider()
      toolSettings.voices.assistant = toolSettings.voices.assistant.withoutOnlineProvider()
    }
    return toolSettings
  }

  func effectiveShowThinking(for conversation: Conversation?) -> Bool {
    guard settings.showThinkingByDefault else { return false }
    return conversation?.showThinking ?? settings.showThinkingByDefault
  }

  func togglePin(_ conversation: Conversation) {
    guard let index = indexedConversationIndex(for: conversation.id) else { return }
    conversations[index].isPinned.toggle()
    conversations[index].updatedAt = Date()
    sortConversations()
    saveConversations()
  }

  /// Returns the running session for the app, reusing it when the same app is
  /// already running so reopening the runner keeps the page state.
  @discardableResult
  func startWebXDCSession(app: WebXDCAppInfo) -> WebXDCRunningSession {
    if let session = activeWebXDCSession, session.app.id == app.id {
      return session
    }
    activeWebXDCSession?.stop()
    let session = WebXDCRunningSession(
      app: app, conversationID: currentConversation?.id, store: self)
    activeWebXDCSession = session
    return session
  }

  func stopWebXDCSession() {
    activeWebXDCSession?.stop()
    activeWebXDCSession = nil
  }

  func send(
    prompt rawPrompt: String,
    displayText rawDisplayText: String? = nil,
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = [],
    promptShortcutSelection: PromptShortcutSelection? = nil
  ) async -> Bool {
    let resolved = resolvedPromptSubmission(
      rawPrompt: rawPrompt,
      rawDisplayText: rawDisplayText,
      shortcutSelection: promptShortcutSelection)
    guard !resolved.prompt.isEmpty || !attachments.isEmpty || resolved.systemPromptID != nil else {
      return false
    }
    if currentConversation == nil {
      newConversation()
    }
    guard let index = currentConversationIndex else { return false }
    let conversationID = conversations[index].id
    normalizeCurrentAppleConversationIfNeeded(index: index)
    guard !respondingConversationIDs.contains(conversationID) else { return false }
    if let systemPromptID = resolved.systemPromptID {
      conversations[index].systemPromptID = systemPromptID
      conversations[index].updatedAt = Date()
      upsertSummary(for: conversations[index])
      saveConversations()
    }
    guard !resolved.prompt.isEmpty || !attachments.isEmpty else { return true }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversations[index], settings: settings)
    {
      errorMessage = message
      return false
    }

    errorMessage = nil
    rememberSelectedConversationID(conversationID)
    await composeUserTurn(
      prompt: resolved.prompt,
      displayText: resolved.displayText,
      conversationID: conversationID,
      mode: .append,
      voiceRecordingFilename: voiceRecordingFilename,
      attachments: attachments)
    return true
  }

  private func resolvedPromptSubmission(
    rawPrompt: String,
    rawDisplayText: String?,
    shortcutSelection: PromptShortcutSelection?
  ) -> ResolvedPromptSubmission {
    let prompt = rawPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let parsed = PromptSlashCommand.parse(prompt)
    guard parsed != nil || shortcutSelection != nil else {
      return ResolvedPromptSubmission(
        prompt: prompt,
        displayText: normalizedDisplayText(rawDisplayText, prompt: prompt),
        systemPromptID: nil)
    }

    let slashCommand = parsed ?? ParsedPromptSlashCommand(command: "", remainder: prompt)
    let target =
      shortcutSelection.flatMap { promptShortcutTarget(selection: $0) }
      ?? promptShortcutTarget(command: slashCommand.command)
    guard let target else {
      return ResolvedPromptSubmission(
        prompt: prompt,
        displayText: normalizedDisplayText(rawDisplayText, prompt: prompt),
        systemPromptID: nil)
    }

    let shortcutDisplayText =
      rawDisplayText
      ?? (shortcutSelection == nil
        ? prompt
        : PromptSlashCommand.visualText(
          commandName: target.commandName,
          remainder: slashCommand.remainder))
    switch target.selection.kind {
    case .system:
      let modelPrompt = slashCommand.remainder.trimmingCharacters(in: .whitespacesAndNewlines)
      return ResolvedPromptSubmission(
        prompt: modelPrompt,
        displayText: normalizedDisplayText(shortcutDisplayText, prompt: modelPrompt),
        systemPromptID: target.selection.id)
    case .user:
      let expanded = UserPrompt.message(text: target.text, arguments: slashCommand.remainder)
      return ResolvedPromptSubmission(
        prompt: expanded,
        displayText: normalizedDisplayText(shortcutDisplayText, prompt: expanded),
        systemPromptID: nil)
    }
  }

  private func normalizedDisplayText(_ displayText: String?, prompt: String) -> String? {
    let trimmed = displayText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, trimmed != prompt else { return nil }
    return trimmed
  }

  private func promptShortcutTarget(selection: PromptShortcutSelection) -> PromptShortcutTarget? {
    switch selection.kind {
    case .system:
      guard let prompt = settings.systemPrompts.first(where: { $0.id == selection.id }) else {
        return nil
      }
      return PromptShortcutTarget(
        selection: selection,
        commandName: prompt.commandName,
        text: prompt.text)
    case .user:
      guard let prompt = settings.userPrompts.first(where: { $0.id == selection.id }) else {
        return nil
      }
      return PromptShortcutTarget(
        selection: selection,
        commandName: prompt.commandName,
        text: prompt.text)
    }
  }

  /// The prompt a typed name means, resolved the way pmai resolves `$name`:
  /// system prompts first, then user prompts. The builtin prompts are
  /// already among the user prompts here, so they are not consulted apart.
  private func promptShortcutTarget(command: String) -> PromptShortcutTarget? {
    let catalog = PromptCatalog(
      system: settings.systemPrompts, user: settings.userPrompts, builtins: [])
    guard let entry = catalog.entry(named: command), let id = entry.promptID else { return nil }
    return PromptShortcutTarget(
      selection: PromptShortcutSelection(kind: entry.kind == .system ? .system : .user, id: id),
      commandName: entry.commandName,
      text: entry.text)
  }

  var isOpenAPIServerRunning: Bool {
    openAPIServerState.isRunning
  }

  var isOpenAPIServerActive: Bool {
    openAPIServerState.isActive
  }

  func startOpenAPIServer() {
    let port = OpenAPIServerSettings.clampedPort(settings.openAPIServer.port)
    if settings.openAPIServer.port != port {
      settings.openAPIServer.port = port
      saveSettings()
    }
    errorMessage = nil
    openAPIServerState = .starting(port)
    openAPIServer.start(
      port: port,
      requestHandler: { [weak self] request in
        guard let self else {
          return .error(statusCode: 503, message: "PocketMai is unavailable.")
        }
        return await self.openAPIServerResponse(for: request)
      },
      stateHandler: { [weak self] state in
        Task { @MainActor [weak self] in
          self?.openAPIServerState = state
          if case .failed(let message) = state {
            self?.errorMessage = "OpenAPI Server: \(message)"
          }
        }
      })
  }

  func stopOpenAPIServer() {
    openAPIServer.stop()
    openAPIServerState = .stopped
  }

  private func openAPIServerResponse(for request: OpenAPIServerHTTPRequest) async
    -> OpenAPIServerHTTPResponse
  {
    if request.method == "OPTIONS" {
      return OpenAPIServerHTTPResponse(
        statusCode: 204, reason: "No Content", headers: [:], body: Data())
    }

    do {
      switch (request.method, request.path) {
      case ("GET", "/"), ("GET", "/health"):
        return .json([
          "status": "ok",
          "server": "PocketMai",
          "model": openAPIServerModelName(),
        ])
      case ("GET", "/api/version"):
        return .json(["version": ConversationExportEnvelope.currentPocketMaiVersion])
      case ("GET", "/api/tags"):
        return ollamaTagsResponse()
      case ("POST", "/api/show"):
        return ollamaShowResponse()
      case ("POST", "/api/chat"):
        let body = try request.decodedBody(OpenAPIServerOllamaChatRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: body.messages,
          prompt: nil,
          system: nil,
          stream: body.stream ?? true)
        let output = try await completeOpenAPIServerRequest(input)
        return ollamaChatResponse(output: output, stream: input.stream)
      case ("POST", "/api/generate"):
        let body = try request.decodedBody(OpenAPIServerOllamaGenerateRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: [],
          prompt: body.prompt,
          system: body.system,
          stream: body.stream ?? true)
        let output = try await completeOpenAPIServerRequest(input)
        return ollamaGenerateResponse(output: output, stream: input.stream)
      case ("GET", "/v1/models"):
        return openAIModelsResponse()
      case ("POST", "/v1/chat/completions"):
        let body = try request.decodedBody(OpenAPIServerOpenAIChatRequest.self)
        let input = OpenAPIServerCompletionInput(
          model: body.model,
          messages: body.messages,
          prompt: nil,
          system: nil,
          stream: body.stream ?? false)
        let output = try await completeOpenAPIServerRequest(input)
        return openAIChatCompletionsResponse(output: output, stream: input.stream)
      default:
        return .error(statusCode: 404, message: "Unsupported endpoint \(request.path).")
      }
    } catch let error as DecodingError {
      return .error(statusCode: 400, message: "Invalid JSON request: \(error.localizedDescription)")
    } catch let error as OpenAPIServerAppError {
      return .error(statusCode: error.statusCode, message: error.localizedDescription)
    } catch {
      return .error(statusCode: 500, message: error.localizedDescription)
    }
  }

  private func completeOpenAPIServerRequest(_ input: OpenAPIServerCompletionInput) async throws
    -> OpenAPIServerCompletionOutput
  {
    switch settings.openAPIServer.conversationScope {
    case .currentChat:
      return try await completeCurrentChatOpenAPIServerRequest(input)
    case .defaultSettings:
      return try await completeDefaultOpenAPIServerRequest(input)
    }
  }

  private func completeCurrentChatOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput
  ) async throws -> OpenAPIServerCompletionOutput {
    guard let conversation = currentConversation else {
      throw OpenAPIServerAppError.unavailable("No selected chat is available.")
    }
    return try await completeIsolatedOpenAPIServerRequest(input, baseConversation: conversation)
  }

  private func completeDefaultOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput
  ) async throws -> OpenAPIServerCompletionOutput {
    try await completeIsolatedOpenAPIServerRequest(input, baseConversation: makeNewConversation())
  }

  private func completeIsolatedOpenAPIServerRequest(
    _ input: OpenAPIServerCompletionInput,
    baseConversation: Conversation
  ) async throws -> OpenAPIServerCompletionOutput {
    let allowTools = settings.openAPIServer.allowToolExecution
    let requestSettings = openAPIServerRequestSettings(allowTools: allowTools)
    let conversation = openAPIServerRequestConversation(
      from: baseConversation,
      input: input,
      allowTools: allowTools)
    guard !conversation.messages.isEmpty else { throw OpenAPIServerAppError.emptyPrompt }
    guard !input.latestUserText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw OpenAPIServerAppError.emptyPrompt
    }
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversation,
      settings: requestSettings)
    {
      throw OpenAPIServerAppError.unavailable(message)
    }

    if allowTools {
      let result = try await AssistantToolLoop.runIsolated(
        conversation: conversation,
        settings: requestSettings,
        baseContext: "",
        store: self)
      return OpenAPIServerCompletionOutput(
        text: result.text,
        model: effectiveModelName(for: conversation),
        toolRuns: result.toolRuns.map {
          OpenAPIServerToolRun(
            name: $0.name,
            argumentsJSON: $0.argumentsJSON,
            result: $0.result,
            isError: $0.isError)
        })
    }

    let request = ChatCompletionRequest(
      conversation: conversation,
      settings: requestSettings,
      context: "",
      assistantMessageID: UUID())
    let text = try await ChatProviderRouter.complete(request: request) { _ in }
    return OpenAPIServerCompletionOutput(
      text: text,
      model: effectiveModelName(for: conversation))
  }

  private func openAPIServerRequestConversation(
    from baseConversation: Conversation,
    input: OpenAPIServerCompletionInput,
    allowTools: Bool
  ) -> Conversation {
    var conversation = baseConversation
    conversation.id = UUID()
    conversation.title = "OpenAPI Server"
    conversation.createdAt = Date()
    conversation.updatedAt = Date()
    conversation.messages = input.chatMessagesForProxy()
    conversation.systemPromptID = Self.openAPIServerSystemPromptID
    conversation.usesStreaming = false
    conversation.isPinned = false
    conversation.folderID = ConversationFolder.defaultID
    conversation.lastContextSignature = nil
    if !allowTools {
      conversation.toolsEnabled = false
      conversation.enabledTools = []
      conversation.enabledMCPServers = []
      conversation.enabledMCPTools = []
      conversation.disabledMCPTools = []
    }
    if settings.openAPIServer.allowClientOverrides,
      let model = input.model?.trimmingCharacters(in: .whitespacesAndNewlines),
      !model.isEmpty
    {
      conversation.modelID = model
    }
    return conversation
  }

  private func openAPIServerRequestSettings(allowTools: Bool) -> AppSettings {
    var requestSettings = settings
    requestSettings.systemPrompts = [
      SystemPrompt(
        id: Self.openAPIServerSystemPromptID,
        name: "OpenAPI Server",
        text: "")
    ]
    requestSettings.defaultSystemPromptID = Self.openAPIServerSystemPromptID
    requestSettings.memory = ""
    if !allowTools {
      requestSettings.defaultEnabledTools = []
      requestSettings.defaultEnabledMCPServers = []
      requestSettings.defaultEnabledMCPTools = []
      requestSettings.mcpServers = []
    }
    return requestSettings
  }

  private func ollamaTagsResponse() -> OpenAPIServerHTTPResponse {
    let model = openAPIServerModelName()
    return .json([
      "models": [
        [
          "name": model,
          "model": model,
          "modified_at": openAPIServerTimestamp(),
          "size": 0,
          "digest": "pocketmai",
          "details": [
            "parent_model": "",
            "format": "pocketmai",
            "family": "pocketmai",
            "families": ["pocketmai"],
            "parameter_size": "",
            "quantization_level": "",
          ],
        ]
      ]
    ])
  }

  private func ollamaShowResponse() -> OpenAPIServerHTTPResponse {
    .json([
      "license": "",
      "modelfile": "",
      "parameters": "",
      "template": "",
      "details": [
        "parent_model": "",
        "format": "pocketmai",
        "family": "pocketmai",
        "families": ["pocketmai"],
        "parameter_size": "",
        "quantization_level": "",
      ],
      "model_info": [:],
    ])
  }

  private func ollamaChatResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let timestamp = openAPIServerTimestamp()
    if stream {
      let contentChunk = jsonLine([
        "model": output.model,
        "created_at": timestamp,
        "message": ["role": "assistant", "content": output.text],
        "done": false,
      ])
      var done: [String: Any] = [
        "model": output.model,
        "created_at": timestamp,
        "done": true,
        "done_reason": "stop",
      ]
      addOpenAPIServerToolRuns(output, to: &done)
      let doneChunk = jsonLine(done)
      return .text(
        contentChunk + doneChunk,
        contentType: "application/x-ndjson; charset=utf-8")
    }
    var body: [String: Any] = [
      "model": output.model,
      "created_at": timestamp,
      "message": ["role": "assistant", "content": output.text],
      "done": true,
      "done_reason": "stop",
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func ollamaGenerateResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let timestamp = openAPIServerTimestamp()
    if stream {
      let contentChunk = jsonLine([
        "model": output.model,
        "created_at": timestamp,
        "response": output.text,
        "done": false,
      ])
      var done: [String: Any] = [
        "model": output.model,
        "created_at": timestamp,
        "response": "",
        "done": true,
        "done_reason": "stop",
      ]
      addOpenAPIServerToolRuns(output, to: &done)
      let doneChunk = jsonLine(done)
      return .text(
        contentChunk + doneChunk,
        contentType: "application/x-ndjson; charset=utf-8")
    }
    var body: [String: Any] = [
      "model": output.model,
      "created_at": timestamp,
      "response": output.text,
      "done": true,
      "done_reason": "stop",
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func openAIModelsResponse() -> OpenAPIServerHTTPResponse {
    .json([
      "object": "list",
      "data": [
        [
          "id": openAPIServerModelName(),
          "object": "model",
          "created": Int(Date().timeIntervalSince1970),
          "owned_by": "pocketmai",
        ]
      ],
    ])
  }

  private func openAIChatCompletionsResponse(
    output: OpenAPIServerCompletionOutput,
    stream: Bool
  ) -> OpenAPIServerHTTPResponse {
    let id = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    let created = Int(Date().timeIntervalSince1970)
    if stream {
      let contentChunk = sseLine([
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": output.model,
        "choices": [
          [
            "index": 0,
            "delta": ["role": "assistant", "content": output.text],
            "finish_reason": NSNull(),
          ]
        ],
      ])
      var stop: [String: Any] = [
        "id": id,
        "object": "chat.completion.chunk",
        "created": created,
        "model": output.model,
        "choices": [
          [
            "index": 0,
            "delta": [:],
            "finish_reason": "stop",
          ]
        ],
      ]
      addOpenAPIServerToolRuns(output, to: &stop)
      let stopChunk = sseLine(stop)
      return .text(
        contentChunk + stopChunk + "data: [DONE]\n\n",
        contentType: "text/event-stream; charset=utf-8")
    }
    var body: [String: Any] = [
      "id": id,
      "object": "chat.completion",
      "created": created,
      "model": output.model,
      "choices": [
        [
          "index": 0,
          "message": ["role": "assistant", "content": output.text],
          "finish_reason": "stop",
        ]
      ],
    ]
    addOpenAPIServerToolRuns(output, to: &body)
    return .json(body)
  }

  private func addOpenAPIServerToolRuns(
    _ output: OpenAPIServerCompletionOutput,
    to body: inout [String: Any]
  ) {
    guard !output.toolRuns.isEmpty else { return }
    body["pocketmai_tool_calls"] = output.toolRuns.map {
      [
        "name": $0.name,
        "arguments": $0.argumentsJSON,
        "result": $0.result,
        "is_error": $0.isError,
      ] as [String: Any]
    }
  }

  private func openAPIServerModelName(requested: String? = nil) -> String {
    if settings.openAPIServer.allowClientOverrides,
      settings.openAPIServer.conversationScope == .defaultSettings,
      let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
      !requested.isEmpty
    {
      return requested
    }
    if settings.openAPIServer.conversationScope == .currentChat,
      let conversation = currentConversation
    {
      return effectiveModelName(for: conversation)
    }
    let defaults = makeNewConversation()
    return effectiveModelName(for: defaults)
  }

  private func effectiveModelName(for conversation: Conversation) -> String {
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !model.isEmpty { return model }
    switch conversation.provider {
    case .apple:
      return "apple-intelligence"
    case .mlx:
      return "mlx-local"
    case .openAICompatible:
      guard
        let endpoint = OpenAICompatibleProvider.selectedEndpoint(
          for: conversation,
          settings: settings)
      else {
        return "openai-compatible"
      }
      let endpointModel = endpoint.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
      return endpointModel.isEmpty ? endpoint.displayName : endpointModel
    }
  }

  private func openAPIServerTimestamp() -> String {
    ISO8601DateFormatter().string(from: Date())
  }

  private func jsonLine(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
      let text = String(data: data, encoding: .utf8)
    else {
      return #"{"error":"Could not encode JSON."}"# + "\n"
    }
    return text + "\n"
  }

  private func sseLine(_ object: Any) -> String {
    "data: \(jsonLine(object))\n"
  }

  func trimAndResubmit(from message: ChatMessage) async {
    guard let convIndex = currentConversationIndex else { return }
    let conversationID = conversations[convIndex].id
    guard
      let msgIndex = conversations[convIndex].messages.firstIndex(where: { $0.id == message.id })
    else { return }
    let cutoff: Int = message.role == .user ? msgIndex : msgIndex - 1
    guard cutoff >= 0 else { return }

    abandonResponse(in: conversationID)

    let removedMessages = Array(conversations[convIndex].messages.dropFirst(cutoff + 1))
    clearStreamingText(for: removedMessages)
    conversations[convIndex].messages = Array(conversations[convIndex].messages.prefix(cutoff + 1))
    removeBookmarks(for: removedMessages, in: conversationID)
    conversations[convIndex].updatedAt = Date()
    upsertSummary(for: conversations[convIndex])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)

    guard let last = conversations[convIndex].messages.last, last.role == .user else { return }
    let prompt = MessageContentFilter.promptSafeText(from: last.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty || !last.attachments.isEmpty else { return }

    if let preflight = ChatProviderRouter.preflightMessage(
      conversation: conversations[convIndex], settings: settings)
    {
      errorMessage = preflight
      return
    }

    errorMessage = nil
    await composeUserTurn(
      prompt: prompt,
      displayText: last.displayText,
      conversationID: conversationID,
      mode: .replaceLastUser,
      voiceRecordingFilename: last.voiceRecordingFilename,
      attachments: last.attachments)
  }

  private enum UserTurnMode {
    case append
    case replaceLastUser
  }

  private func composeUserTurn(
    prompt: String,
    displayText: String? = nil,
    conversationID: UUID,
    mode: UserTurnMode,
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = []
  ) async {
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    clearFollowUpSuggestions(in: conversationID)
    let conversation = conversations[index]
    let context = await ContextBuilder.build(
      input: prompt,
      conversation: conversation,
      settings: settings,
      locationService: { self.locationService }
    )

    guard let i = indexedConversationIndex(for: conversationID) else { return }
    switch mode {
    case .append:
      let userMessage = ChatMessage(
        role: .user,
        text: prompt,
        displayText: displayText,
        voiceRecordingFilename: voiceRecordingFilename,
        attachments: attachments)
      conversations[i].messages.append(userMessage)
      let presentationText = displayText ?? prompt
      let titleSource = MessageContentFilter.render(presentationText).visibleText
        .trimmingCharacters(in: .whitespacesAndNewlines)
      let fallbackTitle = attachments.map(\.displayName).joined(separator: ", ")
      conversations[i].refreshTitle(
        from: titleSource.isEmpty
          ? (presentationText.isEmpty ? fallbackTitle : presentationText)
          : titleSource)
    case .replaceLastUser:
      if let lastIndex = conversations[i].messages.indices.last {
        conversations[i].messages[lastIndex].text = prompt
        conversations[i].messages[lastIndex].displayText = displayText
        conversations[i].messages[lastIndex].voiceRecordingFilename = voiceRecordingFilename
        conversations[i].messages[lastIndex].attachments = attachments
      }
    }
    conversations[i].lastContextSignature = context.signature
    conversations[i].updatedAt = Date()
    upsertSummary(for: conversations[i])
    saveConversations()

    if let idx = indexedConversationIndex(for: conversationID),
      conversations[idx].provider == .mlx,
      settings.mlxAutoCompact
    {
      await autoCompactIfNeeded(conversationID: conversationID)
    }

    dispatchAssistantTurn(
      conversationID: conversationID, context: context.text)
  }

  private func autoCompactIfNeeded(conversationID: UUID) async {
    guard let idx = indexedConversationIndex(for: conversationID) else { return }
    let conversation = conversations[idx]
    guard conversation.messages.count > 3, !isCompacting else { return }

    // Estimate token count at ~3 chars/token; compact when exceeding 75% of the KV window.
    let totalChars = conversation.messages.reduce(0) { $0 + $1.text.count }
    let kvLimit = (conversation.mlxMaxKVSize ?? settings.mlxMaxKVSize).effectiveSize
    guard totalChars > kvLimit * 3 else { return }

    // Summarize all messages except the most recent user message so it is preserved.
    var summaryConversation = conversation
    summaryConversation.messages = Array(conversation.messages.dropLast())
    guard
      let compactReq = await ConversationPromptBuilder.compactRequest(
        conversation: summaryConversation,
        settings: settings)
    else { return }

    isCompacting = true
    defer { isCompacting = false }

    do {
      let summary = try await OneShotPromptRunner.run(compactReq.oneShot, settings: settings)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else { return }
      guard let i = indexedConversationIndex(for: conversationID) else { return }
      let lastMsg = conversations[i].messages.last
      let removed = Array(conversations[i].messages.dropLast())
      conversations[i].messages = [
        ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
      ]
      if let lastMsg { conversations[i].messages.append(lastMsg) }
      conversations[i].updatedAt = Date()
      upsertSummary(for: conversations[i])
      saveConversations()
      deleteUnreferencedVoiceRecordings(from: removed)
    } catch {
      // Best-effort: proceed without compaction if summarization fails.
    }
  }

  private func dispatchAssistantTurn(conversationID: UUID, context: String) {
    let responseTaskToken = UUID()
    respondingConversationIDs.insert(conversationID)
    responseTaskTokens[conversationID] = responseTaskToken
    activityTurnStarted(conversationID: conversationID)
    prepareNotificationsForResponse()
    refreshBackgroundKeepAlive()
    reopenAgentProcess(for: conversationID)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      guard responseTaskTokens[conversationID] == responseTaskToken else { return }
      let messageCountBeforeResponse = conversation(withID: conversationID)?.messages.count ?? 0
      defer {
        if responseTaskTokens[conversationID] == responseTaskToken {
          respondingConversationIDs.remove(conversationID)
          loadingLocalModelConversationIDs.remove(conversationID)
          responseTasks[conversationID] = nil
          responseTaskTokens[conversationID] = nil
          endResponseBackgroundTask(
            for: conversationID, success: responseOutcomes[conversationID] == nil)
          saveConversations()
          activityTurnFinished(conversationID: conversationID)
          completeAgentProcess(for: conversationID)
        }
      }
      if let conversation = conversation(withID: conversationID), conversation.provider == .mlx {
        let modelID = LocalMLXProvider.effectiveModelID(
          conversation: conversation, settings: settings)
        if !modelID.isEmpty {
          loadingLocalModelConversationIDs.insert(conversationID)
          activityPhaseChanged(conversationID: conversationID, phase: .loadingModel)
          defer { loadingLocalModelConversationIDs.remove(conversationID) }
          // Settings may have preloaded this exact shared container. If not,
          // load it before the assistant turn so the chat can report progress.
          try? await LocalMLXProvider.shared.load(modelID: modelID)
        }
      }
      await AssistantTurnRunner.run(
        conversationID: conversationID,
        context: context,
        store: self
      )
      scheduleFollowUpSuggestions(for: conversationID)
      if selectedConversationID != conversationID,
        let conversation = conversation(withID: conversationID),
        conversation.messages.count > messageCountBeforeResponse
      {
        updateConversationUnreadState(id: conversationID, isUnread: true)
      }
    }
    responseTasks[conversationID] = task
    beginResponseBackgroundTask(for: conversationID)
  }

  private func scheduleFollowUpSuggestions(for conversationID: UUID) {
    guard settings.followUps.autoGenerate else { return }
    beginFollowUpGeneration(for: conversationID)
  }

  /// Explicit user request (the refresh button in the suggestion box). Generates
  /// suggestions for the last assistant message regardless of the automatic
  /// setting, giving a fresh set each tap.
  func regenerateFollowUpSuggestions(in conversationID: UUID) {
    beginFollowUpGeneration(for: conversationID)
  }

  private func beginFollowUpGeneration(for conversationID: UUID) {
    guard !Task.isCancelled, settings.followUps.isEnabled,
      let conversation = conversation(withID: conversationID),
      let sourceMessage = conversation.messages.last,
      sourceMessage.role == .assistant,
      !sourceMessage.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return
    }

    clearFollowUpSuggestions(in: conversationID)
    let settingsSnapshot = settings
    let sourceMessageID = sourceMessage.id
    let taskToken = UUID()
    followUpTaskTokens[conversationID] = taskToken
    generatingFollowUpSourceMessageIDsByConversationID[conversationID] = sourceMessageID
    let task = Task { @MainActor [weak self] in
      guard
        let request = FollowUpPromptBuilder.request(
          conversation: conversation,
          settings: settingsSnapshot)
      else {
        self?.finishFollowUpGeneration(in: conversationID, token: taskToken)
        return
      }

      do {
        let response = try await OneShotPromptRunner.run(request, settings: settingsSnapshot)
        try Task.checkCancellation()
        let options = FollowUpSuggestionParser.parse(
          response,
          limit: settingsSnapshot.followUps.suggestionCount)
        guard let self,
          followUpTaskTokens[conversationID] == taskToken,
          settings.followUps.isEnabled,
          self.conversation(withID: conversationID)?.messages.last?.id == sourceMessageID,
          !options.isEmpty
        else {
          self?.finishFollowUpGeneration(in: conversationID, token: taskToken)
          return
        }
        followUpSuggestionsByConversationID[conversationID] = FollowUpSuggestionState(
          sourceMessageID: sourceMessageID,
          options: options)
      } catch {
        // Follow-up suggestions are optional and should never turn a completed reply into an error.
      }
      self?.finishFollowUpGeneration(in: conversationID, token: taskToken)
    }
    followUpTasks[conversationID] = task
  }

  private func finishFollowUpGeneration(in conversationID: UUID, token: UUID) {
    guard followUpTaskTokens[conversationID] == token else { return }
    followUpTasks[conversationID] = nil
    followUpTaskTokens[conversationID] = nil
    generatingFollowUpSourceMessageIDsByConversationID[conversationID] = nil
  }

  private func beginResponseBackgroundTask(for conversationID: UUID) {
    endResponseBackgroundTask(for: conversationID)
    let task = ResponseBackgroundTask(
      onExpiration: { [weak self] in
        self?.handleResponseBackgroundTaskExpired(for: conversationID)
      },
      onCancellation: { [weak self] in
        guard let self else { return }
        if let messageID = latestAssistantMessageID(in: conversationID) {
          checkpointStreamingAssistantMessage(id: messageID)
        }
        cancelResponse(in: conversationID)
      })
    responseBackgroundTasks[conversationID] = task
    task.start(
      title: conversation(withID: conversationID)?.displayTitle ?? "PocketMai",
      // MLX uses the GPU, which needs a separate device capability/entitlement.
      useContinuedProcessing: settings.background.liveActivityEnabled
        && conversation(withID: conversationID)?.provider == .openAICompatible)
  }

  private func handleResponseBackgroundTaskExpired(for conversationID: UUID) {
    // Expiration only ends the extra background execution allowance. Cancelling
    // here used to discard an otherwise resumable in-progress assistant turn.
    guard respondingConversationIDs.contains(conversationID) else { return }
    guard !responseBackgroundTasks.values.contains(where: \.isContinuing) else { return }
    if backgroundKeepAlive.isActive { return }
    // The process is about to be suspended mid-reply. Keep what streamed so far
    // and tell the Lock Screen card why nothing moves until the app reopens.
    if let messageID = latestAssistantMessageID(in: conversationID) {
      checkpointStreamingAssistantMessage(id: messageID)
    }
    activityPhaseChanged(
      conversationID: conversationID,
      phase: .paused,
      detail: "Open PocketMai to continue")
  }

  private func endResponseBackgroundTask(for conversationID: UUID, success: Bool = false) {
    responseBackgroundTasks.removeValue(forKey: conversationID)?.finish(success: success)
  }

  private func endAllResponseBackgroundTasks() {
    for task in responseBackgroundTasks.values {
      task.finish()
    }
    responseBackgroundTasks.removeAll()
  }

  private func checkpointStreamingAssistantMessage(id: UUID) {
    guard let text = streamingTextStore.currentText(for: id) else { return }
    setAssistantMessage(id: id, text: text, role: .assistant, touch: false)
    saveConversations()
  }

  func markAssistantStopped(id: UUID) {
    let current = currentTextOfMessage(id: id)
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      setAssistantMessage(id: id, text: "[stopped]", role: .error)
    } else {
      setAssistantMessage(
        id: id, text: "\(current)\n\n[stopped]", role: .assistant)
    }
  }

  func markLatestAssistantStopped(in conversationID: UUID, fallbackID: UUID) {
    responseOutcomes[conversationID] = .stopped
    markAssistantStopped(id: latestAssistantMessageID(in: conversationID) ?? fallbackID)
  }

  func markLatestAssistantFailed(
    in conversationID: UUID,
    fallbackID: UUID,
    message: String
  ) {
    responseOutcomes[conversationID] = .failed
    let id = latestAssistantMessageID(in: conversationID) ?? fallbackID
    let current = currentTextOfMessage(id: id)
    let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      setAssistantMessage(id: id, text: message, role: .error)
    } else {
      setAssistantMessage(
        id: id,
        text: "\(current)\n\n[operation failed: \(message)]",
        role: .assistant)
    }
  }

  private func latestAssistantMessageID(in conversationID: UUID) -> UUID? {
    conversation(withID: conversationID)?.messages.last(where: { $0.role == .assistant })?.id
  }

  /// Single entry point for streamed assistant tokens. Refreshes the live
  /// message buffer (UI + markdown observe it via `StreamingTextStore`) and,
  /// for token-by-token providers, drives the streaming haptics. Add future
  /// per-token handlers here so they share one throttled fan-out.
  func receiveStreamingAssistantText(_ text: String, for id: UUID, vibrate: Bool) {
    setAssistantMessage(id: id, text: text, role: .assistant, touch: false, streaming: true)
    activityStreamingText(text, messageID: id)
    guard vibrate, settings.appearance.hapticsEnabled else {
      return
    }
    responseHaptics.streamSnapshotReceived(text)
  }

  func assistantResponseCompleted() {
    guard settings.appearance.hapticsEnabled else {
      return
    }
    responseHaptics.responseCompleted()
  }

  func sidebarVisibilitySettled() {
    guard settings.appearance.hapticsEnabled else { return }
    responseHaptics.sidebarVisibilitySettled()
  }

  private func currentTextOfMessage(id: UUID) -> String {
    if let streaming = streamingTextStore.currentText(for: id) { return streaming }
    if let location = messageLocation(for: id) {
      return conversations[location.conversationIndex].messages[location.messageIndex].text
    }
    return ""
  }

  func conversation(withID id: UUID) -> Conversation? {
    guard let index = indexedConversationIndex(for: id) else { return nil }
    return conversations[index]
  }

  func conversationIndex(for id: UUID) -> Int? {
    indexedConversationIndex(for: id)
  }

  func appendAssistantMessage(to conversationID: UUID) -> UUID? {
    guard let index = indexedConversationIndex(for: conversationID) else { return nil }
    let assistantMessage = ChatMessage(role: .assistant, text: "")
    conversations[index].messages.append(assistantMessage)
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    return assistantMessage.id
  }

  func compactConversation() async {
    guard !isCompacting, !isResponding else { return }
    guard let index = currentConversationIndex else { return }
    let conversation = conversations[index]
    let settingsSnapshot = settings

    isCompacting = true
    defer { isCompacting = false }
    errorMessage = nil

    guard
      let compact = await ConversationPromptBuilder.compactRequest(
        conversation: conversation,
        settings: settingsSnapshot
      )
    else {
      errorMessage = "Nothing to compact yet."
      return
    }

    do {
      let summary = try await OneShotPromptRunner.run(compact.oneShot, settings: settingsSnapshot)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else {
        errorMessage = "Compact returned an empty summary."
        return
      }
      guard let idx = indexedConversationIndex(for: compact.conversationID) else {
        return
      }
      conversations[idx].messages = [
        ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
      ]
      conversations[idx].updatedAt = Date()
      upsertSummary(for: conversations[idx])
      saveConversations()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func compactPromptForCurrentConversation() async -> (conversationID: UUID, prompt: String)? {
    guard let conversation = currentConversation else { return nil }
    guard
      let prompt = await ConversationPromptBuilder.compactPrompt(
        conversation: conversation,
        settings: settings)
    else {
      errorMessage = "Nothing to compact yet."
      return nil
    }
    return (conversation.id, prompt)
  }

  func generateCompactSummary(conversationID: UUID, prompt: String) async -> String? {
    guard !isCompacting, !isResponding(in: conversationID) else { return nil }
    guard let index = indexedConversationIndex(for: conversationID) else { return nil }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      errorMessage = "Compact prompt is empty."
      return nil
    }

    let conversation = conversations[index]
    let settingsSnapshot = settings

    isCompacting = true
    defer { isCompacting = false }
    errorMessage = nil

    guard
      let compact = await ConversationPromptBuilder.compactRequest(
        conversation: conversation,
        settings: settingsSnapshot,
        prompt: trimmedPrompt
      )
    else {
      errorMessage = "Nothing to compact yet."
      return nil
    }

    do {
      let summary = try await OneShotPromptRunner.run(compact.oneShot, settings: settingsSnapshot)
      let trimmed = MessageContentFilter.promptSafeText(from: summary)
      guard !trimmed.isEmpty else {
        errorMessage = "Compact returned an empty summary."
        return nil
      }
      return trimmed
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func replaceConversationWithCompactSummary(conversationID: UUID, summary: String) {
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      errorMessage = "Compact summary is empty."
      return
    }

    let removedMessages = conversations[index].messages
    conversations[index].messages = [
      ChatMessage(role: .system, text: "Conversation summary (compacted):\n\n\(trimmed)")
    ]
    conversations[index].updatedAt = Date()
    upsertSummary(for: conversations[index])
    saveConversations()
    deleteUnreferencedVoiceRecordings(from: removedMessages)
  }

  func updateMemoryFromConversations() async {
    guard !isUpdatingMemory else { return }
    isUpdatingMemory = true
    defer { isUpdatingMemory = false }

    let conversationsSnapshot = conversations
    let settingsSnapshot = settings
    guard
      let prompt = await ConversationPromptBuilder.memoryUpdateRequest(
        conversations: conversationsSnapshot,
        settings: settingsSnapshot
      )
    else {
      return
    }

    do {
      let memory = try await OneShotPromptRunner.run(prompt, settings: settingsSnapshot)
      settings.memory = MessageContentFilter.promptSafeText(from: memory)
      saveSettings()
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func importToolFile(from url: URL) {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else { return }
    let excerpt =
      String(data: data.prefix(24_000), encoding: .utf8) ?? "Binary file: \(data.count) bytes"
    settings.toolSettings.files.append(ToolFile(name: url.lastPathComponent, excerpt: excerpt))
    saveSettings()
  }

  func previewSettingsImportFile(from url: URL) async throws -> SettingsImportFilePreview {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      throw SettingsBackupError.unreadableFile
    }
    return try previewSettingsImportFile(filename: url.lastPathComponent, data: data)
  }

  func previewSettingsImportFile(filename: String, data: Data) throws
    -> SettingsImportFilePreview
  {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    if let envelope = try? decoder.decode(SettingsBackupEnvelope.self, from: data),
      envelope.format == SettingsBackupEnvelope.format
    {
      return SettingsImportFilePreview(
        filename: filename,
        kind: .backup(envelope),
        sourceData: data)
    }
    if let envelope = try? Self.decodeConversationImportEnvelope(from: data) {
      return SettingsImportFilePreview(
        filename: filename,
        kind: .conversation(envelope),
        sourceData: data)
    }
    if let archive = try? MaiArchive.decode(from: data) {
      return SettingsImportFilePreview(
        filename: filename,
        kind: .portable(archive),
        sourceData: data)
    }
    throw SettingsBackupError.invalidJSON
  }

  func previewConversationImport(
    from url: URL,
    includePictures: Bool = true
  ) async throws -> ConversationImportPreview {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      throw ConversationImportError.unreadableFile
    }
    let envelope = try Self.decodeConversationImportEnvelope(from: data)
    return await previewConversationImport(from: envelope, includePictures: includePictures)
  }

  func previewConversationImport(
    from envelope: ConversationExportEnvelope,
    includePictures: Bool = true
  ) async -> ConversationImportPreview {
    var envelope = envelope
    if !includePictures {
      envelope.conversation = Self.conversationRemovingImageAttachments(envelope.conversation)
    }

    await loadStoredConversationsForSearch()
    return ConversationImportPreview(
      envelope: envelope,
      conflict: conversationImportConflict(for: envelope.conversation),
      existingTitles: existingConversationImportTitles()
    )
  }

  func previewConversationCollectionImport(
    _ file: PendingConversationImportFile
  ) throws -> ConversationCollectionImportPreview {
    let envelope = try Self.decodeConversationImportEnvelope(from: file.data)
    return ConversationCollectionImportPreview(file: file, envelope: envelope)
  }

  func suggestedConversationImportFolderName(conversationCount: Int) -> String {
    let base = conversationCount == 1 ? "Imported Conversation" : "Imported Conversations"
    let existing = Set(conversationFolders.map {
      normalizedConversationFolderName($0.displayName)
    })
    if !existing.contains(normalizedConversationFolderName(base)) { return base }
    var index = 2
    while existing.contains(normalizedConversationFolderName("\(base) \(index)")) {
      index += 1
    }
    return "\(base) \(index)"
  }

  @discardableResult
  func importConversationCollection(
    _ preview: ConversationCollectionImportPreview,
    destination: ConversationCollectionImportDestination
  ) async throws -> Int {
    await loadStoredConversationsForSearch()
    let importedConversations = preview.conversations
    guard !importedConversations.isEmpty else { throw ConversationImportError.invalidJSON }

    let folderID: String
    switch destination {
    case .newFolder(let rawName):
      let name = ConversationFolder.normalizedCustomName(rawName)
      guard !name.isEmpty else { throw ConversationImportError.folderNameRequired }
      let normalizedName = normalizedConversationFolderName(name)
      guard !conversationFolders.contains(where: {
        normalizedConversationFolderName($0.displayName) == normalizedName
      }) else {
        throw ConversationImportError.folderAlreadyExists(name)
      }
      let folder = ConversationFolder(name: name)
      settings.conversationFolders.append(folder)
      folderID = folder.id
    case .existingFolder(let id):
      let normalized = Conversation.normalizedFolderID(id)
      guard conversationFolders.contains(where: { $0.id == normalized }),
        conversationFolderIsAvailable(normalized)
      else {
        throw ConversationImportError.missingFolder
      }
      folderID = normalized
    }

    discardSelectedDisposableConversation()
    var usedIDs = Set(conversations.map(\.id))
    var inserted: [Conversation] = []
    inserted.reserveCapacity(importedConversations.count)
    let now = Date()
    for source in importedConversations {
      var conversation = source
      while usedIDs.contains(conversation.id) {
        conversation.id = UUID()
      }
      usedIDs.insert(conversation.id)
      conversation.folderID = folderID
      conversation.isPinned = false
      conversation.updatedAt = now
      inserted.append(conversation)
    }

    conversations.insert(contentsOf: inserted, at: 0)
    sortConversations()
    rebuildConversationIndexes()
    conversationSummaries = Self.sortedSummaries(conversations.map(ConversationSummary.init))
    refreshRecentConversationSummaries()
    settings.selectedConversationFolderID = folderID
    setSelectedConversationID(inserted[0].id)
    selectedConversationIDs.removeAll()
    saveSettings()
    saveConversations()
    return inserted.count
  }

  func importConversation(
    _ preview: ConversationImportPreview,
    resolution: ConversationImportResolution
  ) throws {
    switch resolution {
    case .create(let rawTitle):
      let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty else { throw ConversationImportError.titleRequired }
      if let existing = conversationWithTitle(title) {
        throw ConversationImportError.titleAlreadyExists(existing.displayTitle)
      }

      discardSelectedDisposableConversation()
      var conversation = preview.conversation
      conversation.id = uniqueConversationID()
      conversation.title = title
      conversation.isPinned = false
      conversation.updatedAt = Date()
      conversations.insert(conversation, at: 0)
      sortConversations()
      setSelectedConversationID(conversation.id)
      selectedConversationIDs.removeAll()
      saveConversations()
    case .updateExisting:
      guard let conflict = preview.conflict, !conflict.contentsMatch else {
        throw ConversationImportError.updateNotAvailable
      }
      if selectedConversationID != conflict.existingID {
        discardSelectedDisposableConversation()
      }
      guard let index = indexedConversationIndex(for: conflict.existingID) else {
        throw ConversationImportError.missingExistingConversation
      }

      let replacedMessages = conversations[index].messages
      var conversation = preview.conversation
      conversation.id = conflict.existingID
      conversation.title = conversations[index].title
      conversation.isPinned = conversations[index].isPinned
      conversation.folderID = conversations[index].folderID
      conversation.updatedAt = Date()
      conversations[index] = conversation
      sortConversations()
      setSelectedConversationID(conversation.id)
      selectedConversationIDs.removeAll()
      saveConversations()
      deleteUnreferencedVoiceRecordings(from: replacedMessages)
    }
  }

  func exportCurrentConversationEPUB(imageSize: AttachmentImageSize = .full) async -> URL? {
    guard let conversation = currentConversation else { return nil }
    return await exportConversationEPUB(conversation, imageSize: imageSize)
  }

  func exportConversationEPUB(
    _ conversation: Conversation,
    imageSize: AttachmentImageSize = .full
  ) async -> URL? {
    do {
      let data = EPUBExport.data(for: try await exportDocument(conversation, imageSize: imageSize))
      let url = try ConversationExportFiles.url(for: conversation, format: .epub)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export EPUB: \(error.localizedDescription)"
      return nil
    }
  }

  func exportConversationDOCX(
    _ conversation: Conversation,
    imageSize: AttachmentImageSize = .full
  ) async -> URL? {
    do {
      let data = DOCXExport.data(for: try await exportDocument(conversation, imageSize: imageSize))
      let url = try ConversationExportFiles.url(for: conversation, format: .docx)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export Word document: \(error.localizedDescription)"
      return nil
    }
  }

  func exportConversationHTML(
    _ conversation: Conversation,
    imageSize: AttachmentImageSize = .full
  ) async -> URL? {
    do {
      let data = HTMLExport.data(for: try await exportDocument(conversation, imageSize: imageSize))
      let url = try ConversationExportFiles.url(for: conversation, format: .html)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export HTML: \(error.localizedDescription)"
      return nil
    }
  }

  /// The shared export document, with every image the conversation shows
  /// fetched, rendered, and sized as requested.
  private func exportDocument(
    _ conversation: Conversation,
    imageSize: AttachmentImageSize
  ) async throws -> ExportDocument {
    let includeThinking = effectiveShowThinking(for: conversation)
    let catalog = try await ConversationExportContent.buildImageResourceCatalog(
      conversation: conversation,
      includeThinking: includeThinking,
      imageSize: imageSize)
    return ConversationExportContent.exportDocument(
      conversation: conversation,
      includeThinking: includeThinking,
      imageCatalog: catalog)
  }

  func exportCurrentConversationFile(
    format: ConversationExportFormat,
    imageSize: AttachmentImageSize = .full
  ) async -> URL? {
    guard let conversation = currentConversation else { return nil }
    return await exportConversationFile(
      conversation,
      format: format,
      imageSize: imageSize)
  }

  func exportConversationFile(
    id: UUID,
    format: ConversationExportFormat,
    imageSize: AttachmentImageSize = .full
  ) async -> URL? {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return nil }
    return await exportConversationFile(
      conversation,
      format: format,
      imageSize: imageSize)
  }

  func exportConversationFile(
    _ conversation: Conversation,
    format: ConversationExportFormat,
    imageSize: AttachmentImageSize = .full
  ) async -> URL?
  {
    switch format {
    case .markdown:
      return writeConversationExport(
        conversation: conversation,
        format: format,
        content: export(conversation: conversation, format: format))
    case .json, .debug:
      let exportable = await conversationIncludingAgentRecords(conversation)
      return writeConversationExport(
        conversation: exportable,
        format: format,
        content: export(conversation: exportable, format: format))
    case .html:
      return await exportConversationHTML(conversation, imageSize: imageSize)
    case .epub:
      return await exportConversationEPUB(conversation, imageSize: imageSize)
    case .docx:
      return await exportConversationDOCX(conversation, imageSize: imageSize)
    case .audio:
      return nil
    }
  }

  func exportConversationCollectionFile(ids: Set<UUID>) async -> URL? {
    guard !ids.isEmpty else { return nil }
    await loadStoredConversationsForSearch()
    let selected = conversationSummaries.compactMap { summary in
      ids.contains(summary.id) ? conversation(withID: summary.id) : nil
    }
    guard !selected.isEmpty else { return nil }
    var exportable: [Conversation] = []
    for conversation in selected {
      exportable.append(await conversationIncludingAgentRecords(conversation))
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    var envelope = ConversationExportEnvelope(conversations: exportable)
    envelope.portable = MaiArchive(
      generator: "PocketMai \(ConversationExportEnvelope.currentPocketMaiVersion)",
      chats: exportable.map { AgentChat(pocketMai: $0, settings: settings) })
    do {
      let data = try encoder.encode(envelope)
      let filename =
        exportable.count == 1
        ? ConversationExportFiles.filename(for: exportable[0])
        : "PocketMai-\(exportable.count)-Conversations"
      let url = try ConversationExportFiles.url(
        filename: filename,
        fileExtension: ConversationExportFiles.fileExtension)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not export conversations: \(error.localizedDescription)"
      return nil
    }
  }

  func exportCurrentConversationDebugJSONFile() async -> URL? {
    guard let conversation = currentConversation else { return nil }
    return await exportConversationDebugJSONFile(conversation)
  }

  func exportConversationDebugJSONFile(id: UUID) async -> URL? {
    await ensureConversationLoaded(id)
    guard let conversation = conversation(withID: id) else { return nil }
    return await exportConversationDebugJSONFile(conversation)
  }

  func conversationForExport(id: UUID) async -> Conversation? {
    await ensureConversationLoaded(id)
    return conversation(withID: id)
  }

  func exportConversationDebugJSONFile(_ conversation: Conversation) async -> URL? {
    let exportable = await conversationIncludingAgentRecords(conversation)
    let latestPrompt =
      exportable.messages.last(where: { $0.role == .user })
      .map { MessageContentFilter.promptSafeText(from: $0.text) } ?? ""
    let context = await ContextBuilder.build(
      input: latestPrompt,
      conversation: exportable,
      settings: settings,
      locationService: { self.locationService })
    return writeConversationExport(
      conversation: exportable,
      format: .debug,
      content: export(conversation: exportable, format: .debug, debugContext: context))
  }

  func corruptedConversationCount() async -> Int {
    let persistence = self.persistence
    return await Task.detached(priority: .utility) {
      persistence.corruptedConversationCount()
    }.value
  }

  func corruptedConversationDocuments() async -> [CorruptedConversationDocument] {
    let persistence = self.persistence
    return await Task.detached(priority: .utility) {
      persistence.corruptedConversationDocuments()
    }.value
  }

  func deleteCorruptedConversation(id: String) async -> CorruptedConversationDeletionResult {
    let persistence = self.persistence
    return await Task.detached(priority: .userInitiated) {
      persistence.deleteCorruptedConversation(id: id)
    }.value
  }

  func exportCorruptedConversationsArchive() async -> CorruptedConversationExportResult {
    let persistence = self.persistence
    return await Task.detached(priority: .utility) {
      persistence.exportCorruptedConversationsArchive()
    }.value
  }

  func recoverCorruptedConversations() async -> CorruptedConversationRecoveryResult {
    let persistence = self.persistence
    let result = await Task.detached(priority: .userInitiated) {
      persistence.recoverCorruptedConversations()
    }.value
    mergeRecoveredConversations(result.recoveredConversations)
    return result
  }

  private func writeConversationExport(
    conversation: Conversation,
    format: ConversationExportFormat,
    content: String
  ) -> URL? {
    do {
      let url = try ConversationExportFiles.url(
        for: conversation,
        format: format,
        suffix: format == .debug ? "-debug" : "")
      try content.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      errorMessage = "Could not export \(format.displayName): \(error.localizedDescription)"
      return nil
    }
  }

  func clearToolCallingDebugIterations(conversationID: UUID, assistantMessageID: UUID) {
    toolCallingDebugIterations[conversationID, default: []].removeAll {
      $0.assistantMessageID == assistantMessageID
    }
  }

  func appendToolCallingDebugIteration(
    _ iteration: ConversationDebugToolIteration,
    conversationID: UUID
  ) {
    toolCallingDebugIterations[conversationID, default: []].append(iteration)
  }

  func saveSettings() {
    if !settings.followUps.isEnabled {
      clearAllFollowUpSuggestions()
    }
    applyBackgroundActivitySettings()
    // The selected agent's snapshot follows every change to the live fields,
    // so a switch to another agent and back restores what was just set.
    var synced = settings
    synced.syncSelectedAgent()
    if synced != settings {
      settings = synced
    }
    guard hasLoadedPersistedSettings else {
      pendingSettingsSave = true
      return
    }
    persistence.saveSettings(settings)
  }

  // MARK: - Agents

  /// Switches the live settings to another agent. The agent being left keeps
  /// what was configured while it was selected.
  func selectAgent(_ id: UUID) {
    guard settings.selectedAgentID != id, settings.selectAgent(id) else { return }
    saveSettings()
    refreshSelectedDisposableConversationDefaults()
  }

  /// Adds an agent copied from the selected one and switches to it, so the
  /// settings edited next belong to the new agent.
  func addAgent(named name: String, description: String, canSpawnSubagents: Bool) {
    let agent = settings.addAgent(
      named: name, description: description, canSpawnSubagents: canSpawnSubagents)
    settings.selectAgent(agent.id)
    saveSettings()
    refreshSelectedDisposableConversationDefaults()
  }

  func removeAgent(_ id: UUID) {
    let wasSelected = settings.selectedAgentID == id
    guard settings.removeAgent(id) else { return }
    saveSettings()
    if wasSelected {
      refreshSelectedDisposableConversationDefaults()
    }
  }

  func updateAgent(_ id: UUID, name: String, description: String, canSpawnSubagents: Bool) {
    settings.updateAgent(
      id, name: name, description: description, canSpawnSubagents: canSpawnSubagents)
    saveSettings()
  }

  /// After the selected agent changes, an empty chat created from the previous
  /// defaults is rebuilt from the new ones, so typing into it uses the agent
  /// that is now selected. Chats with messages keep their own settings.
  private func refreshSelectedDisposableConversationDefaults() {
    guard let id = selectedConversationID,
      let index = indexedConversationIndex(for: id),
      isDisposableNewConversation(conversations[index]),
      !conversationUsesNewConversationDefaults(conversations[index])
    else {
      return
    }
    rebuildConversationFromDefaults(at: index)
    setSelectedConversationID(id, remember: false)
  }

  var activeLongRunningOperationTimeoutRequest: LongRunningOperationTimeoutRequest? {
    longRunningOperationTimeoutRequests.first
  }

  func requestLongRunningOperationDecision(
    _ context: LongRunningOperationContext
  ) async -> LongRunningOperationDecision {
    guard !Task.isCancelled else { return .interrupt }
    // A background reply cannot answer an alert. Keep the same operation
    // running; the normal timeout prompt is available when the app is active.
    guard UIApplication.shared.applicationState == .active else { return .continue }
    if let assistantMessageID = context.assistantMessageID {
      checkpointStreamingAssistantMessage(id: assistantMessageID)
    }
    let requestID = UUID()
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          if cancelledLongRunningOperationTimeoutIDs.remove(requestID) != nil {
            continuation.resume(returning: .interrupt)
            return
          }
          longRunningOperationTimeoutRequests.append(
            LongRunningOperationTimeoutRequest(
              id: requestID,
              context: context,
              continuation: continuation))
        }
      },
      onCancel: {
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !self.resolveLongRunningOperationTimeout(id: requestID, decision: .interrupt) {
            self.cancelledLongRunningOperationTimeoutIDs.insert(requestID)
          }
        }
      })
  }

  func continueLongRunningOperation(id: UUID) {
    _ = resolveLongRunningOperationTimeout(id: id, decision: .continue)
  }

  func skipLongRunningOperation(id: UUID) {
    _ = resolveLongRunningOperationTimeout(id: id, decision: .skip)
  }

  func interruptLongRunningOperation(id: UUID) {
    _ = resolveLongRunningOperationTimeout(id: id, decision: .interrupt)
  }

  @discardableResult
  private func resolveLongRunningOperationTimeout(
    id: UUID,
    decision: LongRunningOperationDecision
  ) -> Bool {
    guard let index = longRunningOperationTimeoutRequests.firstIndex(where: { $0.id == id })
    else {
      return false
    }
    let request = longRunningOperationTimeoutRequests.remove(at: index)
    request.resume(returning: decision)
    return true
  }

  var activeToolCallApprovalRequest: ToolCallApprovalRequest? {
    toolCallApprovalRequests.first
  }

  func requestToolCallApproval(
    call: ParsedToolCall,
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationID: UUID
  ) async -> ToolCallApprovalDecision {
    let needsApproval = !settings.yoloModeEnabled
    if needsApproval {
      activityApprovalRequested(conversationID: conversationID, toolName: call.name)
    }
    let decision = await requestToolCallApproval(
      call: call,
      definitions: definitions,
      mode: mode,
      conversationTitle: conversation(withID: conversationID)?.displayTitle)
    if needsApproval {
      activityApprovalResolved(
        conversationID: conversationID,
        toolName: call.name,
        decision: decision)
    }
    return decision
  }

  func requestToolCallApproval(
    call: ParsedToolCall,
    definitions: [ToolDefinition],
    mode: ToolCallingMode,
    conversationTitle: String?
  ) async -> ToolCallApprovalDecision {
    guard !settings.yoloModeEnabled else { return .approved(call) }

    let normalizedCall = AgentTooling.normalized(call: call, tools: definitions)
    let requestID = UUID()
    let originalText = AgentTooling.editableToolCallText(for: normalizedCall, mode: mode)

    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { continuation in
          if cancelledToolCallApprovalIDs.remove(requestID) != nil {
            continuation.resume(returning: .cancelled)
            return
          }
          let request = ToolCallApprovalRequest(
            id: requestID,
            callName: normalizedCall.name,
            originalText: originalText,
            mode: mode,
            definitions: definitions,
            conversationTitle: conversationTitle,
            continuation: continuation
          )
          toolCallApprovalRequests.append(request)
        }
      },
      onCancel: {
        Task { @MainActor [weak self] in
          guard let self else { return }
          if !self.resolveToolCallApproval(id: requestID, decision: .cancelled) {
            self.cancelledToolCallApprovalIDs.insert(requestID)
          }
        }
      }
    )
  }

  @discardableResult
  func approveToolCall(id: UUID, editedText: String) -> String? {
    guard let request = toolCallApprovalRequests.first(where: { $0.id == id }) else {
      return "This tool call is no longer pending."
    }
    switch parseApprovedToolCall(editedText, request: request) {
    case .success(let call):
      resolveToolCallApproval(id: id, decision: .approved(call))
      return nil
    case .failure(let message):
      return message
    }
  }

  func cancelToolCallApproval(id: UUID) {
    _ = resolveToolCallApproval(id: id, decision: .cancelled)
  }

  func interruptToolCallApproval(id: UUID) {
    _ = resolveToolCallApproval(id: id, decision: .interrupted)
  }

  @discardableResult
  private func resolveToolCallApproval(id: UUID, decision: ToolCallApprovalDecision) -> Bool {
    guard let index = toolCallApprovalRequests.firstIndex(where: { $0.id == id }) else {
      return false
    }
    let request = toolCallApprovalRequests.remove(at: index)
    request.resume(returning: decision)
    return true
  }

  private func parseApprovedToolCall(
    _ text: String,
    request: ToolCallApprovalRequest
  ) -> ToolCallApprovalParseResult {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failure("Tool call text cannot be empty.")
    }
    let calls = approvalToolCalls(in: trimmed, request: request)
    guard calls.count == 1 else {
      if calls.isEmpty {
        return .failure("Tool call text must contain one valid tool call.")
      }
      return .failure("Tool call text must contain only one tool call.")
    }

    let normalizedCall = AgentTooling.normalized(
      call: calls[0],
      tools: request.definitions
    )
    guard request.definitions.contains(where: { $0.name == normalizedCall.name }) else {
      return .failure("Unknown tool '\(normalizedCall.name)'.")
    }
    if let error = AgentTooling.requiredArgumentsError(
      call: normalizedCall,
      tools: request.definitions)
    {
      return .failure(error)
    }
    return .success(normalizedCall)
  }

  private func approvalToolCalls(
    in text: String,
    request: ToolCallApprovalRequest
  ) -> [ParsedToolCall] {
    AgentTooling.parseCalls(
      in: text,
      tools: request.definitions,
      mode: request.mode
    )
  }

  func resetEndpointStatus(_ id: UUID) {
    endpointStatuses[id] = .unknown
    endpointModels[id] = nil
    endpointVoices[id] = nil
    endpointModelCache[id] = nil
  }

  func refreshAppleIntelligenceAvailabilityInBackground() {
    Task { await refreshAppleIntelligenceAvailability() }
  }

  func refreshAppleIntelligenceAvailability() async {
    let deviceOnlyApple = settings.airplaneModeEnabled
    let report = await Task.detached(priority: .utility) {
      AppleFoundationProvider.availabilityReport(deviceOnly: deviceOnlyApple)
    }.value
    applyAppleAvailabilityReport(report)
  }

  private func applyAppleAvailabilityReport(_ report: AppleFoundationAvailabilityReport) {
    appleAvailabilityReport = report
    appleAvailabilityMessage = report.unavailableMessage
    normalizeUnavailableAppleProviderIfNeeded()
  }

  func resetMCPStatus(_ id: UUID) {
    mcpStatuses[id] = .unknown
    mcpTools[id] = nil
    mcpResources[id] = nil
    mcpCatalogCache[id] = nil
    Task { await MCPHTTPClient.resetSession(for: id) }
  }

  func refreshMCP(_ server: MCPServer, force: Bool = false) async {
    guard !settings.airplaneModeEnabled else {
      mcpTools[server.id] = nil
      mcpResources[server.id] = nil
      mcpStatuses[server.id] = .failed("Airplane mode is enabled.")
      mcpCatalogCache[server.id] = nil
      await MCPHTTPClient.resetSession(for: server.id)
      return
    }
    if !force, isMCPCatalogCacheValid(for: server) {
      return
    }
    mcpStatuses[server.id] = .checking
    mcpTools[server.id] = nil
    mcpResources[server.id] = nil
    do {
      let server = try await authorizedMCPServer(server)
      let catalog = try await MCPHTTPClient.fetchCatalog(
        server: server,
        timeout: settings.mcpRequestTimeoutInterval)
      mcpTools[server.id] = catalog.tools
      mcpResources[server.id] = catalog.resources
      if let transport = catalog.transport,
        let index = settings.mcpServers.firstIndex(where: { $0.id == server.id })
      {
        settings.mcpServers[index].transport = transport
        saveSettings()
      }
      seedEnabledMCPToolsIfNeeded(serverID: server.id, tools: catalog.tools)
      mcpStatuses[server.id] = .available
      mcpCatalogCache[server.id] = RemoteFetchCacheEntry(
        signature: mcpConnectionSignature(for: server.id) ?? server.connectionSignature,
        fetchedAt: Date())
    } catch {
      mcpTools[server.id] = nil
      mcpResources[server.id] = nil
      mcpStatuses[server.id] = .failed(error.localizedDescription)
      mcpCatalogCache[server.id] = nil
      await MCPHTTPClient.resetSession(for: server.id)
    }
  }

  private func mcpConnectionSignature(for id: UUID) -> String? {
    settings.mcpServers.first(where: { $0.id == id })?.connectionSignature
  }

  private func isMCPCatalogCacheValid(for server: MCPServer) -> Bool {
    guard case .available = (mcpStatuses[server.id] ?? .unknown),
      mcpTools[server.id] != nil,
      let entry = mcpCatalogCache[server.id],
      entry.signature == (mcpConnectionSignature(for: server.id) ?? server.connectionSignature),
      Date().timeIntervalSince(entry.fetchedAt) < Self.remoteFetchCacheTTL
    else {
      return false
    }
    return true
  }

  func authorizedMCPServer(_ server: MCPServer) async throws -> MCPServer {
    let current = settings.mcpServers.first(where: { $0.id == server.id }) ?? server
    let authentication = current.authentication
    guard authentication.oauthAccessTokenNeedsRefresh,
      !authentication.oauthRefreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return current
    }

    let result = try await MCPOAuthService.refresh(server: current)
    var refreshed = current
    refreshed.authentication.oauthAccessToken = result.accessToken
    refreshed.authentication.oauthRefreshToken =
      result.refreshToken ?? authentication.oauthRefreshToken
    refreshed.authentication.oauthAccessTokenExpiresAt = result.expiresAt
    refreshed.authentication.oauthClientID = result.clientID
    if let index = settings.mcpServers.firstIndex(where: { $0.id == current.id }) {
      settings.mcpServers[index] = refreshed
      saveSettings()
    }
    await MCPHTTPClient.resetSession(for: current.id)
    return refreshed
  }

  /// Connects the MCP servers a conversation will use, off the critical path, so
  /// the catalog is warm (and cached) before the user sends the first message.
  /// Cheap to call repeatedly — already-connected servers hit the cache.
  func warmEnabledMCPServersInBackground(for conversationID: UUID?) {
    guard !settings.airplaneModeEnabled,
      let conversationID,
      let conversation = conversation(withID: conversationID),
      conversation.toolsEnabled,
      settings.mcpServers.contains(where: {
        $0.isEnabled && $0.hasValidEndpointURL
          && conversation.enabledMCPServers.contains($0.id)
      })
    else {
      return
    }
    Task { await refreshEnabledMCPServers(for: conversation) }
  }

  func refreshEnabledMCPServers(
    for conversation: Conversation,
    settings effectiveSettings: AppSettings? = nil
  ) async {
    let settings = effectiveSettings ?? self.settings
    guard conversation.toolsEnabled else { return }
    guard !settings.airplaneModeEnabled else {
      for server in settings.mcpServers
      where conversation.enabledMCPServers.contains(server.id) {
        mcpTools[server.id] = nil
        mcpResources[server.id] = nil
        mcpStatuses[server.id] = .failed("Airplane mode is enabled.")
        await MCPHTTPClient.resetSession(for: server.id)
      }
      return
    }
    for server in settings.mcpServers
    where server.isEnabled && server.hasValidEndpointURL
      && conversation.enabledMCPServers.contains(server.id)
    {
      await refreshMCP(server)
    }
  }

  func markMCPUnavailable(serverID: UUID, message: String) {
    mcpTools[serverID] = nil
    mcpResources[serverID] = nil
    mcpStatuses[serverID] = .failed(message)
    mcpCatalogCache[serverID] = nil
    Task { await MCPHTTPClient.resetSession(for: serverID) }
  }

  private func seedEnabledMCPToolsIfNeeded(serverID: UUID, tools: [MCPToolDescriptor]) {
    guard !tools.isEmpty else { return }
    let prefix = MCPToolSelection.prefix(serverID: serverID)
    let toolKeys = Set(
      tools.map { MCPToolSelection.key(serverID: serverID, toolName: $0.name) })
    var settingsChanged = false
    if settings.defaultEnabledMCPServers.contains(serverID),
      !settings.defaultEnabledMCPTools.contains(where: { $0.hasPrefix(prefix) })
    {
      settings.defaultEnabledMCPTools.formUnion(toolKeys)
      settingsChanged = true
    }

    var conversationsChanged = false
    for index in conversations.indices
    where conversations[index].enabledMCPServers.contains(serverID)
      && !conversations[index].enabledMCPTools.contains(where: { $0.hasPrefix(prefix) })
    {
      conversations[index].enabledMCPTools.formUnion(toolKeys)
      conversationsChanged = true
    }

    if settingsChanged {
      saveSettings()
    }
    if conversationsChanged {
      saveConversations()
    }
  }

  func refreshEndpoint(_ endpoint: OpenAIEndpoint, force: Bool = false) async {
    guard !settings.airplaneModeEnabled else {
      endpointStatuses[endpoint.id] = .failed("Airplane mode is enabled.")
      endpointModels[endpoint.id] = nil
      endpointVoices[endpoint.id] = nil
      endpointModelCache[endpoint.id] = nil
      return
    }
    if !force, isEndpointModelCacheValid(for: endpoint) {
      return
    }
    endpointStatuses[endpoint.id] = .checking
    async let modelResult = fetchEndpointModelsResult(endpoint)
    async let voiceResult = fetchEndpointVoicesResult(endpoint)
    let results = await (models: modelResult, voices: voiceResult)

    let models = (try? results.models.get()) ?? []
    let voices = (try? results.voices.get()) ?? []

    if !models.isEmpty || !voices.isEmpty {
      endpointModels[endpoint.id] = models
      endpointVoices[endpoint.id] = voices
      endpointStatuses[endpoint.id] = .available
      endpointModelCache[endpoint.id] = RemoteFetchCacheEntry(
        signature: endpointConnectionSignature(for: endpoint.id) ?? endpoint.connectionSignature,
        fetchedAt: Date())
      if let firstModel = models.first,
        let index = settings.openAIEndpoints.firstIndex(where: { $0.id == endpoint.id }),
        settings.openAIEndpoints[index].defaultModel
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        settings.openAIEndpoints[index].defaultModel = firstModel
        saveSettings()
      }
    } else {
      endpointModels[endpoint.id] = nil
      endpointVoices[endpoint.id] = nil
      endpointStatuses[endpoint.id] = .failed(endpointRefreshErrorMessage(results))
      endpointModelCache[endpoint.id] = nil
    }
  }

  private func endpointConnectionSignature(for id: UUID) -> String? {
    settings.openAIEndpoints.first(where: { $0.id == id })?.connectionSignature
  }

  private func isEndpointModelCacheValid(for endpoint: OpenAIEndpoint) -> Bool {
    guard case .available = (endpointStatuses[endpoint.id] ?? .unknown),
      endpointModels[endpoint.id] != nil,
      let entry = endpointModelCache[endpoint.id],
      entry.signature
        == (endpointConnectionSignature(for: endpoint.id) ?? endpoint.connectionSignature),
      Date().timeIntervalSince(entry.fetchedAt) < Self.remoteFetchCacheTTL
    else {
      return false
    }
    return true
  }

  func refreshConfiguredEndpointsInBackground() {
    guard !settings.airplaneModeEnabled else { return }
    let endpoints = settings.openAIEndpoints.filter(\.isEnabled)
    guard !endpoints.isEmpty else { return }
    for endpoint in endpoints {
      Task {
        await Task.yield()
        await refreshEndpoint(endpoint)
      }
    }
  }

  func refreshLocalMLXModelsInBackground() {
    let generation = dataGeneration
    Task {
      await Task.yield()
      let modelIDs = await Self.loadLocalMLXModelIDs(priority: .utility)
      guard generation == dataGeneration else { return }
      applyLocalMLXModelIDs(modelIDs)
    }
  }

  func refreshLocalMLXModels() {
    applyLocalMLXModelIDs(LocalMLXModelCache.listRepositoryIDs())
  }

  private nonisolated static func loadLocalMLXModelIDs(priority: TaskPriority) async -> [String] {
    await Task.detached(priority: priority) {
      LocalMLXModelCache.listRepositoryIDs()
    }.value
  }

  private func applyLocalMLXModelIDs(_ modelIDs: [String]) {
    hasLoadedLocalMLXModels = true
    localMLXModelIDs = modelIDs
    normalizeDefaultLocalMLXModelIfNeeded()
    normalizeUnavailableAppleProviderIfNeeded()
  }

  func availableLocalMLXModelID(preferred rawPreferred: String? = nil) -> String? {
    guard !localMLXModelIDs.isEmpty else { return nil }
    let candidates = [rawPreferred, settings.localMLXModelID, AppSettings.localMLXDefaultModelID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    return candidates.first { localMLXModelIDs.contains($0) } ?? localMLXModelIDs.first
  }

  private func fallbackLocalMLXModelID(preferred rawPreferred: String? = nil) -> String {
    let preferred = normalizedModelID(rawPreferred ?? settings.localMLXModelID)
    guard hasLoadedLocalMLXModels else { return preferred }
    return availableLocalMLXModelID(preferred: preferred) ?? ""
  }

  private func normalizeDefaultLocalMLXModelIfNeeded() {
    guard settings.defaultProvider == .mlx else { return }
    let current = normalizedModelID(settings.localMLXModelID)
    let next = availableLocalMLXModelID(preferred: current) ?? ""
    guard current != next else { return }
    settings.localMLXModelID = next
    saveSettings()
  }

  private func normalizeUnavailableAppleProviderIfNeeded() {
    guard appleAvailabilityReport.kind != .checking, !appleIntelligenceIsAvailable else { return }
    let fallbackModelID = fallbackLocalMLXModelID(preferred: settings.localMLXModelID)
    var settingsChanged = false
    if settings.defaultProvider == .apple {
      settings.defaultProvider = .mlx
      settings.localMLXModelID = fallbackModelID
      settingsChanged = true
    }

    var conversationsChanged = false
    for index in conversations.indices where conversations[index].provider == .apple {
      conversations[index].provider = .mlx
      conversations[index].endpointID = nil
      conversations[index].modelID = fallbackModelID
      conversationsChanged = true
    }

    if settingsChanged {
      saveSettings()
    }
    if conversationsChanged {
      saveConversations()
    }
  }

  private func normalizeCurrentAppleConversationIfNeeded(index: Int) {
    guard conversations.indices.contains(index),
      conversations[index].provider == .apple,
      !appleIntelligenceIsAvailable
    else {
      return
    }
    let fallbackModelID = fallbackLocalMLXModelID(preferred: settings.localMLXModelID)
    conversations[index].provider = .mlx
    conversations[index].endpointID = nil
    conversations[index].modelID = fallbackModelID
    saveConversations()
  }

  private func fetchEndpointModelsResult(_ endpoint: OpenAIEndpoint) async -> Result<
    [String], Error
  > {
    do {
      return .success(try await OpenAICompatibleProvider.fetchModels(endpoint: endpoint))
    } catch {
      return .failure(error)
    }
  }

  private func fetchEndpointVoicesResult(_ endpoint: OpenAIEndpoint) async -> Result<
    [String], Error
  > {
    do {
      return .success(try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint))
    } catch {
      return .failure(error)
    }
  }

  private func endpointRefreshErrorMessage(
    _ results: (models: Result<[String], Error>, voices: Result<[String], Error>)
  ) -> String {
    let modelMessage = failureMessage(results.models)
    let voiceMessage = failureMessage(results.voices)
    switch (modelMessage, voiceMessage) {
    case (.some(let model), .some(let voice)):
      return "Models: \(model)\nVoices: \(voice)"
    case (.some(let model), .none):
      return model
    case (.none, .some(let voice)):
      return voice
    case (.none, .none):
      return "The endpoint returned no models or voices."
    }
  }

  private func failureMessage(_ result: Result<[String], Error>) -> String? {
    if case .failure(let error) = result {
      return error.localizedDescription
    }
    return nil
  }

  func saveConversations() {
    let retained = retainedPlaceholderConversationIDs()
    guard hasLoadedPersistedConversations else {
      pendingConversationSave = true
      dirtyConversationIDsBeforeLoad.formUnion(conversations.map(\.id))
      persistence.saveLoadedConversations(
        conversations, summaries: conversationSummaries, retaining: retained)
      return
    }
    persistence.saveConversations(conversations, retaining: retained)
  }

  /// Stores the session supervisor's latest copy of child-agent records
  /// without discarding records it has already pruned from memory.
  func mergeAgentProcessRecords(
    _ current: [AgentProcessRecord],
    into conversationID: UUID
  ) {
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    let merged = AgentProcessRecord.merging(
      saved: conversations[index].subagents,
      current: current)
    guard merged != conversations[index].subagents else { return }
    conversations[index].subagents = merged
    saveConversations()
  }

  /// Removes durable agent records rooted at the given run identities,
  /// including descendants no longer retained by the live supervisor.
  func removeAgentProcessRecordSubtrees(
    rootedAt rootRunIDs: Set<UUID>,
    from conversationID: UUID
  ) {
    guard let index = indexedConversationIndex(for: conversationID) else { return }
    var deletedRunIDs = rootRunIDs
    var foundDescendant = true
    while foundDescendant {
      foundDescendant = false
      for record in conversations[index].subagents
      where record.parentRunID.map(deletedRunIDs.contains) == true {
        if deletedRunIDs.insert(record.runID).inserted { foundDescendant = true }
      }
    }
    let previousCount = conversations[index].subagents.count
    conversations[index].subagents.removeAll { deletedRunIDs.contains($0.runID) }
    guard conversations[index].subagents.count != previousCount else { return }
    saveConversations()
  }

  /// Placeholders worth a file even though nothing was said yet: a draft is
  /// waiting in them, or a reply is on its way. The store drops every other
  /// untouched placeholder, as pmai does.
  private func retainedPlaceholderConversationIDs() -> Set<UUID> {
    var ids = respondingConversationIDs
    for (id, draft) in conversationDrafts
    where !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      ids.insert(id)
    }
    return ids
  }

  private func saveBookmarks() {
    guard hasLoadedPersistedBookmarks else {
      pendingBookmarkSave = true
      return
    }
    persistence.saveBookmarks(messageBookmarks)
  }

  private func noteDirtyBookmarkBeforeLoad(_ bookmark: MessageBookmark) {
    guard !hasLoadedPersistedBookmarks else { return }
    dirtyBookmarkKeysBeforeLoad.insert(bookmark.storageKey)
    deletedBookmarkKeysBeforeLoad.remove(bookmark.storageKey)
  }

  private func noteDeletedBookmarkBeforeLoad(_ bookmark: MessageBookmark) {
    guard !hasLoadedPersistedBookmarks else { return }
    deletedBookmarkKeysBeforeLoad.insert(bookmark.storageKey)
    dirtyBookmarkKeysBeforeLoad.remove(bookmark.storageKey)
  }

  private func removeBookmarks(for messages: [ChatMessage], in conversationID: UUID) {
    guard !messages.isEmpty else { return }
    let messageIDs = Set(messages.map(\.id))
    let removed = messageBookmarks.filter {
      $0.conversationID == conversationID && messageIDs.contains($0.messageID)
    }
    if !hasLoadedPersistedBookmarks {
      for messageID in messageIDs {
        deletedBookmarkKeysBeforeLoad.insert(
          MessageBookmark(
            conversationID: conversationID,
            messageID: messageID,
            createdAt: .distantPast
          ).storageKey)
      }
      dirtyBookmarkKeysBeforeLoad.subtract(removed.map(\.storageKey))
      saveBookmarks()
    }
    guard !removed.isEmpty else { return }
    messageBookmarks.removeAll {
      $0.conversationID == conversationID && messageIDs.contains($0.messageID)
    }
    saveBookmarks()
  }

  private func removeBookmarks(in conversationIDs: Set<UUID>) {
    guard !conversationIDs.isEmpty else { return }
    if !hasLoadedPersistedBookmarks {
      deletedBookmarkConversationIDsBeforeLoad.formUnion(conversationIDs)
      dirtyBookmarkKeysBeforeLoad.subtract(
        messageBookmarks.lazy
          .filter { conversationIDs.contains($0.conversationID) }
          .map(\.storageKey))
      saveBookmarks()
    }
    let originalCount = messageBookmarks.count
    messageBookmarks.removeAll { conversationIDs.contains($0.conversationID) }
    if messageBookmarks.count != originalCount {
      saveBookmarks()
    }
  }

  private func clearMessageBookmarks() {
    messageBookmarks.removeAll()
    if !hasLoadedPersistedBookmarks {
      clearedBookmarksBeforeLoad = true
      dirtyBookmarkKeysBeforeLoad.removeAll()
      deletedBookmarkKeysBeforeLoad.removeAll()
      deletedBookmarkConversationIDsBeforeLoad.removeAll()
    }
    saveBookmarks()
  }

  private func sortConversations() {
    conversations = Self.sortedConversations(conversations)
    rebuildConversationIndexes()
    rebuildSummariesFromConversations()
  }

  private func mergeLoadedSummaries(_ summaries: [ConversationSummary]) {
    guard !summaries.isEmpty else { return }
    var byID = Dictionary(uniqueKeysWithValues: conversationSummaries.map { ($0.id, $0) })
    for summary in summaries
    where !deletedConversationIDsBeforeLoad.contains(summary.id) {
      if let existing = byID[summary.id],
        existing.updatedAt >= summary.updatedAt
      {
        continue
      }
      byID[summary.id] = summary
    }
    conversationSummaries = Self.sortedSummaries(Array(byID.values))
    refreshRecentConversationSummaries()
    normalizeConversationFoldersForCurrentData()
  }

  private func mergeLoadedConversations(_ loaded: [Conversation]) {
    let loaded = loaded.filter { !deletedConversationIDsBeforeLoad.contains($0.id) }
    var byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
    for conversation in conversations {
      if dirtyConversationIDsBeforeLoad.contains(conversation.id) || byID[conversation.id] == nil {
        byID[conversation.id] = conversation
      }
    }
    conversations = Self.sortedConversations(Array(byID.values))
    rebuildConversationIndexes()
    rebuildSummariesFromConversations()
    hasLoadedPersistedConversations = true
    normalizeConversationFoldersForCurrentData()
    if pendingConversationSave {
      pendingConversationSave = false
      saveConversations()
    }
  }

  private func mergeRecoveredConversations(_ recovered: [Conversation]) {
    guard !recovered.isEmpty else { return }
    var byID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    for conversation in recovered {
      guard let existing = byID[conversation.id] else {
        byID[conversation.id] = conversation
        continue
      }
      if existing.updatedAt < conversation.updatedAt
        || (existing.updatedAt == conversation.updatedAt
          && existing.createdAt < conversation.createdAt)
      {
        byID[conversation.id] = conversation
      }
    }
    conversations = Self.sortedConversations(Array(byID.values))
    rebuildConversationIndexes()
    rebuildSummariesFromConversations()
  }

  private func rebuildSummariesFromConversations() {
    let loadedSummaries = conversations.map(ConversationSummary.init)
    var byID = Dictionary(uniqueKeysWithValues: conversationSummaries.map { ($0.id, $0) })
    for summary in loadedSummaries {
      byID[summary.id] = summary
    }
    conversationSummaries = Self.sortedSummaries(Array(byID.values))
    refreshRecentConversationSummaries()
    normalizeConversationFoldersForCurrentData()
  }

  private func upsertSummary(for conversation: Conversation) {
    let summary = ConversationSummary(conversation: conversation)
    if let index = conversationSummaries.firstIndex(where: { $0.id == conversation.id }) {
      conversationSummaries[index] = summary
    } else {
      conversationSummaries.append(summary)
    }
    conversationSummaries = Self.sortedSummaries(conversationSummaries)
    refreshRecentConversationSummaries()
  }

  private func removeSummaries(for ids: Set<UUID>) {
    conversationSummaries.removeAll { ids.contains($0.id) }
    refreshRecentConversationSummaries()
  }

  private func refreshRecentConversationSummaries() {
    let recent = ConversationSummary.mostRecent(conversationSummaries)
    guard recentConversationSummaries != recent else { return }
    recentConversationSummaries = recent
  }

  nonisolated static func strippedSpuriousToolCallText(_ text: String) -> String {
    let actionableText = MessageContentFilter.removingReasoningSections(from: text)
    guard AgentTooling.containsToolCallMarker(in: actionableText) else { return text }
    let patterns = [
      "<\\s*tool_call\\b[^>]*>[\\s\\S]*?<\\s*/\\s*tool_call\\s*>",
      "<\\s*tool_call\\b[^>]*>[\\s\\S]*$",
      "<\\s*/\\s*tool_call\\s*>",
      "(?im)^\\s*TOOL_CALL\\s*$[\\s\\S]*?(?:^\\s*END_TOOL_CALL\\s*$|\\z)",
    ]
    var result = text
    for pattern in patterns {
      result = result.replacingOccurrences(
        of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
    }
    let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      return "(model attempted a tool call but no tools are enabled.)"
    }
    return trimmed + "\n\n_(stripped spurious tool_call: no tools are enabled.)_"
  }

  nonisolated static func sortedConversations(_ conversations: [Conversation]) -> [Conversation] {
    conversations.sorted(by: conversationPrecedes)
  }

  nonisolated static func sortedSummaries(_ summaries: [ConversationSummary])
    -> [ConversationSummary]
  {
    summaries.sorted(by: summaryPrecedes)
  }

  nonisolated static func sortedMessageBookmarks(_ bookmarks: [MessageBookmark])
    -> [MessageBookmark]
  {
    bookmarks.sorted { lhs, rhs in
      if lhs.isPinned != rhs.isPinned {
        return lhs.isPinned && !rhs.isPinned
      }
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.storageKey < rhs.storageKey
    }
  }

  nonisolated private static func conversationPrecedes(
    _ lhs: Conversation,
    _ rhs: Conversation
  ) -> Bool {
    if lhs.isPinned != rhs.isPinned {
      return lhs.isPinned && !rhs.isPinned
    }
    if lhs.updatedAt != rhs.updatedAt {
      return lhs.updatedAt > rhs.updatedAt
    }
    return lhs.createdAt > rhs.createdAt
  }

  nonisolated private static func summaryPrecedes(
    _ lhs: ConversationSummary,
    _ rhs: ConversationSummary
  ) -> Bool {
    if lhs.isPinned != rhs.isPinned {
      return lhs.isPinned && !rhs.isPinned
    }
    if lhs.updatedAt != rhs.updatedAt {
      return lhs.updatedAt > rhs.updatedAt
    }
    return lhs.createdAt > rhs.createdAt
  }

  private func discardSelectedDisposableConversation() {
    discardDisposableConversation(id: selectedConversationID)
  }

  @discardableResult
  private func discardDisposableConversation(id: UUID?) -> Bool {
    guard let id,
      let index = indexedConversationIndex(for: id),
      isDisposableNewConversation(conversations[index])
    else {
      return false
    }
    let removedID = id
    conversations.remove(at: index)
    rebuildConversationIndexes()
    removeSummaries(for: [removedID])
    responseTasks[removedID]?.cancel()
    responseTasks[removedID] = nil
    responseTaskTokens[removedID] = nil
    endResponseBackgroundTask(for: removedID)
    respondingConversationIDs.remove(removedID)
    activityTurnAbandoned(conversationID: removedID)
    stopAgentProcesses(for: removedID, reason: "Chat deleted")
    clearFollowUpSuggestions(in: removedID)
    queuedUserMessagesByConversationID[removedID] = nil
    if conversationDrafts.removeValue(forKey: removedID) != nil {
      if !hasLoadedPersistedDrafts {
        deletedDraftIDsBeforeLoad.insert(removedID)
        dirtyDraftIDsBeforeLoad.remove(removedID)
      }
      draftStorageRevision += 1
      persistDrafts()
    }
    if !hasLoadedPersistedConversations {
      deletedConversationIDsBeforeLoad.insert(removedID)
    }
    return true
  }

  /// Applies the rule shared with pmai through MaiCore: an untouched
  /// placeholder is dropped instead of being saved or listed. An unsent draft
  /// or a reply in flight is the app's own reason to hold on to one.
  private func isDisposableNewConversation(_ conversation: Conversation) -> Bool {
    let hasDraft = !conversationDrafts[conversation.id, default: ""]
      .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return !hasDraft
      && !respondingConversationIDs.contains(conversation.id)
      && conversation.isDisposable
  }

  private func createInitialConversationIfNeeded() {
    guard conversations.isEmpty else { return }
    let conversation = makeNewConversation()
    conversations.insert(conversation, at: 0)
    sortConversations()
    setSelectedConversationID(conversation.id, remember: false)
    selectedConversationIDs.removeAll()
  }

  private var currentConversationIndex: Int? {
    guard let selectedConversationID else { return nil }
    return indexedConversationIndex(for: selectedConversationID)
  }

  private struct ActiveConversationPublicationKey: Equatable {
    let id: UUID
    let updatedAt: Date
    let messageCount: Int
    let lastMessage: ChatMessageRenderKey?
    let title: String
    let provider: ProviderKind
    let modelID: String
    let endpointID: UUID?
    let systemPromptID: UUID?
    let toolsEnabled: Bool
    let enabledTools: Set<BuiltInToolID>
    let usesStreaming: Bool
    let enabledMCPServers: Set<UUID>
    let enabledMCPTools: Set<String>
    let disabledMCPTools: Set<String>
    let reasoningLevel: ReasoningLevel
    let showThinking: Bool
    let folderID: String
    let languageOverrideIdentifier: String?

    init(_ conversation: Conversation) {
      id = conversation.id
      updatedAt = conversation.updatedAt
      messageCount = conversation.messages.count
      lastMessage = conversation.messages.last.map(ChatMessageRenderKey.init)
      title = conversation.title
      provider = conversation.provider
      modelID = conversation.modelID
      endpointID = conversation.endpointID
      systemPromptID = conversation.systemPromptID
      toolsEnabled = conversation.toolsEnabled
      enabledTools = conversation.enabledTools
      usesStreaming = conversation.usesStreaming
      enabledMCPServers = conversation.enabledMCPServers
      enabledMCPTools = conversation.enabledMCPTools
      disabledMCPTools = conversation.disabledMCPTools
      reasoningLevel = conversation.reasoningLevel
      showThinking = conversation.showThinking
      folderID = conversation.folderID
      languageOverrideIdentifier = conversation.languageOverrideIdentifier
    }
  }

  private func publishActiveConversationIfNeeded(force: Bool = false) {
    guard let selectedConversationID,
      let conversation = cachedConversation(withID: selectedConversationID)
    else {
      if force || activeConversation != nil {
        activeConversationPublicationKey = nil
        activeConversation = nil
      }
      return
    }

    let publicationKey = ActiveConversationPublicationKey(conversation)
    guard force || publicationKey != activeConversationPublicationKey else { return }
    activeConversationPublicationKey = publicationKey
    activeConversation = conversation
    publishWidgetSelection()
  }

  // MARK: - Widget / launch bridging

  /// Applies a launch request that arrived via a deep link (widget) or an App
  /// Intent (Action Button / Siri). The chat UI observes `pendingLaunchAction`.
  func handleLaunchCommand(_ command: LaunchCommand) {
    pendingLaunchAction = command
  }

  /// Drains any launch command an App Intent left in the shared App Group while
  /// the app was backgrounded or not running.
  func drainPendingSharedLaunchCommand() {
    if let command = SharedAppState.takePendingLaunchCommand() {
      pendingLaunchAction = command
    }
    drainSharedInbox()
  }

  /// Picks up whatever the share extension queued — a WhatsApp voice message, a
  /// picture, an EPUB — and asks the composer to import it.
  func drainSharedInbox() {
    let items = SharedInbox.takeAll()
    guard !items.isEmpty else { return }
    var composerItems: [SharedInboxItem] = []
    for item in items {
      guard ConversationExportFiles.isConversationExport(filename: item.filename) else {
        composerItems.append(item)
        continue
      }
      defer { SharedInbox.discard(item) }
      guard let url = SharedInbox.fileURL(for: item),
        let data = try? Data(contentsOf: url)
      else {
        errorMessage = "Could not read \(item.filename)."
        continue
      }
      enqueueConversationImport(filename: item.filename, data: data)
    }
    guard !composerItems.isEmpty else { return }
    queuedSharedItems += composerItems
    sharedImportRequestID &+= 1
  }

  /// Queues a registered `.pocketmai.json` document opened from Files, AirDrop,
  /// Mail, or another application.
  func openConversationImportFile(at url: URL) {
    guard url.isFileURL,
      ConversationExportFiles.isConversationExport(filename: url.lastPathComponent)
    else { return }
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access { url.stopAccessingSecurityScopedResource() }
    }
    guard let data = try? Data(contentsOf: url) else {
      errorMessage = "Could not read \(url.lastPathComponent)."
      return
    }
    enqueueConversationImport(filename: url.lastPathComponent, data: data)
  }

  func finishConversationImportFile(id: UUID) {
    pendingConversationImportFiles.removeAll { $0.id == id }
  }

  private func enqueueConversationImport(filename: String, data: Data) {
    pendingConversationImportFiles.append(
      PendingConversationImportFile(filename: filename, data: data))
  }

  var hasQueuedSharedItems: Bool {
    !queuedSharedItems.isEmpty
  }

  /// Hands the queued shared items to the composer, which imports them through
  /// the usual attachment workflow.
  func takeQueuedSharedItems() -> [SharedInboxItem] {
    let items = queuedSharedItems
    queuedSharedItems = []
    return items
  }

  func requestComposerFocus() {
    composerFocusRequestID &+= 1
  }

  func replaceComposerDraft(with text: String, in conversationID: UUID) {
    setDraftText(text, for: conversationID)
    composerDraftReplacement = ComposerDraftReplacement(
      conversationID: conversationID,
      text: text)
    requestComposerFocus()
  }

  func consumeComposerDraftReplacement(_ replacementID: UUID) {
    guard composerDraftReplacement?.id == replacementID else { return }
    composerDraftReplacement = nil
  }

  /// Mirrors the current provider/model into the shared App Group and asks the
  /// widgets to reload so home/lock-screen widgets follow the app's selection.
  func publishWidgetSelection() {
    let labels = widgetProviderModelLabels()
    guard labels.provider != SharedAppState.providerLabel
      || labels.model != SharedAppState.modelLabel
    else {
      return
    }
    SharedAppState.providerLabel = labels.provider
    SharedAppState.modelLabel = labels.model
    WidgetCenter.shared.reloadAllTimelines()
  }

  private func widgetProviderModelLabels() -> (provider: String, model: String) {
    guard let conversation = activeConversation ?? currentConversation else {
      return ("PocketMai", "")
    }
    let provider: String
    switch conversation.provider {
    case .apple:
      provider = appleIntelligenceIsAvailable ? "Apple Intelligence" : "MLX Local"
    case .mlx:
      provider = "MLX Local"
    case .openAICompatible:
      let endpoint = conversation.endpointID.flatMap { id in
        settings.openAIEndpoints.first(where: { $0.id == id })
      }
      provider = endpoint?.displayName ?? "OpenAI Compatible"
    }
    let model = conversation.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    return (provider, model)
  }

  /// Avoid a scan on ordinary message mutations. A fallback is needed briefly while an array
  /// insertion, removal, or sort is in progress and the index cache still describes the old order.
  private func cachedConversation(withID id: UUID) -> Conversation? {
    if let index = conversationIndexByID[id],
      conversations.indices.contains(index),
      conversations[index].id == id
    {
      return conversations[index]
    }
    return conversations.first(where: { $0.id == id })
  }

  private func indexedConversationIndex(for id: UUID) -> Int? {
    if let index = conversationIndexByID[id],
      conversations.indices.contains(index),
      conversations[index].id == id
    {
      return index
    }
    rebuildConversationIndexes()
    guard let index = conversationIndexByID[id],
      conversations.indices.contains(index),
      conversations[index].id == id
    else {
      return nil
    }
    return index
  }

  private func rebuildConversationIndexes() {
    var conversationIndexes: [UUID: Int] = [:]
    conversationIndexes.reserveCapacity(conversations.count)

    for (conversationIndex, conversation) in conversations.enumerated() {
      conversationIndexes[conversation.id] = conversationIndex
    }

    conversationIndexByID = conversationIndexes
  }

  private func messageLocation(for id: UUID) -> (conversationIndex: Int, messageIndex: Int)? {
    if let selectedIndex = currentConversationIndex,
      let messageIndex = conversations[selectedIndex].messages.firstIndex(where: { $0.id == id })
    {
      return (selectedIndex, messageIndex)
    }
    for conversationIndex in conversations.indices {
      guard conversationIndex != currentConversationIndex else { continue }
      if let messageIndex = conversations[conversationIndex].messages.firstIndex(where: {
        $0.id == id
      }) {
        return (conversationIndex, messageIndex)
      }
    }
    return nil
  }

  func setAssistantMessage(
    id: UUID, text: String, role: ChatRole, touch: Bool = true, streaming: Bool = false
  ) {
    if streaming {
      // Token-rate updates land in a side buffer so `conversations` is not
      // republished per token. Bubbles read from this buffer when present.
      enqueueStreamingText(text, for: id)
      return
    }
    // Final / discrete update: write the canonical message first so any
    // re-render observing the streaming buffer being cleared sees the final
    // text in `message.text` instead of the empty placeholder it started with.
    if let location = messageLocation(for: id) {
      let conversationIndex = location.conversationIndex
      let messageIndex = location.messageIndex
      var conversation = conversations[conversationIndex]
      conversation.messages[messageIndex].text = text
      conversation.messages[messageIndex].role = role
      if touch {
        conversation.updatedAt = Date()
      }
      conversations[conversationIndex] = conversation
      upsertSummary(for: conversation)
    }
    streamingTextStore.clear(id: id)
  }

  func attachGenerationStats(_ stats: GenerationStats, toMessage id: UUID) {
    guard let location = messageLocation(for: id) else { return }
    var conversation = conversations[location.conversationIndex]
    conversation.messages[location.messageIndex].stats = stats
    conversations[location.conversationIndex] = conversation
  }

  private func enqueueStreamingText(_ text: String, for id: UUID) {
    guard messageLocation(for: id) != nil else {
      streamingTextStore.clear(id: id)
      return
    }
    streamingTextStore.enqueue(text, for: id)
  }

  private func clearStreamingText(for messages: [ChatMessage]) {
    for message in messages {
      streamingTextStore.clear(id: message.id)
    }
  }

  private static func decodeConversationImportEnvelope(
    from data: Data
  ) throws -> ConversationExportEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    do {
      let envelope = try decoder.decode(ConversationExportEnvelope.self, from: data)
      guard envelope.format == ConversationExportEnvelope.format else {
        throw ConversationImportError.invalidJSON
      }
      return envelope
    } catch let error as ConversationImportError {
      throw error
    } catch {
      throw ConversationImportError.invalidJSON
    }
  }

  private func conversationImportConflict(
    for importedConversation: Conversation
  ) -> ConversationImportConflict? {
    let title = importedConversation.displayTitle
    let matchingTitleConversations = conversations.filter {
      !isDisposableNewConversation($0)
        && normalizedConversationTitle($0.displayTitle) == normalizedConversationTitle(title)
    }
    guard !matchingTitleConversations.isEmpty else { return nil }
    if let sameContents = matchingTitleConversations.first(where: {
      conversationContentsMatch($0, importedConversation)
    }) {
      return ConversationImportConflict(
        existingID: sameContents.id,
        existingTitle: sameContents.displayTitle,
        contentsMatch: true
      )
    }
    guard let differentContents = matchingTitleConversations.first else { return nil }
    return ConversationImportConflict(
      existingID: differentContents.id,
      existingTitle: differentContents.displayTitle,
      contentsMatch: false
    )
  }

  private func conversationWithTitle(_ title: String) -> Conversation? {
    let normalizedTitle = normalizedConversationTitle(title)
    return conversations.first {
      !isDisposableNewConversation($0)
        && normalizedConversationTitle($0.displayTitle) == normalizedTitle
    }
  }

  private func existingConversationImportTitles() -> [String] {
    conversations.filter { !isDisposableNewConversation($0) }.map(\.displayTitle)
  }

  private func normalizedConversationTitle(_ title: String) -> String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private func conversationContentsMatch(_ lhs: Conversation, _ rhs: Conversation) -> Bool {
    normalizedConversationTitle(lhs.displayTitle) == normalizedConversationTitle(rhs.displayTitle)
      && lhs.createdAt == rhs.createdAt
      && lhs.provider == rhs.provider
      && lhs.modelID == rhs.modelID
      && lhs.endpointID == rhs.endpointID
      && lhs.systemPromptID == rhs.systemPromptID
      && lhs.toolsEnabled == rhs.toolsEnabled
      && lhs.enabledTools == rhs.enabledTools
      && lhs.enabledMCPServers == rhs.enabledMCPServers
      && lhs.enabledMCPTools == rhs.enabledMCPTools
      && lhs.usesStreaming == rhs.usesStreaming
      && lhs.disabledMCPTools == rhs.disabledMCPTools
      && lhs.reasoningLevel == rhs.reasoningLevel
      && lhs.showThinking == rhs.showThinking
      && lhs.lastContextSignature == rhs.lastContextSignature
      && lhs.effectiveLanguageOverrideIdentifier == rhs.effectiveLanguageOverrideIdentifier
      && lhs.subagents == rhs.subagents
      && messageContentsMatch(lhs.messages, rhs.messages)
  }

  private func messageContentsMatch(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { lhsMessage, rhsMessage in
      lhsMessage.role == rhsMessage.role
        && lhsMessage.text == rhsMessage.text
        && lhsMessage.displayText == rhsMessage.displayText
        && lhsMessage.createdAt == rhsMessage.createdAt
        && lhsMessage.voiceRecordingFilename == rhsMessage.voiceRecordingFilename
        && lhsMessage.attachments == rhsMessage.attachments
    }
  }

  private func uniqueConversationID() -> UUID {
    var id = UUID()
    while conversationIndexByID[id] != nil {
      id = UUID()
    }
    return id
  }

  private func export(
    conversation: Conversation,
    format: ConversationExportFormat,
    debugContext: ContextBuilder.Output? = nil
  ) -> String {
    switch format {
    case .markdown:
      return MarkdownExport.text(
        for: ConversationExportContent.exportDocument(
          conversation: conversation,
          includeThinking: effectiveShowThinking(for: conversation)))
    case .json, .debug:
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      var envelope = ConversationExportEnvelope(
        conversation: conversation,
        toolCallingDebug: format == .debug
          ? toolCallingDebug(for: conversation, context: debugContext) : nil)
      envelope.portable = MaiArchive(
        generator: "PocketMai \(ConversationExportEnvelope.currentPocketMaiVersion)",
        chats: [AgentChat(pocketMai: conversation, settings: settings)])
      guard let data = try? encoder.encode(envelope),
        let json = String(data: data, encoding: .utf8)
      else {
        return "{}"
      }
      return json
    case .html, .epub, .docx, .audio:
      return ""
    }
  }

  private func toolCallingDebug(
    for conversation: Conversation,
    context: ContextBuilder.Output?
  ) -> ConversationToolCallingDebug {
    let fullDefinitions = ToolAgentRegistry.definitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let visibleDefinitions = ToolAgentRegistry.visibleDefinitions(
      for: conversation,
      settings: settings,
      mcpTools: mcpTools,
      mcpResources: mcpResources,
      mcpStatuses: mcpStatuses)
    let providerNativeToolCalling =
      settings.toolCallingMode == .native
      && conversation.provider.supportsNativeToolCalling
      && !visibleDefinitions.isEmpty
    let effectiveMode =
      providerNativeToolCalling
      ? ToolCallingMode.native
      : settings.toolCallingMode.textProtocolFallback(for: conversation.provider)
    let textToolPrompt =
      providerNativeToolCalling
      ? "" : AgentTooling.promptDescription(for: visibleDefinitions, mode: effectiveMode)
    let toolPrompt = textToolPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    let toolPromptInContext = !providerNativeToolCalling && !toolPrompt.isEmpty
    let nativeToolNames: [String] = {
      guard providerNativeToolCalling else { return [] }
      let resolver = AgentToolNameResolver(tools: visibleDefinitions)
      return visibleDefinitions.map { resolver.apiName(for: $0.name) }
    }()
    let maxToolCalls = AppSettings.clampedMaxToolCallsPerTurn(settings.maxToolCallsPerTurn)
    let maxRepairTurns = min(4, maxToolCalls + 1)
    let contextPrompt = context?.text ?? ""
    let requestContext = [contextPrompt, toolPrompt]
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
    let systemPrompt = PromptComposer.systemPrompt(settings: settings, conversation: conversation)
    let providerSystemPrompt =
      requestContext.isEmpty ? systemPrompt : "\(systemPrompt)\n\n## Context\n\(requestContext)"
    let hasToolCalling = !visibleDefinitions.isEmpty
    let applePrompt = PromptComposer.applePrompt(
      conversation: conversation,
      settings: settings,
      context: requestContext,
      hasTools: hasToolCalling,
      toolPrompt: providerNativeToolCalling ? "" : toolPrompt,
      toolPromptInContext: toolPromptInContext)
    let messageIDs = Set(conversation.messages.map(\.id))
    let runtimeIterations =
      (toolCallingDebugIterations[conversation.id] ?? [])
      .filter { messageIDs.contains($0.assistantMessageID) }
    let storedIterations = debugToolIterations(in: conversation)

    return ConversationToolCallingDebug(
      selectedMode: settings.toolCallingMode.rawValue,
      selectedModeDisplayName: settings.toolCallingMode.displayName,
      effectiveMode: effectiveMode.rawValue,
      effectiveModeDisplayName: effectiveMode.displayName,
      textProtocolFallback: settings.toolCallingMode.textProtocolFallback(
        for: conversation.provider
      )
      .rawValue,
      providerNativeToolCalling: providerNativeToolCalling,
      nativeToolCallingUnavailableReason: nativeToolCallingUnavailableReason(
        conversation: conversation,
        hasTools: hasToolCalling),
      toolCatalogInlinedInPrompt: !providerNativeToolCalling && hasToolCalling,
      nativeToolNames: nativeToolNames,
      maxToolCallsPerTurn: maxToolCalls,
      maxRepairTurnsPerTurn: maxRepairTurns,
      mcpRequestTimeoutSeconds: AppSettings.clampedMCPRequestTimeoutSeconds(
        settings.mcpRequestTimeoutSeconds),
      yoloModeEnabled: settings.yoloModeEnabled,
      useToolProxy: settings.useToolProxy,
      airplaneModeEnabled: settings.airplaneModeEnabled,
      contextWindowMode: settings.contextWindowMode.rawValue,
      contextWindowMessageLimit: settings.contextWindowMode.messageLimit,
      includeAssistantResponsesInContext: settings.includeAssistantResponsesInContext,
      includeReasoningContentInContext: settings.includeReasoningContentInContext,
      defaultEnabledTools: settings.defaultEnabledTools.map(\.rawValue).sorted(),
      defaultEnabledMCPServers: settings.defaultEnabledMCPServers.map(\.uuidString).sorted(),
      defaultEnabledMCPTools: Array(settings.defaultEnabledMCPTools).sorted(),
      toolsEnabled: conversation.toolsEnabled,
      enabledTools: conversation.enabledTools.map(\.rawValue).sorted(),
      enabledMCPServers: conversation.enabledMCPServers.map(\.uuidString).sorted(),
      enabledMCPTools: Array(conversation.enabledMCPTools).sorted(),
      disabledMCPTools: Array(conversation.disabledMCPTools).sorted(),
      mcpServers: settings.mcpServers.map { server in
        ConversationDebugMCPServer(
          id: server.id,
          name: server.name,
          isEnabled: server.isEnabled,
          hasValidScheme: server.hasValidEndpointURL,
          transport: server.transport?.displayName,
          connectionStatus: (mcpStatuses[server.id] ?? .unknown).statusText)
      },
      nativeToolSettings: debugNativeToolSettings(settings.toolSettings),
      fullToolDefinitions: debugDefinitions(fullDefinitions),
      visibleToolDefinitions: debugDefinitions(visibleDefinitions),
      toolPrompt: toolPrompt,
      contextPrompt: contextPrompt,
      contextSignature: context?.signature ?? "",
      lastStoredContextSignature: conversation.lastContextSignature,
      systemPrompt: systemPrompt,
      providerSystemPrompt: providerSystemPrompt,
      applePrompt: applePrompt,
      promptMessages: debugPromptMessages(
        conversation: conversation,
        systemPrompt: providerSystemPrompt,
        messageLimit: settings.contextWindowMode.messageLimit,
        toolPrompt: providerNativeToolCalling ? "" : toolPrompt,
        toolPromptInContext: toolPromptInContext),
      iterations: runtimeIterations.isEmpty ? storedIterations : runtimeIterations,
      notes: [
        "Debug prompt data is reconstructed at export time from current settings.",
        "Runtime iterations are included for tool loops completed in the current app session.",
        "The original per-iteration provider request payload is not persisted across app launches.",
      ])
  }

  private func nativeToolCallingUnavailableReason(
    conversation: Conversation,
    hasTools: Bool
  ) -> String? {
    guard settings.toolCallingMode == .native, hasTools else { return nil }
    guard !conversation.provider.supportsNativeToolCalling else { return nil }
    return
      "\(conversation.provider.displayName) does not expose native tool calling; using \(settings.toolCallingMode.textProtocolFallback(for: conversation.provider).displayName) text fallback."
  }

  private func debugNativeToolSettings(
    _ toolSettings: NativeToolSettings
  ) -> ConversationDebugNativeToolSettings {
    let searXNGURL = toolSettings.webSearchSearXNGURL.trimmingCharacters(
      in: .whitespacesAndNewlines)
    return ConversationDebugNativeToolSettings(
      includeTimeZone: toolSettings.includeTimeZone,
      includeMoonPhase: toolSettings.includeMoonPhase,
      useGPSLocation: toolSettings.useGPSLocation,
      manualLocationConfigured: !toolSettings.manualLocation.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      weatherLocationConfigured: !toolSettings.weatherLocation.trimmingCharacters(
        in: .whitespacesAndNewlines
      ).isEmpty,
      webSearchProvider: toolSettings.webSearchProvider.rawValue,
      webSearchSearXNGURLConfigured: !searXNGURL.isEmpty,
      webSearchSearXNGURLHost: URLComponents(string: searXNGURL)?.host,
      webSearchSearXNGUsernameConfigured: !toolSettings.webSearchSearXNGUsername
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      webSearchSearXNGPasswordConfigured: !toolSettings.webSearchSearXNGPassword.isEmpty,
      webSearchFetchingEnabled: toolSettings.webSearchFetchingEnabled,
      calendarEventCreationEnabled: toolSettings.calendarEventCreationEnabled,
      filesWorkspaceAccessEnabled: toolSettings.filesWorkspaceAccessEnabled,
      filesAdvancedToolsEnabled: toolSettings.filesAdvancedToolsEnabled,
      configuredToolFilesCount: toolSettings.files.count,
      todoCount: toolSettings.todos.count)
  }

  private func debugDefinitions(
    _ definitions: [ToolDefinition]
  ) -> [ConversationDebugToolDefinition] {
    definitions.map { definition in
      ConversationDebugToolDefinition(
        name: definition.name,
        description: definition.description,
        parameters: definition.parameters.map { parameter in
          ConversationDebugToolParameter(
            name: parameter.name,
            type: parameter.type,
            description: parameter.description,
            required: parameter.required)
        },
        inputSchemaJSON: definition.inputSchemaJSON.trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty ? nil : definition.inputSchemaJSON)
    }
  }

  private func debugPromptMessages(
    conversation: Conversation,
    systemPrompt: String,
    messageLimit: Int?,
    toolPrompt: String = "",
    toolPromptInContext: Bool = false
  ) -> [ConversationDebugPromptMessage] {
    let limited = PromptComposer.contextMessages(
      from: conversation, settings: settings, limit: messageLimit)
    var messages = [ConversationDebugPromptMessage(role: "system", content: systemPrompt)]
    messages.append(
      contentsOf: limited.flatMap { message in
        PromptComposer.contextTranscriptEntries(from: message, settings: settings).map { entry in
          ConversationDebugPromptMessage(
            role: debugRole(displayName: entry.displayName),
            content: entry.content)
        }
      })
    if let reminder = PromptComposer.toolCallingReminder(
      toolPrompt: toolPrompt,
      includeToolPrompt: !toolPromptInContext)
    {
      messages.append(ConversationDebugPromptMessage(role: "user", content: reminder))
    }
    return messages
  }

  private func debugRole(displayName: String) -> String {
    switch displayName {
    case ChatRole.system.displayName:
      return "system"
    case ChatRole.assistant.displayName:
      return "assistant"
    default:
      return "user"
    }
  }

  private func debugToolIterations(in conversation: Conversation)
    -> [ConversationDebugToolIteration]
  {
    var iterations: [ConversationDebugToolIteration] = []
    for (messageIndex, message) in conversation.messages.enumerated()
    where message.role == .assistant {
      for rawBlock in toolRunBlocks(in: message.text) {
        let parsed = parseToolRunBlock(rawBlock)
        iterations.append(
          ConversationDebugToolIteration(
            assistantMessageID: message.id,
            assistantMessageIndex: messageIndex,
            roundIndex: iterations.count + 1,
            toolName: parsed.toolName,
            argumentsJSON: parsed.argumentsJSON,
            result: parsed.result,
            isError: parsed.result.trimmingCharacters(in: .whitespacesAndNewlines)
              .lowercased()
              .hasPrefix("error:"),
            rawBlock: rawBlock))
      }
    }
    return iterations
  }

  private func toolRunBlocks(in text: String) -> [String] {
    let pattern = "<tool_run\\b[^>]*>[\\s\\S]*?</tool_run\\s*>"
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    else { return [] }
    let nsText = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
      .map { nsText.substring(with: $0.range) }
  }

  private func parseToolRunBlock(_ rawBlock: String) -> (
    toolName: String, argumentsJSON: String, result: String
  ) {
    let body =
      rawBlock
      .replacingOccurrences(
        of: "^<tool_run\\b[^>]*>",
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .replacingOccurrences(
        of: "</tool_run\\s*>$",
        with: "",
        options: [.regularExpression, .caseInsensitive]
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let nsBody = body as NSString
    let headerPattern = #"^([^\n]+?) tool \((.*)\):\s*\n?"#
    guard let regex = try? NSRegularExpression(pattern: headerPattern),
      let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: nsBody.length)),
      match.numberOfRanges == 3
    else {
      return ("unknown", "{}", body)
    }
    let toolName = nsBody.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let argumentsJSON = nsBody.substring(with: match.range(at: 2))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let result = nsBody.substring(from: match.range.upperBound)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (toolName, argumentsJSON, result)
  }

  // MARK: - Settings Backup (Import / Export / Clear)

  func exportSettingsBackupFile(
    scope: SettingsBackupScope,
    includeAudio: Bool = false,
    includePictures: Bool = false
  ) async -> URL? {
    let selection = SettingsBackupSelection(scope: scope)
    if selection.conversations {
      await loadStoredConversationsForSearch()
    }
    let envelope = await makeBackupEnvelope(
      selection: selection,
      includeAudio: includeAudio,
      includePictures: includePictures)
    return exportSettingsBackupFile(envelope: envelope, filename: backupFilename(scope: scope))
  }

  func exportSettingsBackupFile(
    selection: SettingsBackupSelection,
    includeAudio: Bool = false,
    includePictures: Bool = false
  ) async -> URL? {
    guard !selection.isEmpty else {
      errorMessage = SettingsBackupError.emptySelection.localizedDescription
      return nil
    }
    if selection.conversations {
      await loadStoredConversationsForSearch()
    }
    let envelope = await makeBackupEnvelope(
      selection: selection,
      includeAudio: includeAudio,
      includePictures: includePictures)
    return exportSettingsBackupFile(
      envelope: envelope, filename: backupFilename(selection: selection))
  }

  func exportEndpointBackupFile(_ endpoint: OpenAIEndpoint) -> URL? {
    let providers = SettingsProvidersBackup(
      endpoints: [endpoint],
      selectedEndpointID: endpoint.id,
      defaultProvider: .openAICompatible)
    let envelope = SettingsBackupEnvelope(
      providers: providers,
      portable: MaiArchive(
        generator: "PocketMai \(ConversationExportEnvelope.currentPocketMaiVersion)",
        settings: MaiArchiveSettings(providers: [ConfiguredProvider(pocketMai: endpoint)])))
    return exportSettingsBackupFile(envelope: envelope, filename: backupFilename(for: endpoint))
  }

  private func exportSettingsBackupFile(envelope: SettingsBackupEnvelope, filename: String) -> URL?
  {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    guard let data = try? encoder.encode(envelope) else {
      errorMessage = "Could not encode backup."
      return nil
    }
    do {
      let url = try ConversationExportFiles.url(
        filename: filename,
        fileExtension: MaiArchive.fileExtension)
      try data.write(to: url, options: .atomic)
      return url
    } catch {
      errorMessage = "Could not write backup: \(error.localizedDescription)"
      return nil
    }
  }

  private func makeBackupEnvelope(
    selection: SettingsBackupSelection,
    includeAudio: Bool,
    includePictures: Bool
  )
    async -> SettingsBackupEnvelope
  {
    let baseConversations =
      selection.conversations
      ? (includePictures ? conversations : conversationsRemovingImageAttachments(conversations))
      : nil
    var exportedConversations: [Conversation]? = nil
    if let baseConversations {
      var snapshots: [Conversation] = []
      for conversation in baseConversations {
        snapshots.append(await conversationIncludingAgentRecords(conversation))
      }
      exportedConversations = snapshots
    }
    let attachments =
      includeAudio && selection.conversations
      ? collectVoiceRecordingAttachments(from: exportedConversations ?? [])
      : nil

    let portableSettings = MaiArchiveSettings(
      providers: selection.providers
        ? settings.openAIEndpoints.map { ConfiguredProvider(pocketMai: $0) } : nil,
      prompts: selection.prompts ? ConfiguredPrompts(pocketMai: settings) : nil,
      mcpServers: selection.tools
        ? settings.mcpServers.map { ConfiguredMCPServer(pocketMai: $0) } : nil)
    let portable = MaiArchive(
      generator: "PocketMai \(ConversationExportEnvelope.currentPocketMaiVersion)",
      settings: portableSettings,
      chats: selection.conversations
        ? (exportedConversations ?? []).map { AgentChat(pocketMai: $0, settings: settings) }
        : nil)
    return SettingsBackupEnvelope(
      providers: selection.providers ? providersBackup() : nil,
      prompts: selection.prompts ? promptsBackup() : nil,
      tools: selection.tools ? toolsBackup() : nil,
      conversations: exportedConversations,
      conversationFolders: selection.conversations ? settings.conversationFolders : nil,
      conversationFolderDefaults: selection.conversations
        ? settings.conversationFolderDefaults : nil,
      voiceRecordings: attachments,
      portable: portable)
  }

  private func collectVoiceRecordingAttachments(from conversations: [Conversation])
    -> [SettingsVoiceRecordingAttachment]
  {
    var seen = Set<String>()
    var attachments: [SettingsVoiceRecordingAttachment] = []
    for conversation in conversations {
      for message in conversation.messages {
        guard let filename = Self.normalizedVoiceRecordingFilename(from: message),
          !seen.contains(filename),
          let url = PocketMaiDirectories.voiceRecordingURL(filename: filename),
          let data = try? Data(contentsOf: url)
        else { continue }
        seen.insert(filename)
        attachments.append(
          SettingsVoiceRecordingAttachment(
            filename: filename, dataBase64: data.base64EncodedString()))
      }
    }
    return attachments
  }

  private static func conversationRemovingImageAttachments(_ source: Conversation) -> Conversation {
    var copy = source
    copy.messages = copy.messages.map { message in
      var message = message
      message.attachments.removeAll { $0.kind == .image }
      return message
    }
    return copy
  }

  private func conversationsRemovingImageAttachments(_ source: [Conversation]) -> [Conversation] {
    source.map(Self.conversationRemovingImageAttachments)
  }

  private func providersBackup() -> SettingsProvidersBackup {
    SettingsProvidersBackup(
      endpoints: settings.openAIEndpoints,
      selectedEndpointID: settings.selectedEndpointID,
      defaultProvider: settings.defaultProvider)
  }

  private func promptsBackup() -> SettingsPromptsBackup {
    SettingsPromptsBackup(
      prompts: settings.systemPrompts,
      defaultSystemPromptID: settings.defaultSystemPromptID,
      compactPrompt: settings.compactPrompt,
      userPrompts: settings.userPrompts,
      followUps: settings.followUps)
  }

  private func toolsBackup() -> SettingsToolsBackup {
    SettingsToolsBackup(
      toolSettings: settings.toolSettings,
      mcpServers: settings.mcpServers,
      mcpRequestTimeoutSeconds: settings.mcpRequestTimeoutSeconds,
      defaultEnabledTools: settings.defaultEnabledTools,
      defaultEnabledMCPServers: settings.defaultEnabledMCPServers,
      defaultEnabledMCPTools: settings.defaultEnabledMCPTools,
      toolCallingMode: settings.toolCallingMode,
      maxToolCallsPerTurn: settings.maxToolCallsPerTurn,
      yoloModeEnabled: settings.yoloModeEnabled,
      useToolProxy: settings.useToolProxy)
  }

  private func backupFilename(scope: SettingsBackupScope) -> String {
    let stamp = backupTimestamp()
    let suffix: String
    switch scope {
    case .everything: suffix = "everything"
    case .providers: suffix = "providers"
    case .prompts: suffix = "prompts"
    case .tools: suffix = "tools"
    case .conversations: suffix = "conversations"
    }
    return "PocketMai-\(suffix)-\(stamp)"
  }

  private func backupFilename(selection: SettingsBackupSelection) -> String {
    let stamp = backupTimestamp()
    let suffix: String
    if selection == SettingsBackupSelection(scope: .everything) {
      suffix = "everything"
    } else {
      let names = selection.selectedSections.map(\.rawValue)
      suffix = names.isEmpty ? "backup" : names.joined(separator: "-")
    }
    return "PocketMai-\(suffix)-\(stamp)"
  }

  private func backupFilename(for endpoint: OpenAIEndpoint) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
      .union(.newlines)
      .union(.controlCharacters)
    let name = endpoint.displayName
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let providerName = name.isEmpty ? "provider" : String(name.prefix(48))
    return "PocketMai-provider-\(providerName)-\(backupTimestamp())"
  }

  private func backupTimestamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }

  @discardableResult
  func importSettingsBackup(
    from url: URL,
    scope: SettingsBackupScope,
    restoreAudio: Bool = false,
    includePictures: Bool = true
  ) throws -> String {
    let access = url.startAccessingSecurityScopedResource()
    defer {
      if access {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      throw SettingsBackupError.unreadableFile
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let envelope = try? decoder.decode(SettingsBackupEnvelope.self, from: data),
      envelope.format == SettingsBackupEnvelope.format
    else {
      throw SettingsBackupError.invalidJSON
    }
    return try applyBackup(
      envelope,
      selection: SettingsBackupSelection(scope: scope),
      restoreAudio: restoreAudio,
      includePictures: includePictures)
  }

  @discardableResult
  func importSettingsBackup(
    _ envelope: SettingsBackupEnvelope,
    selection: SettingsBackupSelection,
    restoreAudio: Bool = false,
    includePictures: Bool = true
  ) throws -> String {
    try applyBackup(
      envelope,
      selection: selection,
      restoreAudio: restoreAudio,
      includePictures: includePictures)
  }

  /// Imports the cross-host part of an archive. Unlike the native PocketMai
  /// backup path, portable sections are merged by stable id or prompt name so
  /// moving one file between the phone and pmai does not erase host-only
  /// settings on either side.
  @discardableResult
  func importPortableArchive(
    _ archive: MaiArchive,
    selection: SettingsBackupSelection,
    includePictures: Bool = true
  ) throws -> String {
    guard !selection.isEmpty else { throw SettingsBackupError.emptySelection }
    var applied: [String] = []
    if selection.providers, let providers = archive.settings?.providers {
      let imported = providers.compactMap { OpenAIEndpoint(archive: $0) }
      mergePortableProviders(imported)
      applied.append("\(imported.count) provider\(imported.count == 1 ? "" : "s")")
    }
    if selection.prompts, let prompts = archive.settings?.prompts {
      let count = mergePortablePrompts(prompts)
      applied.append("\(count) prompt\(count == 1 ? "" : "s")")
    }
    if selection.tools, let servers = archive.settings?.mcpServers {
      let imported = servers.compactMap { MCPServer(archive: $0) }
      mergePortableMCPServers(imported)
      applied.append("\(imported.count) MCP server\(imported.count == 1 ? "" : "s")")
    }
    if selection.conversations, let chats = archive.chats {
      var imported = chats.map {
        Conversation(
          archive: $0,
          settings: settings,
          providers: archive.settings?.providers ?? [])
      }
      if !includePictures {
        imported = conversationsRemovingImageAttachments(imported)
      }
      applyConversationsBackup(imported)
      applied.append("\(imported.count) conversation\(imported.count == 1 ? "" : "s")")
    }
    return finishApplyBackup(applied: applied)
  }

  @discardableResult
  private func applyBackup(
    _ envelope: SettingsBackupEnvelope,
    selection: SettingsBackupSelection,
    restoreAudio: Bool,
    includePictures: Bool
  ) throws -> String {
    guard !selection.isEmpty else { throw SettingsBackupError.emptySelection }

    var applied: [String] = []

    let available = SettingsBackupSelection(
      providers: envelope.providers != nil,
      prompts: envelope.prompts != nil,
      tools: envelope.tools != nil,
      conversations: envelope.conversations != nil)
    let missingSections = selection.selectedSections.filter { !available.contains($0) }
    if let missingSection = missingSections.first {
      throw SettingsBackupError.missingSelectedSection(missingSection)
    }

    if selection.providers, let payload = envelope.providers {
      applyProvidersBackup(payload)
      applied.append(
        "\(payload.endpoints.count) provider\(payload.endpoints.count == 1 ? "" : "s")")
    }

    if selection.prompts, let payload = envelope.prompts {
      applyPromptsBackup(payload)
      applied.append("\(payload.prompts.count) prompt\(payload.prompts.count == 1 ? "" : "s")")
    }

    if selection.tools, let payload = envelope.tools {
      applyToolsBackup(payload)
      applied.append("tool settings")
    }

    if selection.conversations, let payload = envelope.conversations {
      let conversationsPayload =
        includePictures ? payload : payload.map(Self.conversationRemovingImageAttachments)
      applyConversationFoldersBackup(envelope.conversationFolders, for: conversationsPayload)
      applyConversationFolderDefaultsBackup(envelope.conversationFolderDefaults)
      applyConversationsBackup(conversationsPayload)
      applied.append(
        "\(conversationsPayload.count) conversation\(conversationsPayload.count == 1 ? "" : "s")")

      if restoreAudio, let attachments = envelope.voiceRecordings, !attachments.isEmpty {
        let restored = restoreVoiceRecordings(attachments)
        if restored > 0 {
          applied.append("\(restored) audio file\(restored == 1 ? "" : "s")")
        }
      }
    }

    return finishApplyBackup(applied: applied)
  }

  private func restoreVoiceRecordings(_ attachments: [SettingsVoiceRecordingAttachment]) -> Int {
    guard let directory = try? PocketMaiDirectories.ensureVoiceRecordings() else { return 0 }
    var restored = 0
    for attachment in attachments {
      let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !filename.isEmpty,
        PocketMaiDirectories.voiceRecordingURL(filename: filename) != nil,
        let data = Data(base64Encoded: attachment.dataBase64)
      else { continue }
      let url = directory.appendingPathComponent(filename)
      if (try? data.write(to: url, options: .atomic)) != nil {
        restored += 1
      }
    }
    return restored
  }

  private func finishApplyBackup(applied: [String]) -> String {
    saveSettings()
    if applied.isEmpty {
      return "Nothing to import."
    }
    return "Imported: " + applied.joined(separator: ", ") + "."
  }

  private func applyProvidersBackup(_ payload: SettingsProvidersBackup) {
    settings.openAIEndpoints = payload.endpoints
    if let selected = payload.selectedEndpointID,
      payload.endpoints.contains(where: { $0.id == selected })
    {
      settings.selectedEndpointID = selected
    } else {
      settings.selectedEndpointID = payload.endpoints.first?.id
    }
    if let provider = payload.defaultProvider {
      if provider == .apple && !appleIntelligenceIsAvailable {
        settings.defaultProvider = .mlx
      } else if provider == .openAICompatible && settings.selectedEndpointID == nil {
        settings.defaultProvider = .mlx
      } else {
        settings.defaultProvider = provider
      }
    }
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
  }

  private func mergePortableProviders(_ imported: [OpenAIEndpoint]) {
    for var endpoint in imported {
      let match = settings.openAIEndpoints.firstIndex {
        $0.id == endpoint.id
          || ($0.portableID != nil && $0.portableID == endpoint.portableID)
          || ($0.name.caseInsensitiveCompare(endpoint.name) == .orderedSame
            && $0.baseURL == endpoint.baseURL)
      }
      if let match {
        endpoint.id = settings.openAIEndpoints[match].id
        settings.openAIEndpoints[match] = endpoint
      } else {
        settings.openAIEndpoints.append(endpoint)
      }
    }
    if settings.selectedEndpointID == nil {
      settings.selectedEndpointID = settings.openAIEndpoints.first?.id
    }
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
  }

  private func applyPromptsBackup(_ payload: SettingsPromptsBackup) {
    let prompts = payload.prompts.isEmpty ? [AppSettings.defaultSystemPrompt] : payload.prompts
    settings.systemPrompts = prompts
    if let id = payload.defaultSystemPromptID, prompts.contains(where: { $0.id == id }) {
      settings.defaultSystemPromptID = id
    } else {
      settings.defaultSystemPromptID = prompts.first?.id ?? AppSettings.defaultSystemPrompt.id
    }
    if let compactPrompt = payload.compactPrompt {
      settings.compactPrompt = compactPrompt
    }
    if let userPrompts = payload.userPrompts {
      settings.userPrompts = userPrompts
    }
    if let followUps = payload.followUps {
      settings.followUps = followUps
    }
  }

  private func mergePortablePrompts(_ imported: ConfiguredPrompts) -> Int {
    func key(_ name: String) -> String {
      PromptSlashCommand.normalized(PromptSlashCommand.commandName(for: name))
    }
    for (name, text) in imported.system.sorted(by: { $0.key < $1.key }) {
      if let index = settings.systemPrompts.firstIndex(where: { key($0.displayName) == key(name) }) {
        settings.systemPrompts[index].name = name
        settings.systemPrompts[index].text = text
      } else {
        settings.systemPrompts.append(SystemPrompt(name: name, text: text))
      }
    }
    for (name, text) in imported.user.sorted(by: { $0.key < $1.key }) {
      if let index = settings.userPrompts.firstIndex(where: { key($0.displayName) == key(name) }) {
        settings.userPrompts[index].name = name
        settings.userPrompts[index].text = text
      } else {
        settings.userPrompts.append(UserPrompt(name: name, text: text))
      }
    }
    if let compact = imported.compact { settings.compactPrompt = compact }
    return imported.system.count + imported.user.count
  }

  private func applyToolsBackup(_ payload: SettingsToolsBackup) {
    settings.toolSettings = payload.toolSettings
    settings.mcpServers = payload.mcpServers
    if let timeout = payload.mcpRequestTimeoutSeconds {
      settings.mcpRequestTimeoutSeconds = AppSettings.clampedMCPRequestTimeoutSeconds(timeout)
    }
    if let tools = payload.defaultEnabledTools {
      settings.defaultEnabledTools = tools
    }
    if let servers = payload.defaultEnabledMCPServers {
      settings.defaultEnabledMCPServers = servers
    }
    if let mcpTools = payload.defaultEnabledMCPTools {
      settings.defaultEnabledMCPTools = mcpTools
    }
    if let mode = payload.toolCallingMode {
      settings.toolCallingMode = mode
    }
    if let limit = payload.maxToolCallsPerTurn {
      settings.maxToolCallsPerTurn = AppSettings.clampedMaxToolCallsPerTurn(limit)
    }
    if let yolo = payload.yoloModeEnabled {
      settings.yoloModeEnabled = yolo
    }
    if let proxy = payload.useToolProxy {
      settings.useToolProxy = proxy
    }
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
  }

  private func mergePortableMCPServers(_ imported: [MCPServer]) {
    for var server in imported {
      let match = settings.mcpServers.firstIndex {
        $0.id == server.id
          || ($0.portableID != nil && $0.portableID == server.portableID)
          || ($0.name.caseInsensitiveCompare(server.name) == .orderedSame
            && $0.baseURL == server.baseURL)
      }
      if let match {
        server.id = settings.mcpServers[match].id
        settings.mcpServers[match] = server
      } else {
        settings.mcpServers.append(server)
      }
    }
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
  }

  private func applyConversationsBackup(_ payload: [Conversation]) {
    let existingByID = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    var merged = conversations
    for var imported in payload {
      if existingByID[imported.id] != nil {
        imported.id = uniqueConversationID()
      }
      imported.updatedAt = Date()
      merged.insert(imported, at: 0)
    }
    conversations = merged
    sortConversations()
    rebuildConversationIndexes()
    conversationSummaries = Self.sortedSummaries(conversations.map(ConversationSummary.init))
    refreshRecentConversationSummaries()
    saveConversations()
  }

  private func applyConversationFoldersBackup(
    _ importedFolders: [ConversationFolder]?,
    for importedConversations: [Conversation]
  ) {
    var folders = settings.conversationFolders
    var knownIDs = Set(
      [ConversationFolder.defaultID, ConversationFolder.iCloudID, ConversationFolder.archivedID]
        + folders.map(\.id))

    for folder in AppSettings.normalizedConversationFolders(importedFolders ?? []) {
      guard !knownIDs.contains(folder.id) else { continue }
      folders.append(folder)
      knownIDs.insert(folder.id)
    }

    var importedFolderCount = 1
    for conversation in importedConversations {
      let folderID = conversation.folderID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !folderID.isEmpty,
        !knownIDs.contains(folderID),
        !ConversationFolder.reservedIDs.contains(folderID)
      else {
        continue
      }
      let name =
        importedFolderCount == 1 ? "Imported Folder" : "Imported Folder \(importedFolderCount)"
      folders.append(ConversationFolder(id: folderID, name: name))
      knownIDs.insert(folderID)
      importedFolderCount += 1
    }

    settings.conversationFolders = AppSettings.normalizedConversationFolders(folders)
    if !Set(conversationFolders.map(\.id)).contains(settings.selectedConversationFolderID) {
      settings.selectedConversationFolderID = ConversationFolder.defaultID
    }
  }

  private func applyConversationFolderDefaultsBackup(
    _ importedDefaults: [String: ConversationFolderDefaults]?
  ) {
    guard let importedDefaults else { return }
    let knownIDs = Set(conversationFolders.map(\.id))
    let normalized = AppSettings.normalizedConversationFolderDefaults(
      importedDefaults,
      knownFolderIDs: knownIDs)
    settings.conversationFolderDefaults.merge(normalized) { _, imported in imported }
  }

  // MARK: - Clear actions

  func clearProviderSettings() {
    settings.openAIEndpoints.removeAll()
    settings.selectedEndpointID = nil
    if settings.defaultProvider == .openAICompatible {
      settings.defaultProvider = .mlx
    }
    endpointStatuses.removeAll()
    endpointModels.removeAll()
    endpointVoices.removeAll()
    saveSettings()
  }

  func clearSystemPrompts() {
    settings.systemPrompts = [AppSettings.defaultSystemPrompt]
    settings.userPrompts = AppSettings.defaultUserPrompts
    settings.defaultSystemPromptID = AppSettings.defaultSystemPrompt.id
    settings.compactPrompt = AppSettings.defaultCompactPrompt
    settings.followUps = .defaults
    saveSettings()
  }

  func clearToolSettings() {
    settings.toolSettings = .defaults
    settings.defaultEnabledTools = AppSettings.defaultTools
    settings.defaultEnabledMCPTools = AppSettings.defaultMCPTools
    saveSettings()
  }

  func clearMCPServers() {
    settings.mcpServers.removeAll()
    settings.defaultEnabledMCPServers.removeAll()
    settings.defaultEnabledMCPTools.removeAll()
    mcpStatuses.removeAll()
    mcpTools.removeAll()
    mcpResources.removeAll()
    Task { await MCPHTTPClient.resetAllSessions() }
    saveSettings()
  }

  func clearMemory() {
    settings.memory = ""
    saveSettings()
  }

  @discardableResult
  func clearDownloadedMLXModels() -> String {
    let models = LocalMLXModelCache.listModels()
    var removed = 0
    var failed: [String] = []
    for model in models {
      do {
        try LocalMLXModelCache.delete(model)
        removed += 1
      } catch {
        failed.append(model.repoID)
      }
    }
    refreshLocalMLXModels()
    if !failed.isEmpty {
      return
        "Removed \(removed) model\(removed == 1 ? "" : "s"); failed: \(failed.joined(separator: ", "))."
    }
    return "Removed \(removed) downloaded model\(removed == 1 ? "" : "s")."
  }

  @discardableResult
  func clearFilesWorkspace() -> String {
    let url = PocketMaiDirectories.filesWorkspaceURL
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
    else {
      return "Workspace is empty."
    }
    var removed = 0
    for entry in entries {
      if (try? fileManager.removeItem(at: entry)) != nil {
        removed += 1
      }
    }
    _ = try? PocketMaiDirectories.ensureFilesWorkspace()
    return "Removed \(removed) workspace item\(removed == 1 ? "" : "s")."
  }
}

/// A narrow observation boundary for large view trees that use AppStore for actions but should
/// not be invalidated by every unrelated @Published property on the monolithic store.
@MainActor
final class AppStoreViewObservation: ObservableObject {
  enum Scope {
    case application
    case content
    case chat
    case sidebar
    case settings
  }

  @Published private(set) var revision = 0

  private let scope: Scope
  private var cancellables: Set<AnyCancellable> = []
  private weak var connectedStore: AppStore?
  private var invalidationScheduled = false

  init(scope: Scope) {
    self.scope = scope
  }

  func connect(to store: AppStore) {
    guard connectedStore !== store else { return }
    connectedStore = store
    cancellables.removeAll()

    switch scope {
    case .application:
      observe(store.$settings)
    case .content:
      observe(store.$settings)
      observe(store.$errorMessage)
      observe(store.$toolCallApprovalRequests)
      observe(store.$longRunningOperationTimeoutRequests)
    case .chat:
      observe(store.$activeConversation)
      observe(store.$conversationSummaries)
      observe(store.$messageBookmarks)
      observe(store.$recentConversationSummaries)
      observe(store.$selectedConversationID)
      observe(store.$settings)
      observe(store.$respondingConversationIDs)
      observe(store.$agentProcesses)
      observe(store.$queuedUserMessagesByConversationID)
      observe(store.$followUpSuggestionsByConversationID)
      observe(store.$generatingFollowUpSourceMessageIDsByConversationID)
      observe(store.$isCompacting)
      observe(store.$endpointStatuses)
      observe(store.$endpointModels)
      observe(store.$localMLXModelIDs)
      observe(store.$mcpStatuses)
      observe(store.$mcpTools)
      observe(store.$mcpResources)
      observe(store.$draftStorageRevision)
      observe(store.$appleAvailabilityReport)
      observe(store.$appleAvailabilityMessage)
      observe(store.$openAPIServerState)
      observe(store.$pendingLaunchAction)
      observe(store.$sharedImportRequestID)
      observe(store.$pendingConversationImportFiles)
      observe(store.$composerFocusRequestID)
      observe(store.$pendingMessageNavigation)
      observe(store.$browserSession)
    case .sidebar:
      observe(store.$conversationSummaries)
      observe(store.$messageBookmarks)
      observe(store.$selectedConversationID)
      observe(store.$selectedConversationIDs)
      observe(store.$settings)
      observe(store.$respondingConversationIDs)
      observe(store.$endpointStatuses)
      observe(store.$endpointModels)
      observe(store.$localMLXModelIDs)
      observe(store.$appleAvailabilityReport)
      observe(store.$appleAvailabilityMessage)
    case .settings:
      // The Settings form reads endpoint/MCP/model state and settings, but must
      // not be invalidated by high-churn chat state (active conversation,
      // streaming, queued messages, scroll/render bookkeeping).
      observe(store.$settings)
      observe(store.$errorMessage)
      observe(store.$isUpdatingMemory)
      observe(store.$conversationSummaries)
      observe(store.$endpointStatuses)
      observe(store.$endpointModels)
      observe(store.$endpointVoices)
      observe(store.$localMLXModelIDs)
      observe(store.$mcpStatuses)
      observe(store.$mcpTools)
      observe(store.$mcpResources)
      observe(store.$appleAvailabilityReport)
      observe(store.$appleAvailabilityMessage)
      observe(store.$openAPIServerState)
    }
  }

  private func observe<P: Publisher>(_ publisher: P) where P.Failure == Never {
    publisher
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.scheduleInvalidation()
        }
      }
      .store(in: &cancellables)
  }

  private func scheduleInvalidation() {
    guard !invalidationScheduled else { return }
    invalidationScheduled = true
    Task { @MainActor [weak self] in
      await Task.yield()
      guard let self else { return }
      invalidationScheduled = false
      revision &+= 1
    }
  }
}

enum ConversationExportFiles {
  static let fileExtension = MaiArchive.fileExtension

  static func isConversationExport(filename: String) -> Bool {
    filename.lowercased().hasSuffix(".\(fileExtension)")
  }

  static func url(
    for conversation: Conversation,
    format: ConversationExportFormat,
    suffix: String = ""
  ) throws -> URL {
    try url(
      filename: filename(for: conversation) + suffix,
      fileExtension: format.fileExtension)
  }

  static func url(filename: String, fileExtension: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PocketMaiExports",
      isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent(filename).appendingPathExtension(fileExtension)
  }

  static func filename(for conversation: Conversation) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
      .union(.newlines)
      .union(.controlCharacters)
    let title = conversation.displayTitle
      .components(separatedBy: invalid)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = title.isEmpty ? "Chat" : title
    return String(base.prefix(80))
  }
}
