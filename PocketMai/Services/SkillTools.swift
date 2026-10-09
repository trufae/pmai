import Foundation
import MaiCore

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
      settings.enabledSkillTools.contains($0.toolName)
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
    settings.enabledSkillTools = agent?.enabledSkillTools ?? []
    settings.skillApprovalMode = agent?.skillApprovalMode
    return settings
  }

  static func importFolder(_ url: URL) throws {
    try WorkingFolderAccess.withAccess(to: url) {
      guard let skill = AgentSkill.load(directory: url) else {
        throw NSError(domain: "PocketMaiSkills", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "Select a skill folder containing SKILL.md."])
      }
      try MaiArchiveSkill(skill: skill).install(in: directoryURL)
    }
  }
}
