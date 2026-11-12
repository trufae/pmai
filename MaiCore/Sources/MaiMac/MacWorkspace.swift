import AppKit
import Foundation
import MaiACP
import MaiCore
import Observation

enum MacSidebarSection: String, CaseIterable {
  case hosts = "Hosts", folders = "Folders", conversations = "Conversations"
}

@MainActor @Observable
final class MacWorkspace {
  let backend: MacBackend
  var home: AgentHome { backend.home }
  var hosts: [ACPRemoteHost] {
    get { backend.hosts }
    set { backend.hosts = newValue }
  }
  var hostID: UUID?
  var cwd = ""
  var snapshot: ACPWorkspaceSnapshot {
    backend.snapshots[hostID] ?? .init()
  }
  var conversations: [MacConversation] {
    get { backend.conversations }
    set { backend.conversations = newValue }
  }
  var selectedID: UUID?
  var search = ""
  var focusConversationSearch = false
  var sidebarSection: MacSidebarSection? = .folders
  var showArchived = false
  var busy = false
  var error: String?
  var showConnection = false
  var showInspector = false
  private var restored = false
  private let inheritedLocation: Bool

  init(backend: MacBackend, inheriting source: MacWorkspace? = nil) {
    self.backend = backend
    let source = source ?? backend.activeWorkspace
    inheritedLocation = source != nil
    if let source {
      hostID = source.hostID
      cwd = source.cwd
      sidebarSection = source.sidebarSection
      showArchived = source.showArchived
    }
  }

  var hostStore: ACPRemoteHostStore { backend.hostStore }
  var selected: MacConversation? { conversations.first { $0.id == selectedID } }
  var host: ACPRemoteHost? { hosts.first { $0.id == hostID } }
  var hostName: String { host?.name ?? "This Mac" }
  var sessions: [ACPSessionInfo] {
    snapshot.sessions.filter {
      $0.cwd == cwd && ($0.isArchived == true) == showArchived
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }.sorted {
      if ($0.isPinned == true) != ($1.isPinned == true) { return $0.isPinned == true }
      return ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
    }
  }

  var unlistedConversations: [MacConversation] {
    guard !showArchived else { return [] }
    return conversations.filter { chat in
      chat.hostID == hostID && chat.cwd == cwd
        && !snapshot.sessions.contains { $0.sessionID == chat.sessionID && $0.cwd == chat.cwd }
        && (search.isEmpty || chat.title.localizedCaseInsensitiveContains(search))
    }
  }

  func conversation(for session: ACPSessionInfo) -> MacConversation? {
    conversations.first { $0.hostID == hostID && $0.cwd == session.cwd && $0.sessionID == session.sessionID }
  }

  func restore() async {
    guard !restored else { return }
    restored = true
    // A new tab inherits a loaded location; its folders and sessions are shared.
    // Avoid a disk scan or a separate remote connection just to show them again.
    if inheritedLocation, !cwd.isEmpty, hostID == nil || host != nil,
      backend.snapshots[hostID]?.folders.contains(where: { $0.cwd == cwd }) == true {
      newChat()
      return
    }
    busy = true
    defer { busy = false }
    do {
      try await backend.prepare()
      hosts = try hostStore.hosts()
      if !inheritedLocation {
        hostID = UserDefaults.standard.string(forKey: "mac.host").flatMap(UUID.init(uuidString:))
        cwd = UserDefaults.standard.string(forKey: "mac.cwd") ?? ""
      }
      if host == nil { hostID = nil }
      try await refreshLocation()
      if hostID == nil, cwd.isEmpty {
        let project = try home.openProject(atWorkingDirectory: AgentHome.userHomeDirectory())
        cwd = project.workingDirectory
        try await refreshLocation()
      }
      busy = false
      newChat()
    } catch { self.error = error.localizedDescription }
  }

  func refresh() async {
    guard restored, !busy else { return }
    busy = true
    defer { busy = false }
    do { try await refreshLocation() }
    catch { self.error = error.localizedDescription }
  }

  private func refreshLocation() async throws {
    try await backend.refresh(hostID: hostID)
    if hostID != nil, host == nil {
      hostID = nil
      cwd = ""
      selectedID = nil
      try await backend.refresh(hostID: nil)
    }
    if !snapshot.folders.contains(where: { $0.cwd == cwd }) {
      cwd = snapshot.folders.first?.cwd ?? host?.cwd ?? ""
      selectedID = nil
    }
    remember()
  }

  func selectHost(_ id: UUID?) {
    guard !busy else { return }
    sidebarSection = .folders
    search = ""
    showArchived = false
    if hostID == id { return }
    hostID = id
    cwd = ""
    selectedID = nil
    Task { await refresh() }
  }

