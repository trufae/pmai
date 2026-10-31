import SwiftUI

struct NowSpeakingBar: View {
  @EnvironmentObject private var ttsPlayer: TTSPlayer
  let onTap: (UUID) -> Void

  var body: some View {
    if let error = ttsPlayer.errorMessage {
      HStack {
        Label(error, systemImage: "exclamationmark.triangle")
          .font(.caption)
          .frame(maxWidth: .infinity, alignment: .leading)
        Button("Dismiss") { ttsPlayer.dismissError() }
      }
      .padding(12)
    } else if ttsPlayer.isSpeaking {
      bar
        .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private var bar: some View {
    ChatTitleBar(
      title: roleLabel + (ttsPlayer.isPaused ? " • Paused" : ""),
      subtitle: ttsPlayer.currentText, systemImage: roleIcon,
      onTap: ttsPlayer.currentMessageID.map { id in { onTap(id) } }
    ) {
      Button {
        if ttsPlayer.isPaused { ttsPlayer.resume() } else { ttsPlayer.pause() }
      } label: {
        Image(systemName: ttsPlayer.isPaused ? "play.fill" : "pause.fill")
          .frame(width: 30, height: 30)
      }
      .accessibilityLabel(ttsPlayer.isPaused ? "Resume" : "Pause")
      Button { ttsPlayer.stop() } label: {
        Image(systemName: "xmark").frame(width: 30, height: 30)
      }
      .accessibilityLabel("Stop")
    }
  }

  private var roleLabel: String {
    if let title = ttsPlayer.currentTitle, !title.isEmpty { return title }
    switch ttsPlayer.currentRole {
    case .user: return "User"
    case .assistant: return "Assistant"
    case .none: return "Speaking"
    }
  }

  private var roleIcon: String {
    switch ttsPlayer.currentRole {
    case .user: return "person.wave.2"
    case .assistant, .none: return "speaker.wave.2"
    }
  }
}
