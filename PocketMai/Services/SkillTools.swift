import Foundation
import MaiCore
import MaiDocuments

@MainActor
enum SkillTools {
  static var directoryURL: URL {
    PocketMaiDirectories.filesWorkspaceURL.appendingPathComponent(".pmai/skills", isDirectory: true)
  }

  static func catalog(for conversation: Conversation? = nil, settings: AppSettings)
    -> AgentSkillCatalog
  {
    guard let conversation, settings.toolSettings.filesWorkspaceAccessEnabled,
      FileWorkspaceTool.workingFolderReference(for: conversation, settings: settings) != nil,
      let workspace = try? FileWorkspaceTool.context(for: conversation, settings: settings).context
    else { return AgentSkillCatalog.load(directories: [directoryURL]) }
    return WorkingFolderAccess.withAccess(to: workspace.rootURL) {
      AgentSkillCatalog.load(directories: [
        workspace.rootURL.appendingPathComponent(".pmai/skills", isDirectory: true), directoryURL,
      ])
    }
  }

  static func enabledSkills(for conversation: Conversation, settings: AppSettings) -> [AgentSkill] {
    guard conversation.toolsEnabled else { return [] }
    return catalog(for: conversation, settings: settings).modelInvocable.filter {
      settings.toolPolicy.mode(
        for: $0.toolName,
        in: [MaiSkillTools.group(toolNames: [$0.toolName])],
        enabled: settings.enabledSkillTools.contains($0.toolName),
        useToolProxy: settings.useToolProxy, exposedTools: []) != .disabled
    }
  }

  static func definitions(for conversation: Conversation, settings: AppSettings) -> [ToolDefinition]
  {
    enabledSkills(for: conversation, settings: settings).map(MaiSkillTools.definition)
  }

  static func execute(
    call: ParsedToolCall, conversation: Conversation, settings: AppSettings
  ) -> String {
    guard
      let skill = enabledSkills(for: conversation, settings: settings).first(where: {
        $0.toolName == call.name
      })
    else { return AgentTooling.unavailableToolError(name: call.name) }
    return MaiSkillTools.execute(skill: skill, arguments: call.argumentValues).text
  }

  /// A child keeps its provider snapshot, but disabling a skill also revokes
  /// pending calls for that agent. Switching the UI to another agent does not
  /// change the child's grants.
  static func applyingLiveSettings(to snapshot: AppSettings, from live: AppSettings) -> AppSettings
  {
    let agent =
      snapshot.selectedAgentID == live.selectedAgentID
      ? live.agentSettings
      : live.agents.first { $0.id == snapshot.selectedAgentID }?.settings
    var settings = snapshot
    settings.airplaneModeEnabled = live.airplaneModeEnabled
    settings.networkAvailable = live.networkAvailable
    settings.redaction = live.redaction
    settings.enabledSkillTools = agent?.enabledSkillTools ?? []
    settings.skillApprovalMode = agent?.skillApprovalMode
    settings.toolPolicy = agent?.toolPolicy ?? AgentToolPolicy(automatic: false)
    return settings
  }

  @discardableResult
  static func importFolder(_ url: URL) throws -> AgentSkill {
    try WorkingFolderAccess.withAccess(to: url) {
      guard let skill = AgentSkill.load(directory: url) else {
        throw AgentSkillManagerError.invalidSkill
      }
      return try AgentSkillManager.install(MaiArchiveSkill(skill: skill), in: directoryURL)
    }
  }

  static func importZip(_ url: URL) throws -> AgentSkill {
    try WorkingFolderAccess.withAccess(to: url) {
      try AgentSkillManager.install(SkillArchiveImporter.archive(at: url), in: directoryURL)
    }
  }

  static func create(name: String, description: String, prompt: String) throws -> AgentSkill {
    try AgentSkillManager.create(
      name: name, description: description, prompt: prompt, in: directoryURL)
  }

  static func update(
    _ skill: AgentSkill, description: String, prompt: String,
    conversation: Conversation?, settings: AppSettings
  ) throws -> AgentSkill {
    try withSkillAccess(skill, conversation: conversation, settings: settings) {
      try AgentSkillManager.update(skill, description: description, prompt: prompt)
    }
  }

  static func remove(_ skill: AgentSkill, conversation: Conversation?, settings: AppSettings) throws
  {
    try withSkillAccess(skill, conversation: conversation, settings: settings) {
      try AgentSkillManager.remove(skill)
    }
  }

  private static func withSkillAccess<T>(
    _ skill: AgentSkill, conversation: Conversation?, settings: AppSettings, _ body: () throws -> T
  ) throws -> T {
    if skill.rootURL.standardizedFileURL == directoryURL.standardizedFileURL { return try body() }
    guard let conversation, settings.toolSettings.filesWorkspaceAccessEnabled,
      let workspace = try? FileWorkspaceTool.context(for: conversation, settings: settings).context,
      skill.rootURL.standardizedFileURL
        == workspace.rootURL.appendingPathComponent(".pmai/skills", isDirectory: true)
        .standardizedFileURL
    else { throw AgentSkillManagerError.outsideRoot }
    return try WorkingFolderAccess.withAccess(to: workspace.rootURL, body)
  }
}
