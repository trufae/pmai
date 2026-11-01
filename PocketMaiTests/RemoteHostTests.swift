import Foundation
import MaiACP
import MaiCore
import XCTest

@testable import PocketMai

@MainActor
final class RemoteHostTests: XCTestCase {
  func testOpenCodeCredentialAndBackendPersistWithoutLosingChatsOnReimport() throws {
    let url = try XCTUnwrap(URL(string: "https://worker.opentunnel.xyz"))
    try withStore([]) { store, file in
      let profile = try OpenCodeConnection(url: url, token: "opencode-session")
      let id = try store.add(profile)
      defer { store.remove(id) }
      XCTAssertEqual(store.host(id)?.backend, .openCode)
      XCTAssertEqual(store.host(id)?.requiresApproval, false)
      XCTAssertTrue(store.folders(for: try XCTUnwrap(store.host(id))).isEmpty)
      let chat = store.newConversation(hostID: id, cwd: "/work")
      store.toggleFolderPin(hostID: id, cwd: "/work")
      store.toggleConversationPin(hostID: id, conversationID: chat.id)
      let replacement = try OpenCodeConnection(
        name: "Workstation", url: url, token: "refreshed-session")
      XCTAssertEqual(try store.add(replacement), id)
      let reloaded = RemoteAgentStore(file: file)
      let host = try XCTUnwrap(reloaded.host(id))
      XCTAssertEqual(host.backend, .openCode)
      XCTAssertEqual(host.name, "Workstation")
      XCTAssertEqual(host.pinnedFolderPaths, ["/work"])
      XCTAssertEqual(host.pinnedConversationIDs, [chat.id])
      XCTAssertEqual(try reloaded.token(for: id), "refreshed-session")
      XCTAssertEqual(reloaded.conversations(for: host).first?.id, chat.id)
      XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("refreshed-session"))
      XCTAssertTrue(try host.makeClient(token: "test", cwd: "/work") is OpenCodeClient)
    }
  }

  func testRemoteLandingDraftSurvivesDiscoveryAndOnlyPersistsWhenUsed() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "https://worker.example")), cwd: "",
      backend: .openCode)
    try withStore([original]) { store, _ in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(original.id, isOffline: true)
      let draft = try XCTUnwrap(hosts.selectedConversation)
      XCTAssertNil(draft.sessionID)
      XCTAssertFalse(RemoteAgentChat(bookmark: original, conversation: draft, store: store).canSubmit)
      XCTAssertTrue(store.host(original.id)?.conversations?.isEmpty == true)

      // Discovery supplies OpenCode's project after the composer is already visible.
      hosts.selectFolder("/work", preservingDraft: true)
      XCTAssertEqual(hosts.selectedConversation?.id, draft.id)
      XCTAssertEqual(hosts.selectedConversation?.cwd, "/work")
      let unused = try XCTUnwrap(hosts.newConversation())
      XCTAssertNotEqual(unused.id, draft.id)
      XCTAssertTrue(RemoteAgentChat(bookmark: original, conversation: unused, store: store).canSubmit)
      XCTAssertTrue(store.host(original.id)?.conversations?.isEmpty == true)

      var started = unused
      started.sessionID = "new-session"
      started.messages = [.init(role: "user", text: "Hello")]
      store.update(original.id, conversation: started)
      XCTAssertEqual(hosts.selectedConversation?.id, unused.id)
      XCTAssertEqual(hosts.selectedConversation?.messages.first?.text, "Hello")
      XCTAssertEqual(store.host(original.id)?.conversations?.count, 1)
      hosts.selectHost(nil, isOffline: true)
      XCTAssertNil(hosts.selectedConversation)
    }
  }

  func testRemoteLandingRecentsStayOnHostAndOpenTheirOwnFolder() throws {
    let chats = (1...4).map { index in
      RemoteAgentConversation(
        cwd: "/project/\(index)", sessionID: "session-\(index)", title: "Chat \(index)",
        updatedAt: Date(timeIntervalSince1970: Double(index)))
    }
    let first = RemoteAgentBookmark(
      name: "First", url: try XCTUnwrap(URL(string: "wss://first.example/acp")), cwd: "/work",
      conversations: chats + [RemoteAgentConversation(cwd: "/work")])
    let second = RemoteAgentBookmark(
      name: "Second", url: try XCTUnwrap(URL(string: "https://second.example")), cwd: "/other",
      conversations: [.init(cwd: "/other", sessionID: "other-session")], backend: .openCode)
    try withStore([first, second]) { store, _ in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(first.id, isOffline: true)
      XCTAssertEqual(hosts.recentConversations.map(\.id), Array(chats.suffix(3)).map(\.id))
      hosts.selectConversation(chats[2].id)
      XCTAssertEqual(hosts.selectedFolderID, chats[2].cwd)
      XCTAssertEqual(hosts.selectedConversation?.sessionID, chats[2].sessionID)
      hosts.selectHost(second.id, isOffline: true)
      XCTAssertEqual(hosts.recentConversations.map(\.id), second.conversations?.map(\.id))
      XCTAssertEqual(hosts.selectedConversation?.cwd, "/other")
    }
  }

  func testLegacyHostStillUsesACP() throws {
    let host = RemoteAgentBookmark(
      name: "Legacy", url: try XCTUnwrap(URL(string: "wss://host.example/acp")), cwd: "/work")
    let restored = try JSONDecoder().decode(
      RemoteAgentBookmark.self, from: JSONEncoder().encode(host))
    XCTAssertNil(restored.backend)
    XCTAssertNil(restored.pinnedConversationIDs)
    XCTAssertTrue(try restored.makeClient(token: "test", cwd: "/work") is ACPClient)
  }

  func testHostPinPersistsAndSurvivesReimport() throws {
    let url = try XCTUnwrap(URL(string: "wss://host.example/acp"))
    try withStore([]) { store, file in
      let id = try store.add(
        ACPRemoteConnection(name: "Host", url: url, token: "token", cwd: "/work"))
      store.toggleHostPin(id)
      XCTAssertTrue(store.isHostPinned(id))

      XCTAssertEqual(
        try store.add(ACPRemoteConnection(name: "Renamed", url: url, token: "token", cwd: "/work")),
        id)
      XCTAssertTrue(store.isHostPinned(id))

      let reloaded = RemoteAgentStore(file: file)
      XCTAssertTrue(reloaded.isHostPinned(id))
      reloaded.toggleHostPin(id)
      XCTAssertFalse(reloaded.isHostPinned(id))
    }
  }

  func testOpenTunnelProfileImportAndApprovedCredentialPersist() throws {
    var profile = try ACPRemoteConnection(
      name: "Workstation", url: XCTUnwrap(URL(string: "wss://pmai.tunnel.example/acp")),
      token: "invitation-token", cwd: "/work", connectionProtocol: .opentunnel)
    profile.requiresApproval = true
    let imported = try ACPRemoteConnection.parse(profile.uri())
    try withStore([]) { store, file in
      let id = try store.add(imported)
      defer { store.remove(id) }
      XCTAssertEqual(store.host(id)?.connectionProtocol, .opentunnel)
      XCTAssertEqual(store.host(id)?.url, profile.url)
      XCTAssertEqual(store.host(id)?.requiresApproval, true)
      XCTAssertEqual(try store.token(for: id), "invitation-token")
      try store.acceptPairing(id, token: "approved-client-token")
      let reloaded = RemoteAgentStore(file: file)
      XCTAssertEqual(reloaded.host(id)?.connectionProtocol, .opentunnel)
      XCTAssertEqual(reloaded.host(id)?.requiresApproval, false)
      XCTAssertEqual(try reloaded.token(for: id), "approved-client-token")
      XCTAssertFalse(
        try String(contentsOf: file, encoding: .utf8).contains("approved-client-token"))
    }
  }

  func testSidebarFilteringMatchesNamesPathsAndMessageContentsInPlace() {
    XCTAssertTrue(SidebarSearch.matches("  cAFE  ", in: ["Café project", "/work/one"]))
    XCTAssertTrue(SidebarSearch.matches("/work/one", in: ["Project", "/work/one"]))
    XCTAssertTrue(SidebarSearch.matches("answer", in: ["Unrelated title", "Cached answer text"]))
    XCTAssertTrue(SidebarSearch.matches(" \n ", in: []))
    XCTAssertFalse(SidebarSearch.matches("missing", in: ["Title", "Different contents"]))
  }

  func testRemoteConversationPinsPersistOfflineAndStayIsolatedBetweenHostsAndFolders() throws {
    let oldest = RemoteAgentConversation(
      cwd: "/work", sessionID: "oldest", updatedAt: Date(timeIntervalSince1970: 100))
    let newer = RemoteAgentConversation(
      cwd: "/work", sessionID: "newer", updatedAt: Date(timeIntervalSince1970: 200))
    let newest = RemoteAgentConversation(
      cwd: "/work", updatedAt: Date(timeIntervalSince1970: 300))
    let elsewhere = RemoteAgentConversation(cwd: "/other")
    let first = RemoteAgentBookmark(
      name: "ACP", url: try XCTUnwrap(URL(string: "wss://first.example/acp")), cwd: "/work",
      conversations: [oldest, newer, newest, elsewhere])
    let second = RemoteAgentBookmark(
      name: "OpenCode", url: try XCTUnwrap(URL(string: "https://second.example")), cwd: "/work",
      conversations: [oldest, newer, newest], backend: .openCode)
    try withStore([first, second]) { store, file in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(first.id, isOffline: true)
      hosts.selectedConversationID = newest.id
      XCTAssertEqual(hosts.conversations.map(\.id), [newest.id, newer.id, oldest.id])
      hosts.toggleConversationPin(oldest.id)
      hosts.toggleConversationPin(newer.id)
      hosts.toggleConversationPin(elsewhere.id)
      XCTAssertTrue(hosts.isConversationPinned(oldest.id))
      XCTAssertEqual(hosts.conversations.map(\.id), [newer.id, oldest.id, newest.id])
      XCTAssertEqual(hosts.selectedConversationID, newest.id)
      XCTAssertEqual(hosts.selectedFolderID, "/work")
      XCTAssertFalse(hosts.loading)
      XCTAssertNil(store.host(first.id)?.revision)
      XCTAssertEqual(
        store.host(first.id)?.conversations?.map(\.updatedAt),
        first.conversations?.map(\.updatedAt))
      hosts.toggleConversationPin(UUID())
      XCTAssertEqual(
        store.host(first.id)?.pinnedConversationIDs, [oldest.id, newer.id, elsewhere.id])

      hosts.selectFolder("/other")
      XCTAssertEqual(hosts.conversations.map(\.id), [elsewhere.id])
      hosts.selectHost(second.id, isOffline: true)
      XCTAssertFalse(hosts.isConversationPinned(oldest.id))
      hosts.toggleConversationPin(newest.id)
      let restored = RemoteAgentStore(file: file)
      XCTAssertEqual(
        restored.host(first.id)?.pinnedConversationIDs,
        [oldest.id, newer.id, elsewhere.id])
      XCTAssertEqual(restored.host(second.id)?.pinnedConversationIDs, [newest.id])
      let navigation = HostNavigationStore(remotes: restored)
      navigation.selectHost(first.id, isOffline: true)
      XCTAssertEqual(navigation.conversations.map(\.id), [newer.id, oldest.id, newest.id])
      navigation.toggleConversationPin(oldest.id)
      navigation.toggleConversationPin(elsewhere.id)
      restored.deleteConversation(newer.id, hostID: first.id)
      let deleted = RemoteAgentStore(file: file)
      XCTAssertNil(deleted.host(first.id)?.pinnedConversationIDs)
      XCTAssertEqual(deleted.host(second.id)?.pinnedConversationIDs, [newest.id])
      XCTAssertEqual(navigation.conversations.map(\.id), [newest.id, oldest.id])
    }
  }

  func testRemoteConversationPinsSurviveDiscoveryReconnectAndActiveChatUpdates() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work")
    try withStore([original]) { store, file in
      let session = ACPSessionInfo(
        sessionID: "opaque-session", cwd: "/work", title: "Original",
        updatedAt: Date(timeIntervalSince1970: 100))
      store.updateWorkspace(original.id, snapshot: .init(sessions: [session]))
      let host = try XCTUnwrap(store.host(original.id))
      var activeSnapshot = try XCTUnwrap(host.conversations?.first)
      store.toggleConversationPin(hostID: original.id, conversationID: activeSnapshot.id)
      var refreshed = session
      refreshed.title = "Renamed"
      refreshed.updatedAt = Date(timeIntervalSince1970: 200)
      store.updateWorkspace(original.id, snapshot: .init(sessions: [refreshed]))
      store.reconnect(original.id)
      XCTAssertEqual(store.host(original.id)?.conversations?.first?.id, activeSnapshot.id)
      XCTAssertEqual(store.host(original.id)?.conversations?.first?.title, "Renamed")
      activeSnapshot.messages = [.init(role: "assistant", text: "Streaming response")]
      store.update(original.id, conversation: activeSnapshot)
      XCTAssertEqual(
        RemoteAgentStore(file: file).host(original.id)?.pinnedConversationIDs,
        [activeSnapshot.id])
      store.toggleConversationPin(hostID: original.id, conversationID: activeSnapshot.id)
      store.update(original.id, conversation: activeSnapshot)
      XCTAssertNil(RemoteAgentStore(file: file).host(original.id)?.pinnedConversationIDs)
      XCTAssertEqual(store.host(original.id)?.conversations?.count, 1)
    }
  }

  func testRemoteFolderPinsPersistOfflineAndStayIsolatedBetweenHosts() throws {
    let folders: [ACPWorkspaceFolder] = [
      .init(cwd: "/one", name: "One"), .init(cwd: "/two", name: "Two"),
      .init(cwd: "/three", name: "Three"),
    ]
    let first = RemoteAgentBookmark(
      name: "ACP", url: try XCTUnwrap(URL(string: "wss://first.example/acp")), cwd: "/one",
      conversations: [.init(cwd: "/two"), .init(cwd: "/three")])
    let second = RemoteAgentBookmark(
      name: "OpenCode", url: try XCTUnwrap(URL(string: "https://second.example")), cwd: "/one",
      workspace: .init(folders: folders), backend: .openCode)
    try withStore([first, second]) { store, file in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(first.id, isOffline: true)
      XCTAssertEqual(hosts.folders.map(\.cwd), ["/one", "/two", "/three"])
      XCTAssertFalse(hosts.isFolderPinned("/two"))
      hosts.toggleFolderPin("/two")
      hosts.toggleFolderPin("/three")
      XCTAssertEqual(hosts.folders.map(\.cwd), ["/two", "/three", "/one"])
      XCTAssertTrue(hosts.isFolderPinned("/two"))
      XCTAssertEqual(hosts.selectedFolderID, "/one")
      XCTAssertFalse(hosts.loading)
      XCTAssertNil(store.host(first.id)?.revision)

      hosts.selectHost(second.id, isOffline: true)
      XCTAssertFalse(hosts.isFolderPinned("/two"))
      XCTAssertEqual(hosts.folders.map(\.cwd), ["/one", "/two", "/three"])
      hosts.toggleFolderPin("/three")
      XCTAssertEqual(hosts.folders.map(\.cwd), ["/three", "/one", "/two"])
      let restored = RemoteAgentStore(file: file)
      XCTAssertEqual(restored.host(first.id)?.pinnedFolderPaths, ["/two", "/three"])
      XCTAssertEqual(restored.host(second.id)?.pinnedFolderPaths, ["/three"])
      XCTAssertEqual(
        restored.folders(for: try XCTUnwrap(restored.host(first.id))).map(\.cwd),
        ["/two", "/three", "/one"])
      store.toggleFolderPin(hostID: first.id, cwd: "/two")
      store.toggleFolderPin(hostID: first.id, cwd: "/three")
      let unpinned = RemoteAgentStore(file: file)
      let unpinnedHost = try XCTUnwrap(unpinned.host(first.id))
      XCTAssertNil(unpinnedHost.pinnedFolderPaths)
      XCTAssertEqual(unpinned.folders(for: unpinnedHost).map(\.cwd), ["/one", "/two", "/three"])
      XCTAssertEqual(unpinned.host(second.id)?.pinnedFolderPaths, ["/three"])
    }
  }

  func testFolderSearchOnlyMatchesNames() throws {
    let host = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "https://worker.example")), cwd: "/work/cafe",
      conversations: [
        .init(
          cwd: "/work/cafe", title: "Café discussion",
          messages: [.init(role: "user", text: "Coffee")])
      ],
      workspace: .init(folders: [
        .init(cwd: "/work/cafe", name: "Notes"), .init(cwd: "/work/project", name: "Café project"),
      ]), backend: .openCode, pinnedFolderPaths: ["/work/cafe"])
    try withStore([host]) { store, _ in
      let navigation = HostNavigationStore(remotes: store)
      navigation.selectHost(host.id, isOffline: true)
      XCTAssertEqual(
        navigation.folders(matching: "  CAFE  ", sortedBy: .name).map(\.cwd), ["/work/project"])
      XCTAssertTrue(navigation.folders(matching: "/work", sortedBy: .name).isEmpty)
      XCTAssertTrue(navigation.folders(matching: "discussion", sortedBy: .name).isEmpty)
      XCTAssertTrue(navigation.folders(matching: "coffee", sortedBy: .name).isEmpty)
      XCTAssertEqual(navigation.folders(matching: "\n ", sortedBy: .name).count, 2)
    }
  }

  func testFolderSortingKeepsPinsFirstAndUnknownDatesLast() throws {
    let early = Date(timeIntervalSince1970: 100)
    let late = Date(timeIntervalSince1970: 200)
    let host = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/alpha",
      workspace: .init(folders: [
        .init(cwd: "/zeta", name: "Zeta", updatedAt: late),
        .init(cwd: "/alpha", name: "Alpha"),
        .init(cwd: "/project10", name: "Project 10", updatedAt: early),
        .init(cwd: "/project2", name: "Project 2", updatedAt: early),
        .init(cwd: "/beta", name: "Beta"),
        .init(cwd: "/pinned1", name: "First", updatedAt: late),
        .init(cwd: "/pinned2", name: "Second"),
      ]), pinnedFolderPaths: ["/pinned2", "/pinned1"])
    try withStore([host]) { store, _ in
      let navigation = HostNavigationStore(remotes: store)
      navigation.selectHost(host.id, isOffline: true)
      XCTAssertEqual(
        navigation.folders(matching: "", sortedBy: .name).map(\.cwd),
        [
          "/pinned2", "/pinned1", "/alpha", "/beta", "/project2", "/project10", "/zeta",
        ])
      XCTAssertEqual(
        navigation.folders(matching: "", sortedBy: .updated).map(\.cwd),
        [
          "/pinned2", "/pinned1", "/zeta", "/project2", "/project10", "/alpha", "/beta",
        ])
      XCTAssertEqual(
        navigation.folders(matching: "project", sortedBy: .updated).map(\.cwd),
        [
          "/project2", "/project10",
        ])
    }
  }

  func testFolderActivityUsesLatestKnownDatesAcrossRefreshAndReload() throws {
    let old = Date(timeIntervalSince1970: 100)
    let recent = Date(timeIntervalSince1970: 200)
    let latest = Date(timeIntervalSince1970: 300)
    let snapshot = ACPWorkspaceSnapshot(
      folders: [
        .init(cwd: "/metadata", name: "Metadata", updatedAt: latest),
        .init(cwd: "/session", name: "Session", updatedAt: old),
        .init(cwd: "/cached", name: "Cached", updatedAt: old),
        .init(cwd: "/unknown", name: "Unknown"),
      ],
      sessions: [
        .init(sessionID: "one", cwd: "/metadata", title: "One", updatedAt: old),
        .init(sessionID: "two", cwd: "/session", title: "Two", updatedAt: recent),
        .init(sessionID: "three", cwd: "/cached", title: "Three", updatedAt: recent),
        .init(sessionID: "four", cwd: "/unknown", title: "Four"),
      ])
    let host = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/metadata",
      conversations: [
        .init(
          cwd: "/cached", sessionID: "three", updatedAt: latest,
          messages: [.init(role: "user", text: "Local update")])
      ], workspace: snapshot)
    try withStore([host]) { store, file in
      XCTAssertEqual(store.folders(for: host).map(\.updatedAt), [latest, recent, latest, nil])
      store.updateWorkspace(host.id, snapshot: snapshot)
      store.updateWorkspace(host.id, snapshot: snapshot)
      let restored = RemoteAgentStore(file: file)
      let saved = try XCTUnwrap(restored.host(host.id))
      XCTAssertEqual(restored.folders(for: saved).map(\.updatedAt), [latest, recent, latest, nil])
      let legacy = try JSONDecoder().decode(
        ACPWorkspaceFolder.self, from: Data(#"{"cwd":"/legacy","name":"Legacy"}"#.utf8))
      XCTAssertNil(legacy.updatedAt)
    }
  }

  func testRemoteFolderPinsKeepTheirOrderAcrossDiscoveryAndReconnect() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/one",
      workspace: .init(folders: [.init(cwd: "/one", name: "One"), .init(cwd: "/two", name: "Two")]))
    try withStore([original]) { store, file in
      store.toggleFolderPin(hostID: original.id, cwd: "/two")
      store.toggleFolderPin(hostID: original.id, cwd: "/one")
      let renamed = ACPWorkspaceFolder(cwd: "/two", name: "Renamed", icon: "star", tint: "green")
      store.updateWorkspace(
        original.id,
        snapshot: .init(folders: [
          .init(cwd: "/three", name: "Three"), .init(cwd: "/one", name: "One"), renamed,
        ]))
      store.reconnect(original.id)
      let restored = RemoteAgentStore(file: file)
      let host = try XCTUnwrap(restored.host(original.id))
      XCTAssertEqual(restored.folders(for: host).map(\.cwd), ["/two", "/one", "/three"])
      XCTAssertEqual(restored.folders(for: host).first, renamed)
      store.updateWorkspace(
        original.id, snapshot: .init(folders: [.init(cwd: "/one", name: "One")]))
      XCTAssertEqual(
        store.folders(for: try XCTUnwrap(store.host(original.id))).map(\.cwd), ["/one"])
      store.updateWorkspace(
        original.id, snapshot: .init(folders: [.init(cwd: "/one", name: "One"), renamed]))
      XCTAssertEqual(
        store.folders(for: try XCTUnwrap(store.host(original.id))).map(\.cwd), ["/two", "/one"])
    }
  }

  func testRemoteTranscriptUsesSharedMessageRendering() throws {
    let conversation = RemoteAgentConversation(
      cwd: "/work",
      messages: [
        .init(role: "user", text: "Question"), .init(role: "thought", text: "Reasoning"),
        .init(role: "tool", text: "Result", status: "completed"),
        .init(role: "plan", text: "Next step"),
        .init(role: "assistant", text: "Answer"),
      ])
    let presentation = conversation.presentation
    XCTAssertEqual(presentation.id, conversation.id)
    XCTAssertEqual(presentation.messages.map(\.id), conversation.messages.map(\.id))
    XCTAssertEqual(presentation.messages.first?.role, .user)
    XCTAssertEqual(presentation.messages.last?.text, "Answer")
    let reasoning = MessageContentFilter.render(presentation.messages[1].text)
    XCTAssertEqual(reasoning.hiddenSections.first?.tag, "think")
    XCTAssertTrue(reasoning.visibleText.isEmpty)
    let tool = try XCTUnwrap(
      MessageContentFilter.render(presentation.messages[2].text).hiddenSections.first)
    XCTAssertEqual(ToolCallParser.parse(tool.content).first?.body, "completed\nResult")
    let plan = try XCTUnwrap(
      MessageContentFilter.render(presentation.messages[3].text).hiddenSections.first)
    XCTAssertEqual(ToolCallParser.parse(plan.content).first?.body, "Next step")
  }
  func testOpenCodeToolDetailsSurviveCachingAndUseTheLocalToolRows() throws {
    let conversation = RemoteAgentConversation(cwd: "/work", messages: [
      .init(role: "tool", text: "read\nFile contents", status: "completed",
        toolName: "read", toolInput: .object(["path": .string("README.md")])),
      .init(role: "tool", text: "bash\nCommand failed", status: "error",
        toolName: "bash", toolInput: .object(["command": .string("make")])),
      .init(role: "tool", text: "bash", status: "streaming",
        toolName: "bash", toolInput: .string("{\n\"command\":")),
    ])
    let cached = try JSONDecoder().decode(
      RemoteAgentConversation.self, from: JSONEncoder().encode(conversation))
    let entries = try cached.presentation.messages.map { message in
      let section = try XCTUnwrap(MessageContentFilter.render(message.text).hiddenSections.first)
      return try XCTUnwrap(ToolCallParser.parse(section.content).first)
    }
    XCTAssertEqual(entries.map(\.name), ["read", "bash", "bash"])
    XCTAssertEqual(entries[0].params, #"{"path":"README.md"}"#)
    XCTAssertEqual(entries[0].body, "completed\nFile contents")
    XCTAssertTrue(entries[1].hasError)
    XCTAssertTrue(entries[1].body.contains("Command failed"))
    XCTAssertEqual(
      try JSONDecoder().decode(JSONValue.self, from: Data(entries[2].params.utf8)),
      conversation.messages[2].toolInput)
  }

  private func withStore(
    _ bookmarks: [RemoteAgentBookmark],
    body: (RemoteAgentStore, URL) throws -> Void
  ) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "remote-host-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("connections.json")
    try JSONEncoder().encode(bookmarks).write(to: file)
    try body(RemoteAgentStore(file: file), file)
  }

  func testLegacyWorkspaceConnectionsBecomeOneHostWithoutLosingChats() throws {
    let url = try XCTUnwrap(URL(string: "wss://worker.example/acp"))
    var first = RemoteAgentBookmark(
      name: "Worker", url: url, cwd: "/work/one",
      sessionID: "one", messages: [.init(role: "user", text: "First conversation")],
      pinnedFolderPaths: ["/work/one"])
    var second = RemoteAgentBookmark(
      name: "Worker", url: url, cwd: "/work/two",
      sessionID: "two", messages: [.init(role: "user", text: "Second conversation")],
      pinnedFolderPaths: ["/work/two", "/work/one"])
    first.pinnedConversationIDs = [first.id]
    second.pinnedConversationIDs = [second.id, first.id]
    try withStore([first, second]) { store, file in
      XCTAssertEqual(store.connections.count, 1)
      let host = try XCTUnwrap(store.connections.first)
      XCTAssertEqual(host.id, first.id)
      XCTAssertEqual(host.pinnedFolderPaths, ["/work/one", "/work/two"])
      XCTAssertEqual(host.pinnedConversationIDs, [first.id, second.id])
      XCTAssertEqual(Set(store.folders(for: host).map(\.cwd)), Set(["/work/one", "/work/two"]))
      XCTAssertEqual(
        Set(store.conversations(for: host).compactMap(\.sessionID)), Set(["one", "two"]))
      let newChat = store.newConversation(hostID: host.id, cwd: "/work/one")
      let reloaded = RemoteAgentStore(file: file)
      let reloadedHost = try XCTUnwrap(reloaded.connections.first)
      XCTAssertEqual(reloadedHost.pinnedConversationIDs, [first.id, second.id])
      XCTAssertEqual(reloaded.conversations(for: reloadedHost).count, 3)
      XCTAssertTrue(reloaded.conversations(for: reloadedHost).contains { $0.id == newChat.id })
    }
  }

  func testDiscoveryKeepsOpaqueSessionIdentityAndIsolatesHosts() throws {
    let first = RemoteAgentBookmark(
      name: "First", url: try XCTUnwrap(URL(string: "wss://first.example/acp")), cwd: "/work")
    let second = RemoteAgentBookmark(
      name: "Second", url: try XCTUnwrap(URL(string: "wss://second.example/acp")), cwd: "/work")
    try withStore([first, second]) { store, file in
      let snapshot = ACPWorkspaceSnapshot(
        folders: [.init(cwd: "/work", name: "Project")],
        sessions: [.init(sessionID: "opaque-session", cwd: "/work", title: "Remote chat")])
      store.updateWorkspace(first.id, snapshot: snapshot)
      let firstHost = try XCTUnwrap(store.host(first.id))
      let chat = try XCTUnwrap(store.conversations(for: firstHost).first)
      store.updateWorkspace(first.id, snapshot: snapshot)
      XCTAssertEqual(
        store.conversations(for: try XCTUnwrap(store.host(first.id))).first?.id, chat.id)
      XCTAssertTrue(store.conversations(for: try XCTUnwrap(store.host(second.id))).isEmpty)
      var updated = chat
      updated.messages = [.init(role: "user", text: "Continue")]
      store.update(first.id, conversation: updated)
      let reloaded = RemoteAgentStore(file: file)
      XCTAssertEqual(
        reloaded.conversations(for: try XCTUnwrap(reloaded.host(first.id))).first?.messages.first?
          .text, "Continue")
      XCTAssertTrue(reloaded.conversations(for: try XCTUnwrap(reloaded.host(second.id))).isEmpty)
      store.deleteConversation(chat.id, hostID: first.id)
      store.updateWorkspace(first.id, snapshot: .init())
      let deleted = RemoteAgentStore(file: file)
      XCTAssertTrue(deleted.conversations(for: try XCTUnwrap(deleted.host(first.id))).isEmpty)
    }
  }

  func testHostColorApprovalStateAndReconnectRevisionPersist() throws {
    let original = RemoteAgentBookmark(
      name: "Workstation",
      url: try XCTUnwrap(URL(string: "ws://192.168.1.5:19283/acp")), cwd: "/work",
      accentColor: "custom:#22AA55", requiresApproval: true)
    try withStore([original]) { store, file in
      store.reconnect(original.id)
      let updated = try XCTUnwrap(store.host(original.id))
      XCTAssertNotNil(updated.revision)
      let reloaded = try XCTUnwrap(RemoteAgentStore(file: file).host(original.id))
      XCTAssertEqual(reloaded.accentColor, "custom:#22AA55")
      XCTAssertEqual(reloaded.requiresApproval, true)
      XCTAssertEqual(reloaded.revision, updated.revision)
      XCTAssertEqual(reloaded.url, original.url)
    }
  }

  func testRenamePersistsWithoutChangingConnectionOrCachedChats() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work",
      conversations: [.init(cwd: "/work", sessionID: "opaque-session", title: "Saved chat")],
      accentColor: "green", requiresApproval: true)
    try withStore([original]) { store, file in
      try store.rename(original.id, to: "  Home server\n")
      let renamed = try XCTUnwrap(RemoteAgentStore(file: file).host(original.id))
      XCTAssertEqual(renamed.name, "Home server")
      XCTAssertEqual(renamed.url, original.url)
      XCTAssertEqual(renamed.cwd, original.cwd)
      XCTAssertEqual(renamed.revision, original.revision)
      XCTAssertEqual(renamed.accentColor, original.accentColor)
      XCTAssertEqual(renamed.requiresApproval, original.requiresApproval)
      XCTAssertEqual(renamed.conversations?.first?.sessionID, "opaque-session")
      for invalid in [" \n ", String(repeating: "a", count: 201)] {
        XCTAssertThrowsError(try store.rename(original.id, to: invalid))
      }
      XCTAssertEqual(store.host(original.id)?.name, "Home server")
    }
  }

  func testDisconnectReturnsToLocalAndPreservesRemoteHistory() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work",
      conversations: [.init(cwd: "/work", messages: [.init(role: "user", text: "Saved")])])
    try withStore([original]) { store, _ in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(original.id, isOffline: true)
      let conversation = try XCTUnwrap(store.host(original.id)?.conversations?.first)
      let chat = RemoteAgentChat(bookmark: original, conversation: conversation, store: store)
      hosts.activeChat = chat
      chat.connected = true
      XCTAssertTrue(hosts.isConnected(original.id))
      hosts.selectedConversationID = conversation.id
      hosts.selectHost(original.id, isOffline: false)
      XCTAssertFalse(hosts.loading)
      XCTAssertTrue(hosts.activeChat === chat)
      XCTAssertEqual(hosts.selectedConversationID, conversation.id)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .connected)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: true), .disconnected)
      hosts.disconnect(original.id)
      XCTAssertFalse(hosts.isConnected(original.id))
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .disconnected)
      XCTAssertFalse(chat.connected)
      XCTAssertNil(hosts.selectedHostID)
      XCTAssertNil(hosts.activeChat)
      XCTAssertEqual(store.host(original.id)?.conversations?.first?.messages.first?.text, "Saved")
    }
  }

  func testOfflineHostSelectionAndReconnectDoNotStartDiscovery() throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work")
    try withStore([original]) { store, _ in
      let hosts = HostNavigationStore(remotes: store)
      hosts.selectHost(original.id, isOffline: true)
      XCTAssertFalse(hosts.loading)
      XCTAssertFalse(hosts.isConnected(original.id))
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: true), .disconnected)
      XCTAssertTrue(hosts.error?.contains("Airplane Mode") == true)
      hosts.reconnect(original.id, isOffline: true)
      XCTAssertNil(store.host(original.id)?.revision)
      XCTAssertFalse(hosts.loading)
    }
  }

  func testFailedDiscoveryPersistsUntilReconnectOrExplicitDisconnect() async throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work")
    try await withRemoteManagementStore(original) { store in
      let hosts = HostNavigationStore(remotes: store)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .disconnected)
      // No credential was stored for this bookmark, so discovery fails before networking.
      hosts.selectHost(original.id, isOffline: false)
      for _ in 0..<500 {
        if !hosts.loading { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(hosts.loading)
      XCTAssertNotNil(hosts.error)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .failed)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: true), .disconnected)
      hosts.selectHost(original.id, isOffline: false)
      XCTAssertFalse(hosts.loading)
      XCTAssertNotNil(hosts.error)
      hosts.selectHost(nil, isOffline: false)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .failed)
      hosts.reconnect(original.id, isOffline: false)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .disconnected)
      hosts.disconnect(original.id)
      await Task.yield()
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .disconnected)
    }
  }

  func testFailedChatConnectionSurvivesSuspensionAndClearsOnDisconnect() async throws {
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work")
    try await withRemoteManagementStore(original) { store in
      let hosts = HostNavigationStore(remotes: store)
      let chat = RemoteAgentChat(
        bookmark: original, conversation: .init(cwd: "/work"), store: store)
      hosts.activeChat = chat
      chat.connect()
      for _ in 0..<500 {
        if !chat.busy { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertFalse(chat.busy)
      XCTAssertNotNil(chat.error)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .failed)
      hosts.suspendConnections()
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .failed)
      hosts.disconnect(original.id)
      XCTAssertEqual(hosts.connectionState(original.id, isOffline: false), .disconnected)
    }
  }

  func testRemoteChatUsesLiveOfflinePolicyForConnectSendAndManagement() async throws {
    var workspace = ACPWorkspaceSnapshot()
    workspace.canManageSessions = true
    let original = RemoteAgentBookmark(
      name: "Worker", url: try XCTUnwrap(URL(string: "wss://worker.example/acp")), cwd: "/work",
      workspace: workspace)
    var offline = false
    let chat = RemoteAgentChat(
      bookmark: original, conversation: .init(cwd: "/work", sessionID: "remote-session"),
      isOffline: { offline })
    offline = true
    chat.connect()
    XCTAssertFalse(chat.busy)
    XCTAssertFalse(chat.connected)
    XCTAssertTrue(chat.error?.contains("Airplane Mode") == true)
    chat.connected = true
    chat.send("Must not send")
    XCTAssertTrue(chat.messages.isEmpty)
    // The host capability comes from the repository, so test remote management there as well.
    try await withRemoteManagementStore(original) { store in
      let managed = RemoteAgentChat(
        bookmark: original, conversation: .init(cwd: "/work", sessionID: "remote-session"),
        store: store, isOffline: { offline })
      do {
        try await managed.manage(title: "Renamed")
        XCTFail("Offline management should fail before opening a connection")
      } catch is MaiCore.InternetAccessError {
      }
      XCTAssertFalse(managed.busy)
    }
  }

  private func withRemoteManagementStore(
    _ bookmark: RemoteAgentBookmark, body: (RemoteAgentStore) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("connections.json")
    try JSONEncoder().encode([bookmark]).write(to: file)
    try await body(RemoteAgentStore(file: file))
  }
}
