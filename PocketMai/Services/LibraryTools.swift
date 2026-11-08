import Foundation
import MaiCore

/// Library access is separate from invoking a skill or selecting a system prompt.
@MainActor
enum LibraryTools {
  static let skillToolNames: Set<String> = ["skill_list", "skill_read", "skill_write"]

  static func promptDefinitions(readOnly: Bool) -> [ToolDefinition] {
    let selector = [
      parameter("kind", "Prompt library: system or user."),
      parameter("name", "Prompt name, or the UUID returned by prompt_list for an existing prompt."),
    ]
    return [
      definition("prompt_list", "List saved system and user prompts with their names and IDs."),
      definition("prompt_read", "Read the full text of a saved prompt.", parameters: selector),
    ]
      + (readOnly
        ? []
        : [
          definition(
            "prompt_write",
            "Create or replace a saved prompt. Existing prompts keep their ID and selection. This does not change which prompt is selected.",
            parameters: selector + [parameter("text", "Complete prompt text to save.")],
            writes: true)
        ])
  }

  static func skillDefinitions(readOnly: Bool) -> [ToolDefinition] {
    let selector = [parameter("name", "Skill name from skill_list.")]
    return [
      definition("skill_list", "List skills in the working folder and the app's skill library."),
      definition(
        "skill_read", "Read a skill's description, instructions and metadata without invoking it.",
        parameters: selector),
    ]
      + (readOnly
        ? []
        : [
          definition(
            "skill_write",
            "Create or replace a skill's description and instructions. New skills are saved in the app library; existing skills are edited in place, preserving metadata and supporting files. This does not enable automatic invocation.",
            parameters: selector + [
              parameter("description", "When to use this skill."),
              parameter("text", "Complete skill instructions to save, without YAML front matter."),
            ], writes: true)
        ])
  }

  static func executePrompt(call: ParsedToolCall, settings: AppSettings, store: AppStore) -> String
  {
    let catalog = PromptCatalog(
      system: store.settings.systemPrompts, user: store.settings.userPrompts, builtins: [])
    if call.name == "prompt_list" {
      return json(
        .array(
          catalog.entries.map { entry in
            .object([
              "kind": .string(entry.kind.rawValue), "name": .string(entry.name),
              "id": .string(entry.promptID?.uuidString ?? ""),
            ])
          }))
    }
    guard let kind = call.argumentValues["kind"]?.stringValue,
      ["system", "user"].contains(kind),
      let name = call.argumentValues["name"]?.stringValue,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return "Error: specify kind (system or user) and a prompt name or ID." }
    let matches = catalog.entries.filter {
      $0.kind.rawValue == kind
        && ($0.promptID == UUID(uuidString: name)
          || $0.name.caseInsensitiveCompare(name) == .orderedSame)
    }
    guard matches.count <= 1 else {
      return "Error: multiple prompts match; use the ID from prompt_list."
    }
    let entry = matches.first
    if call.name == "prompt_read" {
      guard let entry else { return "Error: prompt '\(name)' was not found." }
      return json(
        .object([
          "kind": .string(kind), "name": .string(entry.name),
          "id": .string(entry.promptID?.uuidString ?? ""), "text": .string(entry.text),
        ]))
    }
    guard call.name == "prompt_write" else {
      return AgentTooling.unavailableToolError(name: call.name)
    }
    guard !settings.toolSettings.promptsReadOnly, !store.settings.toolSettings.promptsReadOnly
    else {
      return "Error: Prompts tools are read-only."
    }
    guard let text = call.argumentValues["text"]?.stringValue else {
      return "Error: specify prompt text."
    }
    // A stale ID must not accidentally create a new prompt with a UUID as its name.
    guard entry != nil || UUID(uuidString: name) == nil else {
      return "Error: this prompt no longer exists."
    }
    var draft: PromptDraft
    if kind == "system" {
      draft = PromptDraft(
        systemPrompt: store.settings.systemPrompts.first { $0.id == entry?.promptID })
    } else {
      draft = PromptDraft(userPrompt: store.settings.userPrompts.first { $0.id == entry?.promptID })
    }
    let original = draft
    draft.name = entry?.name ?? name
    draft.text = text
    if let error = draft.save(to: &store.settings, original: original) { return "Error: \(error)" }
    store.saveSettings()
    return "Saved \(kind) prompt '\(draft.name)'."
  }

  static func executeSkill(
    call: ParsedToolCall, conversation: Conversation, settings: AppSettings, store: AppStore
  ) -> String {
    let catalog = SkillTools.catalog(for: conversation, settings: settings)
    if call.name == "skill_list" {
      return json(
        .array(
          catalog.skills.map { skill in
            .object(["name": .string(skill.name), "description": .string(skill.description)])
          }))
    }
    guard let name = call.argumentValues["name"]?.stringValue,
      !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return "Error: specify a skill name." }
    let skill = catalog.skill(named: name)
    if call.name == "skill_read" {
      guard let skill else { return "Error: skill '\(name)' was not found." }
      return json(
        .object([
          "name": .string(skill.name), "description": .string(skill.description),
          "directory": .string(skill.directoryURL.resolvingSymlinksInPath().path),
          "text": .string(skill.body),
          "metadata": .object(skill.frontMatter.mapValues(JSONValue.string)),
        ]))
    }
    guard call.name == "skill_write" else {
      return AgentTooling.unavailableToolError(name: call.name)
    }
    guard !settings.toolSettings.skillsReadOnly, !store.settings.toolSettings.skillsReadOnly else {
      return "Error: Skills tools are read-only."
    }
    guard let description = call.argumentValues["description"]?.stringValue,
      let text = call.argumentValues["text"]?.stringValue
    else { return "Error: specify a description and skill text." }
    do {
      let saved: AgentSkill
      if let skill {
        saved = try SkillTools.update(
          skill, description: description, prompt: text,
          conversation: conversation, settings: settings)
      } else {
        saved = try SkillTools.create(name: name, description: description, prompt: text)
      }
      // Skill definitions are read from disk; invalidate cached descriptions too.
      ToolAgentRegistry.invalidateCatalog()
      return "Saved skill '\(saved.name)'."
    } catch { return "Error: \(error.localizedDescription)" }
  }

  private static func parameter(_ name: String, _ description: String) -> ToolParameterDef {
    ToolParameterDef(name: name, type: "string", description: description, required: true)
  }

  private static func definition(
    _ name: String, _ description: String, parameters: [ToolParameterDef] = [], writes: Bool = false
  ) -> ToolDefinition {
    ToolDefinition(
      name: name, description: description, parameters: parameters,
      annotations: ToolAnnotations(
        readOnly: !writes, idempotent: true, openWorld: false,
        approval: writes ? .confirm : .automatic))
  }

  private static func json(_ value: JSONValue) -> String {
    value.compactJSONString
  }
}
