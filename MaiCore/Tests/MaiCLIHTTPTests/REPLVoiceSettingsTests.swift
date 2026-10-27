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

@Test("Voice setting errors identify the key and expected value without changing settings")
func replVoiceSettingValidation() throws {
  let settings = ConfiguredVoice()
  for (key, value, message) in [
    ("mode", "walkie", "realtime or walkie-talkie"),
    ("speed", "fast", "finite number"), ("speed", "null", "finite number"),
    ("speed", "0", "voice.speed"), ("silenceSeconds", "0", "voice.silenceSeconds"),
    ("speechThreshold", "1.1", "voice.speechThreshold"),
    ("maximumRecordingSeconds", "301", "voice.maximumRecordingSeconds"),
    ("language", "\"\"", "language tag"), ("language", "Catalan (Spain)", "language tag"),
    ("language", "null", "expects a string"), ("voice", "\"\"", "must not be empty"),
    ("speechModel", "\"\"", "must not be empty"),
    ("speechCommand", "say hello", "JSON object"),
    ("captureCommand", #"{"arguments":[]}"#, "JSON object"),
    ("transcriptionCommand", #"{"executable":"cat","arguments":"{audio}"}"#, "JSON object"),
    ("playbackCommand", #"{"executable":""}"#, "executable must not be empty"),
  ] {
    do {
      _ = try MaiCLI.updatedVoiceSettings(settings, key: key, value: value)
      Issue.record("Accepted invalid voice.\(key): \(value)")
    } catch {
      #expect(error.localizedDescription.contains(message), "\(key): \(error.localizedDescription)")
    }
  }
  #expect(try MaiCLI.updatedVoiceSettings(settings, key: "mode", value: "walkie-talkie").mode == .walkieTalkie)
  #expect(try MaiCLI.updatedVoiceSettings(settings, key: "language", value: "ca_ES").languageIdentifier == "ca-ES")
  #expect(try MaiCLI.updatedVoiceSettings(settings, key: "voice", value: "123").voice == "123")
  var commands = try MaiCLI.updatedVoiceSettings(settings, key: "speechCommand", value: #"{"executable":"cat"}"#)
  #expect(commands.speechCommand == .init("cat"))
  commands = try MaiCLI.updatedVoiceSettings(commands, key: "speechCommand", value: "null")
  #expect(commands.speechCommand == nil)
  #expect(try MaiCLI.updatedVoiceSettings(settings, key: "provider", value: "null").provider == nil)
  for key in ConfiguredVoice.settingNames {
    #expect(!MaiCLI.voiceSettingHelp(key, settings: settings).hasPrefix("Use /set voice."), "Missing help for \(key)")
  }
}
