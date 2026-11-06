import Foundation
import MaiCore

extension MaiCLI {
  static func updatedVoiceSettings(_ settings: ConfiguredVoice, key: String, value: String) throws -> ConfiguredVoice {
    let encoder = JSONEncoder()
    var object = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(settings))
    let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(value.utf8))
    if key.hasSuffix("Command") {
      if value == "null" {
        object[key] = .null
      } else {
        do {
          guard let parsed, case .object(let fields) = parsed,
            Set(fields.keys).isSubset(of: ["executable", "arguments"]) else {
            throw VoiceError.unavailable("Invalid command keys")
          }
          let command = try JSONDecoder().decode(VoiceCommand.self, from: Data(value.utf8))
          object[key] = try JSONDecoder().decode(JSONValue.self, from: encoder.encode(command))
        } catch {
          throw VoiceError.unavailable(
            "voice.\(key) expects a JSON object with executable (string) and arguments (array of strings), or null to reset. Example: {\"executable\":\"say\",\"arguments\":[\"{text}\"]}")
        }
      }
    } else if ["speed", "silenceSeconds", "speechThreshold", "maximumRecordingSeconds"].contains(key) {
      guard let number = Double(value), number.isFinite else {
        throw VoiceError.unavailable("voice.\(key) expects a finite number. \(voiceSettingHelp(key, settings: settings))")
      }
      object[key] = .number(number)
    } else if key == "provider", value == "null" {
      object[key] = .null
    } else {
      let text: String
      if let parsed, case .string(let string) = parsed { text = string }
      else {
        guard value != "null", !["\"", "{", "["].contains(where: value.hasPrefix) else {
          throw VoiceError.unavailable("voice.\(key) expects a string. \(voiceSettingHelp(key, settings: settings))")
        }
        text = value
      }
      if key == "mode", VoiceCaptureMode(rawValue: text) == nil {
        throw VoiceError.unavailable("voice.mode must be realtime or walkie-talkie; got '\(text)'.")
      }
      object[key] = .string(text)
    }
    let result = try JSONDecoder().decode(ConfiguredVoice.self, from: encoder.encode(object))
    try result.validate()
    return result
  }

  static func voiceSettingHelp(_ key: String, settings: ConfiguredVoice) -> String {
    switch key {
    case "input": return "Input backend: system, command, openai, or an installed voice plugin. system requires on-device recognition on macOS."
    case "output": return "Speech backend: system, command, openai, or an installed voice plugin."
    case "mode": return "realtime sends after silence; walkie-talkie waits for /voice send."
    case "language": return "Language tag, e.g. ca-ES or en-US. /voice languages shows input availability separately from speech."
    case "voice": return "Speech voice ID for output=\(settings.output), or default. Use /voice voices. An explicit voice overrides language selection for speech."
    case "speed": return "Range: 0.25–4; 1 is normal speech speed."
    case "silenceSeconds": return "Range: 0.2–10 seconds; silence before sending in realtime mode."
    case "speechThreshold": return "Range: 0.0001–1; microphone level that counts as speech."
    case "maximumRecordingSeconds": return "Range: 1–300 seconds; ends recording in either capture mode."
    case "provider": return "Configured provider ID for openai audio; null clears it. This is separate from /model -voice (the conversation model)."
    case "transcriptionModel": return "Audio transcription model used only by input=openai."
    case "speechModel": return "Speech synthesis model used only by output=openai."
    case "captureCommand": return "JSON command for command/openai input; outputs raw 16 kHz mono signed 16-bit little-endian PCM. null restores sox (macOS) or arecord (Linux). Ignored by native system input."
    case "transcriptionCommand": return "JSON command for input=command. Receives {audio} (WAV) and {language}; prints transcript. null clears it."
    case "speechCommand": return "JSON command for output=command (also Linux system output). Text goes to stdin unless arguments use {text}; supports {language}, {voice}, {speed}. null clears it."
    case "playbackCommand": return "JSON command for output=openai. Receives {audio} (WAV); null restores afplay (macOS) or aplay (Linux)."
    default: return "Use /set voice. to list settings."
    }
  }

  /// Use the Codable keys for listing and completion, including unset optional providers/programs.
  static func voiceSettings(_ settings: ConfiguredVoice) throws -> [String] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let values = try JSONDecoder().decode([String: JSONValue].self, from: encoder.encode(settings))
    return try ConfiguredVoice.settingNames.map { key in
      let value = String(decoding: try encoder.encode(values[key] ?? .null), as: UTF8.self)
      return "voice.\(key) = \(value)"
    }
  }

  static func showVoiceCatalog(
    _ argument: String, configuration: MaiConfiguration?,
    plugins: PluginRegistry, terminal: TerminalWriter, cache: REPLVoiceCatalog? = nil
  ) async {
    let fields = argument.split(whereSeparator: \.isWhitespace)
    let voices = fields.first?.lowercased() == "voices"
    let filter = fields.dropFirst().joined(separator: " ").lowercased()
    let configuration = configuration ?? .init()
    let settings = configuration.voice
    let environment = ProcessInfo.processInfo.environment
    var output = VoiceProviderCatalog()
    do {
      output = try await plugins.voiceFactory(kind: settings.output)
        .catalog(for: .output, settings: settings, configuration: configuration, environment: environment)
    } catch {
      await terminal.line("voice.output=\(settings.output): \(error.localizedDescription)", to: .standardError)
      if voices { return }
    }
    if voices {
      cache?.store(output: output, configuration: configuration, offline: configuration.airplane)
      await terminal.line(
        "Speech voices (\(settings.output)); * is configured. Use /set voice.voice ID.")
      let tag = filter.replacingOccurrences(of: "_", with: "-")
      let byLanguage = output.voices.contains {
        $0.language?.lowercased() == tag || $0.language?.lowercased().hasPrefix(tag + "-") == true
      }
      let matching = output.voices.filter {
        if filter.isEmpty { return true }
        if byLanguage {
          return $0.language?.lowercased() == tag
            || $0.language?.lowercased().hasPrefix(tag + "-") == true
        }
        return [$0.id, $0.name, $0.language ?? ""].contains { $0.lowercased().contains(filter) }
      }
      let selected = settings.voice == "default" ? output.defaultVoice : settings.voice
      for voice in matching {
        await terminal.line(
          "\(voice.id == selected ? "*" : " ") \(voice.id)  \(voice.language ?? "")  \(voice.name)  \(voice.quality ?? "")"
        )
      }
      if matching.isEmpty {
        await terminal.line(
          output.voices.isEmpty
            ? "This provider does not publish a voice catalog. Configure a voice supported by your speech program/provider."
            : "No voices match '\(filter)'.")
      }
      if settings.output == "system", !output.voices.isEmpty {
        await terminal.line(
          "More macOS voices can be installed in System Settings → Accessibility → Spoken Content (or Read & Speak)."
        )
      }
    } else {
      var input = VoiceProviderCatalog()
      do {
        var catalogSettings = settings
        if settings.input == "system" { catalogSettings.language = filter }
        input = try await plugins.voiceFactory(kind: settings.input)
          .catalog(for: .input, settings: catalogSettings, configuration: configuration, environment: environment)
      } catch {
        await terminal.line("voice.input=\(settings.input): \(error.localizedDescription)", to: .standardError)
      }
      cache?.store(output: output, input: input, configuration: configuration, offline: configuration.airplane)
      var options: [String: (name: String, input: Bool, speech: Bool, reason: String?, checked: Bool)] = [:]
      for language in input.languages {
        options[language.id] = (language.name, true, false, language.unavailableReason, language.availabilityChecked)
      }
      for voice in output.voices {
        guard let id = voice.language else { continue }
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        options[id] = (options[id]?.name ?? name, options[id]?.input ?? false, true, options[id]?.reason,
          options[id]?.checked ?? false)
      }
      await terminal.line(
        "Voice languages (input=\(settings.input), output=\(settings.output)); * is configured. Use /set voice.language TAG."
      )
      let tag = filter.replacingOccurrences(of: "_", with: "-")
      let byLanguage = options.keys.contains {
        $0.lowercased() == tag || $0.lowercased().hasPrefix(tag + "-")
      }
      let matching = options.keys.sorted().filter {
        if filter.isEmpty { return true }
        if byLanguage { return $0.lowercased() == tag || $0.lowercased().hasPrefix(tag + "-") }
        return $0.lowercased().contains(filter) || options[$0]!.name.lowercased().contains(filter)
      }
      for id in matching {
        let option = options[id]!
        let uses = [option.input ? option.reason.map { "input unavailable: " + $0 }
            ?? (option.checked ? "input" : "input not checked") : nil,
          option.speech ? "speech" : nil].compactMap {
          $0
        }.joined(separator: ", ")
        await terminal.line(
          "\(id == settings.languageIdentifier ? "*" : " ") \(id)  \(option.name) [\(uses)]")
      }
      if settings.input == "system" {
        await terminal.line("Native input requires on-device recognition; speech voices alone do not enable input. macOS may log missing assets while checking recognition support.")
      }
      if input.languages.isEmpty {
        await terminal.line("Input provider '\(settings.input)' does not publish recognition languages; input language support is unverified.")
      }
      if settings.voice != "default" {
        await terminal.line("Speech uses explicit voice ID '\(settings.voice)'; voice.language does not change that voice. Use /set voice.voice default to follow the language.")
      }
      if matching.isEmpty {
        await terminal.line(
          options.isEmpty
            ? "These providers do not publish language catalogs. Set a language supported by your transcription/speech programs."
            : "No languages match '\(filter)'.")
      }
    }
  }
}
