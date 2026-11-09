import AppKit
import MaiACP
import MaiCore
import SwiftUI

struct MacWorkspaceView: View {
  @Bindable var workspace: MacWorkspace
  @State private var columns = NavigationSplitViewVisibility.all
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationSplitView(columnVisibility: $columns) {
      sidebar.navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
    } detail: {
      Group {
        if let conversation = workspace.selected {
          MacChatView(conversation: conversation)
        } else {
          ContentUnavailableView {
            Label(workspace.cwd.isEmpty ? "Your workspace, in pmai" : "Start a conversation", systemImage: "bubble.left.and.bubble.right")
          } description: {
            Text(workspace.cwd.isEmpty
              ? "Open a folder to use your projects, tools, and agents. Connect a host to work on another machine."
              : "Ask a question, work with files, or delegate a task to an agent.")
          } actions: {
            if workspace.cwd.isEmpty {
              Button("Open Workspace…", action: workspace.chooseFolder).buttonStyle(.borderedProminent)
              Button("Connect to Host…") { workspace.showConnection = true }
            } else {
              Button("New Chat", action: workspace.newChat).buttonStyle(.borderedProminent)
            }
          }
        }
      }
      .navigationTitle(workspace.selected?.title ?? "pmai")
      .navigationSubtitle(workspace.cwd.isEmpty ? workspace.hostName : "\(workspace.hostName) · \(URL(fileURLWithPath: workspace.cwd).lastPathComponent)")
      .toolbar {
        ToolbarItemGroup {
          Button(action: workspace.newChat) { Label("New Chat", systemImage: "square.and.pencil") }
            .help("New Chat (⌘N)").disabled(workspace.cwd.isEmpty || workspace.busy)
          Button { workspace.showInspector.toggle() } label: {
            Label("Conversation Details", systemImage: "sidebar.right")
          }
          .help("Show settings and subagents").disabled(workspace.selected == nil)
        }
      }
      .inspector(isPresented: $workspace.showInspector) {
        if let conversation = workspace.selected { MacInspector(conversation: conversation) }
      }
      .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
    .sheet(isPresented: $workspace.showConnection) { MacConnectionSheet(workspace: workspace) }
    .alert("Couldn’t complete the operation", isPresented: Binding(
      get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } }
    )) { Button("OK") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await workspace.refresh() } }
    }
  }

  private var sidebar: some View {
    VStack(spacing: 0) {
      List {
        Section("Hosts") {
          Button { workspace.selectHost(nil) } label: {
            Label("This Mac", systemImage: workspace.hostID == nil ? "desktopcomputer.and.arrow.down" : "desktopcomputer")
          }
          ForEach(workspace.hosts) { host in
            Button { workspace.selectHost(host.id) } label: {
              HStack {
                Label(host.name, systemImage: "network")
                Spacer()
                if workspace.hostID == host.id { Image(systemName: "checkmark").accessibilityLabel("Selected") }
              }
            }
          }
          Button { workspace.showConnection = true } label: { Label("Connect Host…", systemImage: "plus") }
        }
        Section("Workspaces") {
          ForEach(workspace.snapshot.folders) { folder in
            Button { workspace.selectFolder(folder.cwd) } label: {
              HStack {
                Label(folder.name, systemImage: "folder")
                Spacer()
                if workspace.cwd == folder.cwd { Image(systemName: "checkmark").accessibilityLabel("Selected") }
              }
            }.help(folder.cwd)
          }
          if workspace.hostID == nil {
            Button(action: workspace.chooseFolder) { Label("Open Folder…", systemImage: "folder.badge.plus") }
          }
        }
        if !workspace.conversations.isEmpty {
          Section("Open Chats") {
            ForEach(workspace.conversations) { chat in
              Button {
                workspace.hostID = chat.hostID
                workspace.cwd = chat.cwd
                workspace.selectedID = chat.id
                workspace.remember()
                Task { await workspace.refresh() }
              } label: {
                HStack {
                  Image(systemName: chat.permission != nil ? "hand.raised" : "bubble.left")
                  Text(chat.title).lineLimit(1)
                  Spacer()
                  if chat.busy { ProgressView().controlSize(.mini).accessibilityLabel("Working") }
                  if chat.id == workspace.selectedID { Image(systemName: "checkmark") }
                }
              }
              .help("\(chat.hostName) · \(chat.cwd)")
            }
          }
        }
        Section("Conversations") {
          ForEach(workspace.sessions) { session in
            Button { workspace.open(session) } label: {
              VStack(alignment: .leading, spacing: 3) {
                Text(session.title).lineLimit(2)
                if let date = session.updatedAt {
                  Text(date, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
      }
      .listStyle(.sidebar)
      .buttonStyle(.plain)
      .searchable(text: $workspace.search, prompt: "Find a conversation")
      .disabled(workspace.busy)
      Divider()
      HStack {
        Label(workspace.hostName, systemImage: workspace.hostID == nil ? "desktopcomputer" : "network")
          .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        Spacer()
        if workspace.busy { ProgressView().controlSize(.small) }
        SettingsLink { Image(systemName: "gearshape") }.help("Settings (⌘,)")
      }.padding(12)
    }
  }
}

struct MacChatView: View {
  @Bindable var conversation: MacConversation
  @State private var followsBottom = true

  var body: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 26) {
            if conversation.messages.isEmpty {
              VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(.tint)
                Text("What would you like to work on?").font(.title2.weight(.semibold))
                Text(conversation.cwd).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              }.padding(.vertical, 50)
            }
            ForEach(conversation.messages) { message in
              messageRow(message).id(message.id)
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .frame(maxWidth: 860, alignment: .leading)
          .padding(28)
          .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.bottom)
        .onScrollGeometryChange(for: Bool.self) { geometry in
          geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
        } action: { _, bottom in followsBottom = bottom }
        .onChange(of: conversation.messages.last?.text) { _, _ in
          if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .overlay(alignment: .bottomTrailing) {
          if !followsBottom {
            Button { followsBottom = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
              Label("Latest", systemImage: "arrow.down")
            }.buttonStyle(.bordered).padding()
          }
        }
      }
      if let error = conversation.error {
        HStack(alignment: .top) {
          Image(systemName: "exclamationmark.triangle")
          Text(error).textSelection(.enabled)
          Spacer()
          Button("Dismiss") { conversation.error = nil }
        }.font(.callout).padding().background(.orange.opacity(0.12))
      }
      composer
    }
    .background(Color(nsColor: .textBackgroundColor))
    .sheet(isPresented: Binding(get: { conversation.permission != nil }, set: {
      if !$0 { conversation.answerPermission(nil) }
    })) { MacPermissionSheet(conversation: conversation) }
  }

  private var composer: some View {
    VStack(spacing: 10) {
      Divider()
      ZStack(alignment: .topLeading) {
        if conversation.draft.isEmpty {
          Text("Message pmai…").foregroundStyle(.tertiary).padding(.top, 6).allowsHitTesting(false)
        }
        MacComposer(text: $conversation.draft) { conversation.send(); followsBottom = true }
          .id(conversation.id)
      }.frame(height: 76).padding(.horizontal, 18).padding(.top, 6)
      HStack {
        if conversation.prompts.entries.contains(where: { $0.kind != .system }) {
          Menu {
            ForEach(conversation.prompts.entries.filter { $0.kind != .system }) { entry in
              Button(entry.name) { conversation.draft = "$\(entry.commandName) " }
                .help(entry.summary)
            }
          } label: { Label("Prompts and Skills", systemImage: "text.badge.star") }
            .menuStyle(.borderlessButton).fixedSize().help("Use a configured prompt or skill")
        }
        Circle().fill(conversation.connected ? Color.green : Color.secondary).frame(width: 6, height: 6)
        Text(conversation.status).font(.caption).foregroundStyle(.secondary)
        if let model = conversation.options.first(where: { $0.category == "model" }) {
          Text("· " + (model.choices.first(where: { .string($0.id) == model.currentValue })?.name ?? ""))
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer()
        if !conversation.connected && !conversation.busy {
          Button("Reconnect", action: conversation.connect)
        }
        if conversation.busy {
          Button(action: conversation.stop) { Label("Stop", systemImage: "stop.fill") }
            .help("Stop response (⌘.)")
        } else {
          Button { conversation.send(); followsBottom = true } label: { Label("Send", systemImage: "arrow.up") }
            .buttonStyle(.borderedProminent).keyboardShortcut(.return, modifiers: .command)
            .disabled(!conversation.connected || conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Return sends. Shift-Return adds a new line.")
        }
      }.padding(.horizontal, 16).padding(.bottom, 14)
    }
    .frame(maxWidth: 916)
    .frame(maxWidth: .infinity)
  }

  private func messageRow(_ message: ACPConversationMessage) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(message.role == "user" ? "You" : message.role == "assistant" ? "pmai" : message.role.capitalized,
          systemImage: message.role == "user" ? "person.crop.circle" : message.role == "tool" ? "wrench.and.screwdriver" : "sparkle")
          .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if let status = message.status { Text(status.capitalized).font(.caption).foregroundStyle(.secondary) }
      }
      if message.role == "tool" || message.role == "thought" {
        DisclosureGroup(message.toolName ?? (message.role == "thought" ? "Reasoning" : "Tool details")) {
          if let input = message.toolInput,
            let data = try? JSONEncoder().encode(input), let text = String(data: data, encoding: .utf8) {
            Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          }
          MacMarkdown(text: message.text)
        }
      } else {
        MacMarkdown(text: message.text)
      }
    }
    .padding(message.role == "user" ? 16 : 0)
    .background {
      if message.role == "user" { RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.045)) }
    }
    .contextMenu {
      Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
      if message.role == "user", conversation.canRewind, message.remoteID != nil {
        Button("Edit from Here…") { conversation.rewind(message) }.disabled(conversation.busy)
      }
    }
  }
}
