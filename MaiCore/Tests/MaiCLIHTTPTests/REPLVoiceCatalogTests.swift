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
    return .init(voices: [.init(id: "\(settings.speechModel)-voice", name: "Fixture", language: "en-US")])
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
  for model in ["first", "second"] {
    configuration.voice.speechModel = model
    catalog.select(configuration, plugins: plugins, offline: false)
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !catalog.completions(for: "/set voice.voice ").contains("/set voice.voice \(model)-voice") {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Set(catalog.completions(for: "/set voice.voice ")) == ["/set voice.voice default", "/set voice.voice \(model)-voice"])
    #expect(Set(catalog.completions(for: "/set voice.language ")) == [
      "/set voice.language ca-ES", "/set voice.language en-US", "/set voice.language fr-FR",
    ])
    #expect(catalog.completions(for: "/set voice.voice=").contains("/set voice.voice=\(model)-voice"))
    #expect(!catalog.completions(for: "/set voice.voice ").contains("/set voice.voice first-voice") || model == "first")
    #expect(catalog.completions(for: "/set voice.voice default extra").isEmpty)
  }
}
