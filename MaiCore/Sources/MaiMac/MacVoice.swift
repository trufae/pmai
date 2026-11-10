import Foundation
import MaiCore
import MaiVoice
import Observation
import SwiftUI

/// Audio stays on this Mac even when the chat is connected to a remote host.
@MainActor @Observable
final class MacVoice {
  enum Mode: String, CaseIterable {
    case dictation = "Dictation", conversation = "Voice Conversation", walkieTalkie = "Walkie-talkie"
  }
  private(set) var mode = Mode.dictation
  private(set) var state = VoiceSession.State.off
  private(set) var transcript = ""
  private(set) var error: String?
  private var session: VoiceSession?
  private var setup: Task<Void, Never>?
  private var generation = UUID()
  private static weak var active: MacVoice?
  var isActive: Bool { state != .off }
  static func stopActive() { active?.stop() }

  /// These commands remain usable while a response is running, like the CLI.
  func handleCommand(_ text: String, in conversation: MacConversation) -> Bool {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines).split(whereSeparator: \.isWhitespace)
    guard words.first?.lowercased() == "/voice" else { return false }
    let command = words.dropFirst().joined(separator: " ").lowercased()
    switch command {
    case "off", "stop": stop()
    case "pause": pause()
    case "discard", "cancel": session?.discard()
    case "send": finishCapture()
    case "resume", "record":
      if isActive, state != .error { resume() }
      else if !conversation.busy { start(.conversation, in: conversation) }
    case "" where isActive: stop()
    case "", "on", "realtime", "walkie-talkie", "walkie", "ptt", "dictate", "dictation":
      guard !conversation.busy, conversation.connected else {
        conversation.error = "Start voice when this chat is connected and its current response has finished."
        return true
      }
      let mode: Mode = ["dictate", "dictation"].contains(command) ? .dictation
        : ["walkie-talkie", "walkie", "ptt"].contains(command) ? .walkieTalkie : .conversation
      start(mode, in: conversation)
    default:
      conversation.error = "/voice [on | off | realtime | walkie-talkie | dictate | pause | resume | send | discard]. Control-Space records/sends, Control-T sends, Control-G discards."
    }
    return true
  }

  func toggleCapture(in conversation: MacConversation) {
    if !isActive { _ = handleCommand("/voice on", in: conversation) }
    else if state == .listening { finishCapture() }
    else if !conversation.busy { resume() }
  }
  func discard() { session?.discard() }

  static func configuration(for conversation: MacConversation) throws -> MaiConfiguration {
    let global = AgentHome.expandUserPath("~/.config/pmai/config.json")
    let paths = conversation.hostID == nil ? [conversation.cwd + "/pmai.json", global] : [global]
    for path in paths where FileManager.default.fileExists(atPath: path) {
      return try MaiConfiguration.load(from: URL(fileURLWithPath: path))
    }
    return .init()
  }

  func start(_ mode: Mode, in conversation: MacConversation) {
    stop()
    MacWebXDCNative.stopActiveAudio()
    Self.active?.stop()
    Self.active = self
    self.mode = mode
    state = .starting
    let generation = generation
    setup = Task { [weak self, weak conversation] in
      guard let self, let conversation else { return }
      do {
        let configuration = try Self.configuration(for: conversation)
        var settings = configuration.voice
        settings.mode = mode == .conversation ? .realtime : .walkieTalkie
        let registry = PluginRegistry()
        try await registry.install(MaiVoicePlugin())
        let environment = ProcessInfo.processInfo.environment
        let input = try await registry.voiceFactory(kind: settings.input)
          .makeInput(settings: settings, configuration: configuration, environment: environment)
        let output: any VoiceOutputProvider
        if mode == .dictation { output = MacSilentVoiceOutput() }
        else {
          output = try await registry.voiceFactory(kind: settings.output)
            .makeOutput(settings: settings, configuration: configuration, environment: environment)
        }
        guard self.generation == generation, !Task.isCancelled else { return }
        session = VoiceSession(settings: settings, input: input, output: output,
          changed: { [weak self] _ in
            Task { @MainActor in
              guard let self, self.generation == generation else { return }
              self.refresh()
            }
          }, submit: { [weak self, weak conversation] token, text in
            Task { @MainActor in
              guard let self, let conversation, self.generation == generation,
                self.session?.acceptsSubmission(token) == true else { return }
              if mode == .dictation {
                conversation.draft += (conversation.draft.isEmpty ? "" : "\n") + text
                self.stop()
              } else {
                guard conversation.connected, !conversation.busy,
                  !conversation.importingAttachments else {
                  self.session?.finishReply(error: "The chat is not ready. Resume voice when it is connected and idle.")
                  return
                }
                // Preserve any typed draft and attachments for a later text turn.
                conversation.sendVoice(text)
              }
            }
          })
        session?.start()
      } catch {
        guard self.generation == generation, !Task.isCancelled else { return }
        self.error = error.localizedDescription
        state = .error
      }
    }
  }

  func finishCapture() { session?.send() }
  func resume() { session?.record() }
  func pause() { session?.pause() }
  func beginReply() {
    if mode != .dictation { session?.beginReply() }
    else if isActive { stop() }
  }
  func finishReply(_ text: String, error: String? = nil) {
    guard mode != .dictation else { return }
    session?.appendReply(text)
    session?.finishReply(error: error)
  }
  func stop() {
    generation = UUID()
    setup?.cancel()
    setup = nil
    session?.stop()
    session = nil
    state = .off
    transcript = ""
    error = nil
    if Self.active === self { Self.active = nil }
  }
  private func refresh() {
    guard let session else { return }
    state = session.state
    transcript = session.transcript
    error = session.error
  }
}

