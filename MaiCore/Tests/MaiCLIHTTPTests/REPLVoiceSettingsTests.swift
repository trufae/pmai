import Foundation
import MaiCore
import Testing

@testable import MaiCLI

@Test("Voice settings, namespace listings and completion share every persisted key")
func replVoiceSettingsDiscoverability() throws {
  let settings = ConfiguredVoice()
  let lines = try MaiCLI.voiceSettings(settings)
  let keys = Set(lines.map { String($0.prefix { $0 != " " }) })
  #expect(keys == Set(ConfiguredVoice.settingNames.map { "voice.\($0)" }))
  #expect(lines.contains("voice.speed = 1"))
  #expect(lines.contains("voice.speechCommand = null"))
  let completions = Set(
    MaiCLI.completionCandidates(
      workspace: .init(), configuration: nil,
      availableProviders: [], toolGroups: [],
      themesDirectory: FileManager.default.temporaryDirectory))
  #expect(completions.contains("/set voice."))
  #expect(completions.contains("/voice voices"))
  #expect(completions.contains("/voice languages"))
  #expect(!keys.contains("voice.instructions"))
  #expect(completions.contains("/edit prompt voice"))
  #expect(completions.contains("/edit prompt voiceover"))
  for key in keys { #expect(completions.contains("/set \(key) ")) }
}

@Test("Voice command values stay on one settings line")
func replVoiceSettingsSingleLine() throws {
  var settings = ConfiguredVoice()
  settings.speechCommand = .init("say", arguments: ["{text}"])
  let lines = try MaiCLI.voiceSettings(settings)
  #expect(lines.allSatisfy { !$0.contains("\n") })
  #expect(lines.contains(#"voice.speechCommand = {"arguments":["{text}"],"executable":"say"}"#))
}
