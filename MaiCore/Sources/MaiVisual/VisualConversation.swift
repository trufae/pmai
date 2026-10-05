import Foundation
import MaiCore
import Observation

public struct VisualCommandOutput: Equatable, Sendable {
  public var command: String
  public var text: String

  public init(command: String, text: String) {
    self.command = command
    self.text = text
  }
}

/// One chat shown in the workspace: its agent profile, transcript, draft input,
/// and the live state of an in-flight run.
@MainActor @Observable
public final class VisualConversation: Identifiable {
  nonisolated public let id: UUID
  /// The session the chat presents to providers; see `ChatSession`.
  nonisolated public let sessionID: String
  public var title: String
  public var profile: AgentDefinition
  public var transcript: AgentTranscript
  public var pendingContent: [ContentPart]
  public var draft = ""
  public var liveReply = ""
  public var activity: [String] = []
  public var isRunning = false
  public var errorMessage: String?
  /// The last slash command run in this pane and what it printed.
  public var commandOutput: VisualCommandOutput?
  /// Increments whenever the visible transcript changes so views can follow it.
  public private(set) var revision = 0
  @ObservationIgnored var runTask: Task<Void, Never>?
  /// The supervisor process this conversation is, reused across turns so the
  /// background agents it started stay addressable.
  @ObservationIgnored var processID: AgentPID?
  @ObservationIgnored var commandTask: Task<Void, Never>?
  @ObservationIgnored private(set) var hasCustomTitle: Bool

  public init(seed: VisualConversationSeed, hasCustomTitle: Bool = true) {
    id = seed.id
    sessionID = seed.sessionID
    title = seed.title
    profile = seed.profile
    transcript = AgentTranscript(messages: seed.messages)
    pendingContent = seed.pendingContent
    self.hasCustomTitle = hasCustomTitle
  }

  public var seed: VisualConversationSeed {
    VisualConversationSeed(
      id: id,
      title: title,
      profile: profile,
      messages: transcript.messages,
      pendingContent: pendingContent,
      sessionID: sessionID)
  }

  public var visibleMessages: [AgentMessage] {
    transcript.messages.filter { $0.role != .system && $0.role != .developer }
  }

  public var subtitle: String {
    profile.model.isEmpty
      ? profile.provider.rawValue : "\(profile.provider.rawValue)/\(profile.model)"
  }

  public var lastAssistantText: String? {
    try? TranscriptCopy.text(for: .lastAssistantReply, in: transcript.messages).text
  }

  /// Replaces the conversation with a fresh one for `profile`, keeping the identity.
  public func adopt(profile: AgentDefinition, title: String? = nil) {
    cancelRun()
    self.profile = profile
    if let title {
      self.title = title
      hasCustomTitle = true
    }
    resetTranscript()
  }

  public func rename(to title: String) {
    self.title = title
    hasCustomTitle = true
  }

  public func replace(with seed: VisualConversationSeed) {
    cancelRun()
    title = seed.title
    profile = seed.profile
    transcript = AgentTranscript(messages: seed.messages)
    pendingContent = seed.pendingContent
    errorMessage = nil
    revision &+= 1
  }

  /// Adopts the conversation state a slash command left behind, keeping the identity and title.
  public func applyCommandResult(_ seed: VisualConversationSeed) {
    profile = seed.profile
    transcript = AgentTranscript(messages: seed.messages)
    pendingContent = seed.pendingContent
    revision &+= 1
  }

  public func resetTranscript() {
    transcript.replaceAll(with: Self.initialHistory(for: profile))
    pendingContent.removeAll()
    liveReply = ""
    activity = []
    errorMessage = nil
    revision &+= 1
  }

  /// Keeps the leading system message in sync with edited instructions.
  public func applyInstructions() {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    var messages = transcript.messages
    if let index = messages.firstIndex(where: { $0.role == .system }) {
      if instructions.isEmpty {
        messages.remove(at: index)
      } else {
        messages[index] = AgentMessage(id: messages[index].id, role: .system, content: instructions)
      }
    } else if !instructions.isEmpty {
      messages.insert(.system(instructions), at: 0)
    }
    transcript.replaceAll(with: messages)
    revision &+= 1
  }

