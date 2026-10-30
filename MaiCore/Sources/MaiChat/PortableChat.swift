import Foundation
import MaiCore
import MaiOpenAI
import Observation

/// Hosts may use the shared agent runtime while retaining this model's saved
/// chats, provider settings, streaming presentation and cancellation handling.
public typealias PortableChatTurnHandler = @Sendable (
  ProviderRequest, any ChatProvider, @escaping ProviderEventHandler
) async throws -> [AgentMessage]

/// The small mobile client's settings use the same provider, prompt and chat
/// types as the other hosts. No Android or Apple UI frameworks belong here.
public struct PortableChatConfiguration: Codable, Sendable {
  public var provider: ConfiguredProvider
  public var providers: [ConfiguredProvider]?
  public var prompts: [SystemPrompt]
  public var selectedPromptID: String
  public var selectedChatID: UUID?

  public init() {
    let prompt = SystemPrompt(name: "Assistant", text: SystemPrompt.defaultInstructions)
    provider = ConfiguredProvider(
      id: "openai", kind: .openAICompatible, displayName: "OpenAI-compatible",
      baseURL: URL(string: "https://api.openai.com/v1"))
    prompts = [prompt]
    selectedPromptID = prompt.id.uuidString
  }
}

public enum PortableChatError: LocalizedError {
  case invalidURL, missingModel, emptyPromptName, busy, lastProvider, providerUnavailable

  public var errorDescription: String? {
    switch self {
    case .invalidURL: "Enter a complete HTTP or HTTPS provider URL, including its API path."
    case .missingModel: "Choose a model or enter its model ID first."
    case .emptyPromptName: "Enter a name for the system prompt."
    case .busy: "Stop the current reply before changing chats or settings."
    case .lastProvider: "Add another provider before removing the last one."
    case .providerUnavailable: "This chat’s provider was removed. Select a provider before sending."
    }
  }
}

/// Main-thread presentation state, reusable by any Swift UI. Networking,
/// model discovery, message formats and chat-file persistence are MaiCore's.
@MainActor @Observable
public final class PortableChat {
  public var baseURL: String
  public var apiKey: String
  public var model: String
  public private(set) var providers: [ConfiguredProvider]
  public private(set) var selectedProviderID: String
  public var draft = ""
  public private(set) var prompts: [SystemPrompt]
  public private(set) var selectedPromptID: String
  public private(set) var chat: AgentChat
  public private(set) var chats: [AgentChat] = []
  public private(set) var models: [ModelDescriptor] = []
  public private(set) var isGenerating = false
  public private(set) var isLoadingModels = false
  public private(set) var streamedText = ""
  public private(set) var streamedReasoning = ""
  public var errorMessage: String?
  public private(set) var status = ""

  @ObservationIgnored private let directory: URL
  @ObservationIgnored private let files: ChatFileStore<AgentChat>
  @ObservationIgnored private var configuration: PortableChatConfiguration
  @ObservationIgnored private let makeProvider:
    @Sendable (ConfiguredProvider) throws -> any ChatProvider
  @ObservationIgnored private var replyTask: Task<Void, Never>?
  @ObservationIgnored private var modelTask: Task<Void, Never>?
  @ObservationIgnored private var runID: UUID?
  @ObservationIgnored private let runTurn: PortableChatTurnHandler?
  @ObservationIgnored private var unavailableProviderID: String?

  public init(
    directory: URL,
    makeProvider: @escaping @Sendable (ConfiguredProvider) throws -> any ChatProvider = {
      try OpenAIConfiguredProviderFactory().makeProvider(from: $0, environment: [:])
    },
    runTurn: PortableChatTurnHandler? = nil
  ) throws {
    self.directory = directory
    self.makeProvider = makeProvider
    self.runTurn = runTurn
    files = ChatFileStore(directoryURL: directory.appendingPathComponent("chats"))
    let settingsURL = directory.appendingPathComponent("settings.json")
    let loaded =
      FileManager.default.fileExists(atPath: settingsURL.path)
      ? try MaiJSONCoding.default.makeDecoder().decode(
        PortableChatConfiguration.self, from: Data(contentsOf: settingsURL))
      : PortableChatConfiguration()
    configuration = loaded
    providers = loaded.providers ?? [loaded.provider]
    selectedProviderID = loaded.provider.id
    baseURL = loaded.provider.baseURL?.absoluteString ?? ""
    apiKey = loaded.provider.apiKey ?? ""
    model = loaded.provider.defaultModel ?? ""
    prompts = loaded.prompts
    selectedPromptID = loaded.selectedPromptID
    let prompt = loaded.prompts.first { $0.id.uuidString == loaded.selectedPromptID }
    chat = AgentChat(
      primaryAgent: AgentDefinition(
        id: "chat", instructions: prompt?.text ?? "", provider: ProviderID(loaded.provider.id),
        model: loaded.provider.defaultModel ?? ""))
    var failures: [String] = []
    chats = try files.loadChats { failures.append($0.localizedDescription) }
      .sorted(by: AgentChat.precedes)
    if let selected = chats.first(where: { $0.id == configuration.selectedChatID }) {
      chat = selected
      restoreSelection(from: selected)
    }
    if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
  }

