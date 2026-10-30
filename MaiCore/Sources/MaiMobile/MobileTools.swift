import Foundation
import MaiACP
import MaiCore
import MaiMCP
import MaiStandardTools
import Observation

private struct MobileMCP: Codable {
  var id: String
  var name: String
  var url: URL
  var token: String
  var enabled = true
}
private struct MobileAgentSettings: Codable {
  var enabled = false
  var disabledTools: Set<String> = []
  var disabledGroups: Set<String>?
  var servers: [MobileMCP] = []
}
private struct ToolActivity {
  var id: String
  var name: String
  var text: String
  var state: String
}

@MainActor @Observable final class MobileTools: ApprovalHandler {
  private let directory: URL
  private var settings: MobileAgentSettings
  private var definitions: [ToolDefinition] = []
  private var groups: [ToolGroupDefinition] = []
  private var activity: [ToolActivity] = []
  private var approvals: [ApprovalRequest] = []
  @ObservationIgnored private var replies: [String: CheckedContinuation<ApprovalDecision, Never>] = [:]
  private var skills: AgentSkillCatalog
  var error = ""
  var loading = false
  private var skillsRoot: URL { directory.appendingPathComponent("skills") }
  private var settingsFile: URL { directory.appendingPathComponent("agent.json") }

  init(directory: URL) throws {
    self.directory = directory
    let file = directory.appendingPathComponent("agent.json")
    settings = FileManager.default.fileExists(atPath: file.path)
      ? try JSONDecoder().decode(MobileAgentSettings.self, from: Data(contentsOf: file)) : .init()
    skills = AgentSkillCatalog.load(directories: [directory.appendingPathComponent("skills")])
  }

  func loadCatalog() async {
    loading = true
    defer { loading = false }
    do {
      definitions = try await standardTools().map(\.definition)
      groups = try await MaiStandardToolFactory().toolGroups(context: toolContext)
    }
    catch { self.error = error.localizedDescription }
  }

  private func standardTools() async throws -> [any AgentTool] {
    let workspace = directory.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let tools = try await MaiStandardToolFactory().makeTools(context: toolContext)
    // Mobile hosts have no bundled pmai executable or desktop process environment.
    return tools.filter { !$0.definition.name.hasPrefix("run") && !$0.definition.name.hasPrefix("pmai") }
  }

  private var toolContext: PluginFactoryContext {
    PluginFactoryContext(id: "mobile", options: ["filesRoot": .string(directory.appendingPathComponent("workspace").path)])
  }

  func run(_ request: ProviderRequest, provider: any ChatProvider,
    emit: @escaping ProviderEventHandler) async throws -> [AgentMessage] {
    activity = []
    guard settings.enabled else {
      let response = try await provider.complete(request, emit: emit)
      return request.messages + [response.message]
    }
    let runtime = AgentRuntime(approvalHandler: self)
    try await runtime.register(provider)
    let standard = try await standardTools()
    definitions = standard.map(\.definition)
    groups = try await MaiStandardToolFactory().toolGroups(context: toolContext)
    let groupDisabled = groups.filter { (settings.disabledGroups ?? []).contains($0.catalogID) }
      .reduce(into: Set<String>()) { $0.formUnion($1.toolNames) }
    let enabled = standard.filter { !settings.disabledTools.contains($0.definition.name) && !groupDisabled.contains($0.definition.name) }
    try await runtime.register(tools: enabled)
    let catalog = skills
    let skillTools = MaiSkillTools.makeTools(catalog: { catalog })
      .filter { !settings.disabledTools.contains($0.definition.name) }
    try await runtime.register(tools: skillTools)
    var clients: [MCPClient] = []
    do {
      for server in settings.servers where server.enabled {
        let client = MCPClient(configuration: .init(id: server.id, displayName: server.name, url: server.url,
          headers: server.token.isEmpty ? [:] : ["Authorization": "Bearer \(server.token)"], defaultApproval: .confirm))
        clients.append(client)
        _ = try await runtime.register(mcp: client)
      }
      let available = await runtime.availableTools()
      let tools = Set(available.map(\.name)).subtracting(settings.disabledTools)
      let scope = AgentExecutionScope(sessionID: request.sessionID ?? UUID().uuidString,
        workingDirectory: directory.appendingPathComponent("workspace"))
      let result = try await AgentExecutionScope.$current.withValue(scope) {
        try await runtime.run(AgentRequest(provider: provider.descriptor.id,
        model: request.model, messages: request.messages, toolNames: tools,
        sessionID: request.sessionID)) { [weak self] event in
          switch event {
          case .provider(_, let value): await emit(value)
          default: await self?.receive(event)
          }
        }
      }
      for client in clients { await client.close() }
      return result.transcript
    } catch {
      for client in clients { await client.close() }
      cancelApprovals()
      throw error
    }
  }

