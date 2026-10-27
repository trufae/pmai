import Foundation
import MaiCore

/// Access is limited to the voice agent's own conversation tree.
public enum VoiceAgentTools {
  public static let names: Set<String> = ["voice_agents", "voice_message"]
  public static func tools(supervisor: AgentSupervisor) -> [any AgentTool] {
    [
      ClosureTool(
        definition: ToolDefinition(
          name: "voice_agents",
          description:
            "List all agents in this conversation, including the text agent. With pid, read its complete current transcript.",
          parameters: [
            .init(
              name: "pid", type: "integer", description: "Agent process ID to read; omit to list.",
              required: false)
          ],
          annotations: .init(readOnly: true, approval: .automatic))
      ) { args, context in
        let processes = await supervisor.processes()
        let allowed = scope(processes, caller: context.run.pid)
        if let number = args.objectValue?["pid"]?.intValue {
          let pid = AgentPID(number)
          guard allowed.contains(where: { $0.pid == pid }) else {
            return ToolOutput(text: "Unknown agent in this conversation.", isError: true)
          }
          let messages = try await supervisor.loadTranscript(pid)
          return ToolOutput(
            text: String(decoding: try JSONEncoder().encode(messages), as: UTF8.self))
        }
        return ToolOutput(
          text: allowed.map { "\($0.pid) \($0.agentID) [\($0.state.shortLabel)] \($0.displayName)" }
            .joined(separator: "\n"))
      },
      ClosureTool(
        definition: ToolDefinition(
          name: "voice_message",
          description:
            "Send a user-requested task or correction to another agent in this conversation. Running agents receive it at their next model turn; idle agents retain it in their inbox until continued.",
          parameters: [
            .init(
              name: "pid", type: "integer", description: "Recipient process ID.", required: true),
            .init(
              name: "text", type: "string", description: "The requested task or correction.",
              required: true),
          ],
          annotations: .init(approval: .automatic))
      ) { args, context in
        guard let number = args.objectValue?["pid"]?.intValue,
          let text = args.objectValue?["text"]?.stringValue, !text.isEmpty
        else {
          return ToolOutput(text: "Expected pid and text.", isError: true)
        }
        let pid = AgentPID(number)
        let allowed = scope(await supervisor.processes(), caller: context.run.pid)
        guard pid != context.run.pid, allowed.contains(where: { $0.pid == pid }),
          await supervisor.post(.user(text), to: pid) != nil
        else {
          return ToolOutput(text: "Unknown recipient in this conversation.", isError: true)
        }
        return ToolOutput(text: "Queued for \(pid); delivered at its next model turn.")
      },
    ]
  }

  private static func scope(_ processes: [AgentProcessInfo], caller: AgentPID?)
    -> [AgentProcessInfo]
  {
    guard var root = caller, processes.contains(where: { $0.pid == root }) else { return [] }
    var visited = Set<AgentPID>()
    while visited.insert(root).inserted,
      let parent = processes.first(where: { $0.pid == root })?.parent
    { root = parent }
    var allowed: Set<AgentPID> = [root]
    var count = 0
    repeat {
      count = allowed.count
      for info in processes where info.parent.map(allowed.contains) == true {
        allowed.insert(info.pid)
      }
    } while allowed.count > count
    return processes.filter { allowed.contains($0.pid) }
  }
}
