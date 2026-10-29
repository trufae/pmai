import Foundation
import MaiCore
import Testing

@testable import MaiCLI

private struct VoiceCatalogPlugin: MaiPlugin {
  let manifest = PluginManifest(
    id: "test.voice-catalog", displayName: "Voice catalog fixture", version: "1", capabilities: [.voiceProvider])
  func register(in registry: PluginRegistry) async throws {
    for kind in ["input", "output"] {
      try await registry.register(voiceFactory: CatalogFactory(kind: kind), from: manifest.id)
    }
  }
}

private struct CatalogFactory: ConfiguredVoiceProviderFactory {
  let kind: String
  @MainActor func catalog(
    settings: ConfiguredVoice, configuration: MaiConfiguration, environment: [String: String]
  ) async throws -> VoiceProviderCatalog {
    if kind == "input" { return .init(languages: [.init(id: "ca-ES", name: "Catalan")]) }
    return .init(voices: [.init(id: "\(settings.speechModel)-voice", name: "Fixture", language: "ca-ES")])
  }
  @MainActor func makeInput(
    settings: ConfiguredVoice, configuration: MaiConfiguration, environment: [String: String]
  ) throws -> any VoiceInputProvider { throw VoiceError.unavailable("Unused") }
  @MainActor func makeOutput(
    settings: ConfiguredVoice, configuration: MaiConfiguration, environment: [String: String]
  ) throws -> any VoiceOutputProvider { throw VoiceError.unavailable("Unused") }
}

@Test("Voice and language completion use provider catalogs and refresh after settings change")
func replVoiceCatalogCompletion() async throws {
  let plugins = PluginRegistry()
  try await plugins.install(VoiceCatalogPlugin())
  let catalog = REPLVoiceCatalog()
  defer { catalog.cancel() }
  var configuration = MaiConfiguration()
  configuration.voice.input = "input"
  configuration.voice.output = "output"
  configuration.voice.language = "fr_FR"
  func completions(_ line: String) -> [String] {
    catalog.completions(for: line, configuration: configuration, plugins: plugins, offline: false)
  }
  #expect(completions("ordinary input").isEmpty)
  for model in ["first", "second"] {
    configuration.voice.speechModel = model
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !completions("/set voice.voice ").contains("/set voice.voice \(model)-voice") {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Set(completions("/set voice.voice ")) == ["/set voice.voice default", "/set voice.voice \(model)-voice"])
    #expect(Set(completions("/set voice.language ")) == [
      "/set voice.language ca-ES",
    ])
    #expect(completions("/set voice.input ") == ["/set voice.input input", "/set voice.input output"])
    #expect(completions("/set voice.voice=").contains("/set voice.voice=\(model)-voice"))
    #expect(!completions("/set voice.voice ").contains("/set voice.voice first-voice") || model == "first")
    #expect(completions("/set voice.voice default extra").isEmpty)
  }
}

@Test("Language completion excludes unavailable input and speech-only languages")
func replVoiceCatalogAvailability() {
  let input = VoiceProviderCatalog(languages: [
    .init(id: "ca-ES", name: "Catalan", unavailableReason: "on-device recognition unavailable"),
    .init(id: "en-US", name: "English"), .init(id: "fr-FR", name: "French"),
  ])
  let output = VoiceProviderCatalog(voices: [
    .init(id: "ca", name: "Catalan", language: "ca-ES"),
    .init(id: "en", name: "English", language: "en-US"),
    .init(id: "es", name: "Spanish", language: "es-ES"),
  ])
  var settings = ConfiguredVoice()
  settings.language = "ca-ES"
  #expect(REPLVoiceCatalog.languageSuggestions(input: input, output: output, settings: settings) == ["en-US"])
  settings.voice = "en"
  #expect(REPLVoiceCatalog.languageSuggestions(input: input, output: output, settings: settings) == ["en-US", "fr-FR"])
  #expect(REPLVoiceCatalog.languageSuggestions(input: input, output: nil, settings: settings) == ["en-US", "fr-FR"])
}
