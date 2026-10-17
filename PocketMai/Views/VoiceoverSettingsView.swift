import MaiCore
import SwiftUI

struct VoiceoverSettingsView: View {
  let store: AppStore
  @ObservedObject var storeObservation: AppStoreViewObservation
  @State private var editingAgentID: UUID?

  var body: some View {
    Form {
      Section {
        Picker("Agent", selection: agentBinding) {
          Text("Current conversation model").tag("")
          ForEach(store.settings.agents) { agent in
            Text(agent.name).tag(agent.id.uuidString.lowercased())
          }
        }
        if let agent = store.settings.taskAgent(.voiceover) {
          NavigationLink("Edit agent and model") {
            AgentEditorView(store: store, storeObservation: storeObservation, mode: .edit(agent.id))
          }
        }
        Button("Create Voiceover Agent", systemImage: "plus") {
          ensureDefaultPrompt()
          var agent = store.settings.addAgent(
            named: "Voiceover", description: "Short, conversational spoken summaries")
          agent.canSpawnSubagents = false
          agent.settings.defaultSystemPromptID = VoiceoverPromptBuilder.defaultPrompt.id
          agent.settings.defaultReasoningLevel = .disabled
          if let index = store.settings.agents.firstIndex(where: { $0.id == agent.id }) {
            store.settings.agents[index] = agent
          }
          store.settings.taskAgents.voiceover = agent.id.uuidString.lowercased()
          store.saveSettings()
          editingAgentID = agent.id
        }
      } header: {
        Text("Summary model")
      } footer: {
        Text(
          "Use a separate agent to choose Apple Intelligence, an on-device MLX model, or any configured provider. These settings apply to every chat with Voiceover enabled."
        )
      }

      Section {
        NavigationLink {
          SystemPromptDetailView(
            prompt: VoiceoverPromptBuilder.systemPrompt(settings: store.settings)
          )
          .environmentObject(store)
        } label: {
          LabeledContent(
            "System prompt",
            value: VoiceoverPromptBuilder.systemPrompt(settings: store.settings).displayName)
        }
      } footer: {
        Text(
          "After a reply finishes, voiceover summarizes it in one or two conversational sentences and reads them using the Assistant voice in Settings → Voices. The full written reply stays in the chat. Enable it with the Voiceover switch in Chat Settings."
        )
      }
    }
    .navigationTitle("Voiceover")
    .navigationBarTitleDisplayMode(.inline)
    .navigationDestination(item: $editingAgentID) { id in
      AgentEditorView(store: store, storeObservation: storeObservation, mode: .edit(id))
    }
    .onAppear(perform: ensureDefaultPrompt)
  }

  private var agentBinding: Binding<String> {
    Binding(
      get: { store.settings.taskAgents.voiceover ?? "" },
      set: {
        store.settings.taskAgents.voiceover = $0.isEmpty ? nil : $0
        store.saveSettings()
      })
  }

  private func ensureDefaultPrompt() {
    let prompt = VoiceoverPromptBuilder.defaultPrompt
    guard !store.settings.systemPrompts.contains(where: { $0.id == prompt.id }) else { return }
    store.settings.systemPrompts.append(prompt)
    store.saveSettings()
  }
}
