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
  @State private var managing = false

  var body: some View {
    let invocable = AgentSkillCatalog(skills: skills).modelInvocable
    Group {
      ForEach(skills) { skill in
        let available = invocable.contains {
          $0.directoryURL == skill.directoryURL && $0.name == skill.name
        }
        Toggle(
          isOn: Binding(
            get: { available && store.settings.enabledSkillTools.contains(skill.toolName) },
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
          SkillSummaryView(skill: skill, isAvailable: available)
        }
        .disabled(!available)
      }
      Button {
        managing = true
      } label: {
        HStack {
          Label("Manage Skills", systemImage: "sparkles")
          Spacer()
          Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
        }
      }
      .sheet(isPresented: $managing) {
        SkillsManagerView(skills: $skills)
      }
      .onAppear(perform: reload)
      .onChange(of: store.settings.selectedAgentID) { reload() }
      .onChange(of: store.currentConversation?.id) { reload() }
    }
  }

  private func reload() {
    skills = SkillTools.catalog(for: store.currentConversation, settings: store.settings).skills
  }
}

private struct SkillSummaryView: View {
  let skill: AgentSkill
  var isAvailable = true

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(skill.name).foregroundStyle(.primary)
      Text(skill.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)
      if !isAvailable || !skill.isModelInvocable {
        Text(
          skill.isModelInvocable
            ? "Another skill uses this tool name" : "Automatic use disabled by this skill"
        )
        .font(.caption2).foregroundStyle(.secondary)
      }
      if skill.rootURL.standardizedFileURL != SkillTools.directoryURL.standardizedFileURL {
        Text("Working folder").font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}

private struct SkillsManagerView: View {
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var store: AppStore
  @Binding var skills: [AgentSkill]
  @State private var editor: SkillEditorSelection?
  @State private var importing = false
  @State private var importType = UTType.zip
  @State private var pendingDeletion: AgentSkill?
  @State private var statusMessage: String?
  @State private var errorMessage: String?

  var body: some View {
    NavigationStack {
      Form {
        Section {
          Button("Create Skill", systemImage: "plus") { editor = SkillEditorSelection() }
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

        Section {
          if skills.isEmpty {
            ContentUnavailableView(
              "No skills yet", systemImage: "sparkles",
              description: Text("Create a skill or import one from Files.")
            )
          }

          ForEach(skills) { skill in
            Button {
              editor = SkillEditorSelection(skill: skill)
            } label: {
              HStack {
                SkillSummaryView(skill: skill)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                  .font(.footnote.weight(.semibold))
                  .foregroundStyle(.tertiary)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Edit skill")
            .contextMenu {
              Button("Edit", systemImage: "pencil") { editor = SkillEditorSelection(skill: skill) }
              Button("Delete Skill", systemImage: "trash", role: .destructive) {
                pendingDeletion = skill
              }
            }
            .swipeActions {
              Button("Delete", systemImage: "trash", role: .destructive) {
                pendingDeletion = skill
              }
            }
          }
        } header: {
          Text("Your Skills")
        } footer: {
          Text("Tap a skill to edit its description and instructions. Swipe left to delete.")
        }

        Section {
          if !skills.isEmpty {
            Button("Enable All") {
              store.settings.enabledSkillTools.formUnion(
                AgentSkillCatalog(skills: skills).modelInvocable.map(\.toolName))
              store.saveSettings()
            }
            Button("Disable All") {
              store.settings.enabledSkillTools.subtract(skills.map(\.toolName))
              store.saveSettings()
            }
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
          .pickerStyle(.navigationLink)
        } header: {
          Text("Permissions")
        } footer: {
          Text(
            "Enabled skills are available to \(store.settings.selectedAgent.name). New and imported skills are enabled when they allow automatic use. Ask lets you approve or choose a different skill before use."
          )
        }
        Section {
          Button("Reload Skills", systemImage: "arrow.clockwise", action: reload)
          if let statusMessage {
            Text(statusMessage).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Manage Skills")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
      }
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
      } catch { errorMessage = error.localizedDescription }
    }
    .alert(
      "Couldn't Manage Skill",
      isPresented: Binding(
        get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
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
        } catch { errorMessage = error.localizedDescription }
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
