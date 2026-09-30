import Foundation
import MaiCore
import SwiftTUIRuntime

/// The whole workspace: a title row, the tabbed screens, the key hints, and the
/// approval sheet. Key chords are declared here so they work from every tab.
struct VisualRootView: View {
  @Bindable var workspace: VisualWorkspace
  @Environment(\.clipboardWriteAction) private var clipboardWrite
  @Environment(\.requestTermination) private var requestTermination

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
      TabView(selection: $workspace.selectedTab) {
        Tab("Chats", badge: "\(workspace.conversations.count)", value: VisualTab.chats) {
          ChatsScreen(workspace: workspace)
        }
        Tab("Providers", badge: "\(workspace.providers.count)", value: VisualTab.providers) {
          ProvidersScreen(workspace: workspace)
        }
        Tab("MCP", badge: "\(workspace.catalogs.count)", value: VisualTab.mcp) {
          MCPScreen(workspace: workspace)
        }
        Tab("Tools", badge: "\(workspace.tools.count)", value: VisualTab.tools) {
          ToolsScreen(workspace: workspace)
        }
        Tab("Agents", badge: "\(workspace.agents.count)", value: VisualTab.agents) {
          AgentsScreen(workspace: workspace)
        }
        Tab("Stats", badge: "\(workspace.usageLedger.totals.count)", value: VisualTab.stats) {
          StatsScreen(workspace: workspace)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      Divider()
      footer
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .panel(id: "pmai-visual")
    // Ctrl chords and function keys reach every terminal; the Alt chords only
    // work where the terminal sends Alt as an Escape prefix. Every action is
    // also in the command menu and the toolbar, so nothing depends on them.
    // The chain is kept short on purpose: each modifier nests the root view's
    // generic type one level deeper, and deep chains overflow the stack.
    .keyCommand("Command menu", key: .character("k"), modifiers: .ctrl) {
      workspace.showsCommandMenu = true
    }
    .keyCommand("Command menu", key: .functionKey(2), modifiers: []) {
      workspace.showsCommandMenu = true
    }
    .keyCommand("New conversation", key: .character("n"), modifiers: .alt) {
      workspace.newConversationInFocusedPane()
    }
    .keyCommand("Split right", key: .character("v"), modifiers: .alt) {
      workspace.splitFocusedPane(.horizontal)
    }
    .keyCommand("Split down", key: .character("s"), modifiers: .alt) {
      workspace.splitFocusedPane(.vertical)
    }
    .keyCommand(
      "Close pane", key: .character("x"), modifiers: .alt,
      isEnabled: workspace.layout.canCloseFocusedPane
    ) {
      workspace.closeFocusedPane()
    }
    .keyCommand("Next pane", key: .arrowRight, modifiers: .alt) { workspace.focusNextPane() }
    .keyCommand("Previous pane", key: .arrowLeft, modifiers: .alt) {
      workspace.focusPreviousPane()
    }
    .keyCommand("Toggle sidebar", key: .character("b"), modifiers: .alt) {
      workspace.showsSidebar.toggle()
    }
    .keyCommand("Cancel reply", key: .character("k"), modifiers: .alt) {
      workspace.cancelFocusedRun()
    }
    .keyCommand("Copy last reply", key: .character("c"), modifiers: .alt) { copyLastReply() }
    .sheet("Commands", isPresented: $workspace.showsCommandMenu) {
      CommandMenuSheet(commands: menuCommands, dismiss: { workspace.showsCommandMenu = false })
    }
    .sheet(
      item: $workspace.pendingApproval,
      onDismiss: { workspace.approvalSheetDismissed() }
    ) { pending in
      ApprovalSheet(pending: pending, workspace: workspace)
    }
    .sheet(
      item: $workspace.pendingCompaction,
      onDismiss: { workspace.compactionSheetDismissed() }
    ) { pending in
      CompactionSheet(pending: pending, workspace: workspace)
    }
    .sheet(
      "Rename chat",
      item: $workspace.pendingConversationRename,
      onDismiss: { workspace.cancelConversationRename() }
    ) { request in
      RenameConversationSheet(request: request, workspace: workspace)
    }
    .confirmationDialog(
      "Delete chat?",
      item: $workspace.pendingConversationDeletion
    ) { request in
      Button("Delete", role: .destructive) {
        workspace.confirmConversationDeletion(request)
      }
      Button("Cancel", role: .cancel) {
        workspace.cancelConversationDeletion()
      }
    } message: { request in
      Text("Delete '\(request.title)' permanently?")
    }
    .onChange(of: workspace.exitRequested) {
      if workspace.exitRequested { _ = requestTermination() }
    }
    .task { await workspace.refreshRegistries() }
  }

  /// Everything the workspace can do, in one list the menu renders as buttons.
  private var menuCommands: [VisualMenuCommand] {
    let alt = visualAlternateKeyName
    let hasPanes = workspace.layout.panes.count > 1
    return [
      VisualMenuCommand(id: "new", name: "New conversation", shortcut: "\(alt)+N or /pane new") {
        workspace.newConversationInFocusedPane()
      },
      VisualMenuCommand(
        id: "split-right", name: "Split pane right", shortcut: "\(alt)+V or /pane split"
      ) {
        workspace.splitFocusedPane(.horizontal)
      },
      VisualMenuCommand(
        id: "split-down", name: "Split pane down", shortcut: "\(alt)+S or /pane down"
      ) {
        workspace.splitFocusedPane(.vertical)
      },
      VisualMenuCommand(
        id: "close", name: "Close pane", shortcut: "\(alt)+X or /pane close",
        isEnabled: workspace.layout.canCloseFocusedPane
      ) {
        workspace.closeFocusedPane()
      },
      VisualMenuCommand(
        id: "next", name: "Focus next pane", shortcut: "\(alt)+→ or /pane next", isEnabled: hasPanes
      ) {
        workspace.focusNextPane()
      },
      VisualMenuCommand(
        id: "prev", name: "Focus previous pane", shortcut: "\(alt)+← or /pane prev",
        isEnabled: hasPanes
      ) {
        workspace.focusPreviousPane()
      },
      VisualMenuCommand(id: "rename", name: "Rename chat") {
        workspace.requestRenameFocusedConversation()
      },
      VisualMenuCommand(id: "clear", name: "Clear chat", shortcut: "/clear") {
        workspace.clearFocusedConversation()
      },
      VisualMenuCommand(
        id: "delete", name: "Delete chat", isEnabled: workspace.conversations.count > 1
      ) {
        workspace.deleteFocusedConversation()
      },
      VisualMenuCommand(
        id: "sidebar", name: workspace.showsSidebar ? "Hide sidebar" : "Show sidebar",
        shortcut: "\(alt)+B or /sidebar"
      ) {
        workspace.showsSidebar.toggle()
      },
      VisualMenuCommand(
        id: "cancel", name: "Cancel reply", shortcut: "\(alt)+K or /cancel",
        isEnabled: workspace.focusedConversation?.isRunning ?? false
      ) {
        workspace.cancelFocusedRun()
      },
      VisualMenuCommand(id: "copy", name: "Copy last reply", shortcut: "\(alt)+C or /copy") {
        copyLastReply()
      },
      VisualMenuCommand(id: "tab-chats", name: "Show chats", shortcut: "/tab chats") {
        workspace.selectedTab = .chats
      },
      VisualMenuCommand(id: "tab-providers", name: "Show providers", shortcut: "/tab providers") {
        workspace.selectedTab = .providers
      },
      VisualMenuCommand(id: "tab-mcp", name: "Show MCP servers", shortcut: "/tab mcp") {
        workspace.selectedTab = .mcp
      },
      VisualMenuCommand(id: "tab-tools", name: "Show tools", shortcut: "/tab tools") {
        workspace.selectedTab = .tools
      },
      VisualMenuCommand(id: "tab-agents", name: "Show agents", shortcut: "/tab agents") {
        workspace.selectedTab = .agents
      },
      VisualMenuCommand(id: "tab-stats", name: "Show model statistics", shortcut: "/tab stats") {
        workspace.selectedTab = .stats
      },
      VisualMenuCommand(id: "exit", name: "Back to the REPL", shortcut: "Ctrl+C or /exit") {
        workspace.requestExit()
      },
    ]
  }

  private var header: some View {
    HStack(spacing: 2) {
      Text("pmai visual").bold().foregroundStyle(.tint)
      if let focused = workspace.focusedConversation {
        Text(focused.title).lineLimit(1).truncationMode(.tail)
        Text(focused.subtitle).foregroundStyle(.muted).lineLimit(1)
      }
      Spacer(minLength: 1)
      if let status = workspace.status {
        Text(status)
          .foregroundStyle(status.hasPrefix("error") ? .danger : .warning)
          .lineLimit(1)
          .truncationMode(.tail)
      }
    }
    .padding(.horizontal, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footer: some View {
    HStack(spacing: 2) {
      Text(footerHint).foregroundStyle(.muted).lineLimit(1).truncationMode(.tail)
      Spacer(minLength: 1)
      Text("Ctrl+K menu · Ctrl+C back to REPL").foregroundStyle(.separator)
    }
    .padding(.horizontal, 1)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var footerHint: String {
    switch workspace.selectedTab {
    case .chats:
      "Tab moves between controls · Return activates · type /help for commands, /pane and /tab for layout"
    case .providers:
      "Register OpenAI-compatible or plugin providers; 'Use' switches the focused chat"
    case .mcp:
      "Connect Streamable HTTP MCP servers; their tools appear in the Tools tab"
    case .tools:
      "Toggle which tools the focused chat may call; register plugin tool sources"
    case .agents:
      "Tune the focused chat, switch agents, or save the chat as a named agent"
    case .stats:
      "Tokens/s and time in use per provider:model; bars are colored by provider"
    }
  }

  private func copyLastReply() {
    workspace.copyLastReply { clipboardWrite($0) }
  }
}

struct RenameConversationSheet: View {
  let request: ConversationActionRequest
  @Bindable var workspace: VisualWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Rename '\(request.title)'").bold()
      TextField("Chat name", text: $workspace.conversationRenameDraft)
        .onSubmit { workspace.confirmConversationRename(request) }
      HStack(spacing: 2) {
        Button("Rename") { workspace.confirmConversationRename(request) }
        Button("Cancel", role: .cancel) { workspace.cancelConversationRename() }
      }
    }
    .padding(1)
    .frame(minWidth: 40, maxWidth: 70, alignment: .leading)
  }
}

struct CompactionSheet: View {
  let pending: VisualApprovalHandler.PendingCompaction
  let workspace: VisualWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Reduce this chat's context?").bold()
      Text("Agent '\(pending.request.run.agentID)' has about \(pending.request.estimatedTokens) tokens (threshold \(pending.request.threshold)).")
      Text("Summarization replaces older exchanges with a summary. Pruning shortens older tool output without a model call. Keeping context skips both for this response.")
      if let pruning = pending.request.pruning {
        Text("Pruning preview: \(pruning.summary). Keeps the start and end of each output; the middle is dropped.")
        Button("Prune old tool output") { workspace.resolveCompaction(.pruneToolOutput) }
      }
      HStack(spacing: 2) {
        Button("Summarize") { workspace.resolveCompaction(.compact) }
        Button("Keep context") { workspace.resolveCompaction(.continueWithoutCompacting) }
      }
      HStack(spacing: 2) {
        Button("Stop to change model") { workspace.stopCompactionToChangeModel() }
        Button("Clear chat", role: .destructive) {
          workspace.resolveCompaction(.cancelRun, clearChat: true)
        }
        .disabled(!workspace.canClearCompactionChat)
        Button("Stop", role: .cancel) { workspace.resolveCompaction(.cancelRun) }
      }
    }
    .padding(1)
    .frame(minWidth: 50, maxWidth: 90, alignment: .leading)
  }
}