  public var selectedPrompt: SystemPrompt? {
    prompts.first { $0.id.uuidString == selectedPromptID }
  }

  public var messages: [AgentMessage] { chat.conversationMessages }

  public func saveProvider(id: String? = nil, name: String? = nil) throws {
    guard !isGenerating, !isLoadingModels else { throw PortableChatError.busy }
    var provider = try providerConfiguration(allowMissingProvider: true)
    if let id, !id.isEmpty { provider.id = id }
    if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { provider.displayName = name }
    configuration.provider = provider
    if let i = providers.firstIndex(where: { $0.id == provider.id }) { providers[i] = provider }
    else { providers.append(provider) }
    selectedProviderID = provider.id
    unavailableProviderID = nil
    models = []
    try saveSettings()
    status = "Provider saved"
  }

  public func selectProvider(_ id: String) throws {
    guard !isGenerating, !isLoadingModels else { throw PortableChatError.busy }
    guard let provider = providers.first(where: { $0.id == id }) else { throw CocoaError(.coderInvalidValue) }
    configuration.provider = provider
    selectedProviderID = id
    unavailableProviderID = nil
    baseURL = provider.baseURL?.absoluteString ?? ""
    apiKey = provider.apiKey ?? ""
    model = provider.defaultModel ?? ""
    models = []
    try saveSettings()
  }

  public func removeProvider(_ id: String) throws {
    guard !isGenerating, !isLoadingModels else { throw PortableChatError.busy }
    guard providers.count > 1 else { throw PortableChatError.lastProvider }
    providers.removeAll { $0.id == id }
    if selectedProviderID == id, let next = providers.first { try selectProvider(next.id) }
    try saveSettings()
  }

  public func chooseModel(_ id: String) throws {
    guard !isGenerating else { throw PortableChatError.busy }
    model = id
    configuration.provider.defaultModel = id
    try saveSettings()
  }

  public func selectPrompt(_ id: String) throws {
    guard !isGenerating else { throw PortableChatError.busy }
    guard prompts.contains(where: { $0.id.uuidString == id }) else { return }
    selectedPromptID = id
    configuration.selectedPromptID = id
    try saveSettings()
  }

