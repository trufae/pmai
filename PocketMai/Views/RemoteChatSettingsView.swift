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
          ForEach(chat.configurationOptions) { option in
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
      .refreshable { await chat.refreshConfiguration() }
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
