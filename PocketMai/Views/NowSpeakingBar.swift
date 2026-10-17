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
      .background(.ultraThinMaterial)
    } else if ttsPlayer.isSpeaking {
      bar
        .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  private var bar: some View {
    HStack(spacing: 12) {
      Button {
        if ttsPlayer.isPaused {
          ttsPlayer.resume()
        } else {
          ttsPlayer.pause()
        }
      } label: {
        Image(systemName: ttsPlayer.isPaused ? "play.fill" : "pause.fill")
          .font(.system(size: 16, weight: .semibold))
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(ttsPlayer.isPaused ? "Resume" : "Pause")

      Button {
        if let id = ttsPlayer.currentMessageID { onTap(id) }
      } label: {
        VStack(alignment: .leading, spacing: 1) {
          HStack(spacing: 6) {
            Image(systemName: roleIcon)
              .font(.caption2)
              .foregroundStyle(.secondary)
            Text(roleLabel)
              .font(.caption.weight(.semibold))
              .foregroundStyle(.secondary)
            if ttsPlayer.isPaused {
              Text("• Paused")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
          if let snippet = ttsPlayer.currentText, !snippet.isEmpty {
            Text(snippet)
              .font(.caption)
              .foregroundStyle(.primary)
              .lineLimit(1)
              .truncationMode(.tail)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(ttsPlayer.currentMessageID == nil)

      Button {
        ttsPlayer.stop()
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 13, weight: .semibold))
          .frame(width: 30, height: 30)
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Stop")
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) {
      Divider()
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
