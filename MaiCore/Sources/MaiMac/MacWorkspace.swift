import AppKit
import Foundation
import MaiACP
import MaiCore
import Observation

@MainActor @Observable
final class MacWorkspace {
  let home = AgentHome.resolve()
  var hosts: [ACPRemoteHost] = []
  var hostID: UUID?
  var cwd = ""
  var snapshot = ACPWorkspaceSnapshot()
  var conversations: [MacConversation] = []
  var selectedID: UUID?
  var search = ""
  var busy = false
  var error: String?
  var showConnection = false
  var showInspector = false
  private var restored = false

  var hostStore: ACPRemoteHostStore { .init(directory: home.rootURL.appendingPathComponent("remotes")) }
  var selected: MacConversation? { conversations.first { $0.id == selectedID } }
  var host: ACPRemoteHost? { hosts.first { $0.id == hostID } }
  var hostName: String { host?.name ?? "This Mac" }
  var sessions: [ACPSessionInfo] {
    snapshot.sessions.filter { $0.cwd == cwd && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search)) }
      .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
  }

  func restore() async {
    guard !restored else { return }
    restored = true
    do {
      try await ForwirohRemote.shared.configure(
        directory: home.rootURL.appendingPathComponent("forwiroh-client"), name: "pmai for Mac")
      hosts = try hostStore.hosts()
      hostID = UserDefaults.standard.string(forKey: "mac.host").flatMap(UUID.init(uuidString:))
      if host == nil { hostID = nil }
      cwd = UserDefaults.standard.string(forKey: "mac.cwd") ?? ""
      await refresh()
      if let id = UserDefaults.standard.string(forKey: "mac.session"),
        let session = snapshot.sessions.first(where: { $0.sessionID == id && $0.cwd == cwd }) {
        open(session)
      }
    } catch { self.error = error.localizedDescription }
  }

  func refresh() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      hosts = try hostStore.hosts()
      if let host {
        let client = try hostStore.connection(for: host).makeSession()
        do { snapshot = try await client.workspace() ?? .init() }
        catch { await client.disconnect(); throw error }
        await client.disconnect()
      } else {
        snapshot = try await AgentHomeACPWorkspace(home: home).snapshot()
      }
      if !snapshot.folders.contains(where: { $0.cwd == cwd }) {
        cwd = snapshot.folders.first?.cwd ?? host?.cwd ?? ""
      }
      remember()
    } catch { self.error = error.localizedDescription }
  }

  func selectHost(_ id: UUID?) {
    guard !busy else { return }
    hostID = id
    cwd = ""
    selectedID = nil
    snapshot = .init()
    Task { await refresh() }
  }

  func selectFolder(_ path: String) {
    cwd = path
    selectedID = nil
    remember()
  }

  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = "Open Workspace"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard !busy else { return }
    do {
      _ = try home.openProject(atWorkingDirectory: url)
      hostID = nil
      cwd = url.path
      selectedID = nil
      Task { await refresh() }
    } catch { self.error = error.localizedDescription }
  }

  func open(_ info: ACPSessionInfo? = nil) {
    guard !busy, !cwd.isEmpty else { return }
    if let info, let existing = conversations.first(where: {
      $0.hostID == hostID && $0.sessionID == info.sessionID && $0.cwd == info.cwd
    }) {
      selectedID = existing.id
      remember()
      return
    }
    do {
      let conversation = MacConversation(hostID: hostID, hostName: hostName,
        cwd: info?.cwd ?? cwd, sessionID: info?.sessionID, title: info?.title ?? "New Chat")
      let profile = try host.map { try hostStore.connection(for: $0) }
      conversation.client = try makeClient(profile: profile, conversation: conversation)
      conversation.didChange = { [weak self] in
        self?.remember()
        Task { await self?.refresh() }
      }
      conversations.append(conversation)
      selectedID = conversation.id
      conversation.connect()
    } catch { self.error = error.localizedDescription }
  }

  func newChat() { open() }

  private func makeClient(profile: RemoteHostConnection?, conversation: MacConversation) throws -> any RemoteSessionClient {
    let update: @Sendable (JSONValue) async -> Void = { [weak conversation] in await conversation?.receive($0) }
    let permission: @Sendable (JSONValue) async throws -> String? = { [weak conversation] in
      await conversation?.askPermission($0)
    }
    let disconnect: @Sendable () async -> Void = { [weak conversation] in await conversation?.disconnected() }
    if let profile {
      return try profile.makeSession(cwd: conversation.cwd, sessionID: conversation.sessionID,
        onUpdate: update, onPermission: permission, onDisconnect: disconnect)
    }
    return ACPClient(configuration: localConfiguration(cwd: conversation.cwd, sessionID: conversation.sessionID),
      onUpdate: update, onPermission: permission, onDisconnect: disconnect)
  }

  func localConfiguration(cwd: String, sessionID: String? = nil) -> ACPClient.Configuration {
    var environment = ProcessInfo.processInfo.environment
    // Finder does not inherit shell startup files. Keep explicit environment
    // values and add the conventional locations for installed provider tools.
    environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
      + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
    var arguments = ["--acp", "--home", home.rootURL.path]
    // CLI startup restores the chat's runtime configuration before registering
    // providers, agents, MCP and skills. ACP then opens that same conversation.
    if let sessionID { arguments += ["--resume", sessionID] }
    return .init(command: Bundle.main.executableURL!.path,
      arguments: arguments, environment: environment,
      workingDirectory: URL(fileURLWithPath: cwd), permission: .reject,
      readClientFiles: false, sessionID: sessionID)
  }

  func pair(_ invitation: String, name: String) async throws {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    var profile: RemoteHostConnection
    if let link = try? OpenCodePairingLink.parse(invitation) {
      profile = .init(try await link.redeem())
    } else {
      let parsed = try ACPRemoteConnection.parse(invitation)
      profile = .init(parsed)
      if parsed.requiresApproval == true {
        let client = try parsedClient(parsed)
        do {
          profile.token = try await client.requestPairing(clientID: UUID().uuidString, name: "pmai for Mac")
        } catch { await client.disconnect(); throw error }
        await client.disconnect()
        profile.requiresApproval = false
      }
    }
    let host = try hostStore.pair(profile, name: name.isEmpty ? nil : name)
    hosts = try hostStore.hosts()
    hostID = host.id
    cwd = host.cwd
    selectedID = nil
    snapshot = .init()
    remember()
  }

  private func parsedClient(_ profile: ACPRemoteConnection) throws -> ACPClient {
    ACPClient(configuration: .init(command: profile.name, permission: .reject,
      remoteWorkingDirectory: profile.cwd, readClientFiles: false,
      webSocketURL: profile.url, bearerToken: profile.token, forwirohInvitation: profile.forwirohInvitation))
  }

  func remember() {
    UserDefaults.standard.set(hostID?.uuidString, forKey: "mac.host")
    UserDefaults.standard.set(cwd, forKey: "mac.cwd")
    UserDefaults.standard.set(selected?.sessionID, forKey: "mac.session")
  }

  func openTerminal() {
    guard hostID == nil, !cwd.isEmpty else { return }
    // Transfer this conversation to the terminal only after its writer has
    // disconnected. Two front ends must not write the same transcript.
    let conversation = selected
    Task {
      await conversation?.close()
      launchTerminal(sessionID: conversation?.sessionID)
    }
  }

  private func launchTerminal(sessionID: String?) {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    var arguments = [Bundle.main.executableURL!.path, "--home", home.rootURL.path]
    if let sessionID { arguments += ["--resume", sessionID] }
    let command = "#!/bin/sh\ncd " + quote(cwd) + " || exit 1\nexec " + arguments.map(quote).joined(separator: " ") + "\n"
    do {
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-\(UUID()).command")
      try command.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      NSWorkspace.shared.open(file)
    } catch { self.error = error.localizedDescription }
  }

  func close() async {
    for conversation in conversations { conversation.stop() }
    for conversation in conversations { await conversation.close() }
  }
}
