import Foundation
import MaiACP
import MaiCore
import MaiDocuments
import Observation

@MainActor @Observable
final class MacConversation: Identifiable {
  let id = UUID()
  let hostID: UUID?
  var hostName: String
  let cwd: String
  var sessionID: String?
  var title: String
  var messages: [ACPConversationMessage] = [] {
    didSet { messageRuns = MacMessageRun.grouped(messages); find.update(messages) }
  }
  let find = MacConversationSearch()
  let voice = MacVoice()
  var webXDC: MacWebXDCSession?
  var showWebXDC = false

  func startWebXDC(_ app: WebXDCAppInfo) {
    if webXDC?.app.id != app.id {
      stopWebXDC()
      webXDC = MacWebXDCSession(app: app, conversation: self)
    }
    showWebXDC = true
  }
  func stopWebXDC() {
    webXDC?.stop()
    webXDC = nil
    showWebXDC = false
  }
  private(set) var messageRuns: [MacMessageRun] = []
  var options: [RemoteSessionOption] = []
  var modelName: String? {
    guard let model = options.first(where: { $0.category == "model" }) else { return nil }
    return model.choices.first(where: { .string($0.id) == model.currentValue })?.name
      ?? model.currentValue.stringValue
  }
  var prompts = PromptCatalog(builtins: [])
  var agents: [AgentProcessRecord] = []
  var draft = "" {
    didSet { if let draftKey { UserDefaults.standard.set(draft, forKey: draftKey) } }
  }
  var busy = false
  var attachments: [MacAttachment] = []
  var importingAttachments = false
  var canSend: Bool {
    connected && !busy && !importingAttachments
      && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
  }
  var connected = false
  var status = "Connecting…"
  var error: String?
  var permission: JSONValue?
  var canRewind = false
  var canEditAgentProfiles = false
  var agentProfiles: ACPAgentProfiles?
  var canManageAgents = false
  var canUseVoiceAgent = false
  var client: (any RemoteSessionClient)?
  var didChange: (() -> Void)?
  private var operation: Task<Void, Never>?
  @ObservationIgnored private var loadingMessages: [ACPConversationMessage]?
  private var closing = false
  private struct PermissionRequest {
    let id: UUID
    let value: JSONValue
    let reply: CheckedContinuation<String?, Never>
  }
  private var permissions: [PermissionRequest] = []
  private var draftKey: String? {
    sessionID.map { "mac.draft.\(hostID?.uuidString ?? "local").\($0)" }
  }

  init(hostID: UUID?, hostName: String, cwd: String, sessionID: String?, title: String) {
    self.hostID = hostID
    self.hostName = hostName
    self.cwd = cwd
    self.sessionID = sessionID
    self.title = title
    if let draftKey { draft = UserDefaults.standard.string(forKey: draftKey) ?? "" }
  }

  func connect() {
    guard !connected, let client else { return }
    perform {
      // Session loading replays history through the same callback as live
      // replies. Publish it once so the view starts at the completed tail.
      self.loadingMessages = client is OpenCodeClient ? self.messages : []
      defer { self.loadingMessages = nil }
      self.sessionID = try await client.connect()
      self.messages = self.loadingMessages ?? self.messages
      self.loadingMessages = nil
      if let draftKey = self.draftKey { UserDefaults.standard.set(self.draft, forKey: draftKey) }
      self.options = try await client.configurationOptions()
      self.prompts = try await client.promptCatalog()
      self.canRewind = await client.historyRewindSupported()
      self.canEditAgentProfiles = await (client as? ACPClient)?.agentProfilesSupported() ?? false
      try await self.refreshAgentProfiles()
      self.canManageAgents = await (client as? ACPClient)?.agentManagementSupported() ?? false
      self.canUseVoiceAgent = await (client as? ACPClient)?.voiceSupported() ?? false
      self.connected = true
      self.status = "Ready"
      self.didChange?()
    }
  }

  func send() {
    if voice.handleCommand(draft, in: self) { draft = ""; return }
    guard canSend, !closing, client != nil else { return }
    let submitted = attachments
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    draft = ""
    attachments = []
    submit(text, attachments: submitted, restoreDraft: true)
  }

