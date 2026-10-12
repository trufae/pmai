import MaiCore
import SwiftUI
import UniformTypeIdentifiers

private struct SkillEditorSelection: Identifiable {
  let id = UUID()
  var skill: AgentSkill?
}

struct SkillsSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @State private var skills: [AgentSkill] = []
  @State private var editor: SkillEditorSelection?
  @State private var importing = false
  @State private var importType = UTType.zip
  @State private var pendingDeletion: AgentSkill?
  @State private var statusMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(
        "Skills give your agent reusable instructions for specific tasks. Tap a skill to edit its description and prompt."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      HStack {
        Button("Create Skill", systemImage: "plus") { editor = SkillEditorSelection() }
        Spacer()
        Menu {
          Button("Import ZIP", systemImage: "doc.zipper") {
            importType = .zip
            importing = true
          }
          Button("Import Folder", systemImage: "folder") {
            importType = .folder
            importing = true
          }
        } label: {
          Label("Import", systemImage: "square.and.arrow.down")
        }
      }
      .buttonStyle(.borderless)

      if skills.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "sparkles").font(.title2)
          Text("No skills yet").font(.headline)
          Text("Create a skill with a description and prompt, or import a skill ZIP from Files.")
            .font(.caption)
            .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
      }

      ForEach(skills) { skill in
        HStack(spacing: 12) {
          Button {
            editor = SkillEditorSelection(skill: skill)
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(skill.name).foregroundStyle(.primary)
              Text(skill.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
              if !canInvoke(skill) {
                Text(
                  skill.isModelInvocable
                    ? "Another skill uses this tool name" : "Automatic use disabled by this skill"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
              }
              if skill.rootURL.standardizedFileURL != SkillTools.directoryURL.standardizedFileURL {
                Text("Working folder").font(.caption2).foregroundStyle(.secondary)
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityHint("Edit skill")

          Toggle(
            "Enable \(skill.name)",
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
          )
          .labelsHidden()
          .disabled(!canInvoke(skill))

          Menu {
            Button("Edit", systemImage: "pencil") { editor = SkillEditorSelection(skill: skill) }
            Button("Delete Skill", systemImage: "trash", role: .destructive) {
              pendingDeletion = skill
            }
          } label: {
            Image(systemName: "ellipsis.circle").padding(.vertical, 8)
          }
          .accessibilityLabel("Actions for \(skill.name)")
        }
      }

      if !skills.isEmpty {
        HStack {
          Button("Enable All") {
            store.settings.enabledSkillTools.formUnion(
              AgentSkillCatalog(skills: skills).modelInvocable.map(\.toolName))
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
        "Enabled skills are available to \(store.settings.selectedAgent.name). New and imported skills are enabled when they allow automatic use. Ask lets you approve or choose a different skill before use."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      if let statusMessage {
        Text(statusMessage).font(.caption).foregroundStyle(.secondary)
      }
      Button("Reload Skills", systemImage: "arrow.clockwise", action: reload)
        .buttonStyle(.borderless)
    }
    .onAppear(perform: reload)
    .onChange(of: store.settings.selectedAgentID) { reload() }
    .sheet(item: $editor) { selection in
      SkillEditorView(skill: selection.skill) { name, description, prompt in
        let skill: AgentSkill
        if let existing = selection.skill {
          skill = try SkillTools.update(
            existing, description: description, prompt: prompt,
            conversation: store.currentConversation, settings: store.settings)
        } else {
          skill = try SkillTools.create(name: name, description: description, prompt: prompt)
          enableNewSkill(skill)
        }
        statusMessage = "Saved \(skill.name)."
        reload()
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [importType]) { result in
      do {
        let url = try result.get()
        let skill =
          try importType == .folder ? SkillTools.importFolder(url) : SkillTools.importZip(url)
        enableNewSkill(skill)
        statusMessage = "Imported \(skill.name)."
        reload()
      } catch { store.errorMessage = error.localizedDescription }
    }
    .alert(
      "Delete skill?",
      isPresented: Binding(
        get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { pendingDeletion = nil }
      Button("Delete", role: .destructive) {
        guard let skill = pendingDeletion else { return }
        do {
          try SkillTools.remove(
            skill, conversation: store.currentConversation, settings: store.settings)
          reload()
          // A working-folder deletion can reveal an app copy of the same skill.
          if !skills.contains(where: { $0.toolName == skill.toolName }) {
            store.settings.enabledSkillTools.remove(skill.toolName)
            for index in store.settings.agents.indices {
              store.settings.agents[index].settings.enabledSkillTools.remove(skill.toolName)
            }
            store.saveSettings()
          }
          statusMessage = "Deleted \(skill.name)."
        } catch { store.errorMessage = error.localizedDescription }
        pendingDeletion = nil
      }
    } message: {
      Text("This deletes \(pendingDeletion?.name ?? "the skill") and its supporting files.")
    }
  }

  private func enableNewSkill(_ skill: AgentSkill) {
    reload()
    if canInvoke(skill) {
      store.settings.enabledSkillTools.insert(skill.toolName)
      store.saveSettings()
    }
  }

  private func reload() {
    skills = SkillTools.catalog(for: store.currentConversation, settings: store.settings).skills
  }

  private func canInvoke(_ skill: AgentSkill) -> Bool {
    AgentSkillCatalog(skills: skills).modelInvocable.contains {
      $0.directoryURL == skill.directoryURL && $0.name == skill.name
    }
  }
}

private struct SkillEditorView: View {
  @Environment(\.dismiss) private var dismiss
  let skill: AgentSkill?
  let onSave: (String, String, String) throws -> Void
  @State private var name: String
  @State private var description: String
  @State private var prompt: String
  @State private var errorMessage: String?

  init(skill: AgentSkill?, onSave: @escaping (String, String, String) throws -> Void) {
    self.skill = skill
    self.onSave = onSave
    _name = State(initialValue: skill?.name ?? "")
    _description = State(initialValue: skill?.description ?? "")
    _prompt = State(initialValue: skill?.body ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        Section {
          TextField("e.g. weekly-summary", text: $name)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .disabled(skill != nil)
        } header: {
          Text("Name")
        }
        Section {
          TextField("When should the agent use this skill?", text: $description, axis: .vertical)
            .lineLimit(3...6)
        } header: {
          Text("Description")
        }
        Section {
          TextEditor(text: $prompt)
            .frame(minHeight: 260)
            .accessibilityLabel("Skill prompt")
        } header: {
          Text("Prompt")
        } footer: {
          Text(
            "Write the instructions the agent should follow, including any output format or examples."
          )
        }
        if skill == nil {
          Section {
            Text(
              "Your skill will be saved and enabled for the selected agent. You can edit it at any time."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle(skill == nil ? "Create Skill" : "Edit Skill")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") {
            do {
              try onSave(name, description, prompt)
              dismiss()
            } catch { errorMessage = error.localizedDescription }
          }
          .disabled(
            [name, description, prompt].contains {
              $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            })
        }
      }
      .alert(
        "Couldn't Save Skill",
        isPresented: Binding(
          get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )
      ) {
        Button("OK", role: .cancel) { errorMessage = nil }
      } message: {
        Text(errorMessage ?? "")
      }
    }
  }
}