@MainActor private final class MacSilentVoiceOutput: VoiceOutputProvider {
  func speak(_ text: String) async throws {}
  func stop() {}
}

struct MacVoiceButton: View {
  let conversation: MacConversation
  @AppStorage("mac.voice.mode") private var selected = MacVoice.Mode.dictation.rawValue
  private var voice: MacVoice { conversation.voice }
  var body: some View {
    HStack(spacing: 0) {
      Button {
        if voice.state == .listening { voice.finishCapture() }
        else if voice.isActive { voice.stop() }
        else { voice.start(MacVoice.Mode(rawValue: selected) ?? .dictation, in: conversation) }
      } label: {
        Image(systemName: voice.isActive ? "mic.fill" : "mic").frame(width: 28, height: 28)
          .foregroundStyle(voice.isActive ? Color.red : Color.primary)
      }
      .buttonStyle(.borderless)
      .help(voice.state == .listening ? "Finish speaking" : voice.isActive ? "Stop voice" : "Start \(selected.lowercased())")
      .accessibilityLabel(voice.isActive ? "Finish or stop voice" : "Start \(selected.lowercased())")
      .disabled(!voice.isActive && (!conversation.connected || conversation.busy || conversation.importingAttachments))
      Menu {
        ForEach(MacVoice.Mode.allCases, id: \.rawValue) { mode in
          Button(mode.rawValue) {
            selected = mode.rawValue
            voice.start(mode, in: conversation)
          }
        }
      } label: { Image(systemName: "chevron.down").font(.caption2) }
      .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
      .help("Choose dictation or voice conversation")
      .disabled(!conversation.connected || conversation.busy || conversation.importingAttachments)
    }
  }
}

struct MacVoiceStatus: View {
  let conversation: MacConversation
  private var voice: MacVoice { conversation.voice }
  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: voice.state == .speaking ? "speaker.wave.2" : "waveform")
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 4) {
        Text("\(voice.mode.rawValue) · \(voice.state.rawValue.capitalized)").font(.callout.weight(.medium))
        if let error = voice.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        else if !voice.transcript.isEmpty { Text(voice.transcript).lineLimit(4).textSelection(.enabled) }
        else { Text(voice.mode == .dictation ? "Speak, then click the microphone to add the text to your draft."
          : "Speak naturally. A pause sends your message; replies are read aloud.").foregroundStyle(.secondary) }
      }
      Spacer()
      if voice.state == .error {
        Button("Retry") { voice.start(voice.mode, in: conversation) }.disabled(conversation.busy)
      } else if voice.state == .paused {
        Button("Resume", action: voice.resume).disabled(conversation.busy)
      } else if voice.state == .listening {
        Button(voice.mode == .dictation ? "Add to Draft" : "Send", action: voice.finishCapture)
      } else if voice.state == .speaking { Button("Pause", action: voice.pause) }
      Button("Stop", action: voice.stop)
    }.font(.caption).padding(8)
  }
}

struct MacVoiceCommands: Commands {
  @FocusedValue(\.macWorkspace) private var workspace
  var body: some Commands {
    CommandMenu("Voice") {
      Button("Start Voice Conversation") {
        if let chat = workspace?.selected { _ = chat.voice.handleCommand("/voice on", in: chat) }
      }.disabled(workspace?.selected?.connected != true || workspace?.selected?.busy == true)
      Button("Record or Send Voice") {
        if let chat = workspace?.selected { chat.voice.toggleCapture(in: chat) }
      }.keyboardShortcut(.space, modifiers: .control).disabled(workspace?.selected == nil)
      Button("Send Voice Turn") { workspace?.selected?.voice.finishCapture() }
        .keyboardShortcut("t", modifiers: .control).disabled(workspace?.selected?.voice.state != .listening)
      Button("Discard Voice Turn") { workspace?.selected?.voice.discard() }
        .keyboardShortcut("g", modifiers: .control).disabled(workspace?.selected?.voice.isActive != true)
      Button("Stop Voice") { workspace?.selected?.voice.stop() }
        .disabled(workspace?.selected?.voice.isActive != true)
    }
  }
}
