import Foundation
import MaiCore

/// Fetch provider catalogs away from the input thread; Tab reads a snapshot.
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
  private var retryAfter: Date?

  func select(_ configuration: MaiConfiguration, plugins: PluginRegistry, offline: Bool) {
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
      guard pending == nil, voices == nil || retryAfter.map({ $0 <= Date() }) == true else { return }
      let generation = generation
      pending = Task { [weak self] in
        let settings = configuration.voice
        func catalog(_ kind: String) async -> VoiceProviderCatalog? {
          guard !offline || ["system", "command"].contains(kind),
            let factory = try? await plugins.voiceFactory(kind: kind) else { return nil }
          return try? await factory.catalog(
            settings: settings, configuration: configuration, environment: ProcessInfo.processInfo.environment)
        }
        let output = await catalog(settings.output)
        let input = settings.input == settings.output ? output : await catalog(settings.input)
        guard !Task.isCancelled, let self else { return }
        self.lock.withLock {
          guard self.generation == generation else { return }
          self.voices = Array(Set(["default", settings.voice] + (output?.voices.map(\.id) ?? []))).sorted()
          self.languages = Array(Set(
            [settings.languageIdentifier] + (input?.languages.map(\.id) ?? [])
              + (output?.languages.map(\.id) ?? []) + (output?.voices.compactMap(\.language) ?? [])
          )).filter { !$0.isEmpty }.sorted()
          self.pending = nil
          self.retryAfter = output == nil || input == nil ? Date().addingTimeInterval(30) : nil
        }
      }
    }
  }

  func completions(for line: String) -> [String] {
    for key in ["voice.voice", "voice.language"] {
      for separator in [" ", "="] {
        let prefix = "/set \(key)\(separator)"
        guard line.hasPrefix(prefix), !line.dropFirst(prefix.count).contains(where: \.isWhitespace) else { continue }
        let values = lock.withLock { key == "voice.voice" ? voices : languages }
        return (values ?? []).map { prefix + $0 }
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
}
