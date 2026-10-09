import MaiCore
import SwiftUI
import UniformTypeIdentifiers

struct SkillsSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var skills: [AgentSkill] = []
  @State private var importing = false
  @State private var pendingDeletion: AgentSkill?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Picker(
        "Skill approval",
        selection: Binding(
          get: { store.settings.skillApprovalMode },
          set: {
            store.settings.skillApprovalMode = $0
            store.saveSettings()
          }
        )
      ) {
        Text("Follow tool approval").tag(nil as ToolApprovalMode?)
        Text("Ask").tag(ToolApprovalMode.ask as ToolApprovalMode?)
        Text("Yolo").tag(ToolApprovalMode.yolo as ToolApprovalMode?)
        Text("Smart").tag(ToolApprovalMode.smart as ToolApprovalMode?)
      }
      Text(
        "Ask lets you accept, cancel, or choose another enabled skill. Smart uses your approval agent. Skills also participate in smart tool selection."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ForEach(skills) { skill in
        DisclosureGroup {
          Text(skill.description)
            .font(.subheadline)
          Text(skill.body)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
          Text(skill.fileURL.path)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
          if skill.rootURL.standardizedFileURL == SkillTools.directoryURL.standardizedFileURL {
            Button("Remove Skill", role: .destructive) { pendingDeletion = skill }
          }
        } label: {
          Toggle(
            isOn: Binding(
              get: {
                canInvoke(skill) && store.settings.enabledSkillTools.contains(skill.toolName)
              },
              set: { enabled in
                if enabled {
                  store.settings.enabledSkillTools.insert(skill.toolName)
                } else {
                  store.settings.enabledSkillTools.remove(skill.toolName)
                }
                store.saveSettings()
              }
            )
          ) {
            VStack(alignment: .leading) {
              Text(skill.name)
              Text(
                !skill.isModelInvocable
                  ? "Model invocation disabled by SKILL.md"
                  : canInvoke(skill) ? skill.description : "Another skill uses this tool name"
              )
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(2)
            }
          }
          .disabled(!canInvoke(skill))
        }
      }
      if skills.isEmpty {
        Text(
          "Import a folder containing SKILL.md, or add skills under .pmai/skills in your working folder."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      } else {
        HStack {
          Button("Enable All") {
            store.settings.enabledSkillTools.formUnion(
              skills.filter(\.isModelInvocable).map(\.toolName))
            store.saveSettings()
          }
          Spacer()
          Button("Disable All") {
            store.settings.enabledSkillTools.subtract(skills.map(\.toolName))
            store.saveSettings()
          }
        }
        .buttonStyle(.borderless)
      }
      Button("Import Skill Folder", systemImage: "folder.badge.plus") { importing = true }
      Button("Reload Skills", systemImage: "arrow.clockwise", action: reload)
      Text(
        "Availability is saved for \(store.settings.selectedAgent.name). Imported skills are stored in FilesData/.pmai/skills. Working-folder skills take precedence when Files workspace access is enabled. Enable Files tools for skills that read supporting files."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .onAppear(perform: reload)
    .fileImporter(isPresented: $importing, allowedContentTypes: [.folder]) { result in
      do {
        try SkillTools.importFolder(result.get())
        reload()
      } catch { store.errorMessage = error.localizedDescription }
    }
    .alert(
      "Remove skill?",
      isPresented: Binding(
        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
      Button("Remove", role: .destructive) {
        guard let skill = pendingDeletion else { return }
        do {
          try FileManager.default.removeItem(at: skill.directoryURL)
          store.settings.enabledSkillTools.remove(skill.toolName)
          store.saveSettings()
          reload()
        } catch { store.errorMessage = error.localizedDescription }
        pendingDeletion = nil
      }
    } message: {
      Text("This removes the imported folder and its supporting files.")
    }
  }

  private func reload() {
    skills = SkillTools.catalog(for: store.currentConversation, settings: store.settings).skills
  }

  private func canInvoke(_ skill: AgentSkill) -> Bool {
    AgentSkillCatalog(skills: skills).modelInvocable.contains { $0.name == skill.name }
  }
}