  @discardableResult
  public func savePrompt(id: UUID? = nil, name: String, text: String) throws -> SystemPrompt {
    guard !isGenerating else { throw PortableChatError.busy }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw PortableChatError.emptyPromptName }
    let prompt = SystemPrompt(id: id ?? UUID(), name: name, text: text)
    if let index = prompts.firstIndex(where: { $0.id == prompt.id }) {
      prompts[index] = prompt
    } else {
      prompts.append(prompt)
    }
    configuration.prompts = prompts
    selectedPromptID = prompt.id.uuidString
    configuration.selectedPromptID = selectedPromptID
    try saveSettings()
    status = "System prompt saved"
    return prompt
  }

  public func newChat() throws {
    guard !isGenerating else { throw PortableChatError.busy }
    chat = AgentChat(primaryAgent: currentAgent())
    draft = ""
    configuration.selectedChatID = chat.id
    try saveSettings()
  }

  public func openChat(_ id: UUID) throws {
    guard !isGenerating else { throw PortableChatError.busy }
    guard let saved = try files.loadChat(id: id) else { return }
    chat = saved
    restoreSelection(from: saved)
    configuration.selectedChatID = id
    draft = ""
    try saveSettings()
  }

  private func restoreSelection(from saved: AgentChat) {
    if let provider = providers.first(where: { $0.id == saved.primaryAgent.provider.rawValue }) {
      configuration.provider = provider
      selectedProviderID = provider.id
      baseURL = provider.baseURL?.absoluteString ?? ""
      apiKey = provider.apiKey ?? ""
      unavailableProviderID = nil
    } else {
      unavailableProviderID = saved.primaryAgent.provider.rawValue
    }
    model = saved.primaryAgent.model
    // A resumed chat keeps its prompt, even if the named template was edited.
    let matching = prompts.first { $0.text == saved.primaryAgent.instructions }
    if let matching {
      selectedPromptID = matching.id.uuidString
    } else {
      let prompt = SystemPrompt(
        name: "\(saved.displayTitle) prompt", text: saved.primaryAgent.instructions)
      prompts.append(prompt)
      selectedPromptID = prompt.id.uuidString
    }
    configuration.prompts = prompts
    configuration.selectedPromptID = selectedPromptID
    configuration.provider.defaultModel = model
  }

  public func discoverModels() {
    guard !isGenerating, !isLoadingModels else { return }
    modelTask = Task { await refreshModels() }
  }

  public func refreshModels() async {
    guard !isLoadingModels, !isGenerating else { return }
    isLoadingModels = true
    errorMessage = nil
    defer { isLoadingModels = false }
    do {
      let provider = try makeProvider(providerConfiguration())
      models = try await provider.availableModels()
      try Task.checkCancellation()
      status = "\(models.count) models available"
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  public func sendDraft(attachments: [ContentPart] = []) {
    guard !isGenerating else { return }
    let text = draft
    replyTask = Task { await send(text, attachments: attachments) }
  }

  public func send(_ text: String, attachments: [ContentPart] = []) async {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (!text.isEmpty || !attachments.isEmpty), !isGenerating, !isLoadingModels else { return }
    errorMessage = nil
    let id = UUID()
    do {
      let connection = try providerConfiguration()
      guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw PortableChatError.missingModel
      }
      let provider = try makeProvider(connection)
      configuration.provider = connection
      configuration.selectedChatID = chat.id
      chat.primaryAgent = currentAgent()
      chat.messages.removeAll { $0.role == .system }
      if let prompt = selectedPrompt, !prompt.text.isEmpty {
        chat.messages.insert(.system(prompt.text), at: 0)
      }
      chat.messages.append(AgentMessage(role: .user,
        content: (text.isEmpty ? [] : [.text(text)]) + attachments))
      chat.refreshTitle(from: text)
      draft = ""
      try persistChat()
      try saveSettings()
      runID = id
      isGenerating = true
      streamedText = ""
      streamedReasoning = ""
      status = "Replying…"
      let request = ProviderRequest(
        model: model, messages: chat.messages, toolChoice: .none, sessionID: chat.sessionID)
      let receive: ProviderEventHandler = { [weak self] event in
        await self?.receive(event, run: id)
      }
      let transcript: [AgentMessage]
      if let runTurn {
        transcript = try await runTurn(request, provider, receive)
      } else {
        let response = try await provider.complete(request, emit: receive)
        transcript = chat.messages + [response.message]
      }
      try Task.checkCancellation()
      guard runID == id else { return }
      chat.messages = transcript
      try persistChat()
      status = ""
    } catch {
      if runID == id {
        // Keep a streamed partial reply after stopping or a connection failure.
        if !streamedText.isEmpty {
          chat.messages.append(.assistant(streamedText))
        }
        do { try persistChat() } catch { errorMessage = error.localizedDescription }
      }
      if error is CancellationError || Task.isCancelled {
        status = "Stopped"
      } else {
        errorMessage = error.localizedDescription
        status = ""
      }
    }
    if runID == id {
      runID = nil
      streamedText = ""
      streamedReasoning = ""
      isGenerating = false
    }
  }

  public func stop() { replyTask?.cancel() }

  public func editMessage(_ id: String, text: String) throws {
    guard !isGenerating else { throw PortableChatError.busy }
    guard let i = chat.messages.firstIndex(where: { $0.id == id }),
      [.user, .assistant].contains(chat.messages[i].role), chat.messages[i].toolCalls.isEmpty else { return }
    var transcript = AgentTranscript(messages: chat.messages)
    try transcript.editMessage(at: i, text: text)
    chat.messages = transcript.messages
    try persistChat()
  }

  public func deleteMessage(_ id: String) throws {
    guard !isGenerating else { throw PortableChatError.busy }
    guard let removed = chat.messages.first(where: { $0.id == id }), removed.role != .tool else { return }
    var transcript = AgentTranscript(messages: chat.messages)
    try transcript.removeMessage(id: removed.id)
    chat.messages = transcript.messages
    try persistChat()
  }

  private func receive(_ event: ProviderEvent, run: UUID) {
    guard runID == run else { return }
    switch event {
    case .textDelta(let text): streamedText += text
    case .reasoningDelta(let text): streamedReasoning += text
    default: break
    }
  }

  private func currentAgent() -> AgentDefinition {
    AgentDefinition(
      id: "chat", instructions: selectedPrompt?.text ?? "", provider: ProviderID(selectedProviderID),
      model: model, toolChoice: .none)
  }

  private func providerConfiguration(allowMissingProvider: Bool = false) throws -> ConfiguredProvider {
    guard allowMissingProvider || unavailableProviderID == nil else { throw PortableChatError.providerUnavailable }
    let value = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: value), let host = url.host, !host.isEmpty,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.user == nil, url.password == nil, url.fragment == nil, url.query == nil
    else { throw PortableChatError.invalidURL }
    var provider = configuration.provider
    provider.baseURL = url
    provider.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
    provider.defaultModel = selectedModel.isEmpty ? nil : selectedModel
    try provider.validate()
    return provider
  }

  private func persistChat() throws {
    chat.updatedAt = Date()
    try files.save(chat)
    chats.removeAll { $0.id == chat.id }
    if !chat.isDisposable { chats.append(chat) }
    chats.sort(by: AgentChat.precedes)
  }

  private func saveSettings() throws {
    if let i = providers.firstIndex(where: { $0.id == configuration.provider.id }) {
      providers[i] = configuration.provider
    }
    configuration.providers = providers
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("settings.json")
    try MaiJSONCoding.default.makeEncoder().encode(configuration).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
