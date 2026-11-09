import Foundation
import MaiACP
import MaiCore
import Observation

@MainActor @Observable
final class MacConversation: Identifiable {
  let id = UUID()
  let hostID: UUID?
  let hostName: String
  let cwd: String
  var sessionID: String?
  var title: String
  var messages: [ACPConversationMessage] = []
  var options: [RemoteSessionOption] = []
  var prompts = PromptCatalog(builtins: [])
  var agents: [AgentProcessRecord] = []
  var draft = "" {
    didSet { if let draftKey { UserDefaults.standard.set(draft, forKey: draftKey) } }
  }
  var busy = false
  var connected = false
  var status = "Connecting…"
  var error: String?
  var permission: JSONValue?
  var canRewind = false
  var canManageAgents = false
  var client: (any RemoteSessionClient)?
  var didChange: (() -> Void)?
  private var operation: Task<Void, Never>?
  private var permissionReply: CheckedContinuation<String?, Never>?
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
    guard let client else { return }
    perform {
      self.sessionID = try await client.connect()
      if let draftKey = self.draftKey { UserDefaults.standard.set(self.draft, forKey: draftKey) }
      self.options = try await client.configurationOptions()
      self.prompts = try await client.promptCatalog()
      self.canRewind = await client.historyRewindSupported()
      self.canManageAgents = await (client as? ACPClient)?.agentManagementSupported() ?? false
      self.connected = true
      self.status = "Ready"
      self.didChange?()
    }
  }

  func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, connected, !busy, let client else { return }
    var request = RemotePromptRequest(text: text)
    if let command = PromptSlashCommand.parse(text), let entry = prompts.entry(named: command.command),
      entry.kind != .system {
      request = .init(text: entry.invocation != nil || entry.skillID != nil ? command.remainder
        : entry.message(arguments: command.remainder) ?? text, command: entry.invocation, skillID: entry.skillID)
    }
    draft = ""
    messages.append(.init(role: "user", text: text))
    if title == "New Chat" { title = String(text.prefix(80)) }
    perform {
      self.status = "Working…"
      _ = try await client.prompt(request) { _ in }
      self.status = "Ready"
      self.didChange?()
    }
  }

  func setOption(_ option: RemoteSessionOption, value: JSONValue) {
    guard connected, let client else { return }
    perform { self.options = try await client.setConfigurationOption(id: option.id, value: value) }
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
    ACPConversationTranscript.apply(update, to: &messages)
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
    guard !busy else { return }
    busy = true
    error = nil
    operation = Task {
      defer { busy = false; operation = nil }
      do { try await action() }
      catch {
        if !Task.isCancelled { self.error = error.localizedDescription }
        self.connected = await self.client?.isConnected ?? false
        status = connected ? "Ready" : "Disconnected"
      }
    }
  }

  func stop() {
    answerPermission(nil)
    // The protocol cancellation lets the host save its interrupted transcript
    // before the prompt returns. Closing the transport would lose that result.
    Task { await client?.cancel() }
  }

  func close() async {
    answerPermission(nil)
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
    connected = false
    status = "Disconnected"
    answerPermission(nil)
  }

  func askPermission(_ value: JSONValue) async -> String? {
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        answerPermission(nil)
        permission = value
        permissionReply = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.answerPermission(nil) } }
  }

  func answerPermission(_ option: String?) {
    permission = nil
    let reply = permissionReply
    permissionReply = nil
    reply?.resume(returning: option)
  }
}
