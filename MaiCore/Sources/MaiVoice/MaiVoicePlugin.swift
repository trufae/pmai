import Foundation
import MaiCore
import MaiOpenAI

public struct MaiVoicePlugin: MaiPlugin {
  public let manifest = PluginManifest(
    id: "org.mai.voice", displayName: "Native and program voice",
    version: "1.0.0", capabilities: [.voiceProvider])
  public init() {}
  public func register(in registry: PluginRegistry) async throws {
    for kind in ["system", "command", "openai"] {
      try await registry.register(voiceFactory: VoiceFactory(kind: kind), from: manifest.id)
    }
  }
}

private struct VoiceFactory: ConfiguredVoiceProviderFactory {
  let kind: String
  @MainActor func makeInput(
    settings: ConfiguredVoice, configuration: MaiConfiguration,
    environment: [String: String]
  ) throws -> any VoiceInputProvider {
    try settings.validate()
    #if os(macOS) || os(Linux)
      if kind == "system" {
        #if os(macOS)
          return NativeVoiceInput(settings: settings)
        #else
          throw VoiceError.unavailable(
            "Select voice.input=command with a transcription program, or openai with a configured provider. Linux capture defaults to arecord."
          )
        #endif
      }
      if kind == "openai" {
        let client = try client(configuration, environment: environment, settings: settings)
        return ProgramVoiceInput(settings: settings, environment: environment) { audio in
          try await client.transcribeAudio(
            audio: audio, filename: "voice.wav",
            model: settings.transcriptionModel,
            language: settings.language.replacingOccurrences(of: "_", with: "-").split(
              separator: "-"
            ).first.map(String.init),
            contentType: "audio/wav")
        }
      }
      guard let command = settings.transcriptionCommand else {
        throw VoiceError.unavailable(
          "Set voice.transcriptionCommand. It receives {audio} (WAV) and {language}; print only the transcript to stdout."
        )
      }
      return ProgramVoiceInput(settings: settings, environment: environment) { audio in
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(
          "pmai-voice-\(UUID()).wav")
        try audio.write(to: file, options: .atomic)
        defer { try? FileManager.default.removeItem(at: file) }
        let process = VoiceProcess(
          command, environment: environment,
          values: ["audio": file.path, "language": settings.language])
        return String(decoding: try await process.run(), as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
      }
    #else
      throw VoiceError.unavailable("This voice plugin supports macOS and Linux.")
    #endif
  }

  @MainActor func makeOutput(
    settings: ConfiguredVoice, configuration: MaiConfiguration,
    environment: [String: String]
  ) throws -> any VoiceOutputProvider {
    #if os(macOS) || os(Linux)
      if kind == "system" {
        #if os(macOS)
          return NativeVoiceOutput(settings: settings)
        #else
          return ProgramVoiceOutput(
            command: settings.speechCommand ?? VoiceCommand("festival", arguments: ["--tts"]),
            settings: settings, environment: environment)
        #endif
      }
      if kind == "openai" {
        return RemoteVoiceOutput(
          client: try client(configuration, environment: environment, settings: settings),
          settings: settings, environment: environment)
      }
      guard let command = settings.speechCommand else {
        throw VoiceError.unavailable(
          "Set voice.speechCommand. Speech text is sent on stdin unless arguments contain {text}.")
      }
      return ProgramVoiceOutput(command: command, settings: settings, environment: environment)
    #else
      throw VoiceError.unavailable("This voice plugin supports macOS and Linux.")
    #endif
  }

  private func client(
    _ configuration: MaiConfiguration, environment: [String: String], settings: ConfiguredVoice
  ) throws -> OpenAICompatibleProvider {
    guard !configuration.airplane else {
      throw VoiceError.unavailable("Remote voice is disabled in airplane mode.")
    }
    guard let id = settings.provider,
      let provider = configuration.providers.first(where: { $0.id == id }),
      let url = provider.baseURL
    else {
      throw VoiceError.unavailable(
        "Set voice.provider to an configured OpenAI-compatible provider with a baseURL.")
    }
    return OpenAICompatibleProvider(
      configuration: .init(
        id: ProviderID(provider.id),
        displayName: provider.displayName ?? provider.id, baseURL: url,
        apiKey: try provider.resolvedAPIKey(environment: environment),
        additionalHeaders: try provider.resolvedHeaders(environment: environment),
        requestTimeout: provider.timeout ?? 60))
  }
}

#if os(macOS) || os(Linux)
  @MainActor private final class RemoteVoiceOutput: VoiceOutputProvider {
    let client: OpenAICompatibleProvider
    let settings: ConfiguredVoice
    let environment: [String: String]
    private var player: VoiceProcess?
    init(client: OpenAICompatibleProvider, settings: ConfiguredVoice, environment: [String: String])
    {
      self.client = client
      self.settings = settings
      self.environment = environment
    }
    func speak(_ text: String) async throws {
      let audio = try await client.synthesizeSpeech(
        input: text,
        voice: settings.voice == "default" ? "alloy" : settings.voice,
        responseFormat: "wav", model: settings.speechModel)
      try Task.checkCancellation()
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(
        "pmai-speech-\(UUID()).wav")
      try audio.write(to: file, options: .atomic)
      defer { try? FileManager.default.removeItem(at: file) }
      #if os(macOS)
        let fallback = VoiceCommand("afplay", arguments: ["{audio}"])
      #else
        let fallback = VoiceCommand("aplay", arguments: ["-q", "{audio}"])
      #endif
      let player = VoiceProcess(
        settings.playbackCommand ?? fallback, environment: environment, values: ["audio": file.path]
      )
      self.player = player
      defer { if self.player === player { self.player = nil } }
      _ = try await player.run()
    }
    func stop() {
      player?.stop()
      player = nil
    }
  }
#endif
