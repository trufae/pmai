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
      .modifier(FloatingGlassSurface(shape: RoundedRectangle(cornerRadius: 24)))
    } else if ttsPlayer.isSpeaking {
      bar
        .modifier(FloatingGlassSurface(shape: RoundedRectangle(cornerRadius: 24)))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private var bar: some View {
    HStack(spacing: 12) {
      Button { ttsPlayer.toggleMute() } label: {
        Image(systemName: ttsPlayer.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
          .foregroundStyle(.tint)
          .frame(width: 30, height: 36)
          .contentShape(Rectangle())
      }
      .accessibilityLabel(ttsPlayer.isMuted ? "Unmute" : "Mute")

      Menu {
        Picker(
          ttsPlayer.currentVoice?.provider == .openAICompatible ? "System Voice Language" : "Language",
          selection: Binding(
            get: {
              ttsPlayer.currentVoice?.provider == .openAICompatible
                ? "provider" : ttsPlayer.currentVoice?.language ?? ""
            },
            set: { if $0 != "provider" { ttsPlayer.changeLanguage($0) } })
        ) {
          if ttsPlayer.currentVoice?.provider == .openAICompatible {
            Text("Current Provider Voice").tag("provider")
          }
          Text("System Default").tag("")
          ForEach(SystemLanguageSupport.textToSpeechLanguageIdentifiers, id: \.self) { language in
            Text(SystemLanguageSupport.languageDisplayName(language)).tag(language)
          }
        }
        .pickerStyle(.menu)
        .disabled(!ttsPlayer.canChangeLanguage)

        Button("Rewind to Start", systemImage: "backward.end.fill") { ttsPlayer.rewind() }
        Button(
          ttsPlayer.isMuted ? "Unmute" : "Mute",
          systemImage: ttsPlayer.isMuted ? "speaker.wave.2" : "speaker.slash"
        ) { ttsPlayer.toggleMute() }
        if let messageID = ttsPlayer.currentMessageID {
          Button("Show Message", systemImage: "text.bubble") { onTap(messageID) }
        }
      } label: {
        HStack(spacing: 6) {
          VStack(alignment: .leading, spacing: 2) {
            Text(roleLabel + (ttsPlayer.isPaused ? " • Paused" : "")
              + (ttsPlayer.isMuted ? " • Muted" : ""))
              .font(.caption.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            if let text = ttsPlayer.currentText, !text.isEmpty {
              Text(text).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
      }
      .accessibilityLabel("Playback options")

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
    .buttonStyle(.plain)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var roleLabel: String {
    if let title = ttsPlayer.currentTitle, !title.isEmpty { return title }
    switch ttsPlayer.currentRole {
    case .user: return "User"
    case .assistant: return "Assistant"
    case .none: return "Speaking"
    }
  }
}