  func selectFolder(_ path: String) {
    guard !busy else { return }
    sidebarSection = .conversations
    search = ""
    showArchived = false
    if cwd == path { return }
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
      sidebarSection = .conversations
      search = ""
      showArchived = false
      selectedID = nil
      Task { await refresh() }
    } catch { self.error = error.localizedDescription }
  }

  func open(_ info: ACPSessionInfo? = nil) {
    guard !busy, !cwd.isEmpty, hostID == nil || host != nil else { return }
    sidebarSection = .conversations
    showArchived = info?.isArchived == true
    if let info, let existing = conversations.first(where: {
      $0.hostID == hostID && $0.sessionID == info.sessionID && $0.cwd == info.cwd
    }) {
      selectedID = existing.id
      remember()
      return
    }
    do {
      let conversation = MacConversation(hostID: hostID, hostName: hostName,
        cwd: info?.cwd ?? cwd, sessionID: info?.sessionID, title: info?.title ?? "New Chat", home: home)
      let profile = try host.map { try hostStore.connection(for: $0) }
      conversation.client = try makeClient(profile: profile, conversation: conversation)
      let backend = backend
      let hostID = hostID
      conversation.didChange = { [weak self, weak backend] in
        self?.remember()
        Task {
          do { try await backend?.refresh(hostID: hostID) }
          catch { self?.error = error.localizedDescription }
        }
      }
      conversations.append(conversation)
      selectedID = conversation.id
      conversation.connect()
    } catch { self.error = error.localizedDescription }
  }

  func newChat() { open() }

  func select(_ conversation: MacConversation) {
    guard !busy else { return }
    selectedID = conversation.id
    sidebarSection = .conversations
    remember()
  }

  func manage(_ session: ACPSessionInfo, action: ACPSessionAction, title: String? = nil) {
    manage([session], action: action, title: title)
  }

  func manage(_ sessions: [ACPSessionInfo], action: ACPSessionAction, title: String? = nil,
    destinationCwd: String? = nil) {
    let chats = sessions.compactMap { conversation(for: $0) }
    guard !busy, !sessions.isEmpty, !chats.contains(where: \.busy),
      sessions.allSatisfy({ $0.cwd == cwd }) else { return }
    if action == .move {
      guard snapshot.canMoveSessions == true, let destinationCwd, destinationCwd != cwd,
        snapshot.folders.contains(where: { $0.cwd == destinationCwd }) else { return }
    }
    busy = true
    // Reserve every selected chat before suspending, including chats displayed
    // in other windows, so a turn cannot begin halfway through the batch.
    for chat in chats { chat.busy = true }
    Task {
      defer { for chat in chats { chat.busy = false } }
      var failures: [String] = []
      var fork: ACPSessionInfo?
      for session in sessions {
        let chat = conversation(for: session)
        var temporaryClient: (any RemoteSessionClient)?
        do {
          let client: any RemoteSessionClient
          if let active = chat?.client, chat?.connected == true {
            client = active
          } else {
            if let host {
              client = try hostStore.connection(for: host).makeSession(cwd: session.cwd)
            } else {
              client = ACPClient(configuration: try localConfiguration(cwd: session.cwd))
            }
            temporaryClient = client
          }
          let result: ACPSessionInfo?
          if action == .move, let destinationCwd {
            result = try await client.moveSession(session.sessionID, cwd: session.cwd, destinationCwd: destinationCwd)
          } else {
            result = try await client.manageSession(session.sessionID, cwd: session.cwd, action: action, title: title)
          }
          if action == .rename, let title { chat?.title = title }
          if action == .delete || action == .archive || action == .move, let chat {
            await chat.close()
            conversations.removeAll { $0.id == chat.id }
            if selectedID == chat.id { selectedID = nil }
          }
          if action == .fork { fork = result }
        } catch {
          failures.append("\(session.title): \(error.localizedDescription)")
        }
        await temporaryClient?.disconnect()
      }
      busy = false
      await refresh()
      if let fork { open(fork) }
      if !failures.isEmpty { self.error = failures.joined(separator: "\n") }
      remember()
    }
  }

  func closeConversation(_ chat: MacConversation) {
    guard !busy else { return }
    busy = true
    Task {
      await chat.close()
      conversations.removeAll { $0.id == chat.id }
      if selectedID == chat.id { selectedID = nil }
      busy = false
      await refresh()
    }
  }

  func renameHost(_ host: ACPRemoteHost, to name: String) {
    do {
      try hostStore.rename(host, to: name)
      hosts = try hostStore.hosts()
      for chat in conversations where chat.hostID == host.id { chat.hostName = name }
    } catch { self.error = error.localizedDescription }
  }

  func removeHost(_ host: ACPRemoteHost, onError: ((String) -> Void)? = nil) {
    guard !busy else { return }
    busy = true
    Task {
      do {
        for chat in conversations where chat.hostID == host.id { await chat.close() }
        try hostStore.remove(host)
        conversations.removeAll { $0.hostID == host.id }
        if hostID == host.id {
          hostID = nil
          cwd = ""
          selectedID = nil
        }
        sidebarSection = .hosts
      } catch {
        if let onError { onError(error.localizedDescription) }
        else { self.error = error.localizedDescription }
      }
      busy = false
      await refresh()
    }
  }

  func renameFolder(_ folder: ACPWorkspaceFolder, to name: String) {
    guard hostID == nil, !busy else { return }
    do {
      guard var project = try home.loadProject(atWorkingDirectory: URL(fileURLWithPath: folder.cwd)) else { return }
      project.name = name
      try home.saveProject(project)
      Task { await refresh() }
    } catch { self.error = error.localizedDescription }
  }

  func forgetFolder(_ folder: ACPWorkspaceFolder) {
    guard hostID == nil, !busy else { return }
    busy = true
    Task {
      do {
        for chat in conversations where chat.hostID == nil && chat.cwd == folder.cwd { await chat.close() }
        if let project = try home.loadProject(atWorkingDirectory: URL(fileURLWithPath: folder.cwd)) {
          _ = try home.forgetProject(id: project.id)
        }
        conversations.removeAll { $0.hostID == nil && $0.cwd == folder.cwd }
        if cwd == folder.cwd { cwd = ""; selectedID = nil }
        sidebarSection = .folders
      } catch { self.error = error.localizedDescription }
      busy = false
      await refresh()
    }
  }

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
    return ACPClient(configuration: try localConfiguration(cwd: conversation.cwd, sessionID: conversation.sessionID),
      onUpdate: update, onPermission: permission, onDisconnect: disconnect)
  }

  func localConfiguration(cwd: String, sessionID: String? = nil) throws -> ACPClient.Configuration {
    let environment = MacCLI.environment
    let directory = URL(fileURLWithPath: cwd, isDirectory: true)
    let executable = try MacCLI.executable(environment: environment, workingDirectory: directory)
    var arguments = ["--acp", "--home", home.rootURL.path]
    // CLI startup restores the chat's runtime configuration before registering
    // providers, agents, MCP and skills. ACP then opens that same conversation.
    if let sessionID { arguments += ["--resume", sessionID] }
    return .init(command: executable,
      arguments: arguments, environment: environment,
      workingDirectory: directory, permission: .reject,
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
    sidebarSection = .folders
    search = ""
    showArchived = false
    remember()
  }

  private func parsedClient(_ profile: ACPRemoteConnection) throws -> ACPClient {
    ACPClient(configuration: .init(command: profile.name, permission: .reject,
      remoteWorkingDirectory: profile.cwd, readClientFiles: false,
      webSocketURL: profile.url, bearerToken: profile.token, forwirohInvitation: profile.forwirohInvitation))
  }

  func remember() {
    guard backend.activeWorkspace === self else { return }
    UserDefaults.standard.set(hostID?.uuidString, forKey: "mac.host")
    UserDefaults.standard.set(cwd, forKey: "mac.cwd")
  }

  func openTerminal() {
    guard hostID == nil, !cwd.isEmpty else { return }
    // Transfer this conversation to the terminal only after its writer has
    // disconnected. Two front ends must not write the same transcript.
    let conversation = selected
    Task {
      await conversation?.close()
      await launchTerminal(cwd: conversation?.cwd ?? cwd, sessionID: conversation?.sessionID)
    }
  }

  func openTerminal(in folder: ACPWorkspaceFolder) {
    guard hostID == nil else { return }
    Task { await launchTerminal(cwd: folder.cwd, sessionID: nil) }
  }

  func openTerminal(_ session: ACPSessionInfo) {
    guard hostID == nil, !busy else { return }
    let chat = conversation(for: session)
    Task {
      await chat?.close()
      await launchTerminal(cwd: session.cwd, sessionID: session.sessionID)
    }
  }

  private func launchTerminal(cwd: String, sessionID: String?) async {
    func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    do {
      let executable = try MacCLI.executable(environment: MacCLI.environment,
        workingDirectory: URL(fileURLWithPath: cwd, isDirectory: true))
      var arguments = [executable, "--home", home.rootURL.path]
      if let sessionID { arguments += ["--resume", sessionID] }
      let command = "#!/bin/sh\ncd " + quote(cwd) + " || exit 1\nexec " + arguments.map(quote).joined(separator: " ") + "\n"
      let file = FileManager.default.temporaryDirectory.appendingPathComponent("pmai-\(UUID()).command")
      try command.write(to: file, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
      if let therm2 = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.pancake.therm2") {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-e", file.path]
        // An existing Therm2 instance does not process new startup arguments.
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: therm2, configuration: configuration)
      } else {
        NSWorkspace.shared.open(file)
      }
    } catch { self.error = error.localizedDescription }
  }

}