struct ApprovalSheet: View {
  let pending: VisualApprovalHandler.Pending
  let workspace: VisualWorkspace

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("Tool approval").bold()
      Text(
        "Agent '\(pending.request.run.agentID)' wants to run \(pending.request.tool.annotations.approval.rawValue) tool '\(pending.request.tool.name)'."
      )
      Text(pending.request.call.arguments.compactJSONString)
        .foregroundStyle(.muted)
        .lineLimit(8)
      HStack(spacing: 2) {
        Button("Approve") {
          workspace.resolveApproval(.approve(arguments: pending.request.call.arguments))
        }
        Button("Always (yolo)") {
          workspace.resolveApprovalAlways()
        }
        Button("Deny", role: .destructive) {
          workspace.resolveApproval(.deny(reason: "Denied by user."))
        }
        Button("Cancel run", role: .cancel) {
          workspace.resolveApproval(.cancelRun)
        }
      }
    }
    .padding(1)
    .frame(minWidth: 50, maxWidth: 90, alignment: .leading)
  }
}

/// One entry of the command menu.
struct VisualMenuCommand: Identifiable, Sendable {
  let id: String
  let name: String
  var shortcut: String?
  var isEnabled = true
  let action: @MainActor @Sendable () -> Void

  init(
    id: String,
    name: String,
    shortcut: String? = nil,
    isEnabled: Bool = true,
    action: @escaping @MainActor @Sendable () -> Void
  ) {
    self.id = id
    self.name = name
    self.shortcut = shortcut
    self.isEnabled = isEnabled
    self.action = action
  }
}

