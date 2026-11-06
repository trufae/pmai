import SwiftUI

struct AppleIntelligenceDetailView: View {
  @EnvironmentObject private var store: AppStore

  private var isDefaultProvider: Bool {
    store.settings.defaultProvider == .apple
  }

  var body: some View {
    Form {
      Section {
        Toggle(
          "Enabled",
          isOn: Binding(
            get: { store.settings.appleProviderEnabled },
            set: { enabled in
              store.settings.appleProviderEnabled = enabled
              store.saveSettings()
            }
          ))
        LabeledContent("Status", value: store.appleAvailabilityReport.statusLabel)
        Text(store.appleAvailabilityReport.detail)
          .foregroundStyle(.secondary)
        Button {
          store.refreshAppleIntelligenceAvailabilityInBackground()
        } label: {
          Label("Refresh Availability", systemImage: "arrow.clockwise")
        }
      } footer: {
        Text(
          "This switch controls whether the app offers Apple Intelligence. It must also be enabled in iOS settings and ready on this device."
        )
      }

      Section {
        Button {
          store.settings.defaultProvider = .apple
          store.saveSettings()
        } label: {
          Label(
            isDefaultProvider ? "Default Provider" : "Set as Default",
            systemImage: isDefaultProvider ? "checkmark.circle" : "star"
          )
        }
        .disabled(isDefaultProvider || !store.appleIntelligenceIsAvailable)
      } footer: {
        Text(
          store.appleIntelligenceIsAvailable
            ? "The default provider is used for new chats."
            : "Enable this provider and make sure Apple Intelligence is ready before setting it as the default."
        )
      }
    }
    .navigationTitle("Apple Intelligence")
    .navigationBarTitleDisplayMode(.inline)
  }
}
