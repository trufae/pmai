import Foundation

extension AgentCommandRecord {
  /// Older chats kept the call and structured result, but no launch timestamp
  /// or OS PID. Preserve the available evidence without inventing either.
  static func recovering(
    messages: [AgentMessage], sessionID: String, run: AgentEventContext
  ) -> [AgentCommandRecord] {
    // Providers can reuse call IDs on later turns. Match results in order.
    var results: [String: [ToolResult]] = [:]
    for result in messages.flatMap(\.toolResults) {
      results[result.callID, default: []].append(result)
    }
    return messages.flatMap(\.toolCalls).compactMap { call in
      var name = call.name
      var arguments = call.arguments.objectValue ?? [:]
      if name == ToolProxy.callName {
        name = arguments["name"]?.stringValue ?? ""
        arguments = arguments["arguments"]?.objectValue ?? [:]
      }
      guard name.hasPrefix("run_") else { return nil }
      var args = arguments["args"]?.arrayValue?.map { $0.stringValue ?? $0.compactJSONString } ?? []
      let command: String
      if let script = arguments["script"]?.stringValue, !script.isEmpty {
        command = script
      } else if let script = arguments["command"]?.stringValue, !script.isEmpty {
        command = script
      } else if let lines = arguments["commands"]?.arrayValue?.compactMap(\.stringValue),
        !lines.isEmpty
      {
        command = lines.joined(separator: "\n")
      } else if !args.isEmpty {
        command = args.removeFirst()
      } else {
        return nil
      }
      let result = results[call.id]?.isEmpty == false ? results[call.id]?.removeFirst() : nil
      let metadata = result?.structuredContent?.objectValue ?? [:]
      // Rejected/invalid calls never launched a process.
      guard result == nil || metadata["exitCode"] != nil || metadata["durationMs"] != nil else {
        return nil
      }
      let exit = metadata["exitCode"]?.intValue.flatMap(Int32.init(exactly:))
      let pid = metadata["pid"]?.intValue.flatMap(Int32.init(exactly:))
      return AgentCommandRecord(
        id: UUID(), sessionID: sessionID, run: run, callID: call.id, tool: name,
        pid: pid.flatMap { $0 > 0 ? $0 : nil }, command: command, arguments: args,
        cwd: metadata["cwd"]?.stringValue ?? arguments["cwd"]?.stringValue ?? "—",
        durationMs: metadata["durationMs"]?.intValue.map { max(0, $0) }, exitCode: exit,
        state: result == nil
          ? .interrupted : metadata["timedOut"]?.boolValue == true ? .timedOut : .exited)
    }
  }
}
