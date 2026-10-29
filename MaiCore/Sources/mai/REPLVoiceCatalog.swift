import Foundation
import MaiCore

/// Discover voices only when requested. Native speech discovery uses the main
/// actor, so even a background prefetch can delay the first prompt.
final class REPLVoiceCatalog: @unchecked Sendable {
  private struct Selection: Equatable {
    var settings: ConfiguredVoice
    var providers: [ConfiguredProvider]
    var offline: Bool
  }

  private let lock = NSLock()
  private var selection: Selection?
  private var generation = UUID()
  private var pending: Task<Void, Never>?
  private var voices: [String]?
  private var languages: [String]?
  private var kinds: [String] = []
  private var retryAfter: Date?

  private func prefetch(_ configuration: MaiConfiguration, plugins: PluginRegistry, offline: Bool, key: String) {
    let wanted = Selection(settings: configuration.voice, providers: configuration.providers, offline: offline)
    lock.withLock {
      if selection != wanted {
        pending?.cancel()
        pending = nil
        selection = wanted
        generation = UUID()
        voices = nil
        languages = nil
        retryAfter = nil
      }
      let missing = key == "voice.voice" ? voices == nil : key == "voice.language" ? languages == nil : kinds.isEmpty
      guard pending == nil, missing || retryAfter.map({ $0 <= Date() }) == true else { return }
      let generation = generation
      pending = Task { [weak self] in
        let settings = configuration.voice
        let kinds = await plugins.voiceProviderKinds()
        if key == "voice.input" || key == "voice.output" {
          guard !Task.isCancelled, let self else { return }
          self.lock.withLock {
            guard self.generation == generation else { return }
            self.kinds = kinds
            self.pending = nil
          }
          return
        }
        func catalog(_ kind: String, for role: VoiceProviderRole) async -> VoiceProviderCatalog? {
          guard !offline || ["system", "command"].contains(kind),
            let factory = try? await plugins.voiceFactory(kind: kind) else { return nil }
          return try? await factory.catalog(
            for: role, settings: settings, configuration: configuration, environment: ProcessInfo.processInfo.environment)
        }
        let output = await catalog(settings.output, for: .output)
        let input = await catalog(settings.input, for: .input)
        guard !Task.isCancelled, let self else { return }
        self.lock.withLock {
          guard self.generation == generation else { return }
          let voiceIDs = output?.voices.map(\.id) ?? []
          self.voices = Array(Set(["default"] + (voiceIDs.isEmpty ? [settings.voice] : voiceIDs))).sorted()
          self.kinds = kinds
          self.languages = Self.languageSuggestions(input: input, output: output, settings: settings)
          self.pending = nil
          self.retryAfter = output == nil || input == nil ? Date().addingTimeInterval(30) : nil
        }
      }
    }
  }

  /// Reuse explicit /voice listings instead of querying the same backend again.
  func store(output: VoiceProviderCatalog, input: VoiceProviderCatalog? = nil,
    configuration: MaiConfiguration, offline: Bool) {
    lock.withLock {
      pending?.cancel()
      pending = nil
      generation = UUID()
      selection = Selection(settings: configuration.voice, providers: configuration.providers, offline: offline)
      voices = Array(Set(["default", configuration.voice.voice] + output.voices.map(\.id))).sorted()
      languages = input.map { Self.languageSuggestions(input: $0, output: output, settings: configuration.voice) }
      retryAfter = nil
    }
  }

  static func languageSuggestions(input: VoiceProviderCatalog?, output: VoiceProviderCatalog?,
    settings: ConfiguredVoice) -> [String] {
    let recognition = input?.languages ?? []
    let speech = output?.voices.compactMap(\.language) ?? []
    if !recognition.isEmpty {
      return recognition.filter { language in
        language.unavailableReason == nil && (speech.isEmpty || settings.voice != "default"
          || speech.contains { $0 == language.id })
      }.map(\.id).sorted()
    }
    return Array(Set(speech.isEmpty ? [settings.languageIdentifier] : speech)).sorted()
  }

  func completions(for line: String, configuration: MaiConfiguration,
    plugins: PluginRegistry, offline: Bool) -> [String] {
    for key in ["voice.voice", "voice.language", "voice.input", "voice.output"] {
      for separator in [" ", "="] {
        let prefix = "/set \(key)\(separator)"
        guard line.hasPrefix(prefix), !line.dropFirst(prefix.count).contains(where: \.isWhitespace) else { continue }
        prefetch(configuration, plugins: plugins, offline: offline, key: key)
        let values = lock.withLock {
          key == "voice.voice" ? voices : key == "voice.language" ? languages : kinds
        }
        let fallback = key == "voice.language" ? [configuration.voice.languageIdentifier]
          : key == "voice.voice" ? ["default", configuration.voice.voice] : []
        return (values ?? fallback).map { prefix + $0 }
      }
    }
    return []
  }

  func cancel() {
    lock.withLock {
      pending?.cancel()
      pending = nil
      generation = UUID()
    }
  }

  func invalidate() {
    lock.withLock { selection = nil }
  }
}
