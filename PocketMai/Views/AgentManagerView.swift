import MaiCore
import SwiftUI

/// Lists the agents, switches between them, and adds, edits, or removes them.
/// The stock agent stays so there is always one to select. Selecting an agent
/// makes the rest of Settings show and edit that agent's model, prompt, tools,
/// and MCP servers.
struct AgentManagerView: View {
  let store: AppStore
  @ObservedObject var storeObservation: AppStoreViewObservation
  @State private var showingNewAgent = false
  @State private var editingAgentID: UUID?
  @State private var pendingRemoval: AgentProfile?
  @State private var createdAgentID: UUID?

  var body: some View {
    List {
      Section {
        ForEach(store.settings.agents) { agent in
          row(for: agent)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              if !agent.isStock {
                Button(role: .destructive) {
                  pendingRemoval = agent
                } label: {
                  Label("Remove", systemImage: "trash")
                }
              }
              Button {
                editingAgentID = agent.id
              } label: {
                Label("Edit", systemImage: "pencil")
              }
              .tint(.orange)
            }
            .contextMenu {
              Button("Edit") { editingAgentID = agent.id }
              if !agent.isStock {
                Button("Remove", role: .destructive) { pendingRemoval = agent }
              }
            }
        }
      } header: {
        Text("Agents")
      } footer: {
        Text(
          "Tap an agent to select it; the provider, model, system prompt, tools, MCP servers, and advanced options in Settings then belong to it, and new chats start from it. \(AgentProfile.stockName) is always available. A new agent starts as a copy of the selected one."
        )
      }
      Section {
        ForEach(AgentTask.allCases, id: \.rawValue) { task in
          Picker(task == .compact ? "Compaction" : "Tool decisions", selection: taskBinding(task)) {
            Text("Current conversation agent").tag("")
            ForEach(store.settings.agents) { agent in
              Text(agent.name).tag(agent.id.uuidString.lowercased())
            }
          }
        }
      } header: {
        Text("Task agents")
      } footer: {
        Text(
          "Each task uses its agent's provider, model, prompt, and reasoning effort. Tool decisions use the conversation's allowed tools; the conversation agent writes the final answer. These defaults are saved for all chats."
        )
      }
      Section {
        Toggle("Plan before delegating", isOn: planBinding)
      } footer: {
        Text(
          "An agent that can spawn subagents opens a request of several steps with a short numbered plan — which steps go to child agents and which of those run in parallel — before its first agent_start; a single question gets no plan."
        )
      }
    }
    .navigationTitle("Agents")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showingNewAgent = true
        } label: {
          Label("Add Agent", systemImage: "plus")
        }
        .accessibilityLabel("Add agent")
      }
    }
    .navigationDestination(item: $editingAgentID) { id in
      AgentEditorView(store: store, storeObservation: storeObservation, mode: .edit(id))
    }
    .sheet(
      isPresented: $showingNewAgent,
      onDismiss: {
        if let id = createdAgentID {
          editingAgentID = id
          createdAgentID = nil
        }
      }
    ) {
      NavigationStack {
        AgentEditorView(store: store, storeObservation: storeObservation, mode: .create) { agent in
          createdAgentID = agent.id
        }
      }
    }
    .alert(
      "Remove agent?",
      isPresented: removalBinding,
      presenting: pendingRemoval
    ) { agent in
      Button("Cancel", role: .cancel) { pendingRemoval = nil }
      Button("Remove", role: .destructive) {
        store.removeAgent(agent.id)
        pendingRemoval = nil
      }
    } message: { agent in
      Text(
        "\u{201C}\(agent.name)\u{201D} and its settings will be removed. Existing chats keep the settings they already have."
      )
    }
  }

  private func row(for agent: AgentProfile) -> some View {
    HStack(spacing: 12) {
      Button {
        store.selectAgent(agent.id)
      } label: {
        HStack {
          VStack(alignment: .leading, spacing: 2) {
            Text(agent.name)
            if !agent.description.isEmpty {
              Text(agent.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            Text(summary(for: agent))
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if agent.id == store.settings.selectedAgentID {
            Image(systemName: "checkmark")
              .foregroundStyle(.tint)
              .accessibilityLabel("Selected")
          }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      Button {
        editingAgentID = agent.id
      } label: {
        Image(systemName: "info.circle")
          .foregroundStyle(.tint)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Edit \(agent.name)")
    }
  }

  /// One line naming the model and prompt an agent answers with, and whether
  /// it may start child agents.
  private func summary(for agent: AgentProfile) -> String {
    let settings = agent.settings
    let model: String
    switch settings.defaultProvider {
    case .apple:
      model = "Apple Intelligence"
    case .mlx:
      model = settings.localMLXModelID.isEmpty ? "MLX" : settings.localMLXModelID
    case .openAICompatible:
      if let endpoint = store.settings.openAIEndpoints.first(where: {
        $0.id == settings.selectedEndpointID
      }) {
        let name = endpoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName =
          (settings.openAIModelID.isEmpty ? endpoint.defaultModel : settings.openAIModelID)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        model = [name, modelName].filter { !$0.isEmpty }.joined(separator: " · ")
      } else {
        model = "No provider selected"
      }
    }
    let prompt =
      store.settings.systemPrompts.first(where: { $0.id == settings.defaultSystemPromptID })?.name
      ?? "No system prompt"
    var parts = [model, prompt]
    if agent.canSpawnSubagents {
      parts.append("Subagents")
    }
    return parts.joined(separator: " · ")
  }

  private func taskBinding(_ task: AgentTask) -> Binding<String> {
    Binding(
      get: { store.settings.taskAgents[task] ?? "" },
      set: { value in
        store.settings.taskAgents[task] = value.isEmpty ? nil : value
        store.saveSettings()
      })
  }

  private var planBinding: Binding<Bool> {
    Binding(
      get: { store.settings.plansBeforeDelegating },
      set: { value in
        store.settings.plansBeforeDelegating = value
        store.saveSettings()
      })
  }

  private var removalBinding: Binding<Bool> {
    Binding(
      get: { pendingRemoval != nil },
      set: { if !$0 { pendingRemoval = nil } })
  }
}

/// Edits what identifies an agent: its name, what it is for, and whether it
/// may start child agents. Creating copies the selected agent; editing saves
/// as the fields change without changing the default for new chats.
struct AgentEditorView: View {
  enum Mode: Equatable {
    case create
    case edit(UUID)
  }

  let store: AppStore
  @ObservedObject var storeObservation: AppStoreViewObservation
  let mode: Mode
  var onCreate: ((AgentProfile) -> Void)? = nil
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var description = ""
  @State private var canSpawnSubagents = false
  @State private var loaded = false
  @State private var modelFilter = ""

  private var isCreating: Bool { mode == .create }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $name)
          .textInputAutocapitalization(.words)
        TextField("Description", text: $description, axis: .vertical)
          .lineLimit(2...5)
        Toggle("Can spawn subagents", isOn: $canSpawnSubagents)
      } header: {
        Text("Agent")
      } footer: {
        Text(
          (isCreating
            ? "The new agent starts with the selected agent's model, prompt, tools, and MCP servers, and opens for editing without changing the default for new chats. "
            : "Edit its model and instructions below. Select it in the list to configure tools and MCP servers in Settings. ")
            + "An agent that can spawn subagents gets the agent_start, agent_status, agent_result, and agent_stop tools: it can hand a task to a worker with its own model and tools, or to any other agent by name, and only the answer comes back into the chat. Running subagents show in a bar above the composer, where they can be paused, messaged, or stopped."
        )
      }
      if case .edit(let id) = mode, let agent = store.settings.agents.first(where: { $0.id == id })
      {
        inferenceSection(agent)
      }
    }
    .navigationTitle(isCreating ? "New Agent" : "Edit Agent")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if isCreating {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Add") {
            let agent = store.addAgent(
              named: name, description: description, canSpawnSubagents: canSpawnSubagents)
            onCreate?(agent)
            dismiss()
          }
          .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .onAppear(perform: loadIfNeeded)
    .onChange(of: name) { _, _ in commitEdit() }
    .onChange(of: description) { _, _ in commitEdit() }
    .onChange(of: canSpawnSubagents) { _, _ in commitEdit() }
  }

  private func inferenceSection(_ agent: AgentProfile) -> some View {
    Section {
      Picker("Provider", selection: agentBinding(agent.id, \.defaultProvider)) {
        ForEach(ProviderKind.allCases) { provider in
          Text(provider.displayName).tag(provider)
        }
      }
      if agent.settings.defaultProvider == .openAICompatible {
        Picker("Connection", selection: agentBinding(agent.id, \.selectedEndpointID)) {
          Text("Choose a provider").tag(UUID?.none)
          ForEach(store.settings.openAIEndpoints) { endpoint in
            Text(endpoint.kind == .systemOne ? "\(endpoint.name) · System One" : endpoint.name).tag(
              Optional(endpoint.id))
          }
        }
        if let endpoint = store.settings.openAIEndpoints.first(where: {
          $0.id == agent.settings.selectedEndpointID
        }),
          endpoint.kind == .systemOne
        {
          FilteredModelPicker(
            selection: agentBinding(agent.id, \.openAIModelID), filter: $modelFilter,
            models: store.endpointModels[endpoint.id] ?? [], emptySelectionTitle: "Provider default"
          )
          .task(id: endpoint.connectionSignature) { await store.refreshEndpoint(endpoint) }
        }
        TextField(
          "Model (empty uses provider default)", text: agentBinding(agent.id, \.openAIModelID)
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      } else if agent.settings.defaultProvider == .mlx {
        TextField("On-device model", text: agentBinding(agent.id, \.localMLXModelID))
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
      }
      Picker("Reasoning effort", selection: agentBinding(agent.id, \.defaultReasoningLevel)) {
        ForEach(ReasoningLevel.allCases, id: \.rawValue) { level in
          Text(level.displayName).tag(level)
        }
      }
      Picker("System prompt", selection: agentBinding(agent.id, \.defaultSystemPromptID)) {
        ForEach(store.settings.systemPrompts) { prompt in
          Text(prompt.displayName).tag(prompt.id)
        }
      }
      Toggle("System One tool decisions", isOn: agentBinding(agent.id, \.useSystemOne))
      Picker("Tool format", selection: agentBinding(agent.id, \.toolCallingMode)) {
        ForEach(ToolCallingMode.allCases, id: \.rawValue) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
    } header: {
      Text("Model and instructions")
    } footer: {
      Text(
        "Connection URLs and credentials are shared and edited under Settings → Providers. Model, prompt, and reasoning belong to this agent. Changes are saved automatically."
      )
    }
  }

  private func agentBinding<Value>(_ id: UUID, _ key: WritableKeyPath<AgentSettings, Value>)
    -> Binding<Value>
  {
    Binding(
      get: {
        let profile =
          id == store.settings.selectedAgentID
          ? store.settings.agentSettings
          : store.settings.agents.first(where: { $0.id == id })?.settings ?? AgentSettings()
        return profile[keyPath: key]
      },
      set: { value in
        guard let index = store.settings.agents.firstIndex(where: { $0.id == id }) else { return }
        store.settings.agents[index].settings[keyPath: key] = value
        if id == store.settings.selectedAgentID {
          store.settings.agentSettings = store.settings.agents[index].settings
        }
        store.saveSettings()
      })
  }

  private func loadIfNeeded() {
    guard !loaded else { return }
    loaded = true
    guard case .edit(let id) = mode,
      let agent = store.settings.agents.first(where: { $0.id == id })
    else { return }
    name = agent.name
    description = agent.description
    canSpawnSubagents = agent.canSpawnSubagents
  }

  private func commitEdit() {
    guard loaded, case .edit(let id) = mode else { return }
    store.updateAgent(
      id, name: name, description: description, canSpawnSubagents: canSpawnSubagents)
  }
}
