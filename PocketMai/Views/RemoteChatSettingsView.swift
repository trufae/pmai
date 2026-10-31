import MaiACP
import MaiCore
import SwiftUI

struct RemoteChatSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  let chat: RemoteAgentChat

  var body: some View {
    NavigationStack {
      Form {
        if !chat.connected {
          Button("Connect") { chat.connect() }
            .disabled(chat.busy || store.settings.isOffline)
        } else {
          let toolOptions = chat.remoteToolOptions
          if !toolOptions.isEmpty {
            Section("Tools") {
              NavigationLink {
                RemoteToolSettingsView(chat: chat)
              } label: {
                LabeledContent(
                  "Select Tools",
                  value: "\(chat.enabledRemoteToolCount)/\(max(0, toolOptions.count - 1)) enabled")
              }
            }
          }
          ForEach(chat.configurationOptions.filter {
            $0.id != "tools.enabled" && !$0.id.hasPrefix("tools.tool.")
          }) { option in
            if option.isBoolean {
              Toggle(
                option.name,
                isOn: Binding(
                  get: { option.currentValue.boolValue ?? false },
                  set: { chat.setConfigurationOption(id: option.id, value: .bool($0)) }))
            } else if chat.bookmark.backend == .openCode, option.id == "model" {
              NavigationLink {
                RemoteOpenCodeModelPicker(chat: chat)
              } label: {
                let current = option.currentValue.stringValue ?? ""
                LabeledContent(
                  option.name,
                  value: option.choices.first(where: { $0.id == current })?.name
                    ?? (current.isEmpty ? "Server default" : current))
              }
            } else {
              Picker(
                option.name,
                selection: Binding(
                  get: { option.currentValue.stringValue ?? "" },
                  set: { chat.setConfigurationOption(id: option.id, value: .string($0)) })
              ) {
                let current = option.currentValue.stringValue ?? ""
                if !option.choices.contains(where: { $0.id == current }) {
                  Text(current.isEmpty ? "Server default" : current).tag(current)
                    .disabled(true)
                }
                ForEach(option.choices) { choice in
                  Text(choice.group.map { "\($0) · \(choice.name)" } ?? choice.name).tag(choice.id)
                }
              }
              .pickerStyle(.navigationLink)
            }
          }
          .disabled(chat.busy || chat.settingsLoading || store.settings.isOffline)
          if chat.settingsLoading {
            ProgressView()
          } else if chat.configurationOptions.isEmpty, chat.settingsError == nil {
            Text("This host does not expose chat settings.").foregroundStyle(.secondary)
          }
        }
        if let error = chat.settingsError ?? chat.error {
          Text(error).foregroundStyle(.red)
          if chat.connected {
            Text("The host is still connected.").font(.footnote).foregroundStyle(.secondary)
          }
        }
      }
      .navigationTitle("Chat Settings")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
      .task(id: chat.connected) { await chat.refreshConfiguration() }
      .refreshable { await chat.refreshConfiguration(force: true) }
    }
  }
}

struct RemoteToolSettingsView: View {
  let chat: RemoteAgentChat

