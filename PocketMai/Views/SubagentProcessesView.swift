import MaiCore
import SwiftUI

/// One line above the composer while a chat has child agents: how many are
/// running, what the newest one is doing, and a way into the process list.
struct SubagentsBar: View {
  let processes: [AgentProcessInfo]
  let onOpen: () -> Void

  private var live: [AgentProcessInfo] { processes.filter { !$0.state.isTerminal } }

  var body: some View {
    Button(action: onOpen) {
      HStack(spacing: 10) {
        Image(systemName: "person.2")
          .foregroundStyle(.tint)
        VStack(alignment: .leading, spacing: 1) {
          Text(headline)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          if let detail, !detail.isEmpty {
            Text(detail)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer()
        if !live.isEmpty {
          ProgressView()
            .controlSize(.small)
        }
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .background(.thinMaterial)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(headline)
    .accessibilityHint("Shows the child agents of this chat")
  }

  private var headline: String {
    let waiting = live.filter(\.needsAttention).count
    if live.isEmpty {
      return "\(processes.count) agent\(processes.count == 1 ? "" : "s") finished"
    }
    var text = "\(live.count) agent\(live.count == 1 ? "" : "s") running"
    if waiting > 0 { text += ", \(waiting) waiting for you" }
    return text
  }

  private var detail: String? {
    guard let newest = live.max(by: { $0.updatedAt < $1.updatedAt }) else {
      return processes.last.map { "\($0.displayName): \($0.state.shortLabel)" }
    }
    let activity = newest.attention?.summary ?? newest.failure ?? newest.activity
    let trimmed = activity.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty
      ? "\(newest.displayName): \(newest.state.shortLabel)"
      : "\(newest.displayName): \(trimmed)"
  }
}

/// The child agents of one chat, parents before their children, with the
/// controls pmai offers through `/jobs`: stop, pause, resume, a message
/// for the next turn, and the transcript.
struct SubagentProcessesSheet: View {
  let store: AppStore
  @ObservedObject var storeObservation: AppStoreViewObservation
  let conversationID: UUID?
  @Environment(\.dismiss) private var dismiss
  @State private var agentPendingDeletion: AgentProcessInfo?

  private var processes: [AgentProcessInfo] {
    store.agentChildren(of: conversationID)
  }

  var body: some View {
    NavigationStack {
      Group {
        if processes.isEmpty {
          ContentUnavailableView(
            "No Agents",
            systemImage: "person.2",
            description: Text(
              "Child agents this chat starts with agent_start are listed here while they run and after they finish."
            ))
        } else {
          List {
            ForEach(processes) { process in
              NavigationLink {
                SubagentProcessDetailView(
                  store: store, storeObservation: storeObservation,
                  conversationID: conversationID, pid: process.pid)
              } label: {
                SubagentProcessRow(process: process)
              }
              .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if !process.state.isTerminal {
                  Button(role: .destructive) {
                    store.stopAgentProcess(process.pid)
                  } label: {
                    Label("Stop", systemImage: "stop.fill")
                  }
                  if process.state == .paused {
                    Button {
                      store.resumeAgentProcess(process.pid)
                    } label: {
                      Label("Resume", systemImage: "play.fill")
                    }
                    .tint(.green)
                  } else {
                    Button {
                      store.pauseAgentProcess(process.pid)
                    } label: {
                      Label("Pause", systemImage: "pause.fill")
                    }
                    .tint(.orange)
                  }
                }
              }
              .contextMenu {
                if !process.state.isTerminal {
                  if process.state == .paused {
                    Button {
                      store.resumeAgentProcess(process.pid)
                    } label: {
                      Label("Resume", systemImage: "play.fill")
                    }
                  } else {
                    Button {
                      store.pauseAgentProcess(process.pid)
                    } label: {
                      Label("Pause", systemImage: "pause.fill")
                    }
                  }
                  Button(role: .destructive) {
                    store.stopAgentProcess(process.pid)
                  } label: {
                    Label("Interrupt", systemImage: "stop.fill")
                  }
                  Divider()
                }
                Button(role: .destructive) {
                  agentPendingDeletion = process
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
        }
      }
      .navigationTitle("Agents")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Button {
              store.clearFinishedAgentProcesses(in: conversationID)
            } label: {
              Label("Clear Finished", systemImage: "trash")
            }
            .disabled(!processes.contains(where: \.state.isTerminal))
            Button(role: .destructive) {
              for process in processes where !process.state.isTerminal && process.depth == 1 {
                store.stopAgentProcess(process.pid)
              }
            } label: {
              Label("Stop All", systemImage: "stop.circle")
            }
            .disabled(!processes.contains(where: { !$0.state.isTerminal }))
          } label: {
            Image(systemName: "ellipsis.circle")
          }
          .accessibilityLabel("Agent actions")
        }
      }
      .alert(item: $agentPendingDeletion) { process in
        Alert(
          title: Text("Delete \(process.displayName)?"),
          message: Text("Its transcript and any child agents will be deleted."),
          primaryButton: .destructive(Text("Delete")) {
            store.deleteAgentProcess(process.pid, from: conversationID)
          },
          secondaryButton: .cancel())
      }
    }
  }
}

/// `#3 researcher  run · 2 turns · 1 tool · 12s — web_search`, indented by
/// depth so a child's children read as such.
struct SubagentProcessRow: View {
  let process: AgentProcessInfo

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      SubagentStateBadge(state: process.state, waiting: process.needsAttention)
        .padding(.top, 2)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 6) {
          Text(process.displayName)
            .font(.body.weight(.medium))
            .lineLimit(1)
          Text(process.pid.description)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if !process.task.isEmpty {
          Text(process.task)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        TimelineView(.periodic(from: .now, by: 1)) { context in
          Text(facts(at: context.date))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }
    }
    .padding(.leading, CGFloat(max(0, process.depth - 1)) * 16)
  }

  private func facts(at now: Date) -> String {
    var facts: [String] = [process.state.shortLabel]
    if process.modelTurns > 0 {
      facts.append("\(process.modelTurns) turn\(process.modelTurns == 1 ? "" : "s")")
    }
    if process.toolCalls > 0 {
      facts.append("\(process.toolCalls) tool\(process.toolCalls == 1 ? "" : "s")")
    }
    if process.state != .starting || process.finishedAt != nil {
      facts.append(ModelUsageFormat.duration(process.elapsedSeconds(at: now)))
    }
    if process.queuedMessages > 0 { facts.append("\(process.queuedMessages) queued") }
    var line = facts.joined(separator: " · ")
    let detail = (process.attention?.summary ?? process.failure ?? process.activity)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if !detail.isEmpty { line += " — \(AgentProcessInfo.oneLine(detail, limit: 80))" }
    return line
  }
}

struct SubagentStateBadge: View {
  let state: AgentProcessState
  let waiting: Bool

  var body: some View {
    Image(systemName: symbol)
      .font(.body)
      .foregroundStyle(color)
      .frame(width: 20)
      .accessibilityLabel(state.shortLabel)
  }

  private var symbol: String {
    if waiting { return "exclamationmark.bubble" }
    switch state {
    case .starting, .queued: return "clock"
    case .running: return "circle.dotted.circle"
    case .waitingForApproval, .waitingForInput, .blocked: return "exclamationmark.bubble"
    case .paused: return "pause.circle"
    case .completed: return "checkmark.circle.fill"
    case .failed: return "xmark.octagon.fill"
    case .cancelled: return "stop.circle.fill"
    case .interrupted: return "exclamationmark.circle.fill"
    }
  }

  private var color: Color {
    if waiting { return .orange }
    switch state {
    case .starting, .queued: return .secondary
    case .running: return .accentColor
    case .waitingForApproval, .waitingForInput, .blocked, .paused: return .orange
    case .completed: return .green
    case .failed, .interrupted: return .red
    case .cancelled: return .secondary
    }
  }
}

/// One child agent: its state, its transcript so far, and the controls.
struct SubagentProcessDetailView: View {
  let store: AppStore
  @ObservedObject var storeObservation: AppStoreViewObservation
  let conversationID: UUID?
  let pid: AgentPID
  @State private var transcript: [AgentMessage] = []
  @State private var draft = ""

  private var process: AgentProcessInfo? {
    store.agentProcesses.first { $0.pid == pid }
  }

  private var conversation: Conversation? {
    conversationID.flatMap { store.conversation(withID: $0) }
  }

  private var renderedTranscript: [ChatMessage] {
    ChatMessage.conversationMessages(from: transcript)
  }

  var body: some View {
    List {
      if let process {
        Section {
          SubagentProcessRow(process: process)
            .padding(.leading, -CGFloat(max(0, process.depth - 1)) * 16)
          if let failure = process.failure, !failure.isEmpty {
            Label(failure, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        if !process.state.isTerminal {
          Section {
            HStack {
              TextField("Message for its next turn", text: $draft, axis: .vertical)
                .lineLimit(1...4)
              Button {
                store.sendMessageToAgentProcess(pid, text: draft)
                draft = ""
              } label: {
                Image(systemName: "arrow.up.circle.fill")
                  .font(.title2)
              }
              .buttonStyle(.borderless)
              .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              .accessibilityLabel("Send message to agent")
            }
            HStack {
              if process.state == .paused {
                Button {
                  store.resumeAgentProcess(pid)
                } label: {
                  Label("Resume", systemImage: "play.fill")
                }
              } else {
                Button {
                  store.pauseAgentProcess(pid)
                } label: {
                  Label("Pause", systemImage: "pause.fill")
                }
              }
              Spacer()
              Button(role: .destructive) {
                store.stopAgentProcess(pid)
              } label: {
                Label("Stop", systemImage: "stop.fill")
              }
            }
            .buttonStyle(.borderless)
          } header: {
            Text("Steer")
          } footer: {
            Text(
              "A message is read before the agent's next model turn. Pause holds it at the next turn boundary; Stop ends it and anything it started."
            )
          }
        }
        Section {
          if renderedTranscript.isEmpty {
            Text("Nothing yet.")
              .foregroundStyle(.secondary)
          } else {
            ForEach(renderedTranscript) { message in
              MessageBubble(
                message: message,
                toolSettings: store.effectiveToolSettings(for: conversation),
                openAIEndpoints: store.settings.airplaneModeEnabled
                  ? [] : store.settings.openAIEndpoints,
                skipTechnicalContentInTTS: store.settings.conversation
                  .skipTechnicalContentInTTS,
                appearance: store.settings.appearance,
                renderMarkdown: store.settings.renderMarkdownInChat,
                renderImages: store.settings.renderMarkdownImagesInChat,
                conversationCreatedAt: process.startedAt,
                showThinking: store.effectiveShowThinking(for: conversation),
                isWaitingForResponse: false)
                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
          }
        } header: {
          Text("Transcript")
        }
      } else {
        ContentUnavailableView(
          "Agent Gone",
          systemImage: "person.2.slash",
          description: Text("This agent is no longer listed."))
      }
    }
    .navigationTitle(process?.displayName ?? pid.description)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: transcriptRefreshKey) {
      transcript = await store.agentTranscript(pid)
    }
  }

  /// The transcript is re-read when the process reports progress, not on
  /// every table change elsewhere.
  private var transcriptRefreshKey: Date? {
    process?.updatedAt
  }
}
