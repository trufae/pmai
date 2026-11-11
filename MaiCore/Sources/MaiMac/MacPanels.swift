import AppKit
import MaiACP
import MaiCore
import SwiftUI

struct MacInspector: View {
  @Bindable var conversation: MacConversation
  @State private var task = ""
  @State private var toolSearch = ""
  @State private var edit: MacAgentEdit?
  @State private var deleting: AgentDefinition?

  private var agentOption: RemoteSessionOption? {
    conversation.options.first { $0.category == "agent" || $0.id == "agent" || $0.category == "mode" }
  }
  private var toolOptions: [RemoteSessionOption] {
    conversation.options.filter { $0.id.hasPrefix("tools.") || $0.category == "tools" || $0.category?.hasPrefix("tools/") == true }
  }
  private var modelOptions: [RemoteSessionOption] {
    conversation.options.filter { $0.id != agentOption?.id && !toolOptions.contains($0) }
  }
  private var unavailable: Bool { conversation.busy || !conversation.connected }

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          if let option = agentOption { optionControl(option) }
          else { Text("Agent").font(.headline); Spacer() }
          if conversation.canEditAgentProfiles {
            Button { editAgent(creating: true) } label: { Image(systemName: "plus") }
              .buttonStyle(.borderless).help("New agent from this chat’s settings")
              .accessibilityLabel("New Agent")
            Menu {
              Button("Edit Agent…", systemImage: "pencil") { editAgent(creating: false) }
                .disabled(savedAgent == nil)
              Divider()
              Button("Delete Agent…", systemImage: "trash", role: .destructive) { deleting = savedAgent }
                .disabled(savedAgent == nil || (conversation.agentProfiles?.agents.filter(\.isEnabled).count ?? 0) < 2)
            } label: { Image(systemName: "ellipsis.circle") }
              .menuStyle(.borderlessButton).fixedSize().help("Create and manage agents")
              .accessibilityLabel("Manage agents")
          }
        }
        if let current = conversation.agentProfiles?.current, !current.description.isEmpty {
          Text(current.description).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }
        Text("Settings below apply to this chat.").font(.caption).foregroundStyle(.secondary)
        if let savedAgent, let current = conversation.agentProfiles?.current, current != savedAgent {
          Button("Save to Agent…", systemImage: "square.and.arrow.down") { editAgent(creating: false) }
            .font(.caption)
        }
      }.padding(16).disabled(unavailable)
      Divider()
      Form {
        Section("Model & Reasoning") {
          ForEach(modelOptions) { option in
            if option.category == "thought_level" || ["reasoning", "reasoning_effort", "effort"].contains(option.id),
              option.choices.count > 1 {
              MacReasoningSlider(option: option) { conversation.setOption(option, value: .string($0)) }
            } else { optionControl(option) }
          }
        }.disabled(unavailable)
        if let current = conversation.agentProfiles?.current {
          Section {
            DisclosureGroup("Prompt") {
              Text(current.instructions.isEmpty ? "No system prompt" : current.instructions)
                .font(.callout).foregroundStyle(current.instructions.isEmpty ? .secondary : .primary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
              Button("Edit Agent Prompt…") { editAgent(creating: false) }
                .disabled(unavailable || savedAgent == nil)
            }
          }
        }
        if !toolOptions.isEmpty {
          Section {
            DisclosureGroup {
              ForEach(toolOptions.filter { $0.category?.hasPrefix("tools/") != true && !$0.id.hasPrefix("tools.tool.") }) {
                optionControl($0)
              }
              TextField("Find a tool", text: $toolSearch).textFieldStyle(.roundedBorder)
              let tools = toolOptions.filter {
                ($0.id.hasPrefix("tools.tool.") || $0.category?.hasPrefix("tools/") == true)
                  && (toolSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(toolSearch)
                    || ($0.description?.localizedCaseInsensitiveContains(toolSearch) ?? false))
              }
              ForEach(toolGroups(tools), id: \.self) { group in
                Text(group).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 8)
                ForEach(tools.filter { toolGroup($0) == group }) { option in
                  optionControl(option).help(option.description ?? option.name)
                    .disabled(toolOptions.first(where: { $0.id == "tools.enabled" })?.currentValue.boolValue == false)
                }
              }
              if tools.isEmpty { Text("No matching tools").font(.caption).foregroundStyle(.secondary) }
            } label: {
              HStack {
                Text("Tools")
                Spacer()
                Text("\(toolOptions.filter { $0.id.hasPrefix("tools.tool.") && $0.currentValue.boolValue == true }.count) enabled")
                  .font(.caption).foregroundStyle(.secondary)
              }
            }
          }.disabled(unavailable)
        }
        if conversation.canManageAgents {
          Section {
            DisclosureGroup {
              TextField("Describe a self-contained task…", text: $task, axis: .vertical).lineLimit(3...8)
              Button("Launch Subagent", systemImage: "person.badge.plus") {
                conversation.launchAgent(task)
                task = ""
              }.disabled(unavailable || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
              Text("Uses this chat’s model, tools, and approval rules.").font(.caption).foregroundStyle(.secondary)
              ForEach(conversation.agents) { agent in
                DisclosureGroup {
                  ForEach(Array(agent.messages.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 6) {
                      Text(message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                      MacMarkdown(text: message.text, role: message.role.rawValue)
                    }.padding(.vertical, 5)
                  }
                  if let failure = agent.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
                  if !agent.state.isTerminal {
                    Button("Stop Agent", role: .destructive) { conversation.stopAgent(agent.pid) }
                  }
                } label: {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(agent.task.isEmpty ? agent.displayName : agent.task).lineLimit(2)
                    Text(agent.state.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                  }
                }
              }
            } label: {
              HStack {
                Text("Subagents")
                Spacer()
                if !conversation.agents.isEmpty {
                  Text("\(conversation.agents.filter { !$0.state.isTerminal }.count) running")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }
        Section {
          DisclosureGroup("Workspace") {
            LabeledContent("Host", value: conversation.hostName)
            Text(conversation.cwd).font(.caption).textSelection(.enabled)
          }
        }
      }.formStyle(.grouped)
    }
    .sheet(item: $edit) { MacAgentEditor(conversation: conversation, edit: $0) }
    .alert("Delete agent?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
      Button("Delete Agent", role: .destructive) {
        if let deleting { conversation.deleteAgentProfile(deleting.id) }
        deleting = nil
      }
      Button("Cancel", role: .cancel) { deleting = nil }
    } message: {
      Text("Remove \(deleting?.displayName ?? "this agent") from saved agents? Existing chats keep their settings. Task assignments using this agent will return to the conversation agent.")
    }
    .task(id: conversation.id) {
      while !Task.isCancelled {
        await conversation.refreshAgents()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
  }

  private var savedAgent: AgentDefinition? {
    guard let profiles = conversation.agentProfiles else { return nil }
    return profiles.agents.first { $0.id == profiles.current.id }
  }

  private func editAgent(creating: Bool) {
    guard var agent = conversation.agentProfiles?.current else { return }
    if creating {
      agent.id = "agent-" + UUID().uuidString.lowercased()
      agent.displayName = "New Agent"
      agent.systemPrompt = agent.id
      agent.description = ""
    }
    edit = .init(agent: agent, creating: creating)
  }

  private func toolGroup(_ option: RemoteSessionOption) -> String {
    option.category?.hasPrefix("tools/") == true ? String(option.category!.dropFirst(6)) : "Other"
  }

  private func toolGroups(_ options: [RemoteSessionOption]) -> [String] {
    Array(Set(options.map(toolGroup))).sorted()
  }

  @ViewBuilder private func optionControl(_ option: RemoteSessionOption) -> some View {
    if option.isBoolean {
      Toggle(option.name, isOn: Binding(get: { option.currentValue.boolValue ?? false },
        set: { conversation.setOption(option, value: .bool($0)) }))
    } else {
      Picker(option.name, selection: Binding(get: { option.currentValue.stringValue ?? "" },
        set: { conversation.setOption(option, value: .string($0)) })) {
        let groups = option.choices.reduce(into: [String]()) { groups, choice in
          if let group = choice.group, !groups.contains(group) { groups.append(group) }
        }
        ForEach(option.choices.filter { $0.group == nil }) { choice in Text(choice.name).tag(choice.id) }
        ForEach(groups, id: \.self) { group in
          Section(group) {
            ForEach(option.choices.filter { $0.group == group }) { choice in Text(choice.name).tag(choice.id) }
          }
        }
      }.pickerStyle(.menu)
    }
  }
}

private struct MacReasoningSlider: View {
  let option: RemoteSessionOption
  let commit: (String) -> Void
  @State private var position = 0.0

  private var index: Int { min(max(Int(position.rounded()), 0), option.choices.count - 1) }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Reasoning effort")
        Spacer()
        Text(option.choices[index].name.capitalized).foregroundStyle(.secondary)
      }
      Slider(value: $position, in: 0...Double(option.choices.count - 1), step: 1) { editing in
        if !editing, option.currentValue.stringValue != option.choices[index].id { commit(option.choices[index].id) }
      }
      .accessibilityLabel("Reasoning effort")
      .accessibilityValue(option.choices[index].name)
      HStack {
        Text(option.choices.first?.name.capitalized ?? "")
        Spacer()
        Text(option.choices.last?.name.capitalized ?? "")
      }.font(.caption).foregroundStyle(.secondary)
    }
    .onChange(of: option, initial: true) { _, value in
      position = Double(value.choices.firstIndex { $0.id == value.currentValue.stringValue } ?? 0)
    }
  }
}

struct MacPermissionSheet: View {
  @Bindable var conversation: MacConversation

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Permission Required", systemImage: "hand.raised").font(.title2.weight(.semibold))
      Text("\(conversation.hostName) · \(conversation.title)").foregroundStyle(.secondary)
      if let request = conversation.permission?.objectValue {
        let tool = request["toolCall"]?.objectValue
        Text(tool?["title"]?.stringValue ?? "The agent is requesting permission to continue.").font(.headline)
        if let input = tool?["rawInput"], let data = try? JSONEncoder().encode(input),
          let text = String(data: data, encoding: .utf8) {
          ScrollView { Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            .frame(maxHeight: 240)
        }
        HStack {
          Button("Cancel", role: .cancel) { conversation.answerPermission(nil) }.keyboardShortcut(.cancelAction)
          Spacer()
          ForEach(Array((request["options"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, option in
            if let fields = option.objectValue, let id = fields["optionId"]?.stringValue {
              Button(fields["name"]?.stringValue ?? id) { conversation.answerPermission(id) }
            }
          }
        }
      }
    }.padding(24).frame(width: 560)
  }
}

struct MacConnectionSheet: View {
  @Bindable var workspace: MacWorkspace
  @Environment(\.dismiss) private var dismiss
  @State private var invitation = ""
  @State private var name = ""
  @State private var connecting = false
  @State private var error: String?
  @State private var operation: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Label("Connect to a Host", systemImage: "network").font(.title2.weight(.semibold))
      Text("Paste a pairing link or connection profile from pmai’s /remote command, or an OpenCode pairing link.")
        .foregroundStyle(.secondary)
      TextField("Name (optional)", text: $name)
      SecureField("Pairing link or profile", text: $invitation)
      if connecting {
        HStack { ProgressView().controlSize(.small); Text("Connecting… Approve the device on your host if requested.") }
      }
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Button("Cancel") { operation?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button("Connect") {
          connecting = true
          error = nil
          operation = Task {
            do {
              try await workspace.pair(invitation, name: name)
              try Task.checkCancellation()
              dismiss()
              await workspace.refresh()
            } catch { self.error = error.localizedDescription }
            connecting = false
          }
        }.keyboardShortcut(.defaultAction).disabled(connecting || invitation.isEmpty)
      }
    }.textFieldStyle(.roundedBorder).padding(24).frame(width: 540)
      .onDisappear { operation?.cancel() }
  }
}
