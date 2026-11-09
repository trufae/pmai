import MaiACP
import MaiCore
import SwiftUI

struct PebbleSettingsView: View {
  private static let favoritesKey = "pebble.favoritePromptIDs"
  static var favoriteIDs: Set<UUID> {
    CarPlayFavorites.ids(from: UserDefaults.standard.string(forKey: favoritesKey) ?? "")
  }

  let bridge: PebbleBridge
  let prompts: [UserPrompt]
  @AppStorage(PebbleSettingsView.favoritesKey) private var favorites = ""

  var body: some View {
    let selected = CarPlayFavorites.ids(from: favorites)
    let active = prompts.filter { selected.contains($0.id) && !$0.message(arguments: "").isEmpty }
    Form {
      Section {
        Toggle("Enable Pebble", isOn: Binding(get: { bridge.enabled }, set: bridge.setEnabled))
        if !bridge.error.isEmpty { Text(bridge.error) }
        if bridge.paired {
          Button("Forget Watch", role: .destructive) { bridge.unpair() }
        } else if let code = bridge.pairingCode {
          Text("Watch code: \(code)").monospacedDigit()
          Button("Confirm Matching Code") { bridge.approvePairing() }
          Button("Start Over") { bridge.beginPairing() }
        } else if bridge.pairing {
          Text("Select Pair Phone on the watch.")
        } else {
          Button("Pair a Watch") { bridge.beginPairing() }.disabled(!bridge.listening)
        }
      } footer: {
        Text("Keep PocketMai open while using the watch. Enable Keep Awake to prevent the screen from locking.")
      }
      Section("Favorite Prompts") {
        if prompts.isEmpty { Text("Add a user prompt in Settings to send it from your watch.") }
        ForEach(prompts) { prompt in
          Toggle(prompt.displayName, isOn: Binding(get: { selected.contains(prompt.id) }, set: { enabled in
            var ids = selected.intersection(prompts.map(\.id))
            if enabled { ids.insert(prompt.id) } else { ids.remove(prompt.id) }
            favorites = ids.map(\.uuidString).sorted().joined(separator: ",")
          }))
          .disabled(prompt.message(arguments: "").isEmpty
            || (!selected.contains(prompt.id) && active.count >= PebbleBridge.presetLimit))
        }
      }
    }
    .navigationTitle("Pebble")
  }
}
