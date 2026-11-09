import AppKit
import MaiACP
import MaiCore
import SwiftUI

struct MacInspector: View {
  @Bindable var conversation: MacConversation
  @State private var task = ""

  var body: some View {
    Form {
      Section("Workspace") {
        LabeledContent("Host", value: conversation.hostName)
        Text(conversation.cwd).font(.caption).textSelection(.enabled)
      }
      Section("Session Settings") {
        ForEach(conversation.options) { option in
          if option.isBoolean {
            Toggle(option.name, isOn: Binding(get: { option.currentValue.boolValue ?? false },
              set: { conversation.setOption(option, value: .bool($0)) }))
          } else {
            Picker(option.name, selection: Binding(get: { option.currentValue.stringValue ?? "" },
              set: { conversation.setOption(option, value: .string($0)) })) {
              ForEach(option.choices) { choice in Text(choice.name).tag(choice.id) }
            }
          }
        }.disabled(conversation.busy || !conversation.connected)
      }
      if conversation.canManageAgents {
        Section("Subagents") {
          TextField("Describe a self-contained task…", text: $task, axis: .vertical).lineLimit(3...8)
          Button("Launch Subagent", systemImage: "person.badge.plus") {
            conversation.launchAgent(task)
            task = ""
          }.disabled(conversation.busy || task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Text("Uses this chat’s model, tools, and approval rules. Include the context the agent needs.")
            .font(.caption).foregroundStyle(.secondary)
          ForEach(conversation.agents) { agent in
            DisclosureGroup {
              ForEach(Array(agent.messages.enumerated()), id: \.offset) { _, message in
                VStack(alignment: .leading, spacing: 6) {
                  Text(message.role.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                  MacMarkdown(text: message.text)
                }.padding(.vertical, 5)
              }
              if let failure = agent.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
              if !agent.state.isTerminal {
                Button("Stop Agent", role: .destructive) { conversation.stopAgent(agent.pid) }
              }
            } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(agent.task.isEmpty ? agent.displayName : agent.task).lineLimit(2)
                Text("\(agent.pid.description) · \(agent.state.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
              }
            }
          }
        }
      }
    }
    .formStyle(.grouped)
    .task(id: conversation.id) {
      while !Task.isCancelled {
        await conversation.refreshAgents()
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
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
