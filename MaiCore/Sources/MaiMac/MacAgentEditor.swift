import MaiCore
import SwiftUI

struct MacAgentEdit: Identifiable {
  let id = UUID()
  var agent: AgentDefinition
  let creating: Bool
}

struct MacAgentEditor: View {
  @Bindable var conversation: MacConversation
  let creating: Bool
  @State private var agent: AgentDefinition
  @State private var saving = false
  @State private var error: String?
  @Environment(\.dismiss) private var dismiss

  init(conversation: MacConversation, edit: MacAgentEdit) {
    self.conversation = conversation
    creating = edit.creating
    _agent = State(initialValue: edit.agent)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(creating ? "New Agent" : "Edit Agent").font(.title2.bold())
      Text(creating
        ? "Start with this chat’s model, reasoning, and tools. Your new agent will be selected when you save."
        : "Save this chat’s model, reasoning, tool selection, and prompt to the agent. Other open chats keep their settings.")
        .foregroundStyle(.secondary)
      Form {
        TextField("Name", text: $agent.displayName)
        TextField("Description", text: $agent.description, axis: .vertical).lineLimit(2...3)
        LabeledContent("Model", value: agent.model)
        VStack(alignment: .leading, spacing: 6) {
          Text("System prompt").font(.headline)
          TextEditor(text: $agent.instructions)
            .font(.body).frame(minHeight: 150, maxHeight: 260)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
        }
        Toggle("Include workspace context", isOn: Binding(
          get: { agent.systemContext != false }, set: { agent.systemContext = $0 }))
        if let prompt = agent.systemPrompt,
          let others = conversation.agentProfiles?.agents.filter({ $0.id != agent.id && $0.systemPrompt == prompt }),
          !others.isEmpty {
          Text("This prompt is also used by \(others.map(\.displayName).joined(separator: ", ")). Editing it updates those profiles.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if saving { ProgressView().controlSize(.small) }
        Button(creating ? "Create Agent" : "Save Agent") {
          saving = true
          error = nil
          Task {
            do {
              agent.displayName = agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
              try await conversation.saveAgentProfile(agent, creating: creating)
              dismiss()
            } catch { self.error = error.localizedDescription }
            saving = false
          }
        }.keyboardShortcut(.defaultAction)
          .disabled(agent.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .textFieldStyle(.roundedBorder).padding(24).frame(width: 500)
    .disabled(saving).interactiveDismissDisabled(saving)
  }
}
