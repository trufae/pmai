import MaiCore
import SwiftUI

@MainActor
private func settingsToolCatalog(_ store: AppStore) -> AgentToolCatalog {
  var conversation = store.currentConversation ?? Conversation()
  conversation.toolsEnabled = true
  conversation.enabledTools = store.settings.defaultEnabledTools
  conversation.enabledMCPServers = store.settings.defaultEnabledMCPServers
  conversation.enabledMCPTools = store.settings.defaultEnabledMCPTools
  return ToolAgentRegistry.catalog(
    for: conversation, settings: store.settings, mcpTools: store.mcpTools,
    mcpResources: store.mcpResources, mcpStatuses: store.mcpStatuses)
}

/// Reused beside each native group and at the top of the tool settings.
struct ToolCatalogSettingsButton: View {
  @EnvironmentObject private var store: AppStore
  var groupID: String? = nil
  @State private var showingCatalog = false

  var body: some View {
    let catalog = settingsToolCatalog(store)
    let group = catalog.groups.first { $0.catalogID == groupID }
    let summary = catalog.summary(for: group)
    Button {
      showingCatalog = true
    } label: {
      if groupID == nil {
        Label("Tool list (\(summary.enabled)/\(summary.total) enabled)", systemImage: "list.bullet")
      } else {
        Text("\(summary.enabled)/\(summary.total)")
          .font(.caption.monospacedDigit())
      }
    }
    .buttonStyle(.borderless)
    .accessibilityLabel(groupID == nil ? "Tool list" : "\(group?.displayName ?? "Group") tool list")
    .accessibilityValue("\(summary.enabled) of \(summary.total) enabled")
    .sheet(isPresented: $showingCatalog) {
      ToolCatalogSettingsView(groupID: groupID)
    }
  }
}

struct ToolCatalogSettingsView: View {
  @EnvironmentObject private var store: AppStore
  @Environment(\.dismiss) private var dismiss
  var groupID: String? = nil
  @State private var search = ""

  var body: some View {
    let catalog = settingsToolCatalog(store)
    NavigationStack {
      List {
        Section {
          Text("Tools for \(store.settings.selectedAgent.name)")
          Text(
            "Inherit follows the enabled group and proxy default. Individual choices override groups. Access settings and server connections are still required."
          )
          .font(.caption).foregroundStyle(.secondary)
          Toggle(
            "Proxy by default",
            isOn: Binding(
              get: { store.settings.useToolProxy },
              set: {
                store.settings.useToolProxy = $0
                store.saveSettings()
              }))
        }
        ForEach(
          catalog.groups.filter { group in
            (groupID == nil || group.catalogID == groupID)
              && (search.isEmpty || group.displayName.localizedCaseInsensitiveContains(search)
                || catalog.definitions(in: group).contains(where: matchesSearch))
          }, id: \.catalogID
        ) { group in
          Section {
            policyPicker(
              "Group default",
              selection: Binding(
                get: { store.settings.toolPolicy.groupMode(for: group)?.rawValue ?? "inherit" },
                set: {
                  store.settings.toolPolicy.setGroupMode(AgentToolMode(rawValue: $0), for: group)
                  store.saveSettings()
                }))
            ForEach(
              catalog.definitions(in: group).filter { tool in
                search.isEmpty || group.displayName.localizedCaseInsensitiveContains(search)
                  || matchesSearch(tool)
              }, id: \.name
            ) { tool in
              VStack(alignment: .leading, spacing: 5) {
                policyPicker(
                  tool.name,
                  selection: Binding(
                    get: { store.settings.toolPolicy.tools[tool.name]?.rawValue ?? "inherit" },
                    set: {
                      store.settings.toolPolicy.tools[tool.name] = AgentToolMode(rawValue: $0)
                      store.saveSettings()
                    }))
                Text("Currently \(catalog.modes[tool.name, default: .disabled].displayName)")
                  .font(.caption).foregroundStyle(.secondary)
                if !tool.description.isEmpty {
                  Text(tool.description).font(.caption).foregroundStyle(.secondary)
                }
                if !tool.parameters.isEmpty {
                  DisclosureGroup("Arguments") {
                    ForEach(tool.parameters, id: \.name) { parameter in
                      Text(
                        "\(parameter.name): \(parameter.type)\(parameter.required ? " (required)" : "") — \(parameter.description)"
                      )
                      .font(.caption).foregroundStyle(.secondary)
                    }
                  }
                }
              }
            }
            if group.toolNames.isEmpty {
              Text(
                "No callable tools available. Check this group's access settings or refresh its connection."
              )
              .font(.caption).foregroundStyle(.secondary)
            }
          } header: {
            Text(
              "\(group.displayName) · \(catalog.summary(for: group).enabled)/\(group.toolNames.count) enabled"
            )
          } footer: {
            Text(catalog.summary(for: group).description)
          }
        }
      }
      .navigationTitle("Tool list")
      .navigationBarTitleDisplayMode(.inline)
      .searchable(text: $search, prompt: "Tool name or description")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
  }

  private func matchesSearch(_ tool: ToolDefinition) -> Bool {
    tool.name.localizedCaseInsensitiveContains(search)
      || tool.description.localizedCaseInsensitiveContains(search)
  }

  private func policyPicker(_ title: String, selection: Binding<String>) -> some View {
    Picker(title, selection: selection) {
      Text("Inherit").tag("inherit")
      ForEach(AgentToolMode.allCases, id: \.rawValue) { mode in
        Text(mode.displayName).tag(mode.rawValue)
      }
    }
    .pickerStyle(.menu)
  }
}
