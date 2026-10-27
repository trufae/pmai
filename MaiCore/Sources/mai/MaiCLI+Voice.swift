import Foundation
import MaiCore

extension MaiCLI {
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
    plugins: PluginRegistry, terminal: TerminalWriter
  ) async {
    let fields = argument.split(whereSeparator: \.isWhitespace)
    let voices = fields.first?.lowercased() == "voices"
    let filter = fields.dropFirst().joined(separator: " ").lowercased()
    let configuration = configuration ?? .init()
    let settings = configuration.voice
    let environment = ProcessInfo.processInfo.environment
    do {
      let output = try await plugins.voiceFactory(kind: settings.output)
        .catalog(settings: settings, configuration: configuration, environment: environment)
      if voices {
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
        let input: VoiceProviderCatalog
        if settings.input == settings.output {
          input = output
        } else {
          // A speech service's voice endpoint may not describe recognition languages.
          input = try await plugins.voiceFactory(kind: settings.input)
            .catalog(settings: settings, configuration: configuration, environment: environment)
        }
        var options: [String: (name: String, input: Bool, speech: Bool)] = [:]
        for language in input.languages {
          options[language.id] = (language.name, true, false)
        }
        for voice in output.voices {
          guard let id = voice.language else { continue }
          let name = Locale.current.localizedString(forIdentifier: id) ?? id
          options[id] = (options[id]?.name ?? name, options[id]?.input ?? false, true)
        }
        await terminal.line(
          "Voice languages; * is configured. Use /set voice.language TAG. Availability depends on installed speech models/voices."
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
          let uses = [option.input ? "input" : nil, option.speech ? "speech" : nil].compactMap {
            $0
          }.joined(separator: ", ")
          await terminal.line(
            "\(id == settings.languageIdentifier ? "*" : " ") \(id)  \(option.name) [\(uses)]")
        }
        if matching.isEmpty {
          await terminal.line(
            options.isEmpty
              ? "These providers do not publish language catalogs. Set a language supported by your transcription/speech programs."
              : "No languages match '\(filter)'.")
        }
      }
    } catch { await terminal.line("voice: \(error.localizedDescription)", to: .standardError) }
  }
}
