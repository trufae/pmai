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