  var body: some View {
    ToolPickerContainer {
      if let enabled = chat.remoteToolsEnabled {
        Toggle(
          "Enable Tools",
          isOn: Binding(
            get: { enabled },
            set: { chat.setConfigurationOption(id: "tools.enabled", value: .bool($0)) })
        )
        .padding(.horizontal, 12).padding(.vertical, 9)
        .disabled(!chat.canSend || chat.settingsLoading)
        Divider()
      }
      RemoteToolPickerContent(chat: chat)
    }
    .navigationTitle("Select Tools")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// Remote groups use the same selection and disclosure rows as local MCP servers.
struct RemoteToolPickerContent: View {
  @EnvironmentObject private var store: AppStore
  let chat: RemoteAgentChat
  @State private var expandedGroups: Set<String> = []

  private var unavailable: Bool {
    !chat.canSend || chat.settingsLoading || chat.remoteToolsEnabled != true
  }

  private var groups: [(name: String, options: [RemoteSessionOption])] {
    let options = chat.remoteToolOptions.filter { $0.id != "tools.enabled" }
    let grouped = Dictionary(grouping: options) {
      $0.category?.split(separator: "/", maxSplits: 1).last.map(String.init) ?? "Other"
    }
    return grouped.keys.sorted().map { name in
      (name, (grouped[name] ?? []).sorted { $0.name < $1.name })
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(groups, id: \.name) { group in
        let enabledCount = group.options.filter { $0.currentValue.boolValue == true }.count
        let expanded = expandedGroups.contains(group.name)
        ToolPickerGroupRow(
          title: group.name,
          systemImage: groupIcon(group.name),
          isEnabled: enabledCount == group.options.count,
          isPartiallyEnabled: enabledCount > 0 && enabledCount < group.options.count,
          isExpanded: expanded, itemCount: group.options.count,
          toggle: {
            let enabled = enabledCount != group.options.count
            chat.setConfigurationOptions(
              group.options.filter {
                $0.currentValue.boolValue != enabled
              }.map { (id: $0.id, value: .bool(enabled)) })
          },
          expand: {
            withAnimation(.snappy) {
              if expanded {
                expandedGroups.remove(group.name)
              } else {
                expandedGroups.insert(group.name)
              }
            }
          }
        )
        .disabled(unavailable).opacity(unavailable ? 0.5 : 1)
        if expanded {
          ForEach(group.options) { option in
            ToolSelectionRow(
              title: option.name, detail: option.description,
              isEnabled: option.currentValue.boolValue == true, isUnavailable: unavailable
            ) {
              chat.setConfigurationOption(
                id: option.id, value: .bool(option.currentValue.boolValue != true))
            }
            .font(.callout).padding(.leading, 26)
          }
        }
      }
      if chat.settingsLoading {
        ProgressView().frame(maxWidth: .infinity).padding(12)
      } else if !chat.connected {
        Button("Connect", systemImage: "network") { chat.connect() }
          .padding(12).disabled(chat.busy || store.settings.isOffline)
      } else if chat.remoteToolsEnabled == nil {
        Text("This host manages its own tools. Update pmai to choose tools for this chat.")
          .font(.callout).foregroundStyle(.secondary).padding(12)
      }
      if let error = chat.settingsError {
        Text(error).font(.callout).foregroundStyle(.red).padding(12)
      }
    }
    .disabled(store.settings.isOffline)
    .task(id: chat.connected) { await chat.refreshConfiguration() }
  }

  private func groupIcon(_ name: String) -> String {
    if let tool = BuiltInToolID.allCases.first(where: { $0.displayName == name }) {
      return tool.systemImage
    }
    switch name.lowercased() {
    case "run", "pmai commands": return "terminal"
    case "agents", "subagents": return "person.2"
    default: return "wrench.and.screwdriver"
    }
  }
}

private struct RemoteOpenCodeModelPicker: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  @State private var search = ""
  @FocusState private var searchFocused: Bool
  let chat: RemoteAgentChat

  private var option: RemoteSessionOption? {
    chat.configurationOptions.first { $0.id == "model" }
  }

  var body: some View {
    let current = option?.currentValue.stringValue ?? ""
    let choices = option?.choices ?? []
    let matches = choices.filter { SidebarSearch.matches(search, in: [$0.name]) }
    let currentName = current.isEmpty ? "Server default" : current
    let showUnavailableCurrent = !choices.contains { $0.id == current }
      && SidebarSearch.matches(search, in: [currentName])
    List {
      if showUnavailableCurrent {
        Text(currentName).foregroundStyle(.secondary)
      }
      ForEach(matches) { choice in
        Button {
          chat.setConfigurationOption(id: "model", value: .string(choice.id))
          dismiss()
        } label: {
          HStack {
            Text(choice.name).foregroundStyle(.primary)
            Spacer()
            if choice.id == current {
              Image(systemName: "checkmark").foregroundStyle(.tint)
            }
          }
        }
        .accessibilityAddTraits(choice.id == current ? .isSelected : [])
        .disabled(!chat.connected || chat.busy || chat.settingsLoading || store.settings.isOffline)
      }
    }
    .overlay {
      if matches.isEmpty && !showUnavailableCurrent {
        ContentUnavailableView.search(text: search)
      }
    }
    .navigationTitle(option?.name ?? "Model")
    .navigationBarTitleDisplayMode(.inline)
    .scrollDismissesKeyboard(.interactively)
    .safeAreaInset(edge: .bottom) {
      FloatingSearchField(text: $search, isFocused: $searchFocused, placeholder: "Filter models") {
        search = ""
        searchFocused = false
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 12)
    }
  }
}
