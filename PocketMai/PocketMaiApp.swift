import MaiCore
import SwiftUI

@main
@MainActor
struct PocketMaiApp: App {
  static let sharedStore = AppStore()

  private var store: AppStore { Self.sharedStore }
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
  @Environment(\.scenePhase) private var scenePhase
  @AppStorage(AwakeController.preferenceKey) private var keepAwake = false
  @StateObject private var storeObservation = AppStoreViewObservation(scope: .application)

  var body: some View {
    ContentView(store: store)
        .environmentObject(store)
        .environmentObject(store.streamingTextStore)
        .environmentObject(ttsPlayer)
        .preferredColorScheme(store.settings.appearance.theme.colorScheme)
        .onAppear {
          storeObservation.connect(to: store)
          updateAwake()
        }
        .onChange(of: keepAwake, initial: true) { _, _ in updateAwake() }
        .onChange(of: scenePhase) { _, _ in updateAwake() }
        .onDisappear { try? AwakeController.shared.setEnabled(false) }
  }

  private func updateAwake() {
    try? AwakeController.shared.setEnabled(keepAwake && scenePhase == .active)
  }
}
