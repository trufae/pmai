import Foundation

extension AgentRuntime {
  public func conversationRecords(under pid: AgentPID) async -> [AgentProcessRecord] {
    var records = await supervisor.records(under: pid)
    for index in records.indices {
      let child = records[index].pid
      if conversationIDs[child] == nil { conversationIDs[child] = records[index].runID }
      records[index].conversationID = conversationIDs[child]
      if var request = await conversationRequest(for: records[index].pid) {
        request.messages = []
        records[index].conversationRequest = request
      }
    }
    return records
  }

  @discardableResult
  public func restoreConversations(
    _ records: [AgentProcessRecord], under parent: AgentPID, sessionID: String? = nil
  ) async -> [AgentPID] {
    let restored = await supervisor.restore(records, under: parent)
    let processes = await supervisor.processes()
    for record in records {
      if let pid = processes.first(where: { $0.runID == record.runID })?.pid {
        conversationIDs[pid] = record.id
        if var request = record.conversationRequest {
          if let sessionID { request.sessionID = sessionID }
          conversationRequests[pid] = request
        }
      }
    }
    return restored
  }

  /// A snapshot uses this process's actual settings, including a derived
  /// worker's tool restrictions, rather than guessing from its agent name.
  public func conversationRequest(for pid: AgentPID) async -> AgentRequest? {
    let known = Set(await supervisor.processes().map(\.pid))
    conversationRequests = conversationRequests.filter { known.contains($0.key) }
    conversationIDs = conversationIDs.filter { known.contains($0.key) }
    guard var request = liveRequests[pid] ?? conversationRequests[pid] else { return nil }
    request.messages = await supervisor.transcript(pid)
    return request
  }

  /// Creates an idle child without a provider call. The host can switch to it
  /// immediately, then pass its request and pid to `run` for each new turn.
  public func forkConversation(
    _ request: AgentRequest, parent: AgentPID, title: String
  ) async -> AgentPID? {
    guard let info = await supervisor.info(parent) else { return nil }
    let pid = await supervisor.register(
      runID: UUID(), parent: parent, agentID: request.agentID,
      displayName: title, task: title, depth: info.depth + 1)
    conversationIDs[pid] = await supervisor.info(pid)?.runID
    var settings = request
    settings.messages = []
    conversationRequests[pid] = settings
    await supervisor.note(pid, transcript: request.messages)
    await supervisor.complete(pid)
    return pid
  }
}