  // ApprovalHandler is actor-safe; Kotlin only receives immutable request data.
  nonisolated func toolApprovalMode() async -> ToolApprovalMode? { .ask }
  func decide(_ request: ApprovalRequest) async throws -> ApprovalDecision {
    try Task.checkCancellation()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if Task.isCancelled { continuation.resume(returning: .cancelRun); return }
        approvals.append(request)
        replies[request.call.id] = continuation
      }
    } onCancel: { Task { @MainActor [weak self] in self?.answer(request.call.id, choice: "cancel") } }
  }
  func answer(_ id: String, choice: String) {
    let request = approvals.first { $0.call.id == id }
    approvals.removeAll { $0.call.id == id }
    let reply = replies.removeValue(forKey: id)
    if choice == "approve", let request { reply?.resume(returning: .approve(arguments: request.call.arguments)) }
    else if choice == "cancel" { reply?.resume(returning: .cancelRun) }
    else { reply?.resume(returning: .deny(reason: "Denied by the user")) }
  }
  func cancelApprovals() { for id in Array(replies.keys) { answer(id, choice: "cancel") } }

  private func receive(_ event: AgentEvent) {
    switch event {
    case .toolStarted(_, let call):
      activity.append(.init(id: call.id, name: call.name, text: call.arguments.compactJSONString, state: "Running"))
      if activity.count > 30 { activity.removeFirst() }
    case .toolFinished(_, let result):
      if let i = activity.firstIndex(where: { $0.id == result.callID }) {
        activity[i].state = result.isError ? "Failed" : "Done"
        activity[i].text = String(result.text.prefix(16000))
      }
    default: break
    }
  }

  func configure(_ command: [String: String]) throws {
    let action = command["action"] ?? ""
    switch action {
    case "toolsEnabled": settings.enabled = command["enabled"] == "true"
    case "toolEnabled":
      if command["enabled"] == "true" { settings.disabledTools.remove(command["name"] ?? "") }
      else { settings.disabledTools.insert(command["name"] ?? "") }
    case "groupEnabled":
      var disabled = settings.disabledGroups ?? []
      if command["enabled"] == "true" { disabled.remove(command["id"] ?? "") }
      else { disabled.insert(command["id"] ?? "") }
      settings.disabledGroups = disabled
    case "saveMcp":
      guard let url = URL(string: command["url"] ?? ""), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil, url.user == nil, url.password == nil else { throw PortableAgentError.invalidServer }
      let id = command["id"].flatMap { $0.isEmpty ? nil : $0 } ?? UUID().uuidString.lowercased()
      let old = settings.servers.first { $0.id == id }
      let server = MobileMCP(id: id, name: command["name"] ?? "MCP", url: url,
        token: command["token"].flatMap { $0.isEmpty ? nil : $0 } ?? old?.token ?? "")
      settings.servers.removeAll { $0.id == id }; settings.servers.append(server)
    case "mcpEnabled":
      if let i = settings.servers.firstIndex(where: { $0.id == command["id"] }) { settings.servers[i].enabled = command["enabled"] == "true" }
    case "removeMcp": settings.servers.removeAll { $0.id == command["id"] }
    case "saveSkill":
      let name = command["name"] ?? ""
      if let existing = skills.skill(named: name) {
        _ = try AgentSkillManager.saveDocument(AgentSkillManager.document(name: name,
          description: command["description"] ?? "", prompt: command["body"] ?? ""), for: existing)
      } else {
        _ = try AgentSkillManager.create(name: name, description: command["description"] ?? "",
          prompt: command["body"] ?? "", in: skillsRoot)
      }
      skills = AgentSkillCatalog.load(directories: [skillsRoot])
    case "removeSkill":
      if let skill = skills.skill(named: command["name"] ?? "") { try AgentSkillManager.remove(skill) }
      skills = AgentSkillCatalog.load(directories: [skillsRoot])
    default: throw CocoaError(.coderInvalidValue)
    }
    try ACPStateFiles.write(settings, to: settingsFile)
  }

  var snapshot: [String: Any] {
    ["enabled": settings.enabled, "loading": loading, "error": error,
      "tools": definitions.map { ["name": $0.name, "description": $0.description,
        "enabled": !settings.disabledTools.contains($0.name)] as [String: Any] },
      "groups": groups.compactMap { group -> [String: Any]? in
        let names = group.toolNames.intersection(Set(definitions.map(\.name))).sorted()
        guard !names.isEmpty else { return nil }
        return ["id": group.catalogID, "name": group.displayName, "description": group.description,
          "enabled": !(settings.disabledGroups ?? []).contains(group.catalogID), "tools": names]
      },
      "servers": settings.servers.map { ["id": $0.id, "name": $0.name,
        "url": $0.url.absoluteString, "enabled": $0.enabled, "hasToken": !$0.token.isEmpty] as [String: Any] },
      "skills": skills.skills.map { ["name": $0.name, "description": $0.description,
        "body": $0.body, "toolName": $0.toolName, "enabled": !settings.disabledTools.contains($0.toolName)] as [String: Any] },
      "activity": activity.map { ["id": $0.id, "name": $0.name, "text": $0.text, "state": $0.state] },
      "approvals": approvals.map { ["id": $0.call.id, "name": $0.tool.name, "description": $0.tool.description,
        "arguments": $0.call.arguments.compactJSONString] },
    ]
  }
}

private enum PortableAgentError: LocalizedError {
  case invalidServer
  var errorDescription: String? { "Enter an HTTP or HTTPS MCP endpoint without embedded credentials." }
}
