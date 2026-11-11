import AppKit
import MaiACP
import MaiCore
import SwiftUI
import UniformTypeIdentifiers

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
          MacChatView(conversation: conversation).id(conversation.id)
        } else {
          MacWelcomeView(workspace: workspace)
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
  private struct ScrollLayout: Equatable {
    let contentSize: CGSize
    let containerSize: CGSize
  }

  @Bindable var conversation: MacConversation
  @State private var showApps = false
  @State private var followsBottom = true
  @State private var firstVisibleRunID: UUID?
  @State private var scrollPhase = ScrollPhase.idle
  @State private var searchScrollTarget: UUID?
  @FocusState private var findFocused: Bool
  @State private var pinchBaseFontSize: Double?
  @GestureState private var isPinching = false
  private var typography = MacChatTypography()

  private var firstVisibleIndex: Int {
    let runs = conversation.messageRuns
    return firstVisibleRunID.flatMap { id in runs.firstIndex { $0.id == id } } ?? max(0, runs.count - 8)
  }

  var body: some View {
    VStack(spacing: 0) {
      if conversation.find.isPresented { findBar }
      ScrollViewReader { proxy in
        ScrollView {
          // A bounded eager stack avoids stale height estimates for streaming bubbles.
          VStack(alignment: .leading, spacing: 18) {
            if firstVisibleIndex > 0 {
              Button("Load earlier messages") {
                let anchor = conversation.messageRuns[firstVisibleIndex].id
                followsBottom = false
                firstVisibleRunID = conversation.messageRuns[max(0, firstVisibleIndex - 8)].id
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
              }.buttonStyle(.borderless)
            }
            if conversation.messages.isEmpty {
              VStack(alignment: .leading, spacing: 12) {
                Image(systemName: "sparkle").font(.largeTitle).foregroundStyle(.tint)
                Text("What would you like to work on?").font(.title2.weight(.semibold))
                Text(conversation.cwd).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
              }.padding(.vertical, 50)
            }
            ForEach(conversation.messageRuns.suffix(from: firstVisibleIndex)) { run in
              Group {
                if run.isActivity {
                  MacActivityRow(run: run, conversation: conversation,
                    searchQuery: conversation.find.activeQuery,
                    selectedSearchID: conversation.find.isPresented ? conversation.find.selectedID : nil).equatable()
                } else if let message = run.messages.first {
                  MacMessageRow(message: message, conversation: conversation,
                    searchQuery: conversation.find.activeQuery,
                    isSearchSelected: conversation.find.isPresented && message.id == conversation.find.selectedID,
                    isStreaming: conversation.connected && conversation.busy
                      && conversation.messages.last?.id == message.id).equatable()
                }
              }.id(run.id)
            }
            Color.clear.frame(height: 1).id("bottom")
          }
          .frame(maxWidth: 860, alignment: .leading)
          .padding(28)
          .frame(maxWidth: .infinity)
        }
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
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .onChange(of: conversation.messageRuns.first?.id, initial: true) { _, _ in
          if firstVisibleRunID == nil || !conversation.messageRuns.contains(where: { $0.id == firstVisibleRunID }) {
            firstVisibleRunID = conversation.messageRuns.suffix(8).first?.id
          }
        }
        .onScrollGeometryChange(for: ScrollLayout.self) { geometry in
          ScrollLayout(contentSize: geometry.contentSize, containerSize: geometry.containerSize)
        } action: { _, _ in
          // Follow layout, including asynchronously parsed Markdown and tool updates.
          // Content growth must never be mistaken for the user scrolling away.
          DispatchQueue.main.async {
            guard scrollPhase == .idle else { return }
            if let target = searchScrollTarget, conversation.find.isPresented {
              proxy.scrollTo("message-\(target)", anchor: .top)
            } else if followsBottom { proxy.scrollTo("bottom", anchor: .bottom) }
          }
        }
        .onScrollPhaseChange { old, phase, context in
          scrollPhase = phase
          if phase == .interacting {
            followsBottom = false
            searchScrollTarget = nil
          } else if phase == .idle, old == .interacting || old == .decelerating {
            followsBottom = context.geometry.visibleRect.maxY >= context.geometry.contentSize.height - 80
          }
        }
        .onChange(of: followsBottom) { _, follows in
          if follows { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .onChange(of: conversation.find.navigationRequest) { _, _ in
          searchScrollTarget = conversation.find.selectedID
          guard let id = searchScrollTarget,
            let index = conversation.messageRuns.firstIndex(where: { $0.messages.contains { $0.id == id } }) else { return }
          followsBottom = false
          if index < firstVisibleIndex { firstVisibleRunID = conversation.messageRuns[index].id }
          DispatchQueue.main.async { proxy.scrollTo("message-\(id)", anchor: .top) }
        }
        .overlay(alignment: .bottomTrailing) {
          if !followsBottom {
            Button { searchScrollTarget = nil; followsBottom = true; proxy.scrollTo("bottom", anchor: .bottom) } label: {
              Label("Latest", systemImage: "arrow.down")
            }.buttonStyle(.bordered).padding()
          }
        }
      }
    }
    .sheet(isPresented: $showApps) { MacWebXDCLauncher(conversation: conversation) }
    .onChange(of: conversation.find.focusRequest) { _, _ in
      DispatchQueue.main.async { findFocused = true }
    }
    .onChange(of: conversation.find.isPresented) { _, presented in
      if !presented { searchScrollTarget = nil; findFocused = false }
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
        if let session = conversation.webXDC, conversation.showWebXDC {
          MacWebXDCRunner(session: session, conversation: conversation)
        }
        composer
      }
    }
    .onDisappear { conversation.voice.stop(); conversation.webXDC?.suspendAudio() }
    .background(Color(nsColor: .textBackgroundColor))
    .sheet(isPresented: Binding(get: { conversation.permission != nil }, set: {
      if !$0 { conversation.answerPermission(nil) }
    })) { MacPermissionSheet(conversation: conversation) }
  }

  private var findBar: some View {
    @Bindable var find = conversation.find
    return HStack(spacing: 8) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
      TextField("Find in conversation", text: $find.query)
        .textFieldStyle(.roundedBorder).focused($findFocused)
        .onSubmit { conversation.find.advance() }
        .onExitCommand { conversation.find.close() }
      if conversation.find.searching {
        ProgressView().controlSize(.small)
      } else if !conversation.find.activeQuery.isEmpty {
        Text(conversation.find.matches.isEmpty ? "No matches"
          : "\(conversation.find.position) of \(conversation.find.matches.count) messages")
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Button { conversation.find.advance(backwards: true) } label: { Image(systemName: "chevron.up") }
        .help("Previous matching message (⇧⌘G)").disabled(conversation.find.matches.isEmpty)
      Button { conversation.find.advance() } label: { Image(systemName: "chevron.down") }
        .help("Next matching message (⌘G)").disabled(conversation.find.matches.isEmpty)
      Button { conversation.find.close() } label: { Image(systemName: "xmark") }
        .help("Close search (Escape)")
    }
    .buttonStyle(.borderless).padding(10).background(.bar)
  }

  private var composer: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let app = conversation.webXDC, !conversation.showWebXDC {
        Button { conversation.showWebXDC = true } label: { Label("Open " + app.app.name, systemImage: "app") }
          .buttonStyle(.borderless)
      }
      if conversation.voice.isActive { MacVoiceStatus(conversation: conversation) }
      if conversation.importingAttachments {
        ProgressView("Preparing attachments…").controlSize(.small)
      }
      if !conversation.attachments.isEmpty {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(conversation.attachments) { attachment in
              HStack(spacing: 6) {
                Label(attachment.name, systemImage: attachment.symbol).lineLimit(1)
                Button {
                  conversation.attachments.removeAll { $0.id == attachment.id }
                } label: { Image(systemName: "xmark") }
                  .buttonStyle(.plain).help("Remove \(attachment.name)")
                  .accessibilityLabel("Remove \(attachment.name)")
              }
              .font(typography.font(.caption1)).padding(8)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
      }
      HStack(alignment: .center, spacing: 12) {
        Menu {
          Button("Webxdc Apps…", systemImage: "app") { showApps = true }
          Divider()
          Button("Images…", systemImage: "photo") { chooseAttachments(images: true) }
          Button("Documents and Files…", systemImage: "doc") { chooseAttachments() }
          Button("Folder…", systemImage: "folder") { chooseAttachments(folders: true) }
            .disabled(conversation.hostID != nil)
        } label: {
          Image(systemName: "plus").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(conversation.importingAttachments)
        .help("Start a webxdc app or attach files").accessibilityLabel("Add attachments or apps")
        MacComposer(text: $conversation.draft, prompts: conversation.prompts) { conversation.send(); followsBottom = true }
          .id(conversation.id)
          .zIndex(1)
          .overlay(alignment: .topLeading) {
            if conversation.draft.isEmpty {
              Text("Message pmai…").font(typography.messageFont(for: "user")).foregroundStyle(.tertiary)
                .padding(.top, 6).allowsHitTesting(false)
            }
          }
        MacVoiceButton(conversation: conversation)
        Group {
          if conversation.busy {
            Button(action: conversation.stop) { Label("Stop", systemImage: "stop.fill") }
              .help("Stop response (⌘.)")
          } else {
            Button { conversation.send(); followsBottom = true } label: { Label("Send", systemImage: "arrow.up") }
              .keyboardShortcut(.return, modifiers: .command)
              .disabled(!conversation.canSend)
              .help("Return sends. Shift-Return adds a new line.")
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
      }
    }
    .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
    .background { composerBackground }
    .frame(maxWidth: 860)
    .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 14)
    .frame(maxWidth: .infinity)
  }

  private func chooseAttachments(images: Bool = false, folders: Bool = false) {
    let panel = NSOpenPanel()
    panel.title = folders ? "Attach Folders" : images ? "Attach Images" : "Attach Documents and Files"
    panel.prompt = "Attach"
    panel.canChooseFiles = !folders
    panel.canChooseDirectories = folders
    panel.allowsMultipleSelection = true
    if images { panel.allowedContentTypes = [.image] }
    panel.begin { response in
      if response == .OK { conversation.importAttachments(panel.urls) }
    }
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
}