/// A filterable list of every workspace action, opened with Ctrl+K, F2,
/// the toolbar's Menu button, or `/menu`. Tab and the arrows move between the
/// entries, Return runs one, Escape closes the sheet.
struct CommandMenuSheet: View {
  let commands: [VisualMenuCommand]
  let dismiss: @MainActor @Sendable () -> Void
  @State private var query = ""
  @FocusState private var isQueryFocused: Bool

  private var matches: [VisualMenuCommand] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return commands }
    return commands.filter { command in
      command.name.lowercased().contains(needle)
        || (command.shortcut?.lowercased().contains(needle) ?? false)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 2) {
        Text("Commands").bold()
        Spacer(minLength: 1)
        Text("Return runs · Esc closes").foregroundStyle(.separator)
      }
      Divider()
      TextField("Filter commands", text: $query)
        .focused($isQueryFocused)
      Divider()
      if matches.isEmpty {
        Text("No matching command").foregroundStyle(.muted)
      }
      ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(matches) { command in
            Button {
              command.action()
              dismiss()
            } label: {
              HStack(spacing: 2) {
                Text(command.name)
                Spacer(minLength: 1)
                if let shortcut = command.shortcut {
                  Text(shortcut).foregroundStyle(.separator)
                }
              }
            }
            .disabled(!command.isEnabled)
          }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
      }
      .frame(maxHeight: 14)
      Divider()
      HStack {
        Spacer(minLength: 1)
        Button("Close", role: .cancel) { dismiss() }
      }
    }
    .padding(1)
    .frame(minWidth: 56, maxWidth: 84, alignment: .leading)
    .onAppear {
      query = ""
      isQueryFocused = true
    }
  }
}