  func sendVoice(_ text: String) { submit(text) }

  @discardableResult
  func sendApp(_ text: String, completion: @escaping (Result<String, Error>) -> Void) -> Bool {
    guard connected, !busy, !closing, client != nil else { return false }
    submit(text, completion: completion)
    return true
  }

  private func submit(_ text: String, attachments submittedAttachments: [MacAttachment] = [],
    restoreDraft: Bool = false, completion: ((Result<String, Error>) -> Void)? = nil) {
    guard connected, !busy, !closing, let client else { return }
    var request = RemotePromptRequest(text: text)
    if let command = PromptSlashCommand.parse(text), let entry = prompts.entry(named: command.command),
      entry.kind != .system {
      request = .init(text: entry.invocation != nil || entry.skillID != nil ? command.remainder
        : entry.message(arguments: command.remainder) ?? text, command: entry.invocation, skillID: entry.skillID)
    }
    request.attachments = submittedAttachments.map(\.content)
    let displayText = ([text] + submittedAttachments.map { "Attached: \($0.name)" })
      .filter { !$0.isEmpty }.joined(separator: "\n\n")
    messages.append(.init(role: "user", text: displayText))
    if title == "New Chat" { title = String(displayText.prefix(80)) }
    voice.beginReply()
    perform {
      self.status = "Working…"
      do {
        _ = try await client.prompt(request) { _ in }
      } catch {
        if restoreDraft {
          if self.draft.isEmpty { self.draft = text }
          self.attachments.insert(contentsOf: submittedAttachments, at: 0)
        }
        self.voice.finishReply("", error: error.localizedDescription)
        completion?(.failure(error))
        throw error
      }
      let reply = self.messages.reversed().prefix(while: { $0.role != "user" }).reversed()
        .filter { $0.role == "assistant" }.map(\.text).joined(separator: "\n\n")
      self.voice.finishReply(reply)
      completion?(.success(reply))
      self.status = "Ready"
      self.didChange?()
    }
  }

  func importAttachments(_ urls: [URL]) {
    guard !importingAttachments, !urls.isEmpty else { return }
    importingAttachments = true
    let local = hostID == nil
    Task {
      defer { importingAttachments = false }
      do {
        let imported = try await Task.detached(priority: .userInitiated) {
          try urls.map { try MacAttachment.load($0, allowsLocalReferences: local) }
        }.value
        attachments.append(contentsOf: imported)
      } catch { self.error = error.localizedDescription }
    }
  }

  func setOption(_ option: RemoteSessionOption, value: JSONValue) {
    guard connected, let client else { return }
    perform {
      self.options = try await client.setConfigurationOption(id: option.id, value: value)
      try await self.refreshAgentProfiles()
    }
  }

  func refreshAgentProfiles() async throws {
    guard canEditAgentProfiles, let client = client as? ACPClient else { return }
    agentProfiles = try await client.agentProfiles()
    options = try await client.configurationOptions()
  }

  func saveAgentProfile(_ agent: AgentDefinition, creating: Bool) async throws {
    guard !busy, connected, let client = client as? ACPClient else {
      throw JSONRPCError.invalidParams("Wait for this conversation to finish before editing its agent")
    }
    busy = true
    defer { busy = false }
    agentProfiles = try await client.agentProfiles(saving: agent, creating: creating)
    options = try await client.configurationOptions()
    didChange?()
  }

  func deleteAgentProfile(_ id: String) {
    guard let client = client as? ACPClient else { return }
    perform {
      self.agentProfiles = try await client.agentProfiles(deleting: id)
      self.options = try await client.configurationOptions()
    }
  }

  func rewind(_ message: ACPConversationMessage) {
    guard canRewind, let remoteID = message.remoteID, let client else { return }
    perform {
      try await client.rewind(to: remoteID)
      self.draft = message.text
      self.didChange?()
    }
  }

