import AVFoundation
import MaiCore
import Speech
import SwiftUI
import UIKit

enum CarPlayFavorites {
  static let key = "carPlay.favoritePromptIDs"

  static func ids(from value: String) -> Set<UUID> {
    Set(value.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
  }
}

struct CarPlayFavoritesView: View {
  let prompts: [UserPrompt]
  @AppStorage(CarPlayFavorites.key) private var favoriteIDs = ""
  @State private var microphonePermission = AVAudioApplication.shared.recordPermission
  @State private var speechPermission = SFSpeechRecognizer.authorizationStatus()
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    Form {
      Section {
        if microphonePermission != .granted {
          Button("Enable Microphone Access") {
            if microphonePermission == .denied {
              if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } else {
              Task {
                _ = await AVAudioApplication.requestRecordPermission()
                microphonePermission = AVAudioApplication.shared.recordPermission
              }
            }
          }
        }
        if speechPermission == .notDetermined {
          Button("Enable Speech Recognition") {
            SFSpeechRecognizer.requestAuthorization { status in
              Task { @MainActor in speechPermission = status }
            }
          }
        } else if speechPermission == .denied {
          Button("Open Speech Recognition Settings") {
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
          }
        }
        if prompts.isEmpty { Text("Add a user prompt to mark it as a CarPlay favorite.") }
        ForEach(prompts) { prompt in
          Toggle(prompt.displayName, isOn: favoriteBinding(for: prompt.id))
            .disabled(prompt.message(arguments: "").isEmpty)
        }
      } footer: {
        Text("Favorites appear in PocketMai on CarPlay and play the agent’s reply aloud.")
      }
    }
    .navigationTitle("CarPlay")
    .onChange(of: scenePhase) { _, phase in
      guard phase == .active else { return }
      microphonePermission = AVAudioApplication.shared.recordPermission
      speechPermission = SFSpeechRecognizer.authorizationStatus()
    }
  }

  private func favoriteBinding(for id: UUID) -> Binding<Bool> {
    Binding(
      get: { CarPlayFavorites.ids(from: favoriteIDs).contains(id) },
      set: { enabled in
        var ids = CarPlayFavorites.ids(from: favoriteIDs)
        if enabled { ids.insert(id) } else { ids.remove(id) }
        favoriteIDs = ids.map(\.uuidString).sorted().joined(separator: ",")
      })
  }
}
