import SwiftUI

@main
struct PocketMaiApp: App {
  @State private var store = AppStore()
  private let ttsPlayer = TTSPlayer.shared

  init() {
    SystemLanguageSupport.preload()
    ResponseNotificationService.shared.installDelegate()
  }

  var body: some Scene {
    WindowGroup {
      PocketMaiRootView(store: store, ttsPlayer: ttsPlayer)
        .onOpenURL { url in
          if url.isFileURL {
            store.openImportFile(at: url)
          } else if let command = PocketMaiDeepLink.command(from: url) {
            store.handleLaunchCommand(command)
          }
        }
    }
  }
}

private struct PocketMaiRootView: View {
  let store: AppStore
  let ttsPlayer: TTSPlayer
  @StateObject private var storeObservation = AppStoreViewObservation(scope: .application)

  var body: some View {
    ContentView(store: store)
        .environmentObject(store)
        .environmentObject(store.streamingTextStore)
        .environmentObject(ttsPlayer)
        .preferredColorScheme(store.settings.appearance.theme.colorScheme)
        .onAppear { storeObservation.connect(to: store) }
  }
}
