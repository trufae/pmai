import Foundation
import MaiACP
import MaiCore
import Observation

/// Android's remote screen shares the same ACP client and host store as the CLI.
@MainActor @Observable
public final class PortableRemoteChat {
  public var invitation = ""
  public var draft = ""
  public var error: String?
  public private(set) var status = ""
  public private(set) var hosts: [ACPRemoteHost] = []
  public private(set) var selected: ACPRemoteHost?
  public private(set) var busy = false
  public private(set) var connected = false
  public private(set) var messages: [Message] = []
  public private(set) var streamed = ""
  private let preparation: Task<Void, any Error>?
  private let store: ACPRemoteHostStore
  private var client: ACPClient?
  private var operation: Task<Void, Never>?
  private var generation = 0

  public struct Message: Codable, Identifiable {
    public var id = UUID()
    public let role: String
    public var text: String
  }
  private struct Conversation: Codable {
    var sessionID: String
    var messages: [Message]
  }

  public init(directory: URL, preparation: Task<Void, any Error>? = nil) {
    self.preparation = preparation
    store = ACPRemoteHostStore(directory: directory)
    do { hosts = try store.hosts() } catch { self.error = error.localizedDescription }
  }

  public func pair() {
    guard !busy else { return }
    let text = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
    run {
      var profile = try ACPRemoteConnection.parse(text)
      if profile.requiresApproval == true {
        self.status =
          "Waiting for host approval. Forwiroh requires device approval, then ACP chat approval."
        let pairing = ACPClient(
          configuration: .init(
            command: profile.name,
            webSocketURL: profile.url, bearerToken: profile.token,
            forwirohInvitation: profile.forwirohInvitation))
        self.client = pairing
        profile.token = try await pairing.requestPairing(
          clientID: UUID().uuidString, name: "PocketMai Android")
        profile.requiresApproval = false
      }
      try Task.checkCancellation()
      let host = try self.store.pair(profile)
      self.hosts = try self.store.hosts()
      self.invitation = ""
      try await self.open(host)
    }
  }

  public func connect(_ host: ACPRemoteHost) {
    guard !busy else { return }
    run { try await self.open(host) }
  }

  private func open(_ host: ACPRemoteHost) async throws {
    await client?.disconnect()
    connected = false
    selected = host
    let saved = try conversation(host)
    messages = saved?.messages ?? []
    let token = try String(contentsOf: store.tokenFile(for: host), encoding: .utf8)
    let client = ACPClient(
      configuration: .init(
        command: host.name, permission: .reject,
        remoteWorkingDirectory: host.cwd, readClientFiles: false,
        webSocketURL: host.url, bearerToken: token, sessionID: saved?.sessionID))
    self.client = client
    status = "Connecting to \(host.name)…"
    let session = try await client.connect()
    try Task.checkCancellation()
    try save(Conversation(sessionID: session, messages: messages), host: host)
    connected = true
    status = "Connected to \(host.name) · \(host.cwd)"
  }

  public func send() {
    let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !busy, connected, let client, let host = selected, !text.isEmpty else { return }
    draft = ""
    messages.append(Message(role: "user", text: text))
    streamed = ""
    run {
      let session = try await client.connect()
      _ = try await client.prompt(text) { event in
        if case .textDelta(let delta) = event { await self.append(delta) }
      }
      self.messages.append(Message(role: "assistant", text: self.streamed))
      self.streamed = ""
      try self.save(Conversation(sessionID: session, messages: self.messages), host: host)
    }
  }

  private func append(_ delta: String) { streamed += delta }

  public func disconnect() {
    generation += 1
    operation?.cancel()
    operation = nil
    let previous = client
    client = nil
    busy = false
    connected = false
    status = "Disconnected"
    Task { await previous?.disconnect() }
  }

  private func run(_ body: @escaping @MainActor () async throws -> Void) {
    busy = true
    error = nil
    generation += 1
    let attempt = generation
    operation = Task {
      do {
        try await preparation?.value
        try Task.checkCancellation()
        try await body()
      } catch {
        if generation == attempt {
          self.error = error.localizedDescription
          connected = false
          await client?.disconnect()
        }
      }
      if generation == attempt {
        busy = false
        operation = nil
      }
    }
  }

  private func conversation(_ host: ACPRemoteHost) throws -> Conversation? {
    let file = store.sessionFile(for: host)
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    return try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: file))
  }
  private func save(_ conversation: Conversation, host: ACPRemoteHost) throws {
    try ACPStateFiles.write(conversation, to: store.sessionFile(for: host))
  }
}
