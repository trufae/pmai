import Foundation
import MaiStandardTools

enum ContextBuilder {
  struct Output {
    let text: String
    /// Equal signatures mean the configured context sources haven't changed.
    let signature: String
  }

  @MainActor
  static func build(
    input: String,
    conversation: Conversation,
    settings: AppSettings,
    locationService: @MainActor () -> LocationService
  ) async -> Output {
    var sections: [String] = []
    var signatureParts: [String] = []
    guard conversation.toolsEnabled else {
      return Output(text: "", signature: "")
    }
    let enabled = conversation.enabledTools

    if enabled.contains(.datetime) {
      sections.append(DateTimeRenderer.render(settings: settings.toolSettings))
      signatureParts.append(
        "datetime:\(DateTimeRenderer.signature(settings: settings.toolSettings))")
    }
    if enabled.contains(.language) {
      sections.append(
        LanguagePreferenceRenderer.render(conversation: conversation, settings: settings))
      signatureParts.append(
        "language:\(LanguagePreferenceRenderer.signature(conversation: conversation, settings: settings))"
      )
    }
    if enabled.contains(.location) {
      sections.append(
        await LocationRenderer.render(
          settings: settings.toolSettings, locationService: locationService))
      signatureParts.append(
        "location:\(LocationRenderer.signature(settings: settings.toolSettings))")
    }
    if enabled.contains(.files) {
      let files = filesContext(settings: settings.toolSettings)
      if !files.isEmpty {
        sections.append(files)
        signatureParts.append("files:\(filesSignature(settings: settings.toolSettings))")
      }
    }
    return Output(
      text: sections.joined(separator: "\n\n"),
      signature: signatureParts.joined(separator: "|"))
  }

  private static func filesContext(settings: NativeToolSettings) -> String {
    let files = settings.files.map { file in
      """
      File: \(file.name)
      \(file.excerpt)
      """
    }
    return files.isEmpty ? "" : "Files tool:\n" + files.joined(separator: "\n\n")
  }

  private static func filesSignature(settings: NativeToolSettings) -> String {
    settings.files.map { "\($0.id.uuidString)\($0.name)\($0.excerpt.count)" }
      .joined(separator: ",")
  }
}

enum LanguagePreferenceRenderer {
  static func render(conversation: Conversation, settings: AppSettings) -> String {
    let label = languageLabel(conversation: conversation, settings: settings)
    return "Language Preference tool:\nUser prefers \(label) language."
  }

  static func signature(conversation: Conversation, settings: AppSettings) -> String {
    languageIdentifier(conversation: conversation, settings: settings) ?? ""
  }

  private static func languageLabel(conversation: Conversation, settings: AppSettings) -> String {
    guard let identifier = languageIdentifier(conversation: conversation, settings: settings) else {
      return SystemLanguageSupport.languageDisplayName(Locale.current.identifier)
    }
    return SystemLanguageSupport.languageDisplayName(identifier)
  }

  private static func languageIdentifier(conversation: Conversation, settings: AppSettings)
    -> String?
  {
    if let override = conversation.effectiveLanguageOverrideIdentifier {
      return override
    }

    let candidates = [
      settings.conversation.speechRecognitionLanguageIdentifier,
      settings.toolSettings.voices.user.language,
      settings.toolSettings.voices.assistant.language,
      Locale.current.identifier,
    ]
    return candidates.lazy.compactMap(SystemLanguageSupport.normalizedLanguageIdentifier).first
  }
}

enum DateTimeRenderer {
  static func render(settings: NativeToolSettings) -> String {
    var values: [String] = []
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateStyle = .full
    formatter.timeStyle = .long
    values.append("Current date/time: \(formatter.string(from: now))")
    if settings.includeTimeZone {
      values.append("Time zone: \(TimeZone.current.identifier)")
    }
    if settings.includeMoonPhase {
      values.append(MaiWeatherService.moonPhaseLine(for: now))
    }
    return "Date & Time tool:\n" + values.joined(separator: "\n")
  }

  static func signature(settings: NativeToolSettings) -> String {
    "\(settings.includeTimeZone ? 1 : 0)\(settings.includeMoonPhase ? 1 : 0)"
  }
}

enum LocationRenderer {
  @MainActor
  static func render(
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> String {
    if settings.useGPSLocation {
      return
        "Location tool:\n\(await locationService().currentLocationText(precise: settings.preciseLocation))"
    }
    let manual = settings.manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
    return manual.isEmpty ? "Location tool:\nNo location configured" : "Location tool:\n\(manual)"
  }

  static func signature(settings: NativeToolSettings) -> String {
    "\(settings.useGPSLocation ? "gps" : "manual"):\(settings.preciseLocation):\(settings.manualLocation)"
  }
}

enum PocketMaiNetworkTools {
  @MainActor
  static func weatherTool(
    arguments: [String: AgentToolArgumentValue],
    settings: NativeToolSettings,
    locationService: @MainActor () -> LocationService
  ) async -> MaiWeatherTool {
    let requestedLocation =
      arguments["location"]?.coercedStringValue
      ?? arguments["city"]?.coercedStringValue
      ?? arguments["place"]?.coercedStringValue
      ?? arguments["query"]?.coercedStringValue
      ?? arguments["q"]?.coercedStringValue
    let configuredLocation = settings.weatherLocation.trimmingCharacters(
      in: .whitespacesAndNewlines)
    var coordinate: MaiCoordinate?
    if configuredLocation.isEmpty, settings.useGPSLocation,
      usesConfiguredLocation(requestedLocation)
    {
      if let current = await locationService().currentCoordinate(precise: settings.preciseLocation)
      {
        coordinate = MaiCoordinate(
          latitude: current.latitude,
          longitude: current.longitude)
      }
    }
    return MaiWeatherTool(
      configuration: MaiWeatherConfiguration(
        location: configuredLocation,
        coordinate: coordinate))
  }

  private static func usesConfiguredLocation(_ value: String?) -> Bool {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    return value.isEmpty
      || ["current", "current location", "here", "my location", "configured location"]
        .contains(value)
  }
}

extension AppSettings {
  var maiWebSearchConfiguration: MaiWebSearchConfiguration {
    MaiWebSearchConfiguration(
      provider: toolSettings.webSearchProvider,
      searXNGURL: toolSettings.webSearchSearXNGURL,
      searXNGUsername: toolSettings.webSearchSearXNGUsername,
      searXNGPassword: toolSettings.webSearchSearXNGPassword,
      ollamaAPIKey: ollamaWebSearchAPIKey)
  }

  var hasOllamaWebSearchConfiguration: Bool {
    !ollamaWebSearchAPIKey.isEmpty
  }

  private var ollamaWebSearchAPIKey: String {
    openAIEndpoints.first { endpoint in
      guard endpoint.isEnabled else { return false }
      let host = URL(string: endpoint.baseURL)?.host?.lowercased() ?? ""
      let apiKey = endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
      return host.hasSuffix("ollama.com") && !apiKey.isEmpty
    }?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }
}

extension NativeToolSettings {
  var maiMastodonConfiguration: MaiMastodonConfiguration {
    MaiMastodonConfiguration(
      instance: mastodonInstance,
      apiKey: mastodonAPIKey,
      writeEnabled: mastodonWriteEnabled)
  }
}
