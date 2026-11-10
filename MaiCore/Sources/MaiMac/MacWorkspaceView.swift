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
      MacSidebar(workspace: workspace).navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
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
      .navigationSubtitle(subtitle)
      .toolbar {
        ToolbarItemGroup {
          if let conversation = workspace.selected, !conversation.connected && !conversation.busy {
            Button("Reconnect", systemImage: "arrow.clockwise", action: conversation.connect)
          }
          Button(action: workspace.newChat) { Label("New Chat", systemImage: "square.and.pencil") }
            .help("New Chat (⌘N)").disabled(workspace.cwd.isEmpty || workspace.busy)
          Button { workspace.showInspector.toggle() } label: {
            Label("Conversation Details", systemImage: "sidebar.right")
          }
          .help("Show settings and subagents (⌘O)").disabled(workspace.selected == nil)
        }
      }
      .inspector(isPresented: $workspace.showInspector) {
        if let conversation = workspace.selected { MacInspector(conversation: conversation) }
      }
      .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
    }
    .focusedSceneValue(\.macSidebarVisibility, $columns)
    .sheet(isPresented: $workspace.showConnection) { MacConnectionSheet(workspace: workspace) }
    .alert("Couldn’t complete the operation", isPresented: Binding(
      get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } }
    )) { Button("OK") { workspace.error = nil } } message: { Text(workspace.error ?? "") }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { Task { await workspace.refresh() } }
    }
    .onChange(of: workspace.hosts) { _, _ in
      if workspace.hostID != nil, workspace.host == nil {
        Task { await workspace.refresh() }
      }
    }
  }

  private var subtitle: String {
    [workspace.selected?.modelName, workspace.hostName,
      workspace.cwd.isEmpty ? nil : URL(fileURLWithPath: workspace.cwd).lastPathComponent]
      .compactMap { $0 }.joined(separator: " · ")
  }
}

struct MacChatView: View {
  @Bindable var conversation: MacConversation
  @State private var followsBottom = true
  @State private var pinchBaseFontSize: Double?
  @GestureState private var isPinching = false
  private var typography = MacChatTypography()
  private var appearance = MacAppearance()

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
        .simultaneousGesture(
          MagnifyGesture()
            .updating($isPinching) { _, active, _ in active = true }
            .onChanged { value in
              if pinchBaseFontSize == nil {
                pinchBaseFontSize = typography.size
                followsBottom = false
              }
              typography.resize(to: (pinchBaseFontSize ?? typography.size) * value.magnification)
            }
        )
        .onChange(of: isPinching) { _, active in
          if !active { pinchBaseFontSize = nil }
        }
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
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      VStack(spacing: 0) {
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
    }
    .background(Color(nsColor: .textBackgroundColor))
    .sheet(isPresented: Binding(get: { conversation.permission != nil }, set: {
      if !$0 { conversation.answerPermission(nil) }
    })) { MacPermissionSheet(conversation: conversation) }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 12) {
      MacComposer(text: $conversation.draft, prompts: conversation.prompts) { conversation.send(); followsBottom = true }
        .id(conversation.id)
        .zIndex(1)
        .overlay(alignment: .topLeading) {
          if conversation.draft.isEmpty {
            Text("Message pmai…").font(typography.font()).foregroundStyle(.tertiary)
              .padding(.top, 6).allowsHitTesting(false)
          }
        }
      Group {
        if conversation.busy {
          Button(action: conversation.stop) { Label("Stop", systemImage: "stop.fill") }
            .help("Stop response (⌘.)")
        } else {
          Button { conversation.send(); followsBottom = true } label: { Label("Send", systemImage: "arrow.up") }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!conversation.connected || conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Return sends. Shift-Return adds a new line.")
        }
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.circle)
      .controlSize(.regular)
    }
    .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
    .background { composerBackground }
    .frame(maxWidth: 860)
    .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  private var composerBackground: some View {
    let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    return Group {
      if #available(macOS 26.0, *) {
        shape.fill(.clear).glassEffect(.regular, in: shape)
      } else {
        shape.fill(.regularMaterial)
          .overlay { shape.strokeBorder(.secondary.opacity(0.2), lineWidth: 1) }
      }
    }
    .allowsHitTesting(false)
  }

  private func messageRow(_ message: ACPConversationMessage) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack {
        Label(message.role == "user" ? "You" : message.role == "assistant" ? "pmai" : message.role.capitalized,
          systemImage: message.role == "user" ? "person.crop.circle" : message.role == "tool" ? "wrench.and.screwdriver" : "sparkle")
          .font(typography.font(.callout).weight(.semibold)).foregroundStyle(.secondary)
        Spacer()
        if let status = message.status { Text(status.capitalized).font(typography.font(.caption1)).foregroundStyle(.secondary) }
      }
      if message.role == "tool" || message.role == "thought" {
        DisclosureGroup(message.toolName ?? (message.role == "thought" ? "Reasoning" : "Tool details")) {
          if let input = message.toolInput,
            let data = try? JSONEncoder().encode(input), let text = String(data: data, encoding: .utf8) {
            Text(text).font(typography.font(.caption1, design: .monospaced)).textSelection(.enabled)
          }
          MacMarkdown(text: message.text)
        }
      } else {
        MacMarkdown(text: message.text)
      }
    }
    .font(typography.font())
    .padding(message.role == "user" ? 16 : 0)
    .background {
      if message.role == "user" { RoundedRectangle(cornerRadius: 14).fill(appearance.accentColor.opacity(0.12)) }
    }
    .contextMenu {
      Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
      if message.role == "user", conversation.canRewind, message.remoteID != nil {
        Button("Edit from Here…") { conversation.rewind(message) }.disabled(conversation.busy)
      }
    }
  }
}