  static func initialHistory(for profile: AgentDefinition) -> [AgentMessage] {
    let instructions = profile.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
    return instructions.isEmpty ? [] : [.system(instructions)]
  }

  func request() -> AgentRequest {
    AgentRequest(
      agentID: profile.id,
      provider: profile.provider,
      model: profile.model,
      messages: transcript.messages,
      toolNames: profile.toolNames,
      toolGroupNames: profile.toolGroupNames,
      subagentNames: profile.subagentNames,
      toolChoice: profile.toolChoice,
      responseFormat: profile.responseFormat,
      options: profile.options,
      limits: profile.limits,
      stream: profile.stream,
      toolCallingStrategy: profile.toolCallingStrategy,
      useToolProxy: profile.useToolProxy,
      useSystemOne: profile.useSystemOne,
      proxyExposedTools: profile.proxyExposedTools,
      toolPolicy: profile.toolPolicy,
      retry: profile.retry,
      autocompact: profile.autocompact,
      context: profile.context,
      sessionID: sessionID)
  }

  func appendUserMessage(_ text: String) {
    var content: [ContentPart] = [.text(text)]
    content.append(contentsOf: pendingContent)
    pendingContent.removeAll()
    transcript.append(AgentMessage(role: .user, content: content))
    if !hasCustomTitle {
      title = Self.autoTitle(from: text)
      hasCustomTitle = true
    }
    revision &+= 1
  }

  func beginRun() {
    isRunning = true
    errorMessage = nil
    liveReply = ""
    activity = []
    revision &+= 1
  }

  func consume(_ event: AgentEvent) {
    switch event {
    case .started(let context, _) where context.depth == 0:
      processID = context.pid
    case .modelStarted(let context, let turn) where context.depth == 0:
      if turn > 1, !liveReply.isEmpty {
        activity.append("assistant: \(liveReply.prefix(100))")
        liveReply = ""
      }
    case .provider(let context, .textDelta(let text)) where context.depth == 0:
      liveReply += text
    case .approvalRequested(let context, let request) where context.depth == 0:
      activity.append("? approval requested for \(request.tool.name)")
    case .toolStarted(let context, let call) where context.depth == 0:
      activity.append(ToolCallPreview.render(call))
    case .toolFinished(let context, let result) where context.depth == 0:
      activity.append(ToolResultPreview.render(result, maxLines: 0))
    case .childStarted(_, let child):
      activity.append("↳ child \(child.agentID)")
    case .childFinished(_, let child):
      activity.append("↲ child \(child.agentID): \(child.response.text.prefix(100))")
    default:
      return
    }
    revision &+= 1
  }

  func finishRun(with result: AgentResult) {
    transcript.replaceAll(with: result.transcript)
    liveReply = ""
    activity = []
    isRunning = false
    runTask = nil
    // A paused run kept everything it did; saying so is what lets the person
    // send "continue" instead of starting over.
    if let interruption = result.interruption {
      errorMessage =
        "Paused: \(interruption.summary). Send \"continue\" to go on, or raise \(interruption.settingKey)."
    }
    revision &+= 1
  }

  func failRun(_ message: String) {
    errorMessage = message
    liveReply = ""
    isRunning = false
    runTask = nil
    revision &+= 1
  }

  public func cancelRun() {
    runTask?.cancel()
    runTask = nil
    if isRunning {
      isRunning = false
      liveReply = ""
      activity = []
      errorMessage = "Cancelled."
      revision &+= 1
    }
  }

  static func autoTitle(from text: String) -> String {
    let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard collapsed.count > 28 else { return collapsed }
    return String(collapsed.prefix(27)).trimmingCharacters(in: .whitespaces) + "…"
  }
}
