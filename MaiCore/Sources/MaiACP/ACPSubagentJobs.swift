import Foundation
import MaiCore

/// Restricted child sessions from ACP's Subagent Sessions proposal.
actor ACPSubagentJobs {
  private struct Child {
    var context: AgentEventContext
    var parentID: String
    var title: String?
    var task = ""
    var canCancel = false
    var model: String?
    var effort: String?
    var messages: [ACPConversationMessage] = []
    var calls: [String: ToolCall] = [:]
    var startsMessage = true
  }

  private var scope: ProviderProcessScope
  private var children: [String: Child] = [:]

  init(scope: ProviderProcessScope) { self.scope = scope }

  func configure(_ scope: ProviderProcessScope) { self.scope = scope }
  func contains(_ id: String) -> Bool { children[id] != nil }

  func apply(
    _ update: JSONValue, sessionID: String, rootID: String,
    cancel: @escaping @Sendable (String) async throws -> Void
  ) async {
    guard let fields = update.objectValue, let kind = fields["sessionUpdate"]?.stringValue else { return }
    if kind == "subagent_update" {
      guard let id = fields["sessionId"]?.stringValue, !id.isEmpty, id != rootID,
        sessionID == rootID || children[sessionID] != nil,
        let parent = sessionID == rootID ? scope.context : children[sessionID]?.context,
        let parentPID = parent.pid
      else { return }
      if let child = children[id], child.parentID != sessionID { return }
      let previousPID = children[id]?.context.pid
      let missingProcess = if let previousPID { await scope.supervisor.info(previousPID) == nil } else { true }
      if missingProcess {
        let runID = UUID()
        let pid = await scope.supervisor.register(
          runID: runID, parent: parentPID, agentID: "\(scope.context.agentID).acp",
          displayName: fields["title"]?.stringValue ?? "ACP subagent",
          depth: parent.depth + 1, externalSessionID: id)
        let context = AgentEventContext(
          runID: runID, parentRunID: parent.runID, agentID: "\(scope.context.agentID).acp",
          depth: parent.depth + 1, pid: pid)
        if var child = children[id] {
          child.context = context
          children[id] = child
        } else { children[id] = Child(context: context, parentID: sessionID) }
        await scope.supervisor.note(pid, state: .blocked, activity: "state unknown")
      }
      guard var child = children[id] else { return }
      if let title = fields["title"] { child.title = title.stringValue }
      if let task = fields["description"] { child.task = task.stringValue ?? "" }
      if let capabilities = fields["capabilities"] {
        child.canCancel = capabilities.objectValue?["cancel"]?.objectValue != nil
      }
      children[id] = child
      await configure(id, cancel: cancel)
      if let state = fields["state"] { await applyState(state, to: id) }
      return
    }
    guard var child = children[sessionID], let pid = child.context.pid else { return }
    if kind == "config_option_update" {
      let options = RemoteSessionOption.parse(fields["configOptions"])
      child.model = options.first { $0.category == "model" || $0.id == "model" }?.currentValue.stringValue
      child.effort = options.first {
        $0.category == "thought_level" || ["effort", "reasoning_effort"].contains($0.id)
      }?.currentValue.stringValue
      children[sessionID] = child
      await configure(sessionID, cancel: cancel)
      return
    }
    if kind == "session_message" || kind == "session_message_chunk", let id = fields["messageId"]?.stringValue {
      let index = child.messages.firstIndex { $0.remoteID == id } ?? child.messages.count
      if index == child.messages.count { child.messages.append(.init(role: "message", text: "", remoteID: id)) }
      if kind == "session_message_chunk" { child.messages[index].text += ACP.ContentBlock.text(from: fields["content"]) }
      else if let content = fields["content"] { child.messages[index].text = ACP.ContentBlock.text(from: content) }
    } else {
      if child.startsMessage, kind == "agent_message_chunk" || kind == "agent_thought_chunk" {
        child.messages.append(.init(role: kind == "agent_message_chunk" ? "assistant" : "thought", text: ""))
        child.startsMessage = false
      }
      ACPConversationTranscript.apply(update, to: &child.messages)
    }
    var event: AgentEvent?
    let text = ACP.ContentBlock.text(from: fields["content"])
    switch kind {
    case "agent_message_chunk": event = .provider(child.context, .textDelta(text))
    case "agent_thought_chunk": event = .provider(child.context, .reasoningDelta(text))
    case "tool_call", "tool_call_update":
      if let id = fields["toolCallId"]?.stringValue {
        let previous = child.calls[id]
        let call = ToolCall(
          id: id, name: fields["name"]?.stringValue ?? previous?.name ?? fields["title"]?.stringValue ?? "ACP tool",
          arguments: fields["rawInput"] ?? previous?.arguments ?? .object([:]))
        child.calls[id] = call
        event = previous == nil ? .toolStarted(child.context, call) : .toolUpdated(child.context, call)
        if ["completed", "failed"].contains(fields["status"]?.stringValue ?? "") {
          event = .toolFinished(child.context, .init(callID: id, text: text, isError: fields["status"] == .string("failed")))
        }
      }
    default: break
    }
    children[sessionID] = child
    await scope.supervisor.note(
      pid, toolCalls: child.calls.count, activity: fields["title"]?.stringValue,
      transcript: child.messages.map { message in
        let text = message.toolID.flatMap { child.calls[$0] }.map {
          "[tool \($0.name)] \($0.arguments.compactJSONString)\n\(message.text)"
        } ?? (message.role == "message" ? "[inter-agent message]\n\(message.text)" : message.text)
        return AgentMessage(id: message.id.uuidString,
          role: message.role == "message" ? .developer : message.role == "user" ? .user : .assistant,
          content: message.role == "thought" ? [.reasoning(text)] : [.text(text)])
      })
    if let event { await scope.emit(event) }
  }

  private func configure(
    _ id: String, cancel: @escaping @Sendable (String) async throws -> Void
  ) async {
    guard let child = children[id], let pid = child.context.pid else { return }
    let handler: (@Sendable () async throws -> Void)? = child.canCancel ? { @Sendable in try await cancel(id) } : nil
    await scope.supervisor.configureExternalProcess(
      pid, sessionID: id, title: child.title ?? "ACP subagent", task: child.task,
      model: child.model, reasoningEffort: child.effort, provider: scope.provider, cancel: handler)
  }

  private func applyState(_ value: JSONValue, to id: String) async {
    guard var child = children[id], let pid = child.context.pid else { return }
    let state = value.objectValue?["state"]?.stringValue
    if state == "idle" { child.startsMessage = true; children[id] = child }
    if state != "idle", await scope.supervisor.info(pid)?.state.isTerminal == true {
      _ = await scope.supervisor.reopen(pid, runID: child.context.runID, task: child.task)
    }
    switch state {
    case "running": await scope.supervisor.note(pid, state: .running, activity: "thinking")
    case "requires_action": await scope.supervisor.note(pid, state: .waitingForApproval, activity: "waiting for action")
    case "idle":
      switch value.objectValue?["stopReason"]?.stringValue {
      case "cancelled": await scope.supervisor.fail(pid, state: .cancelled, message: "Cancelled", announce: false)
      case "error": await scope.supervisor.fail(pid, state: .failed,
        message: value.objectValue?["error"]?.objectValue?["message"]?.stringValue ?? "ACP subagent failed", announce: false)
      default: await scope.supervisor.complete(pid)
      }
    default: await scope.supervisor.note(pid, state: .blocked, activity: "state unknown")
    }
  }

  func disconnected() async {
    for (id, var child) in children {
      guard let pid = child.context.pid else { continue }
      child.canCancel = false
      children[id] = child
      await scope.supervisor.configureExternalProcess(
        pid, sessionID: id, title: child.title ?? "ACP subagent", task: child.task,
        model: child.model, reasoningEffort: child.effort, provider: scope.provider, cancel: nil)
      await scope.supervisor.fail(pid, state: .interrupted,
        message: "ACP disconnected; native subagent state is unknown", announce: false)
    }
  }
}