  func receive(_ update: JSONValue) {
    if update.objectValue?["sessionUpdate"]?.stringValue == "_pmai/voice" {
      voice.receive(update)
      return
    }
    if loadingMessages != nil {
      ACPConversationTranscript.apply(update, to: &loadingMessages!)
    } else {
      ACPConversationTranscript.apply(update, to: &messages)
    }
    if update.objectValue?["sessionUpdate"]?.stringValue == "config_option_update" {
      options = RemoteSessionOption.parse(update.objectValue?["configOptions"])
    }
  }

  func refreshAgents() async {
    guard canManageAgents, let client = client as? ACPClient else { return }
    do { agents = try await client.sessionAgents() }
    catch { self.error = error.localizedDescription }
  }

  func launchAgent(_ task: String) {
    guard canManageAgents, let client = client as? ACPClient,
      !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    perform {
      self.agents = try await client.sessionAgents(task: task)
      if self.title == "New Chat" { self.title = String(task.prefix(80)) }
      self.didChange?()
    }
  }

  func stopAgent(_ pid: AgentPID) {
    guard let client = client as? ACPClient else { return }
    Task {
      do { agents = try await client.sessionAgents(stopping: pid) }
      catch { self.error = error.localizedDescription }
    }
  }

  private func perform(_ action: @escaping @MainActor () async throws -> Void) {
    guard !busy, !closing else { return }
    busy = true
    error = nil
    operation = Task {
      defer { busy = false; operation = nil; webXDC?.flushChat() }
      do { try await action() }
      catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
        self.connected = await self.client?.isConnected ?? false
        status = connected ? "Ready" : "Disconnected"
      }
    }
  }

  func stop() {
    voice.stop()
    dismissPermissions()
    // The protocol cancellation lets the host save its interrupted transcript
    // before the prompt returns. Closing the transport would lose that result.
    Task { await client?.cancel() }
  }

  func close() async {
    closing = true
    voice.stop()
    stopWebXDC()
    defer { closing = false }
    dismissPermissions()
    let client = client
    // Give the host a bounded opportunity to checkpoint interrupted work.
    // A broken transport must never hold up application termination forever.
    let deadline = Task {
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      await client?.disconnect()
    }
    defer { deadline.cancel() }
    await client?.cancel()
    await operation?.value
    if let acp = client as? ACPClient, canManageAgents,
      let running = try? await acp.sessionAgents() {
      for agent in running where !agent.state.isTerminal {
        _ = try? await acp.sessionAgents(stopping: agent.pid)
      }
    }
    await client?.disconnect()
    connected = false
  }

  func disconnected() {
    voice.stop()
    connected = false
    status = "Disconnected"
    dismissPermissions()
  }

  func askPermission(_ value: JSONValue) async -> String? {
    if let turn = value.objectValue?["_meta"]?.objectValue?["pmai"]?.objectValue?["voiceTurnId"]?.stringValue,
      !voice.acceptsPermission(turn) { return nil }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard !closing, !Task.isCancelled else { continuation.resume(returning: nil); return }
        permissions.append(.init(id: id, value: value, reply: continuation))
        permission = permissions.first?.value
      }
    } onCancel: { Task { @MainActor [weak self] in self?.cancelPermission(id) } }
  }

  func answerPermission(_ option: String?) {
    guard !permissions.isEmpty else { return }
    let request = permissions.removeFirst()
    permission = permissions.first?.value
    request.reply.resume(returning: option)
  }

  private func cancelPermission(_ id: UUID) {
    guard let index = permissions.firstIndex(where: { $0.id == id }) else { return }
    let request = permissions.remove(at: index)
    permission = permissions.first?.value
    request.reply.resume(returning: nil)
  }

  func dismissVoicePermissions(_ turnID: UUID) {
    let ids = permissions.filter {
      $0.value.objectValue?["_meta"]?.objectValue?["pmai"]?.objectValue?["voiceTurnId"]?.stringValue == turnID.uuidString
    }.map(\.id)
    for id in ids { cancelPermission(id) }
  }

  private func dismissPermissions() {
    let pending = permissions
    permissions = []
    permission = nil
    for request in pending { request.reply.resume(returning: nil) }
  }
}
