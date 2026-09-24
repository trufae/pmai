import Foundation
import MaiCore
import MaiStandardTools

enum ChatRole: String, Codable, CaseIterable, Identifiable, Sendable {
  case user
  case assistant
  case system
  case tool
  case error

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .user: "You"
    case .assistant: "Assistant"
    case .system: "System"
    case .tool: "Tool"
    case .error: "Error"
    }
  }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case apple
  case mlx
  case openAICompatible

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apple: "Apple"
    case .mlx: "MLX"
    case .openAICompatible: "OpenAI-compatible"
    }
  }

  var supportsNativeToolCalling: Bool {
    switch self {
    case .openAICompatible:
      return true
    case .apple, .mlx:
      return false
    }
  }

  var isAirplaneModeEligible: Bool {
    switch self {
    case .apple, .mlx:
      return true
    case .openAICompatible:
      return false
    }
  }
}

enum ConversationExportFormat: String, CaseIterable, Identifiable, Sendable {
  case markdown
  case html
  case epub
  case docx
  case audio
  case json
  case debug

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .markdown: "Markdown"
    case .html: "HTML"
    case .json: "JSON"
    case .debug: "Debug"
    case .epub: "EPUB"
    case .docx: "Word"
    case .audio: "Audio"
    }
  }

  var systemImage: String {
    switch self {
    case .markdown: "doc.richtext"
    case .html: "chevron.left.forwardslash.chevron.right"
    case .json: "curlybraces"
    case .debug: "ladybug"
    case .epub: "book"
    case .docx: "doc.text"
    case .audio: "waveform"
    }
  }

  var fileExtension: String {
    switch self {
    case .markdown: "md"
    case .html: "html"
    case .json: ConversationExportFiles.fileExtension
    case .debug: "json"
    case .epub: "epub"
    case .docx: "docx"
    case .audio: "m4a"
    }
  }
}

enum AppearanceFontFamily: Codable, Equatable, Hashable, Identifiable, Sendable {
  case system
  case serif
  case rounded
  case monospaced
  case installed(String)

  var id: String {
    switch self {
    case .system: "system"
    case .serif: "serif"
    case .rounded: "rounded"
    case .monospaced: "monospaced"
    case .installed(let fontName): "installed:\(fontName)"
    }
  }

  var displayName: String {
    switch self {
    case .system: "System"
    case .serif: "Serif"
    case .rounded: "Rounded"
    case .monospaced: "Monospaced"
    case .installed(let fontName): fontName.replacingOccurrences(of: "-", with: " ")
    }
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    switch value {
    case "system": self = .system
    case "serif": self = .serif
    case "rounded": self = .rounded
    case "monospaced": self = .monospaced
    default:
      if value.hasPrefix("installed:") {
        self = .installed(String(value.dropFirst("installed:".count)))
      } else {
        self = .system
      }
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .system:
      try container.encode("system")
    case .serif:
      try container.encode("serif")
    case .rounded:
      try container.encode("rounded")
    case .monospaced:
      try container.encode("monospaced")
    case .installed(let fontName):
      try container.encode("installed:\(fontName)")
    }
  }
}

enum AppearanceTint: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case blue
  case purple
  case pink
  case red
  case orange
  case yellow
  case green
  case mint
  case teal
  case cyan
  case indigo

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .blue: "Blue"
    case .purple: "Purple"
    case .pink: "Pink"
    case .red: "Red"
    case .orange: "Orange"
    case .yellow: "Yellow"
    case .green: "Green"
    case .mint: "Mint"
    case .teal: "Teal"
    case .cyan: "Cyan"
    case .indigo: "Indigo"
    }
  }
}

/// Accent color a conversation folder can use instead of the app tint.
/// A folder without a tint keeps whatever accent the app is configured with.
///
/// The stored form, parsing, and hex normalization are MaiCore's
/// `AgentProjectTint`, which pmai projects use too, so a folder color reads
/// the same everywhere and files written by any earlier app version decode.
enum ConversationFolderTint: Codable, Equatable, Hashable, Identifiable, Sendable {
  case preset(AppearanceTint)
  case custom(String)

  static let customPrefix = AgentProjectTint.customPrefix

  static let presetOptions: [ConversationFolderTint] =
    AppearanceTint.allCases.filter { $0 != .system }.map { ConversationFolderTint.preset($0) }

  var id: String { rawIdentifier }

  /// The shared MaiCore tint this folder color corresponds to.
  var projectTint: AgentProjectTint? {
    switch self {
    case .preset(let tint): AgentProjectTint(rawValue: tint.rawValue)
    case .custom(let hex): AgentProjectTint(rawValue: hex)
    }
  }

  init?(projectTint: AgentProjectTint) {
    if projectTint.isPreset {
      guard let preset = AppearanceTint(rawValue: projectTint.rawValue), preset != .system else {
        return nil
      }
      self = .preset(preset)
    } else {
      self = .custom(projectTint.rawValue)
    }
  }

  var rawIdentifier: String {
    if let projectTint { return projectTint.storageIdentifier }
    switch self {
    case .preset(let tint): return tint.rawValue
    case .custom(let hex): return "\(Self.customPrefix)\(hex)"
    }
  }

  var displayName: String {
    switch self {
    case .preset(let tint): tint.displayName
    case .custom(let hex): hex
    }
  }

  var customHex: String? {
    switch self {
    case .preset: nil
    case .custom(let hex): hex
    }
  }

  init?(rawIdentifier: String) {
    guard let projectTint = AgentProjectTint(rawValue: rawIdentifier) else { return nil }
    self.init(projectTint: projectTint)
  }

  /// Accepts `#RGB`, `RGB`, `#RRGGBB` and `RRGGBB`, always answering `#RRGGBB`.
  static func normalizedHex(_ raw: String) -> String? {
    AgentProjectTint.normalizedHex(raw)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    let value = try container.decode(String.self)
    guard let tint = ConversationFolderTint(rawIdentifier: value) else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported folder tint \"\(value)\".")
    }
    self = tint
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawIdentifier)
  }
}

enum AppearanceTheme: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case light
  case dark

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }
}

enum AppearanceZoomMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case realtime
  case tiled
  case disabled

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .realtime: "Realtime"
    case .tiled: "Tiled"
    case .disabled: "Disabled"
    }
  }

  var detail: String {
    switch self {
    case .realtime:
      "Changes and reflows the font continuously while you pinch."
    case .tiled:
      "Scales the rendered conversation, then changes the font when you release."
    case .disabled:
      "Turns off the conversation pinch-to-zoom gesture."
    }
  }
}

enum SolidBubbleMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case user
  case both
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .user: "User"
    case .both: "Both"
    case .none: "None"
    }
  }

  func includes(_ role: ChatRole) -> Bool {
    switch (self, role) {
    case (.both, .user), (.both, .assistant), (.user, .user):
      true
    default:
      false
    }
  }
}

enum AppStartupBehavior: String, Codable, CaseIterable, Identifiable, Sendable {
  case continueChats
  case newChat
  case lastConversation

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .continueChats: "Continue Chats"
    case .newChat: "New Chat"
    case .lastConversation: "Last Conversation"
    }
  }
}

struct AppearanceSettings: Codable, Equatable, Sendable {
  static let fontSizeRange: ClosedRange<Double> = 6...43
  static let fontSizeStep: Double = 0.05
  static let lineSpacingRange: ClosedRange<Double> = 0...14
  static let lineSpacingStep: Double = 0.25

  var userFontFamily: AppearanceFontFamily = .rounded
  var assistantFontFamily: AppearanceFontFamily = .serif
  var fontSize: Double = 17
  var lineSpacing: Double = 3
  var zoomMethod: AppearanceZoomMethod = .realtime
  var tint: AppearanceTint = .system
  var theme: AppearanceTheme = .system
  var solidBubbles: SolidBubbleMode = .user
  var liveMarkdown: Bool = true
  var justifyText: Bool = false
  var unwrappedTables: Bool = false
  var scrollToFollowResponses: Bool = true
  var hapticsEnabled: Bool = true

  static let defaults = AppearanceSettings()

  init() {}

  static func clampedFontSize(_ size: Double) -> Double {
    min(max(size, fontSizeRange.lowerBound), fontSizeRange.upperBound)
  }

  static func clampedLineSpacing(_ spacing: Double) -> Double {
    min(max(spacing, lineSpacingRange.lowerBound), lineSpacingRange.upperBound)
  }

  enum CodingKeys: String, CodingKey {
    case userFontFamily, assistantFontFamily, fontFamily, fontSize, lineSpacing, zoomMethod, tint,
      theme
    case solidBubbles, solidResponseBubbles, colorizeResponseBubbles, liveMarkdown, justifyText,
      unwrappedTables
    case scrollToFollowResponses, hapticsEnabled
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let legacyFamily = try? c.decode(AppearanceFontFamily.self, forKey: .fontFamily)
    userFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .userFontFamily)) ?? .rounded
    assistantFontFamily =
      (try? c.decode(AppearanceFontFamily.self, forKey: .assistantFontFamily))
      ?? legacyFamily ?? .serif
    fontSize = Self.clampedFontSize((try? c.decode(Double.self, forKey: .fontSize)) ?? 17)
    lineSpacing =
      Self.clampedLineSpacing((try? c.decode(Double.self, forKey: .lineSpacing)) ?? 3)
    zoomMethod = (try? c.decode(AppearanceZoomMethod.self, forKey: .zoomMethod)) ?? .realtime
    tint = (try? c.decode(AppearanceTint.self, forKey: .tint)) ?? .system
    theme = (try? c.decode(AppearanceTheme.self, forKey: .theme)) ?? .system
    if let decoded = try? c.decode(SolidBubbleMode.self, forKey: .solidBubbles) {
      solidBubbles = decoded
    } else if let legacySolidResponses =
      (try? c.decode(Bool.self, forKey: .solidResponseBubbles))
      ?? (try? c.decode(Bool.self, forKey: .colorizeResponseBubbles))
    {
      solidBubbles = legacySolidResponses ? .both : .user
    } else {
      solidBubbles = .user
    }
    liveMarkdown = (try? c.decode(Bool.self, forKey: .liveMarkdown)) ?? true
    justifyText = (try? c.decode(Bool.self, forKey: .justifyText)) ?? false
    unwrappedTables = (try? c.decode(Bool.self, forKey: .unwrappedTables)) ?? false
    scrollToFollowResponses =
      (try? c.decode(Bool.self, forKey: .scrollToFollowResponses)) ?? true
    hapticsEnabled = (try? c.decode(Bool.self, forKey: .hapticsEnabled)) ?? true
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(userFontFamily, forKey: .userFontFamily)
    try c.encode(assistantFontFamily, forKey: .assistantFontFamily)
    try c.encode(fontSize, forKey: .fontSize)
    try c.encode(lineSpacing, forKey: .lineSpacing)
    try c.encode(zoomMethod, forKey: .zoomMethod)
    try c.encode(tint, forKey: .tint)
    try c.encode(theme, forKey: .theme)
    try c.encode(solidBubbles, forKey: .solidBubbles)
    try c.encode(liveMarkdown, forKey: .liveMarkdown)
    try c.encode(justifyText, forKey: .justifyText)
    try c.encode(unwrappedTables, forKey: .unwrappedTables)
    try c.encode(scrollToFollowResponses, forKey: .scrollToFollowResponses)
    try c.encode(hapticsEnabled, forKey: .hapticsEnabled)
  }
}

enum LiveSpeechRecognitionBackend: String, Codable, CaseIterable, Identifiable, Sendable {
  case nativeIOSSpeechTranscriber
  case nativeIOS

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .nativeIOSSpeechTranscriber: "Native iOS Live"
    case .nativeIOS: "Native iOS File"
    }
  }

  var systemImage: String {
    switch self {
    case .nativeIOSSpeechTranscriber: "waveform.and.mic"
    case .nativeIOS: "doc.badge.waveform"
    }
  }

  var isRuntimeAvailable: Bool {
    switch self {
    case .nativeIOSSpeechTranscriber:
      if #available(iOS 26.0, *) {
        return true
      }
      return false
    case .nativeIOS:
      return true
    }
  }

  var unavailableReason: String? {
    guard !isRuntimeAvailable else { return nil }
    switch self {
    case .nativeIOSSpeechTranscriber:
      return "Requires iOS 26 or later."
    case .nativeIOS:
      return nil
    }
  }

  static var defaultBackend: LiveSpeechRecognitionBackend {
    if #available(iOS 26.0, *) {
      return .nativeIOSSpeechTranscriber
    }
    return .nativeIOS
  }

}

struct ConversationSettings: Codable, Equatable, Sendable {
  static let silenceTimeoutRange: ClosedRange<Double> = 0.5...8
  static let silenceTimeoutStep: Double = 0.25

  var silenceTimeoutSeconds: Double = 1.25
  var speechRecognitionBackend: LiveSpeechRecognitionBackend = LiveSpeechRecognitionBackend
    .defaultBackend
  var speechRecognitionLanguageIdentifier: String = Locale.current.identifier
  var streamTTS: Bool = true
  var skipTechnicalContentInTTS: Bool = true
  var backgroundVoiceListeningEnabled: Bool = false

  static let defaults = ConversationSettings()

  init() {}

  var canUseBackgroundVoiceListening: Bool {
    speechRecognitionBackend == .nativeIOSSpeechTranscriber
  }

  var allowsBackgroundVoiceListening: Bool {
    canUseBackgroundVoiceListening && backgroundVoiceListeningEnabled
  }

  enum CodingKeys: String, CodingKey {
    case silenceTimeoutSeconds, speechRecognitionBackend, speechRecognitionLanguageIdentifier,
      streamTTS, skipTechnicalContentInTTS, backgroundVoiceListeningEnabled
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = ConversationSettings.defaults
    let timeout =
      (try? c.decode(Double.self, forKey: .silenceTimeoutSeconds))
      ?? defaults.silenceTimeoutSeconds
    silenceTimeoutSeconds = Self.clampedSilenceTimeout(timeout)
    let decodedBackend =
      (try? c.decode(LiveSpeechRecognitionBackend.self, forKey: .speechRecognitionBackend))
      ?? defaults.speechRecognitionBackend
    speechRecognitionBackend =
      decodedBackend.isRuntimeAvailable
      ? decodedBackend : LiveSpeechRecognitionBackend.defaultBackend
    let languageIdentifier =
      (try? c.decode(String.self, forKey: .speechRecognitionLanguageIdentifier))
      ?? defaults.speechRecognitionLanguageIdentifier
    speechRecognitionLanguageIdentifier =
      languageIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? defaults.speechRecognitionLanguageIdentifier
      : languageIdentifier
    streamTTS =
      (try? c.decode(Bool.self, forKey: .streamTTS)) ?? defaults.streamTTS
    skipTechnicalContentInTTS =
      (try? c.decode(Bool.self, forKey: .skipTechnicalContentInTTS))
      ?? defaults.skipTechnicalContentInTTS
    backgroundVoiceListeningEnabled =
      (try? c.decode(Bool.self, forKey: .backgroundVoiceListeningEnabled))
      ?? defaults.backgroundVoiceListeningEnabled
  }

  static func clampedSilenceTimeout(_ value: Double) -> Double {
    min(max(value, silenceTimeoutRange.lowerBound), silenceTimeoutRange.upperBound)
  }
}

enum BuiltInToolID: String, Codable, CaseIterable, Identifiable, Sendable {
  case datetime
  case language
  case location
  case weather
  case webSearch
  case todo
  case calculator
  case textToSpeech
  case files
  case calendar
  case clipboard
  case alarms
  case webxdc
  case github
  case mastodon
  case browser
  case memory

  var id: String { rawValue }

  /// Keeps known tool IDs and drops unknown ones, so chats written by newer
  /// builds keep loading on older ones instead of failing to decode.
  static func knownTools(from rawValues: [String]?) -> Set<BuiltInToolID> {
    Set((rawValues ?? []).compactMap(BuiltInToolID.init(rawValue:)))
  }

  var isContextSource: Bool {
    switch self {
    case .datetime, .language, .location, .memory:
      return true
    case .weather, .webSearch, .todo, .calculator, .textToSpeech, .files, .calendar, .clipboard,
      .alarms, .webxdc, .github, .mastodon, .browser:
      return false
    }
  }

  var isCallableTool: Bool {
    switch self {
    case .weather, .webSearch, .todo, .calculator, .textToSpeech, .files, .calendar, .clipboard,
      .alarms, .webxdc, .github, .mastodon, .browser:
      return true
    case .datetime, .language, .location, .memory:
      return false
    }
  }

  var displayName: String {
    switch self {
    case .datetime: "Date & Time"
    case .language: "Language Preference"
    case .location: "Location"
    case .weather: "Weather"
    case .webSearch: "Web Search"
    case .todo: "Todo"
    case .calculator: "Calculator"
    case .textToSpeech: "Text to Speech"
    case .files: "Files"
    case .calendar: "Calendar"
    case .clipboard: "Clipboard"
    case .alarms: "Alarms"
    case .webxdc: "WebXDC Apps"
    case .github: "GitHub"
    case .mastodon: "Mastodon"
    case .browser: "Browser"
    case .memory: "Memory"
    }
  }

  var systemImage: String {
    switch self {
    case .datetime: "clock"
    case .language: "globe"
    case .location: "location"
    case .weather: "cloud.sun"
    case .webSearch: "magnifyingglass"
    case .todo: "checklist"
    case .calculator: "function"
    case .textToSpeech: "speaker.wave.2"
    case .files: "folder"
    case .calendar: "calendar"
    case .clipboard: "doc.on.clipboard"
    case .alarms: "alarm"
    case .webxdc: "square.grid.2x2"
    case .github: "arrow.triangle.branch"
    case .mastodon: "bubble.left.and.bubble.right"
    case .browser: "safari"
    case .memory: "brain"
    }
  }

  var isDisabledInAirplaneMode: Bool {
    switch self {
    case .weather, .webSearch, .github, .mastodon, .browser:
      return true
    case .datetime, .language, .location, .todo, .calculator, .textToSpeech, .files, .calendar,
      .clipboard, .alarms, .webxdc, .memory:
      return false
    }
  }

}

extension ToolCallingMode {
  func textProtocolFallback(for provider: ProviderKind) -> ToolCallingMode {
    if self == .native, provider == .mlx {
      return .json
    }
    return textProtocolFallback
  }

  func appleInstruction(hasToolResults: Bool) -> String {
    if hasToolResults {
      return
        "Continue from the latest host tool result. Either emit one more \(callReference) for a host tool if another host tool run is needed, or call respond with action and content."
    }
    return
      "Reply to the latest user message. If you need a tool, emit one \(callReference) and stop; otherwise answer directly."
  }

  private var callReference: String {
    switch self {
    case .text: "TOOL_CALL block"
    case .xml: "<tool_call> block"
    case .json: "tool-call JSON object"
    case .native: "TOOL_CALL block"
    }
  }
}

typealias ReasoningLevel = MaiCore.ReasoningEffort

extension ReasoningLevel {
  var systemImage: String {
    switch self {
    case .automatic: "brain"
    case .disabled: "xmark.circle"
    case .minimal: "tortoise"
    case .low: "speedometer"
    case .medium: "circle.lefthalf.filled"
    case .high: "flame"
    case .xhigh, .max: "flame.fill"
    }
  }
}

enum ContextWindowMode: String, Codable, CaseIterable, Identifiable, Sendable {
  case full
  case last10
  case last5
  case lastMessage
  case none

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .full: "Full"
    case .last10: "Last 10 messages"
    case .last5: "Last 5 messages"
    case .lastMessage: "Last Message"
    case .none: "None"
    }
  }

  var messageLimit: Int? {
    switch self {
    case .full: nil
    case .last10: 10
    case .last5: 5
    case .lastMessage: 1
    case .none: 0
    }
  }
}

enum OpenAPIServerConversationScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case currentChat
  case defaultSettings

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .currentChat:
      return "Current Chat Model"
    case .defaultSettings:
      return "Default Model"
    }
  }

  var summary: String {
    switch self {
    case .currentChat:
      return
        "Requests use only the selected chat's provider and model. Client messages stay isolated and are not saved to the chat."
    case .defaultSettings:
      return
        "Requests use the default provider and model. Client messages stay isolated and are not saved to the selected chat."
    }
  }
}

struct OpenAPIServerSettings: Codable, Equatable, Sendable {
  static let defaultPort = 11_434
  static let portRange: ClosedRange<Int> = 1_024...65_535

  var port: Int = OpenAPIServerSettings.defaultPort
  var conversationScope: OpenAPIServerConversationScope = .currentChat
  var allowClientOverrides: Bool = false
  var allowToolExecution: Bool = false

  init() {}

  enum CodingKeys: String, CodingKey {
    case port, conversationScope, allowClientOverrides, allowToolExecution
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    port = Self.clampedPort((try? c.decode(Int.self, forKey: .port)) ?? Self.defaultPort)
    conversationScope =
      (try? c.decode(OpenAPIServerConversationScope.self, forKey: .conversationScope))
      ?? .currentChat
    allowClientOverrides =
      (try? c.decode(Bool.self, forKey: .allowClientOverrides)) ?? false
    allowToolExecution =
      (try? c.decode(Bool.self, forKey: .allowToolExecution)) ?? false
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(Self.clampedPort(port), forKey: .port)
    try c.encode(conversationScope, forKey: .conversationScope)
    try c.encode(allowClientOverrides, forKey: .allowClientOverrides)
    try c.encode(allowToolExecution, forKey: .allowToolExecution)
  }

  static func clampedPort(_ value: Int) -> Int {
    min(max(value, portRange.lowerBound), portRange.upperBound)
  }
}

enum MLXKVCacheSize: Int, Codable, CaseIterable, Identifiable, Sendable {
  case auto = 0
  case size1024 = 1024
  case size2048 = 2048
  case size4096 = 4096
  case size8192 = 8192
  case size16384 = 16384

  var id: Int { rawValue }

  var effectiveSize: Int {
    guard case .auto = self else { return rawValue }
    let gb = ProcessInfo.processInfo.physicalMemory / (1_024 * 1_024 * 1_024)
    switch gb {
    case ..<6: return 2_048
    case ..<8: return 4_096
    case ..<16: return 8_192
    default: return 16_384
    }
  }

  var displayName: String {
    switch self {
    case .auto:
      let effective = effectiveSize
      let formatted =
        effective >= 1_000
        ? "\(effective / 1_000),\(String(format: "%03d", effective % 1_000))" : "\(effective)"
      return "Auto (\(formatted) tokens)"
    case .size1024: return "1,024 tokens"
    case .size2048: return "2,048 tokens"
    case .size4096: return "4,096 tokens"
    case .size8192: return "8,192 tokens"
    case .size16384: return "16,384 tokens"
    }
  }
}

enum AttachmentImageSize: String, Codable, CaseIterable, Identifiable, Sendable {
  case prompt
  case tiny
  case small
  case medium
  case big
  case full

  static var concreteCases: [AttachmentImageSize] {
    allCases.filter { $0 != .prompt }
  }

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .prompt: "Prompt"
    case .tiny: "Tiny"
    case .small: "Small"
    case .medium: "Medium"
    case .big: "Big"
    case .full: "Original"
    }
  }

  var maxDimension: Int? {
    switch self {
    case .prompt:
      nil
    case .tiny: 100
    case .small: 320
    case .medium: 640
    case .big: 1024
    case .full: nil
    }
  }
}

typealias WebSearchProvider = MaiWebSearchProvider

extension MaiWebSearchProvider {
  var displayName: String {
    switch self {
    case .duckDuckGo: "DuckDuckGo"
    case .wikipedia: "Wikipedia"
    case .exa: "Exa"
    case .searXNG: "SearXNG"
    case .ollama: "Ollama Web Search"
    case .all: "All"
    }
  }
}

enum ChatAttachmentKind: String, Codable, Sendable {
  case textFile
  case image
}

struct ChatAttachment: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var kind: ChatAttachmentKind
  var filename: String
  var mimeType: String
  var text: String?
  var dataBase64: String?
  var width: Int?
  var height: Int?

  static func textFile(filename: String, text: String, mimeType: String = "text/plain")
    -> ChatAttachment
  {
    ChatAttachment(kind: .textFile, filename: filename, mimeType: mimeType, text: text)
  }

  static func image(
    filename: String,
    data: Data,
    mimeType: String = "image/jpeg",
    width: Int?,
    height: Int?
  ) -> ChatAttachment {
    ChatAttachment(
      kind: .image,
      filename: filename,
      mimeType: mimeType,
      dataBase64: data.base64EncodedString(),
      width: width,
      height: height)
  }

  var displayName: String {
    filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Attachment" : filename
  }

  var dataURL: String? {
    guard kind == .image, let dataBase64, !dataBase64.isEmpty else { return nil }
    return "data:\(mimeType);base64,\(dataBase64)"
  }
}

/// Metrics for one or more model calls behind an assistant message. The type
/// is MaiCore's `ModelCallStats`, shared with the pmai REPL, under the name
/// PocketMai's persisted conversations have always used; its property names
/// are the JSON keys, so older chats keep decoding.
typealias GenerationStats = ModelCallStats

struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var role: ChatRole
  var text: String
  var displayText: String? = nil
  var createdAt: Date = Date()
  var voiceRecordingFilename: String? = nil
  var attachments: [ChatAttachment] = []
  var stats: GenerationStats? = nil

  enum CodingKeys: String, CodingKey {
    case id, role, text, displayText, createdAt, voiceRecordingFilename, attachments, stats
  }

  init(
    id: UUID = UUID(),
    role: ChatRole,
    text: String,
    displayText: String? = nil,
    createdAt: Date = Date(),
    voiceRecordingFilename: String? = nil,
    attachments: [ChatAttachment] = [],
    stats: GenerationStats? = nil
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.displayText = displayText
    self.createdAt = createdAt
    self.voiceRecordingFilename = voiceRecordingFilename
    self.attachments = attachments
    self.stats = stats
  }

  var presentationText: String {
    guard let displayText,
      !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return text
    }
    return displayText
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    role = try c.decode(ChatRole.self, forKey: .role)
    text = try c.decode(String.self, forKey: .text)
    displayText = try? c.decode(String.self, forKey: .displayText)
    createdAt = try c.decode(Date.self, forKey: .createdAt)
    voiceRecordingFilename = try? c.decode(String.self, forKey: .voiceRecordingFilename)
    attachments = (try? c.decode([ChatAttachment].self, forKey: .attachments)) ?? []
    stats = try? c.decode(GenerationStats.self, forKey: .stats)
  }
}

struct MessageBookmark: Codable, Equatable, Sendable {
  var conversationID: UUID
  var messageID: UUID
  var createdAt: Date
  var isPinned: Bool = false

  var storageKey: String {
    "\(conversationID.uuidString)/\(messageID.uuidString)"
  }
}

struct BookmarkedMessage: Identifiable, Equatable, Sendable {
  var bookmark: MessageBookmark
  var message: ChatMessage
  var conversationTitle: String

  var id: String { bookmark.storageKey }
}

struct MessageNavigationRequest: Identifiable, Equatable, Sendable {
  let id = UUID()
  var conversationID: UUID
  var messageID: UUID
}

/// A user turn waiting for the active assistant loop to reach a safe interruption point.
/// Queued turns are runtime state, not conversation history, until the loop consumes them.
struct QueuedChatMessage: Identifiable, Equatable, Sendable {
  var id: UUID = UUID()
  var text: String
  var createdAt: Date = Date()
  var attachments: [ChatAttachment] = []
}

/// The fields that can change a bubble's rendered output. Image payloads are deliberately absent:
/// attachment identity and metadata select the async image cache without comparing base64 strings.
struct ChatMessageRenderKey: Equatable, Sendable {
  struct Attachment: Equatable, Sendable {
    let id: UUID
    let kind: String
    let filename: String
    let mimeType: String
    let text: String?
    let hasImageData: Bool
    let width: Int?
    let height: Int?

    init(_ attachment: ChatAttachment) {
      id = attachment.id
      kind = attachment.kind.rawValue
      filename = attachment.filename
      mimeType = attachment.mimeType
      text = attachment.kind == .textFile ? attachment.text : nil
      hasImageData = attachment.dataBase64?.isEmpty == false
      width = attachment.width
      height = attachment.height
    }
  }

  let id: UUID
  let role: ChatRole
  let text: String
  let displayText: String?
  let createdAt: Date
  let voiceRecordingFilename: String?
  let attachments: [Attachment]
  let stats: GenerationStats?

  init(_ message: ChatMessage) {
    id = message.id
    role = message.role
    text = message.text
    displayText = message.displayText
    createdAt = message.createdAt
    voiceRecordingFilename = message.voiceRecordingFilename
    attachments = message.attachments.map(Attachment.init)
    stats = message.stats
  }
}

struct ConversationPreviewMessage: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var role: ChatRole
  var text: String
  var displayText: String?
  var createdAt: Date

  init(message: ChatMessage) {
    id = message.id
    role = message.role
    text = Self.clippedText(message.text)
    displayText = message.displayText.map(Self.clippedText)
    createdAt = message.createdAt
  }

  var chatMessage: ChatMessage {
    ChatMessage(
      id: id,
      role: role,
      text: text,
      displayText: displayText,
      createdAt: createdAt)
  }

  private static func clippedText(_ text: String) -> String {
    let limit = 6_000
    guard text.count > limit else { return text }
    return String(text.prefix(limit)) + "..."
  }
}

/// A user-picked working folder outside the app sandbox, kept reachable across
/// launches through a security-scoped bookmark.
struct WorkingFolderReference: Codable, Equatable, Sendable {
  var bookmarkData: Data
  var displayName: String

  init(bookmarkData: Data, displayName: String) {
    self.bookmarkData = bookmarkData
    self.displayName = Self.normalizedDisplayName(displayName)
  }

  static func normalizedDisplayName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "Working Folder" : trimmed
  }
}

/// How a chat resolves the folder the Files tools work in.
enum ConversationWorkingFolderMode: Equatable, Sendable {
  /// The Files tools are off for the chat, so no working folder is reachable.
  case disabled
  /// The chat inherits its chat folder's default, else the built-in workspace.
  case inherited
  /// The chat picked its own folder.
  case custom
}

struct ConversationFolderDefaults: Codable, Equatable, Sendable {
  var systemPromptID: UUID?
  var provider: ProviderKind?
  var endpointID: UUID?
  var modelID: String
  var workingFolder: WorkingFolderReference?

  init(
    systemPromptID: UUID? = nil,
    provider: ProviderKind? = nil,
    endpointID: UUID? = nil,
    modelID: String = "",
    workingFolder: WorkingFolderReference? = nil
  ) {
    self.systemPromptID = systemPromptID
    self.provider = provider
    self.endpointID = endpointID
    self.modelID = modelID
    self.workingFolder = workingFolder
  }

  var usesAppDefaults: Bool {
    systemPromptID == nil
      && provider == nil
      && endpointID == nil
      && modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && workingFolder == nil
  }
}

struct ConversationFolder: Identifiable, Codable, Equatable, Sendable {
  static let defaultID = "default"
  static let iCloudID = "icloud"
  static let archivedID = "archived"
  static let reservedIDs: Set<String> = [defaultID, iCloudID, archivedID]

  var id: String
  var name: String
  var icon: String?
  var tint: ConversationFolderTint?
  var createdAt: Date

  init(
    id: String = UUID().uuidString,
    name: String,
    icon: String? = nil,
    tint: ConversationFolderTint? = nil,
    createdAt: Date = Date()
  ) {
    self.id = Self.normalizedID(id)
    self.name = name
    self.icon = Self.normalizedIcon(icon)
    self.tint = tint
    self.createdAt = createdAt
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = Self.normalizedID((try? c.decode(String.self, forKey: .id)) ?? "")
    name = (try? c.decode(String.self, forKey: .name)) ?? ""
    let decodedIcon = try? c.decode(String.self, forKey: .icon)
    icon = Self.normalizedIcon(decodedIcon)
    tint = try? c.decode(ConversationFolderTint.self, forKey: .tint)
    createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
  }

  var displayName: String {
    switch id {
    case Self.defaultID:
      return "Default"
    case Self.iCloudID:
      return "iCloud"
    case Self.archivedID:
      return "Archived"
    default:
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmedName.isEmpty ? "Untitled" : trimmedName
    }
  }

  var systemImage: String {
    switch id {
    case Self.defaultID:
      return "tray"
    case Self.iCloudID:
      return "icloud"
    case Self.archivedID:
      return "archivebox"
    default:
      if let icon, !icon.isEmpty {
        return icon
      }
      return "folder"
    }
  }

  var isSystem: Bool {
    Self.reservedIDs.contains(id)
  }

  static let defaultFolder = ConversationFolder(
    id: Self.defaultID,
    name: "Default",
    createdAt: .distantPast)
  static let iCloudFolder = ConversationFolder(
    id: Self.iCloudID,
    name: "iCloud",
    createdAt: .distantPast)
  static let archivedFolder = ConversationFolder(
    id: Self.archivedID,
    name: "Archived",
    createdAt: .distantPast)

  static func normalizedID(_ id: String) -> String {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? UUID().uuidString : trimmed
  }

  static func normalizedIcon(_ icon: String?) -> String? {
    guard let trimmed = icon?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }

  static func normalizedCustomName(_ name: String) -> String {
    name.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct ConversationSummary: Identifiable, Codable, Equatable, Sendable {
  static let recentCacheLimit = 3

  var id: UUID
  var title: String
  var createdAt: Date
  var updatedAt: Date
  var isPinned: Bool
  var isUnread: Bool
  var folderID: String
  var preview: String
  var hasMessages: Bool
  var previewMessages: [ConversationPreviewMessage]

  init(conversation: Conversation) {
    id = conversation.id
    title = conversation.title
    createdAt = conversation.createdAt
    updatedAt = conversation.updatedAt
    isPinned = conversation.isPinned
    isUnread = conversation.isUnread
    folderID = conversation.folderID
    hasMessages = !conversation.messages.isEmpty
    preview = Self.previewText(from: conversation.messages)
    previewMessages = Self.previewMessages(from: conversation.messages)
  }

  var isArchived: Bool {
    folderID == ConversationFolder.archivedID
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AgentChat.placeholderTitle : title
  }

  var displayPreview: String {
    let plainText = MessageContentFilter.markdownPlainText(from: preview)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return plainText.isEmpty ? "No messages" : plainText
  }

  private static func previewText(from messages: [ChatMessage]) -> String {
    messages.reversed().compactMap(previewText(from:)).first ?? ""
  }

  private static func previewText(from message: ChatMessage) -> String? {
    guard message.role == .user || message.role == .assistant else { return nil }
    let text = MessageContentFilter.previewText(from: message.presentationText)
    guard !text.isEmpty else { return nil }
    return text
  }

  private static func previewMessages(from messages: [ChatMessage])
    -> [ConversationPreviewMessage]
  {
    messages
      .filter { $0.role == .user || $0.role == .assistant }
      .suffix(6)
      .map(ConversationPreviewMessage.init(message:))
  }

  static func mostRecent(
    _ summaries: [ConversationSummary],
    limit: Int = recentCacheLimit
  ) -> [ConversationSummary] {
    guard limit > 0 else { return [] }
    return Array(
      summaries
        .filter(\.hasMessages)
        .sorted { lhs, rhs in
          if lhs.updatedAt != rhs.updatedAt {
            return lhs.updatedAt > rhs.updatedAt
          }
          return lhs.createdAt > rhs.createdAt
        }
        .prefix(limit))
  }

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case createdAt
    case updatedAt
    case isPinned
    case isUnread
    case isArchived
    case folderID
    case preview
    case hasMessages
    case previewMessages
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    isPinned = try container.decode(Bool.self, forKey: .isPinned)
    isUnread = (try? container.decode(Bool.self, forKey: .isUnread)) ?? false
    let legacyArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
    folderID = Conversation.normalizedFolderID(
      try? container.decode(String.self, forKey: .folderID),
      legacyIsArchived: legacyArchived)
    preview = (try? container.decode(String.self, forKey: .preview)) ?? ""
    hasMessages = (try? container.decode(Bool.self, forKey: .hasMessages)) ?? true
    previewMessages =
      (try? container.decode([ConversationPreviewMessage].self, forKey: .previewMessages)) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(isPinned, forKey: .isPinned)
    try container.encode(isUnread, forKey: .isUnread)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encode(folderID, forKey: .folderID)
    try container.encode(preview, forKey: .preview)
    try container.encode(hasMessages, forKey: .hasMessages)
    try container.encode(previewMessages, forKey: .previewMessages)
  }
}

struct Conversation: Identifiable, Codable, Equatable, Sendable {
  var id: UUID = UUID()
  var title: String = AgentChat.placeholderTitle
  var messages: [ChatMessage] = []
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var provider: ProviderKind = .mlx
  var modelID: String = AppSettings.localMLXDefaultModelID
  var endpointID: UUID? = nil
  var systemPromptID: UUID? = nil
  var toolsEnabled: Bool = true
  var enabledTools: Set<BuiltInToolID> = AppSettings.defaultTools
  var usesStreaming: Bool = true
  var isPinned: Bool = false
  var isUnread: Bool = false
  var enabledMCPServers: Set<UUID> = AppSettings.defaultMCPServers
  var enabledMCPTools: Set<String> = AppSettings.defaultMCPTools
  var disabledMCPTools: Set<String> = []
  var reasoningLevel: ReasoningLevel = .automatic
  var showThinking: Bool = false
  // nil inherits the app-wide setting. These overrides are especially useful
  // for local models where tool transcripts consume the KV cache quickly.
  var contextWindowMode: ContextWindowMode? = nil
  var mlxMaxKVSize: MLXKVCacheSize? = nil
  var lastContextSignature: String? = nil
  var folderID: String = ConversationFolder.defaultID
  var languageOverrideIdentifier: String? = nil
  var workingFolder: WorkingFolderReference? = nil
  /// The session this conversation presents to providers, minted by MaiCore
  /// when the conversation is created and kept in its file; a child agent's
  /// transient conversation carries its parent's. See `ChatSession`.
  var sessionID: String = ChatSession.newID()
  /// Durable child-agent process trees, including every child transcript.
  /// Runtime pids are restored under a fresh conversation process on load;
  /// `runID` and `parentRunID` preserve identity and nesting across sessions.
  var subagents: [AgentProcessRecord] = []

  var isArchived: Bool {
    get { folderID == ConversationFolder.archivedID }
    set { folderID = newValue ? ConversationFolder.archivedID : ConversationFolder.defaultID }
  }

  init() {}

  enum CodingKeys: String, CodingKey {
    case id
    case title
    case messages
    case createdAt
    case updatedAt
    case provider
    case modelID
    case endpointID
    case systemPromptID
    case toolsEnabled
    case enabledTools
    case usesStreaming
    case isPinned
    case isUnread
    case enabledMCPServers
    case enabledMCPTools
    case disabledMCPTools
    case reasoningLevel
    case showThinking
    case contextWindowMode
    case mlxMaxKVSize
    case lastContextSignature
    case lastToolContextSignature
    case folderID
    case isArchived
    case languageOverrideIdentifier
    case workingFolder
    case sessionID
    case subagents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    sessionID =
      (try? container.decode(String.self, forKey: .sessionID)) ?? ChatSession.legacyID(for: id)
    title = try container.decode(String.self, forKey: .title)
    messages = try container.decode([ChatMessage].self, forKey: .messages)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    provider = try container.decode(ProviderKind.self, forKey: .provider)
    modelID = try container.decode(String.self, forKey: .modelID)
    endpointID = try container.decodeIfPresent(UUID.self, forKey: .endpointID)
    systemPromptID = try container.decodeIfPresent(UUID.self, forKey: .systemPromptID)
    toolsEnabled = (try? container.decode(Bool.self, forKey: .toolsEnabled)) ?? true
    enabledTools = BuiltInToolID.knownTools(
      from: try? container.decode([String].self, forKey: .enabledTools))
    usesStreaming = try container.decode(Bool.self, forKey: .usesStreaming)
    isPinned = (try? container.decode(Bool.self, forKey: .isPinned)) ?? false
    isUnread = (try? container.decode(Bool.self, forKey: .isUnread)) ?? false
    enabledMCPServers =
      (try? container.decode(Set<UUID>.self, forKey: .enabledMCPServers)) ?? []
    enabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .enabledMCPTools)) ?? []
    disabledMCPTools =
      (try? container.decode(Set<String>.self, forKey: .disabledMCPTools)) ?? []
    reasoningLevel =
      (try? container.decode(ReasoningLevel.self, forKey: .reasoningLevel)) ?? .automatic
    showThinking = (try? container.decode(Bool.self, forKey: .showThinking)) ?? false
    contextWindowMode = try? container.decodeIfPresent(
      ContextWindowMode.self, forKey: .contextWindowMode)
    mlxMaxKVSize = try? container.decodeIfPresent(MLXKVCacheSize.self, forKey: .mlxMaxKVSize)
    lastContextSignature =
      (try? container.decodeIfPresent(String.self, forKey: .lastContextSignature))
      ?? (try? container.decodeIfPresent(String.self, forKey: .lastToolContextSignature))
    let legacyArchived = (try? container.decode(Bool.self, forKey: .isArchived)) ?? false
    folderID = Self.normalizedFolderID(
      try? container.decode(String.self, forKey: .folderID),
      legacyIsArchived: legacyArchived)
    let decodedLanguageOverride =
      (try? container.decodeIfPresent(String.self, forKey: .languageOverrideIdentifier)) ?? nil
    languageOverrideIdentifier = Self.normalizedLanguageOverride(decodedLanguageOverride)
    workingFolder =
      (try? container.decodeIfPresent(WorkingFolderReference.self, forKey: .workingFolder)) ?? nil
    subagents =
      (try? container.decodeIfPresent([AgentProcessRecord].self, forKey: .subagents)) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(title, forKey: .title)
    try container.encode(messages, forKey: .messages)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(updatedAt, forKey: .updatedAt)
    try container.encode(provider, forKey: .provider)
    try container.encode(modelID, forKey: .modelID)
    try container.encodeIfPresent(endpointID, forKey: .endpointID)
    try container.encodeIfPresent(systemPromptID, forKey: .systemPromptID)
    try container.encode(toolsEnabled, forKey: .toolsEnabled)
    try container.encode(enabledTools, forKey: .enabledTools)
    try container.encode(usesStreaming, forKey: .usesStreaming)
    try container.encode(isPinned, forKey: .isPinned)
    try container.encode(isUnread, forKey: .isUnread)
    try container.encode(enabledMCPServers, forKey: .enabledMCPServers)
    try container.encode(enabledMCPTools, forKey: .enabledMCPTools)
    try container.encode(disabledMCPTools, forKey: .disabledMCPTools)
    try container.encode(reasoningLevel, forKey: .reasoningLevel)
    try container.encode(showThinking, forKey: .showThinking)
    try container.encodeIfPresent(contextWindowMode, forKey: .contextWindowMode)
    try container.encodeIfPresent(mlxMaxKVSize, forKey: .mlxMaxKVSize)
    try container.encodeIfPresent(lastContextSignature, forKey: .lastContextSignature)
    try container.encode(folderID, forKey: .folderID)
    try container.encode(isArchived, forKey: .isArchived)
    try container.encodeIfPresent(
      Self.normalizedLanguageOverride(languageOverrideIdentifier),
      forKey: .languageOverrideIdentifier)
    try container.encodeIfPresent(workingFolder, forKey: .workingFolder)
    try container.encode(sessionID, forKey: .sessionID)
    if !subagents.isEmpty {
      try container.encode(subagents, forKey: .subagents)
    }
  }

  var displayTitle: String {
    title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? AgentChat.placeholderTitle : title
  }

  static func normalizedFolderID(_ id: String?, legacyIsArchived: Bool = false) -> String {
    let trimmed = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !trimmed.isEmpty {
      return trimmed
    }
    return legacyIsArchived ? ConversationFolder.archivedID : ConversationFolder.defaultID
  }

  /// Names a placeholder after its first message, the way pmai does.
  mutating func refreshTitle(from message: String) {
    guard AgentChat.isPlaceholderTitle(title) else { return }
    title = AgentChat.derivedTitle(from: message) ?? AgentChat.placeholderTitle
  }

  var effectiveLanguageOverrideIdentifier: String? {
    Self.normalizedLanguageOverride(languageOverrideIdentifier)
  }

  static func normalizedLanguageOverride(_ identifier: String?) -> String? {
    SystemLanguageSupport.normalizedLanguageIdentifier(identifier)
  }
}

/// Conversations are stored through MaiCore's `ChatFileStore`, sharing the
/// file layout and the placeholder rule with pmai.
extension Conversation: StoredChat {
  /// An untouched placeholder nobody pinned earns no file. The app keeps a
  /// placeholder alive on its own when a draft or a reply is pending.
  var isDisposable: Bool {
    AgentChat.isDisposable(
      title: title,
      hasConversation: !messages.isEmpty,
      isBusy: false,
      isKept: isPinned)
  }
}

extension ConversationSummary: ChatRecord {}

extension ConversationSettings {
  func applyingLanguageOverride(from conversation: Conversation?) -> ConversationSettings {
    guard let identifier = conversation?.effectiveLanguageOverrideIdentifier else { return self }
    var copy = self
    copy.speechRecognitionLanguageIdentifier = identifier
    return copy
  }
}

extension RoleVoiceSettings {
  func applyingLanguageOverride(_ identifier: String?) -> RoleVoiceSettings {
    guard provider == .system,
      let identifier = SystemLanguageSupport.normalizedLanguageIdentifier(identifier)
    else {
      return self
    }
    var copy = self
    copy.language = identifier
    copy.voiceIdentifier = ""
    return copy
  }
}

extension VoiceSettings {
  func applyingLanguageOverride(_ identifier: String?) -> VoiceSettings {
    var copy = self
    copy.user = copy.user.applyingLanguageOverride(identifier)
    copy.assistant = copy.assistant.applyingLanguageOverride(identifier)
    return copy
  }
}

extension NativeToolSettings {
  func applyingLanguageOverride(from conversation: Conversation?) -> NativeToolSettings {
    guard let identifier = conversation?.effectiveLanguageOverrideIdentifier else { return self }
    var copy = self
    copy.voices = copy.voices.applyingLanguageOverride(identifier)
    return copy
  }
}

enum EndpointAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case apiKey
  case oauth

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .apiKey: "API Key"
    case .oauth: "OAuth"
    }
  }
}

struct OpenAIEndpoint: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  /// The original Mai provider ID when it is not representable as an iOS
  /// UUID. Keeping it makes repeated CLI/iOS imports stable and reversible.
  var portableID: String?
  var name: String
  var baseURL: String
  var apiKey: String
  var defaultModel: String
  var defaultReasoningLevel: ReasoningLevel
  var isEnabled: Bool
  var authMethod: EndpointAuthMethod
  var oauthIssuer: String
  var oauthClientID: String
  var oauthAudience: String
  var oauthScope: String
  var oauthRedirectURI: String
  var oauthRefreshToken: String
  var oauthAccessTokenExpiresAt: Date?
  var oauthAuthorizeURL: String
  var oauthTokenURL: String
  /// Custom HTTP headers sent with every request to this endpoint. A value
  /// may contain `{{session}}`, which MaiCore replaces with the chat's
  /// session id; see `ProviderHeaders` and `ChatSession`.
  var headers: [String: String]

  init(
    id: UUID = UUID(),
    name: String = "",
    baseURL: String = "https://api.openai.com/v1",
    apiKey: String = "",
    defaultModel: String = "",
    defaultReasoningLevel: ReasoningLevel = .automatic,
    isEnabled: Bool = true,
    authMethod: EndpointAuthMethod = .apiKey,
    oauthIssuer: String = "",
    oauthClientID: String = "",
    oauthAudience: String = "",
    oauthScope: String = "",
    oauthRedirectURI: String = "",
    oauthRefreshToken: String = "",
    oauthAccessTokenExpiresAt: Date? = nil,
    oauthAuthorizeURL: String = "",
    oauthTokenURL: String = "",
    headers: [String: String] = [:],
    portableID: String? = nil
  ) {
    self.id = id
    self.portableID = portableID
    self.name = name
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.defaultModel = defaultModel
    self.defaultReasoningLevel = defaultReasoningLevel
    self.isEnabled = isEnabled
    self.authMethod = authMethod
    self.oauthIssuer = oauthIssuer
    self.oauthClientID = oauthClientID
    self.oauthAudience = oauthAudience
    self.oauthScope = oauthScope
    self.oauthRedirectURI = oauthRedirectURI
    self.oauthRefreshToken = oauthRefreshToken
    self.oauthAccessTokenExpiresAt = oauthAccessTokenExpiresAt
    self.oauthAuthorizeURL = oauthAuthorizeURL
    self.oauthTokenURL = oauthTokenURL
    self.headers = headers
  }

  enum CodingKeys: String, CodingKey {
    case id, portableID, name, baseURL, apiKey, defaultModel, defaultReasoningLevel, isEnabled
    case authMethod, oauthIssuer, oauthClientID, oauthAudience, oauthScope, oauthRedirectURI
    case oauthRefreshToken, oauthAccessTokenExpiresAt
    case oauthAuthorizeURL, oauthTokenURL
    case headers
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(UUID.self, forKey: .id)
    portableID = try? c.decode(String.self, forKey: .portableID)
    name = try c.decode(String.self, forKey: .name)
    baseURL = try c.decode(String.self, forKey: .baseURL)
    apiKey = try c.decode(String.self, forKey: .apiKey)
    defaultModel = try c.decode(String.self, forKey: .defaultModel)
    defaultReasoningLevel =
      (try? c.decode(ReasoningLevel.self, forKey: .defaultReasoningLevel)) ?? .automatic
    isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
    authMethod = (try? c.decode(EndpointAuthMethod.self, forKey: .authMethod)) ?? .apiKey
    oauthIssuer = (try? c.decode(String.self, forKey: .oauthIssuer)) ?? ""
    oauthClientID = (try? c.decode(String.self, forKey: .oauthClientID)) ?? ""
    oauthAudience = (try? c.decode(String.self, forKey: .oauthAudience)) ?? ""
    oauthScope = (try? c.decode(String.self, forKey: .oauthScope)) ?? ""
    oauthRedirectURI = (try? c.decode(String.self, forKey: .oauthRedirectURI)) ?? ""
    oauthRefreshToken = (try? c.decode(String.self, forKey: .oauthRefreshToken)) ?? ""
    oauthAccessTokenExpiresAt =
      try? c.decode(Date.self, forKey: .oauthAccessTokenExpiresAt)
    oauthAuthorizeURL = (try? c.decode(String.self, forKey: .oauthAuthorizeURL)) ?? ""
    oauthTokenURL = (try? c.decode(String.self, forKey: .oauthTokenURL)) ?? ""
    // The same forms a pmai configuration accepts, so a provider JSON written
    // by hand imports too.
    headers = (try? ProviderHeaders.decode(from: c, forKey: .headers)) ?? [:]
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(id, forKey: .id)
    try c.encodeIfPresent(portableID, forKey: .portableID)
    try c.encode(name, forKey: .name)
    try c.encode(baseURL, forKey: .baseURL)
    try c.encode(apiKey, forKey: .apiKey)
    try c.encode(defaultModel, forKey: .defaultModel)
    try c.encode(defaultReasoningLevel, forKey: .defaultReasoningLevel)
    try c.encode(isEnabled, forKey: .isEnabled)
    try c.encode(authMethod, forKey: .authMethod)
    try c.encode(oauthIssuer, forKey: .oauthIssuer)
    try c.encode(oauthClientID, forKey: .oauthClientID)
    try c.encode(oauthAudience, forKey: .oauthAudience)
    try c.encode(oauthScope, forKey: .oauthScope)
    try c.encode(oauthRedirectURI, forKey: .oauthRedirectURI)
    try c.encode(oauthRefreshToken, forKey: .oauthRefreshToken)
    try c.encodeIfPresent(oauthAccessTokenExpiresAt, forKey: .oauthAccessTokenExpiresAt)
    try c.encode(oauthAuthorizeURL, forKey: .oauthAuthorizeURL)
    try c.encode(oauthTokenURL, forKey: .oauthTokenURL)
    if !headers.isEmpty {
      try c.encode(headers, forKey: .headers)
    }
  }

  /// Identifies the fields that affect model/voice discovery, so a cached fetch
  /// can be reused until the URL or credentials actually change.
  var connectionSignature: String {
    (
      [
        baseURL,
        apiKey,
        authMethod.rawValue,
        oauthClientID,
        oauthRefreshToken,
        oauthTokenURL,
        oauthIssuer,
      ] + ProviderHeaders.lines(headers)
    ).joined(separator: "\u{1}")
  }

  static let openAIAuthDefaults = OAuthPresetDefaults(
    issuer: "https://auth.openai.com",
    clientID: "",
    audience: "https://api.openai.com/v1",
    scope: "openid profile email offline_access",
    redirectURI: "pocketmai://oauth/callback",
    baseURL: "https://api.openai.com/v1"
  )

  static let anthropicOAuthDefaults = OAuthPresetDefaults(
    issuer: "https://claude.ai",
    clientID: "",
    audience: "",
    scope: "org:create_api_key user:profile user:inference",
    redirectURI: "pocketmai://oauth/callback",
    baseURL: "https://api.anthropic.com/v1",
    authorizeURL: "https://claude.ai/oauth/authorize",
    tokenURL: "https://console.anthropic.com/v1/oauth/token"
  )

  // Vertex AI's OpenAI-compatible endpoint requires the user's GCP project ID and a
  // region — supply a placeholder so the field is editable rather than blank.
  static let googleOAuthDefaults = OAuthPresetDefaults(
    issuer: "https://accounts.google.com",
    clientID: "",
    audience: "",
    scope: "https://www.googleapis.com/auth/cloud-platform",
    redirectURI: "pocketmai://oauth/callback",
    baseURL:
      "https://us-central1-aiplatform.googleapis.com/v1/projects/YOUR_PROJECT/locations/us-central1/endpoints/openapi",
    authorizeURL: "https://accounts.google.com/o/oauth2/v2/auth",
    tokenURL: "https://oauth2.googleapis.com/token"
  )

  var hasOAuthAccessToken: Bool {
    authMethod == .oauth
      && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  var oauthAccessTokenExpired: Bool {
    guard authMethod == .oauth, let expiry = oauthAccessTokenExpiresAt else { return false }
    return expiry <= Date()
  }
}

struct OAuthPresetDefaults: Sendable {
  let issuer: String
  let clientID: String
  let audience: String
  let scope: String
  let redirectURI: String
  let baseURL: String
  let authorizeURL: String
  let tokenURL: String

  init(
    issuer: String,
    clientID: String,
    audience: String,
    scope: String,
    redirectURI: String,
    baseURL: String,
    authorizeURL: String = "",
    tokenURL: String = ""
  ) {
    self.issuer = issuer
    self.clientID = clientID
    self.audience = audience
    self.scope = scope
    self.redirectURI = redirectURI
    self.baseURL = baseURL
    self.authorizeURL = authorizeURL
    self.tokenURL = tokenURL
  }
}

struct ConversationExportEnvelope: Codable, Equatable, Sendable {
  static let format = "pocketmai.conversation"

  var format: String
  var title: String
  var model: String
  var provider: String
  var exportedAt: Date
  var createdAt: Date
  var pocketMaiVersion: String
  var conversation: Conversation
  /// A packed export. `conversation` remains the first item so older PocketMai
  /// versions can still import a useful, single conversation from this file.
  var conversations: [Conversation]?
  /// The cross-host representation consumed by MaiCore and pmai. Older
  /// PocketMai releases ignore this key and keep importing `conversation`.
  var portable: MaiArchive?
  var toolCallingDebug: ConversationToolCallingDebug?

  init(
    conversation: Conversation,
    exportedAt: Date = Date(),
    pocketMaiVersion: String = Self.currentPocketMaiVersion,
    toolCallingDebug: ConversationToolCallingDebug? = nil
  ) {
    self.format = Self.format
    self.title = conversation.displayTitle
    self.model = conversation.modelID
    self.provider = conversation.provider.rawValue
    self.exportedAt = exportedAt
    self.createdAt = conversation.createdAt
    self.pocketMaiVersion = pocketMaiVersion
    self.conversation = conversation
    self.conversations = nil
    self.portable = nil
    self.toolCallingDebug = toolCallingDebug
  }

  init(
    conversations: [Conversation],
    exportedAt: Date = Date(),
    pocketMaiVersion: String = Self.currentPocketMaiVersion
  ) {
    precondition(!conversations.isEmpty, "A conversation export cannot be empty")
    let first = conversations[0]
    self.format = Self.format
    self.title =
      conversations.count == 1
      ? first.displayTitle
      : "\(conversations.count) Conversations"
    self.model = first.modelID
    self.provider = first.provider.rawValue
    self.exportedAt = exportedAt
    self.createdAt = conversations.map(\.createdAt).min() ?? first.createdAt
    self.pocketMaiVersion = pocketMaiVersion
    self.conversation = first
    self.conversations = conversations.count == 1 ? nil : conversations
    self.portable = nil
    self.toolCallingDebug = nil
  }

  var exportedConversations: [Conversation] {
    guard let conversations, !conversations.isEmpty else { return [conversation] }
    return conversations
  }

  var providerDisplayName: String {
    ProviderKind(rawValue: provider)?.displayName ?? provider
  }

  static var currentPocketMaiVersion: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "Unknown"
    guard let build = info?["CFBundleVersion"] as? String,
      !build.isEmpty,
      build != short
    else {
      return short
    }
    return "\(short) (\(build))"
  }
}

struct ConversationToolCallingDebug: Codable, Equatable, Sendable {
  var selectedMode: String
  var selectedModeDisplayName: String
  var effectiveMode: String
  var effectiveModeDisplayName: String
  var textProtocolFallback: String
  var providerNativeToolCalling: Bool
  var nativeToolCallingUnavailableReason: String?
  var toolCatalogInlinedInPrompt: Bool
  var nativeToolNames: [String]
  var maxToolCallsPerTurn: Int
  var maxRepairTurnsPerTurn: Int
  var mcpRequestTimeoutSeconds: Int?
  var yoloModeEnabled: Bool
  var useToolProxy: Bool
  var airplaneModeEnabled: Bool
  var contextWindowMode: String
  var contextWindowMessageLimit: Int?
  var includeAssistantResponsesInContext: Bool?
  var includeReasoningContentInContext: Bool?
  var defaultEnabledTools: [String]
  var defaultEnabledMCPServers: [String]
  var defaultEnabledMCPTools: [String]
  var toolsEnabled: Bool
  var enabledTools: [String]
  var enabledMCPServers: [String]
  var enabledMCPTools: [String]
  var disabledMCPTools: [String]
  var mcpServers: [ConversationDebugMCPServer]
  var nativeToolSettings: ConversationDebugNativeToolSettings
  var fullToolDefinitions: [ConversationDebugToolDefinition]
  var visibleToolDefinitions: [ConversationDebugToolDefinition]
  var toolPrompt: String
  var contextPrompt: String
  var contextSignature: String
  var lastStoredContextSignature: String?
  var systemPrompt: String
  var providerSystemPrompt: String
  var applePrompt: String?
  var promptMessages: [ConversationDebugPromptMessage]
  var iterations: [ConversationDebugToolIteration]
  var notes: [String]
}

struct ConversationDebugNativeToolSettings: Codable, Equatable, Sendable {
  var includeTimeZone: Bool
  var includeMoonPhase: Bool
  var useGPSLocation: Bool
  var manualLocationConfigured: Bool
  var weatherLocationConfigured: Bool
  var webSearchProvider: String
  var webSearchSearXNGURLConfigured: Bool
  var webSearchSearXNGURLHost: String?
  var webSearchSearXNGUsernameConfigured: Bool
  var webSearchSearXNGPasswordConfigured: Bool
  var webSearchFetchingEnabled: Bool
  var calendarEventCreationEnabled: Bool
  var filesWorkspaceAccessEnabled: Bool
  var filesAdvancedToolsEnabled: Bool
  var configuredToolFilesCount: Int
  var todoCount: Int
}

struct ConversationDebugMCPServer: Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var isEnabled: Bool
  var hasValidScheme: Bool
  var transport: String?
  var connectionStatus: String
}

struct ConversationDebugToolDefinition: Codable, Equatable, Sendable {
  var name: String
  var description: String
  var parameters: [ConversationDebugToolParameter]
  var inputSchemaJSON: String?
}

struct ConversationDebugToolParameter: Codable, Equatable, Sendable {
  var name: String
  var type: String
  var description: String
  var required: Bool
}

struct ConversationDebugPromptMessage: Codable, Equatable, Sendable {
  var role: String
  var content: String
  var reasoningContent: String? = nil
  var toolCallsJSON: String? = nil
  var toolCallID: String? = nil
}

struct ConversationDebugParsedToolCall: Codable, Equatable, Sendable {
  var name: String
  var argumentsJSON: String
  var rawBlock: String
}

struct ConversationDebugToolIteration: Codable, Equatable, Sendable {
  var assistantMessageID: UUID
  var assistantMessageIndex: Int
  var roundIndex: Int
  var source: String = "storedToolRun"
  var createdAt: Date? = nil
  var provider: String? = nil
  var model: String? = nil
  var selectedMode: String? = nil
  var effectiveMode: String? = nil
  var maxToolCallsPerTurn: Int? = nil
  var maxRepairTurnsPerTurn: Int? = nil
  var yoloModeEnabled: Bool? = nil
  var useToolProxy: Bool? = nil
  var nativeToolCallingUnavailableReason: String? = nil
  var requestContext: String? = nil
  var toolPrompt: String? = nil
  var nativeToolNames: [String] = []
  var visibleToolDefinitions: [ConversationDebugToolDefinition]? = nil
  var promptMessages: [ConversationDebugPromptMessage] = []
  var rawModelResponse: String? = nil
  var parsedToolCalls: [ConversationDebugParsedToolCall] = []
  var outcome: String? = nil
  var toolName: String
  var argumentsJSON: String
  var result: String
  var isError: Bool
  var rawBlock: String
}

struct ConversationImportConflict: Equatable, Sendable {
  var existingID: UUID
  var existingTitle: String
  var contentsMatch: Bool
}

struct ConversationImportPreview: Identifiable, Sendable {
  let id = UUID()
  var envelope: ConversationExportEnvelope
  var conflict: ConversationImportConflict?
  var existingTitles: [String] = []

  var conversation: Conversation {
    envelope.conversation
  }

  var suggestedRenameTitle: String {
    let title = envelope.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = title.isEmpty ? "Imported conversation" : title
    guard conflict != nil else { return base }
    return "\(base) (Imported)"
  }
}

struct PendingConversationImportFile: Identifiable, Sendable {
  let id = UUID()
  var filename: String
  var data: Data
}

struct ConversationCollectionImportPreview: Identifiable, Sendable {
  var id: UUID { file.id }
  var file: PendingConversationImportFile
  var envelope: ConversationExportEnvelope

  var conversations: [Conversation] {
    envelope.exportedConversations
  }
}

enum ConversationCollectionImportDestination: Sendable {
  case newFolder(name: String)
  case existingFolder(id: String)
}

enum ConversationImportResolution: Sendable {
  case create(title: String)
  case updateExisting
}

enum SettingsBackupScope: String, CaseIterable, Sendable {
  case everything
  case providers
  case prompts
  case tools
  case conversations
}

enum SettingsBackupSection: String, CaseIterable, Identifiable, Sendable {
  case providers
  case prompts
  case tools
  case conversations

  var id: String { rawValue }
}

struct SettingsBackupSelection: Equatable, Sendable {
  var providers: Bool
  var prompts: Bool
  var tools: Bool
  var conversations: Bool

  init(
    providers: Bool = false,
    prompts: Bool = false,
    tools: Bool = false,
    conversations: Bool = false
  ) {
    self.providers = providers
    self.prompts = prompts
    self.tools = tools
    self.conversations = conversations
  }

  init(scope: SettingsBackupScope) {
    switch scope {
    case .everything:
      self.init(providers: true, prompts: true, tools: true, conversations: true)
    case .providers:
      self.init(providers: true)
    case .prompts:
      self.init(prompts: true)
    case .tools:
      self.init(tools: true)
    case .conversations:
      self.init(conversations: true)
    }
  }

  var isEmpty: Bool {
    !providers && !prompts && !tools && !conversations
  }

  var selectedSections: [SettingsBackupSection] {
    SettingsBackupSection.allCases.filter { contains($0) }
  }

  func contains(_ section: SettingsBackupSection) -> Bool {
    switch section {
    case .providers: providers
    case .prompts: prompts
    case .tools: tools
    case .conversations: conversations
    }
  }

  mutating func set(_ section: SettingsBackupSection, isSelected: Bool) {
    switch section {
    case .providers: providers = isSelected
    case .prompts: prompts = isSelected
    case .tools: tools = isSelected
    case .conversations: conversations = isSelected
    }
  }

  func intersection(_ other: SettingsBackupSelection) -> SettingsBackupSelection {
    SettingsBackupSelection(
      providers: providers && other.providers,
      prompts: prompts && other.prompts,
      tools: tools && other.tools,
      conversations: conversations && other.conversations)
  }
}

struct SettingsProvidersBackup: Codable, Sendable {
  var endpoints: [OpenAIEndpoint]
  var selectedEndpointID: UUID?
  var defaultProvider: ProviderKind?
}

struct SettingsPromptsBackup: Codable, Sendable {
  var prompts: [SystemPrompt]
  var defaultSystemPromptID: UUID?
  var compactPrompt: String?
  var userPrompts: [UserPrompt]? = nil
  var followUps: FollowUpSettings? = nil
}

struct SettingsToolsBackup: Codable, Sendable {
  var toolSettings: NativeToolSettings
  var mcpServers: [MCPServer]
  var mcpRequestTimeoutSeconds: Int?
  var defaultEnabledTools: Set<BuiltInToolID>?
  var defaultEnabledMCPServers: Set<UUID>?
  var defaultEnabledMCPTools: Set<String>?
  var toolCallingMode: ToolCallingMode?
  var maxToolCallsPerTurn: Int?
  var yoloModeEnabled: Bool?
  var useToolProxy: Bool?
}

struct SettingsVoiceRecordingAttachment: Codable, Sendable {
  var filename: String
  var dataBase64: String
}

struct SettingsBackupEnvelope: Codable, Sendable {
  static let format = "pocketmai.backup"
  static let currentVersion = 1

  var format: String
  var version: Int
  var exportedAt: Date
  var pocketMaiVersion: String
  var providers: SettingsProvidersBackup?
  var prompts: SettingsPromptsBackup?
  var tools: SettingsToolsBackup?
  var conversations: [Conversation]?
  var conversationFolders: [ConversationFolder]?
  var conversationFolderDefaults: [String: ConversationFolderDefaults]?
  var voiceRecordings: [SettingsVoiceRecordingAttachment]?
  /// Canonical providers, prompts, MCPs, chats and skills for other Mai
  /// hosts. The legacy fields above remain the source of truth for older iOS
  /// versions and retain PocketMai-only settings without loss.
  var portable: MaiArchive?

  init(
    providers: SettingsProvidersBackup? = nil,
    prompts: SettingsPromptsBackup? = nil,
    tools: SettingsToolsBackup? = nil,
    conversations: [Conversation]? = nil,
    conversationFolders: [ConversationFolder]? = nil,
    conversationFolderDefaults: [String: ConversationFolderDefaults]? = nil,
    voiceRecordings: [SettingsVoiceRecordingAttachment]? = nil,
    portable: MaiArchive? = nil,
    exportedAt: Date = Date(),
    pocketMaiVersion: String = ConversationExportEnvelope.currentPocketMaiVersion
  ) {
    self.format = Self.format
    self.version = Self.currentVersion
    self.exportedAt = exportedAt
    self.pocketMaiVersion = pocketMaiVersion
    self.providers = providers
    self.prompts = prompts
    self.tools = tools
    self.conversations = conversations
    self.conversationFolders = conversationFolders
    self.conversationFolderDefaults = conversationFolderDefaults
    self.voiceRecordings = voiceRecordings
    self.portable = portable
  }
}

enum SettingsImportFileKind: Sendable {
  case backup(SettingsBackupEnvelope)
  case conversation(ConversationExportEnvelope)
  case portable(MaiArchive)
}

struct SettingsImportFilePreview: Identifiable, Sendable {
  let id = UUID()
  var filename: String
  var kind: SettingsImportFileKind
  var sourceData: Data? = nil

  var availableSelection: SettingsBackupSelection {
    switch kind {
    case .backup(let envelope):
      SettingsBackupSelection(
        providers: envelope.providers != nil,
        prompts: envelope.prompts != nil,
        tools: envelope.tools != nil,
        conversations: envelope.conversations != nil)
    case .conversation:
      SettingsBackupSelection(conversations: true)
    case .portable(let archive):
      SettingsBackupSelection(
        providers: archive.settings?.providers != nil,
        prompts: archive.settings?.prompts != nil,
        tools: archive.settings?.mcpServers != nil,
        conversations: archive.chats != nil)
    }
  }

  var pocketMaiVersion: String {
    switch kind {
    case .backup(let envelope):
      envelope.pocketMaiVersion
    case .conversation(let envelope):
      envelope.pocketMaiVersion
    case .portable(let archive):
      archive.generator
    }
  }

  var exportedAt: Date {
    switch kind {
    case .backup(let envelope):
      envelope.exportedAt
    case .conversation(let envelope):
      envelope.exportedAt
    case .portable(let archive):
      archive.exportedAt
    }
  }
}

enum SettingsBackupError: LocalizedError {
  case unreadableFile
  case invalidJSON
  case missingSection(SettingsBackupScope)
  case missingSelectedSection(SettingsBackupSection)
  case emptySelection

  var errorDescription: String? {
    switch self {
    case .unreadableFile: return "The selected file could not be read."
    case .invalidJSON: return "The selected file is not a valid PocketMai JSON file."
    case .missingSection(let scope):
      return "The backup does not contain \(scope.sectionName)."
    case .missingSelectedSection(let section):
      return "The selected file does not contain \(section.sectionName)."
    case .emptySelection:
      return "Choose at least one section."
    }
  }
}

extension SettingsBackupScope {
  var sectionName: String {
    switch self {
    case .everything: return "any data"
    case .providers: return "provider settings"
    case .prompts: return "system prompts"
    case .tools: return "tool settings"
    case .conversations: return "conversations"
    }
  }
}

extension SettingsBackupSection {
  var sectionName: String {
    switch self {
    case .providers: return "provider settings"
    case .prompts: return "prompts"
    case .tools: return "tool settings"
    case .conversations: return "conversations"
    }
  }
}

extension OpenAIEndpoint {
  static let defaultDisplayName = "New Provider"

  var displayName: String {
    let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmedName.isEmpty ? Self.defaultDisplayName : trimmedName
  }
}

// SystemPrompt and UserPrompt live in MaiCore, shared with pmai.

enum PromptShortcutKind: String, Sendable {
  case system
  case user
}

struct PromptShortcutSelection: Equatable, Sendable {
  var kind: PromptShortcutKind
  var id: UUID
}

// ParsedPromptSlashCommand and PromptSlashCommand live in MaiCore: a prompt
// line is read the same way here and in pmai, `/name rest` or `$name rest`.

/// The todo list is shared with pmai: the item, the tools, and the Markdown
/// form live in MaiCore, and the stored keys are unchanged.
typealias TodoItem = AgentTodoItem

struct ToolFile: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  var name: String
  var excerpt: String
  var importedAt: Date

  init(id: UUID = UUID(), name: String, excerpt: String, importedAt: Date = Date()) {
    self.id = id
    self.name = name
    self.excerpt = excerpt
    self.importedAt = importedAt
  }
}

typealias MCPToolDescriptor = ToolDefinition
typealias MCPResourceDescriptor = MaiCore.MCPResourceDescriptor

enum MCPToolSelection {
  static func key(serverID: UUID, toolName: String) -> String {
    "\(serverID.uuidString):\(toolName)"
  }

  static func prefix(serverID: UUID) -> String {
    "\(serverID.uuidString):"
  }
}

enum MCPTransport: String, Codable, Equatable, Identifiable, Sendable {
  case streamableHTTP

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .streamableHTTP:
      return "Streamable HTTP"
    }
  }
}

enum MCPAuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
  case none
  case bearer
  case oauth

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: "None"
    case .bearer: "Bearer Token"
    case .oauth: "OAuth"
    }
  }
}

struct MCPAuthentication: Codable, Equatable, Sendable {
  var method: MCPAuthenticationMethod = .none
  var bearerToken = ""
  var oauthAccessToken = ""
  var oauthRefreshToken = ""
  var oauthAccessTokenExpiresAt: Date?
  var oauthClientID = ""

  enum CodingKeys: String, CodingKey {
    case method, bearerToken, oauthAccessToken, oauthRefreshToken, oauthAccessTokenExpiresAt
    case oauthClientID
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    method = (try? container.decode(MCPAuthenticationMethod.self, forKey: .method)) ?? .none
    bearerToken = (try? container.decode(String.self, forKey: .bearerToken)) ?? ""
    oauthAccessToken = (try? container.decode(String.self, forKey: .oauthAccessToken)) ?? ""
    oauthRefreshToken = (try? container.decode(String.self, forKey: .oauthRefreshToken)) ?? ""
    oauthAccessTokenExpiresAt = try? container.decode(Date.self, forKey: .oauthAccessTokenExpiresAt)
    oauthClientID = (try? container.decode(String.self, forKey: .oauthClientID)) ?? ""
  }

  var accessToken: String? {
    let value: String
    switch method {
    case .none: return nil
    case .bearer: value = bearerToken
    case .oauth: value = oauthAccessToken
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  var oauthAccessTokenExpired: Bool {
    guard method == .oauth, let oauthAccessTokenExpiresAt else { return false }
    return oauthAccessTokenExpiresAt <= Date()
  }

  var oauthAccessTokenNeedsRefresh: Bool {
    guard method == .oauth else { return false }
    let token = oauthAccessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    if token.isEmpty { return true }
    guard let oauthAccessTokenExpiresAt else { return false }
    return oauthAccessTokenExpiresAt <= Date().addingTimeInterval(60)
  }
}

struct MCPServer: Identifiable, Codable, Equatable, Sendable {
  var id: UUID
  /// The original Mai MCP ID when it is not representable as an iOS UUID.
  var portableID: String?
  var name: String
  var baseURL: String
  var isEnabled: Bool
  var transport: MCPTransport?
  var authentication: MCPAuthentication

  init(
    id: UUID = UUID(), name: String = "MCP Server", baseURL: String = "https://",
    isEnabled: Bool = true, transport: MCPTransport? = nil,
    authentication: MCPAuthentication = MCPAuthentication(), portableID: String? = nil
  ) {
    self.id = id
    self.portableID = portableID
    self.name = name
    self.baseURL = baseURL
    self.isEnabled = isEnabled
    self.transport = transport
    self.authentication = authentication
  }

  enum CodingKeys: String, CodingKey {
    case id, portableID, name, baseURL, isEnabled, transport, authentication
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
    portableID = try? c.decode(String.self, forKey: .portableID)
    name = (try? c.decode(String.self, forKey: .name)) ?? "MCP Server"
    baseURL = (try? c.decode(String.self, forKey: .baseURL)) ?? "https://"
    isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
    transport = try? c.decode(MCPTransport.self, forKey: .transport)
    authentication =
      (try? c.decode(MCPAuthentication.self, forKey: .authentication)) ?? MCPAuthentication()
  }

  var isHTTPS: Bool {
    URL(string: baseURL)?.scheme?.lowercased() == "https"
  }

  var hasValidScheme: Bool {
    let scheme = URL(string: baseURL)?.scheme?.lowercased() ?? ""
    return scheme == "https" || scheme == "http"
  }

  var hasValidEndpointURL: Bool {
    let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let components = URLComponents(string: trimmed),
      let scheme = components.scheme?.lowercased(),
      ["https", "http"].contains(scheme),
      let host = components.host,
      !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return false
    }
    return true
  }

  /// Identifies the fields that affect catalog fetching, so a cached connection
  /// can be reused until the URL, transport, or credentials actually change.
  var connectionSignature: String {
    [
      baseURL,
      transport?.rawValue ?? "",
      authentication.method.rawValue,
      authentication.bearerToken,
      authentication.oauthAccessToken,
    ].joined(separator: "\u{1}")
  }
}

enum TTSVoiceProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
  case system
  case openAICompatible

  var id: String { rawValue }
}

struct RoleVoiceSettings: Codable, Equatable, Sendable {
  var provider: TTSVoiceProviderKind = .system
  var language: String = ""
  var voiceIdentifier: String = ""
  var openAIEndpointID: UUID? = nil
  var openAIVoice: String = ""
  var rate: Double = 0.5
  var pitch: Double = 1.0

  init(
    provider: TTSVoiceProviderKind = .system,
    language: String = "",
    voiceIdentifier: String = "",
    openAIEndpointID: UUID? = nil,
    openAIVoice: String = "",
    rate: Double = 0.5,
    pitch: Double = 1.0
  ) {
    self.provider = provider
    self.language = language
    self.voiceIdentifier = voiceIdentifier
    self.openAIEndpointID = openAIEndpointID
    self.openAIVoice = openAIVoice
    self.rate = rate
    self.pitch = pitch
  }

  enum CodingKeys: String, CodingKey {
    case provider, language, voiceIdentifier, openAIEndpointID, openAIVoice, rate, pitch
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    provider = (try? c.decode(TTSVoiceProviderKind.self, forKey: .provider)) ?? .system
    language = (try? c.decode(String.self, forKey: .language)) ?? ""
    voiceIdentifier = (try? c.decode(String.self, forKey: .voiceIdentifier)) ?? ""
    openAIEndpointID = try? c.decode(UUID.self, forKey: .openAIEndpointID)
    openAIVoice = (try? c.decode(String.self, forKey: .openAIVoice)) ?? ""
    rate = (try? c.decode(Double.self, forKey: .rate)) ?? 0.5
    pitch = (try? c.decode(Double.self, forKey: .pitch)) ?? 1.0
  }

  static let defaults = RoleVoiceSettings()

  func withoutOnlineProvider() -> RoleVoiceSettings {
    guard provider == .openAICompatible else { return self }
    var copy = self
    copy.provider = .system
    return copy
  }
}

struct VoiceSettings: Codable, Equatable, Sendable {
  var user: RoleVoiceSettings = .defaults
  var assistant: RoleVoiceSettings = .defaults

  static let defaults = VoiceSettings()
}

enum VoiceRole: String, Codable, Sendable {
  case user
  case assistant
}

extension VoiceSettings {
  func settings(for role: VoiceRole) -> RoleVoiceSettings {
    switch role {
    case .user: return user
    case .assistant: return assistant
    }
  }
}

/// Which other chats the memory tools may list, search, and read.
enum ConversationSearchScope: String, Codable, CaseIterable, Identifiable, Sendable {
  case none
  case currentFolder
  case allFolders

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .none: "None"
    case .currentFolder: "Current Folder"
    case .allFolders: "All Folders"
    }
  }
}

struct NativeToolSettings: Codable, Equatable, Sendable {
  var includeTimeZone: Bool = true
  var includeMoonPhase: Bool = true
  var useGPSLocation: Bool = false
  var manualLocation: String = ""
  var weatherLocation: String = ""
  var webSearchProvider: WebSearchProvider = .exa
  var webSearchSearXNGURL: String = ""
  var webSearchSearXNGUsername: String = ""
  var webSearchSearXNGPassword: String = ""
  var webSearchFetchingEnabled: Bool = false
  var calendarEventCreationEnabled: Bool = false
  var todos: [TodoItem] = []
  var files: [ToolFile] = []
  var filesWorkspaceAccessEnabled: Bool = false
  var filesAdvancedToolsEnabled: Bool = false
  var webxdcAllowInternet: Bool = false
  var webxdcChatInteractionEnabled: Bool = true
  var webxdcAllowGPSLocation: Bool = false
  var webxdcAllowMotionSensors: Bool = false
  var webxdcAllowWASM: Bool = true
  var webxdcAllowWebGL: Bool = true
  var webxdcAllowCanvas2D: Bool = true
  var webxdcAllowAudioPlayback: Bool = true
  var webxdcAllowCamera: Bool = false
  var webxdcAllowMicrophone: Bool = false
  var webxdcAllowClipboard: Bool = false
  var webxdcAllowFileImport: Bool = false
  var webxdcAllowLocalStorage: Bool = true
  var webxdcAllowServiceWorkers: Bool = false
  var webxdcAllowNotifications: Bool = false
  var webxdcAllowRealtimeChannels: Bool = false
  var voices: VoiceSettings = .defaults
  var conversationSearchScope: ConversationSearchScope = .none
  var mastodonInstance: String = "mastodon.social"
  var mastodonAPIKey: String = ""
  var mastodonWriteEnabled: Bool = false

  static let defaults = NativeToolSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case includeTimeZone, includeMoonPhase, includeCurrentTime, includeYear, useGPSLocation
    case manualLocation, weatherLocation, webSearchProvider
    case webSearchSearXNGURL, webSearchSearXNGUsername, webSearchSearXNGPassword
    case webSearchFetchingEnabled, calendarEventCreationEnabled, todos, files
    case filesWorkspaceAccessEnabled, filesAdvancedToolsEnabled
    case webxdcAllowInternet, webxdcChatInteractionEnabled
    case webxdcAllowGPSLocation, webxdcAllowMotionSensors, webxdcAllowWASM
    case webxdcAllowWebGL, webxdcAllowCanvas2D, webxdcAllowAudioPlayback
    case webxdcAllowCamera, webxdcAllowMicrophone, webxdcAllowClipboard
    case webxdcAllowFileImport, webxdcAllowLocalStorage, webxdcAllowServiceWorkers
    case webxdcAllowNotifications, webxdcAllowRealtimeChannels
    case voices
    case conversationSearchScope, mastodonInstance, mastodonAPIKey, mastodonWriteEnabled
  }

  private enum LegacyCodingKeys: String, CodingKey {
    case textToSpeechLanguage, textToSpeechVoiceIdentifier
    case textToSpeechRate, textToSpeechPitch
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = NativeToolSettings.defaults
    includeTimeZone =
      (try? c.decode(Bool.self, forKey: .includeTimeZone)) ?? defaults.includeTimeZone
    includeMoonPhase =
      (try? c.decode(Bool.self, forKey: .includeMoonPhase))
      ?? (try? c.decode(Bool.self, forKey: .includeYear))
      ?? defaults.includeMoonPhase
    useGPSLocation = (try? c.decode(Bool.self, forKey: .useGPSLocation)) ?? defaults.useGPSLocation
    manualLocation =
      (try? c.decode(String.self, forKey: .manualLocation)) ?? defaults.manualLocation
    weatherLocation =
      (try? c.decode(String.self, forKey: .weatherLocation)) ?? defaults.weatherLocation
    webSearchProvider =
      (try? c.decode(WebSearchProvider.self, forKey: .webSearchProvider))
      ?? defaults.webSearchProvider
    webSearchSearXNGURL =
      (try? c.decode(String.self, forKey: .webSearchSearXNGURL))
      ?? defaults.webSearchSearXNGURL
    webSearchSearXNGUsername =
      (try? c.decode(String.self, forKey: .webSearchSearXNGUsername))
      ?? defaults.webSearchSearXNGUsername
    webSearchSearXNGPassword =
      (try? c.decode(String.self, forKey: .webSearchSearXNGPassword))
      ?? defaults.webSearchSearXNGPassword
    webSearchFetchingEnabled =
      (try? c.decode(Bool.self, forKey: .webSearchFetchingEnabled))
      ?? defaults.webSearchFetchingEnabled
    calendarEventCreationEnabled =
      (try? c.decode(Bool.self, forKey: .calendarEventCreationEnabled))
      ?? defaults.calendarEventCreationEnabled
    todos = (try? c.decode([TodoItem].self, forKey: .todos)) ?? defaults.todos
    files = (try? c.decode([ToolFile].self, forKey: .files)) ?? defaults.files
    filesWorkspaceAccessEnabled =
      (try? c.decode(Bool.self, forKey: .filesWorkspaceAccessEnabled))
      ?? defaults.filesWorkspaceAccessEnabled
    filesAdvancedToolsEnabled =
      (try? c.decode(Bool.self, forKey: .filesAdvancedToolsEnabled))
      ?? defaults.filesAdvancedToolsEnabled
    webxdcAllowInternet =
      (try? c.decode(Bool.self, forKey: .webxdcAllowInternet)) ?? defaults.webxdcAllowInternet
    webxdcChatInteractionEnabled =
      (try? c.decode(Bool.self, forKey: .webxdcChatInteractionEnabled))
      ?? defaults.webxdcChatInteractionEnabled
    webxdcAllowGPSLocation =
      (try? c.decode(Bool.self, forKey: .webxdcAllowGPSLocation))
      ?? defaults.webxdcAllowGPSLocation
    webxdcAllowMotionSensors =
      (try? c.decode(Bool.self, forKey: .webxdcAllowMotionSensors))
      ?? defaults.webxdcAllowMotionSensors
    webxdcAllowWASM =
      (try? c.decode(Bool.self, forKey: .webxdcAllowWASM)) ?? defaults.webxdcAllowWASM
    webxdcAllowWebGL =
      (try? c.decode(Bool.self, forKey: .webxdcAllowWebGL)) ?? defaults.webxdcAllowWebGL
    webxdcAllowCanvas2D =
      (try? c.decode(Bool.self, forKey: .webxdcAllowCanvas2D)) ?? defaults.webxdcAllowCanvas2D
    webxdcAllowAudioPlayback =
      (try? c.decode(Bool.self, forKey: .webxdcAllowAudioPlayback))
      ?? defaults.webxdcAllowAudioPlayback
    webxdcAllowCamera =
      (try? c.decode(Bool.self, forKey: .webxdcAllowCamera)) ?? defaults.webxdcAllowCamera
    webxdcAllowMicrophone =
      (try? c.decode(Bool.self, forKey: .webxdcAllowMicrophone))
      ?? defaults.webxdcAllowMicrophone
    webxdcAllowClipboard =
      (try? c.decode(Bool.self, forKey: .webxdcAllowClipboard))
      ?? defaults.webxdcAllowClipboard
    webxdcAllowFileImport =
      (try? c.decode(Bool.self, forKey: .webxdcAllowFileImport))
      ?? defaults.webxdcAllowFileImport
    webxdcAllowLocalStorage =
      (try? c.decode(Bool.self, forKey: .webxdcAllowLocalStorage))
      ?? defaults.webxdcAllowLocalStorage
    webxdcAllowServiceWorkers =
      (try? c.decode(Bool.self, forKey: .webxdcAllowServiceWorkers))
      ?? defaults.webxdcAllowServiceWorkers
    webxdcAllowNotifications =
      (try? c.decode(Bool.self, forKey: .webxdcAllowNotifications))
      ?? defaults.webxdcAllowNotifications
    webxdcAllowRealtimeChannels =
      (try? c.decode(Bool.self, forKey: .webxdcAllowRealtimeChannels))
      ?? defaults.webxdcAllowRealtimeChannels

    if let decoded = try? c.decode(VoiceSettings.self, forKey: .voices) {
      voices = decoded
    } else if let legacy = try? decoder.container(keyedBy: LegacyCodingKeys.self) {
      // Migrate from the previous flat textToSpeech* fields. Both roles seed
      // from the same legacy values so the user has a consistent starting
      // point and can diverge them later.
      let legacyVoice = RoleVoiceSettings(
        language: (try? legacy.decode(String.self, forKey: .textToSpeechLanguage)) ?? "",
        voiceIdentifier: (try? legacy.decode(String.self, forKey: .textToSpeechVoiceIdentifier))
          ?? "",
        rate: (try? legacy.decode(Double.self, forKey: .textToSpeechRate))
          ?? RoleVoiceSettings.defaults.rate,
        pitch: (try? legacy.decode(Double.self, forKey: .textToSpeechPitch))
          ?? RoleVoiceSettings.defaults.pitch)
      voices = VoiceSettings(user: legacyVoice, assistant: legacyVoice)
    } else {
      voices = defaults.voices
    }
    conversationSearchScope =
      (try? c.decode(ConversationSearchScope.self, forKey: .conversationSearchScope))
      ?? defaults.conversationSearchScope
    mastodonInstance =
      (try? c.decode(String.self, forKey: .mastodonInstance)) ?? defaults.mastodonInstance
    mastodonAPIKey =
      (try? c.decode(String.self, forKey: .mastodonAPIKey)) ?? defaults.mastodonAPIKey
    mastodonWriteEnabled =
      (try? c.decode(Bool.self, forKey: .mastodonWriteEnabled)) ?? defaults.mastodonWriteEnabled
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(includeTimeZone, forKey: .includeTimeZone)
    try c.encode(includeMoonPhase, forKey: .includeMoonPhase)
    try c.encode(useGPSLocation, forKey: .useGPSLocation)
    try c.encode(manualLocation, forKey: .manualLocation)
    try c.encode(weatherLocation, forKey: .weatherLocation)
    try c.encode(webSearchProvider, forKey: .webSearchProvider)
    try c.encode(webSearchSearXNGURL, forKey: .webSearchSearXNGURL)
    try c.encode(webSearchSearXNGUsername, forKey: .webSearchSearXNGUsername)
    try c.encode(webSearchSearXNGPassword, forKey: .webSearchSearXNGPassword)
    try c.encode(webSearchFetchingEnabled, forKey: .webSearchFetchingEnabled)
    try c.encode(calendarEventCreationEnabled, forKey: .calendarEventCreationEnabled)
    try c.encode(todos, forKey: .todos)
    try c.encode(files, forKey: .files)
    try c.encode(filesWorkspaceAccessEnabled, forKey: .filesWorkspaceAccessEnabled)
    try c.encode(filesAdvancedToolsEnabled, forKey: .filesAdvancedToolsEnabled)
    try c.encode(webxdcAllowInternet, forKey: .webxdcAllowInternet)
    try c.encode(webxdcChatInteractionEnabled, forKey: .webxdcChatInteractionEnabled)
    try c.encode(webxdcAllowGPSLocation, forKey: .webxdcAllowGPSLocation)
    try c.encode(webxdcAllowMotionSensors, forKey: .webxdcAllowMotionSensors)
    try c.encode(webxdcAllowWASM, forKey: .webxdcAllowWASM)
    try c.encode(webxdcAllowWebGL, forKey: .webxdcAllowWebGL)
    try c.encode(webxdcAllowCanvas2D, forKey: .webxdcAllowCanvas2D)
    try c.encode(webxdcAllowAudioPlayback, forKey: .webxdcAllowAudioPlayback)
    try c.encode(webxdcAllowCamera, forKey: .webxdcAllowCamera)
    try c.encode(webxdcAllowMicrophone, forKey: .webxdcAllowMicrophone)
    try c.encode(webxdcAllowClipboard, forKey: .webxdcAllowClipboard)
    try c.encode(webxdcAllowFileImport, forKey: .webxdcAllowFileImport)
    try c.encode(webxdcAllowLocalStorage, forKey: .webxdcAllowLocalStorage)
    try c.encode(webxdcAllowServiceWorkers, forKey: .webxdcAllowServiceWorkers)
    try c.encode(webxdcAllowNotifications, forKey: .webxdcAllowNotifications)
    try c.encode(webxdcAllowRealtimeChannels, forKey: .webxdcAllowRealtimeChannels)
    try c.encode(voices, forKey: .voices)
    try c.encode(conversationSearchScope, forKey: .conversationSearchScope)
    try c.encode(mastodonInstance, forKey: .mastodonInstance)
    try c.encode(mastodonAPIKey, forKey: .mastodonAPIKey)
    try c.encode(mastodonWriteEnabled, forKey: .mastodonWriteEnabled)
  }
}

struct FollowUpSettings: Codable, Equatable, Sendable {
  static let suggestionCountRange = 1...6
  static let contextMessageCountRange = 1...20
  static let defaultPrompt = UserPrompt.followUp.text

  var isEnabled: Bool = false
  /// When true, suggestions are generated automatically after each assistant
  /// reply. When false, the suggestion box still appears at the end of the chat
  /// but stays empty until the user taps its refresh button.
  var autoGenerate: Bool = true
  var prompt: String = FollowUpSettings.defaultPrompt
  var suggestionCount: Int = 3
  var contextMessageCount: Int = 3

  static let defaults = FollowUpSettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case isEnabled, autoGenerate, prompt, suggestionCount, contextMessageCount
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false
    autoGenerate = (try? container.decode(Bool.self, forKey: .autoGenerate)) ?? true
    prompt =
      (try? container.decode(String.self, forKey: .prompt)) ?? FollowUpSettings.defaultPrompt
    suggestionCount = Self.clampedSuggestionCount(
      (try? container.decode(Int.self, forKey: .suggestionCount)) ?? 3)
    contextMessageCount = Self.clampedContextMessageCount(
      (try? container.decode(Int.self, forKey: .contextMessageCount)) ?? 3)
  }

  static func clampedSuggestionCount(_ count: Int) -> Int {
    min(suggestionCountRange.upperBound, max(suggestionCountRange.lowerBound, count))
  }

  static func clampedContextMessageCount(_ count: Int) -> Int {
    min(contextMessageCountRange.upperBound, max(contextMessageCountRange.lowerBound, count))
  }
}

struct BackgroundActivitySettings: Codable, Equatable, Sendable {
  /// Mirror running replies into a Live Activity (Lock Screen and Dynamic Island).
  var liveActivityEnabled: Bool = true
  /// Local notification when a reply finishes or fails while the app is not on screen.
  var notifyWhenResponseFinishes: Bool = true
  /// Local notification when a tool call waits for approval while the app is not on screen.
  var notifyWhenApprovalNeeded: Bool = true
  /// Keep the process alive with a silent audio session while a reply runs in the background.
  var extendedBackgroundProcessing: Bool = false

  static let defaults = BackgroundActivitySettings()

  init() {}

  enum CodingKeys: String, CodingKey {
    case liveActivityEnabled, notifyWhenResponseFinishes, notifyWhenApprovalNeeded,
      extendedBackgroundProcessing
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = BackgroundActivitySettings.defaults
    liveActivityEnabled =
      (try? c.decode(Bool.self, forKey: .liveActivityEnabled)) ?? defaults.liveActivityEnabled
    notifyWhenResponseFinishes =
      (try? c.decode(Bool.self, forKey: .notifyWhenResponseFinishes))
      ?? defaults.notifyWhenResponseFinishes
    notifyWhenApprovalNeeded =
      (try? c.decode(Bool.self, forKey: .notifyWhenApprovalNeeded))
      ?? defaults.notifyWhenApprovalNeeded
    extendedBackgroundProcessing =
      (try? c.decode(Bool.self, forKey: .extendedBackgroundProcessing))
      ?? defaults.extendedBackgroundProcessing
  }
}

struct AppSettings: Codable, Equatable, Sendable {
  static let currentSettingsVersion = 1
  static let currentStockPromptsVersion = 4
  static let recentChatLanguageLimit = 3
  static let appleDefaultModelID = ""
  static let localMLXDefaultModelID = "LiquidAI/LFM2.5-1.2B-Instruct-MLX-4bit"
  static let defaultTools: Set<BuiltInToolID> = []
  static let defaultMCPServers: Set<UUID> = []
  static let defaultMCPTools: Set<String> = []
  static let defaultMCPRequestTimeoutSeconds = 60
  static let mcpRequestTimeoutRange = 5...300
  static let defaultMaxToolCallsPerTurn = 50
  static let maxToolCallsPerTurnRange = 1...100
  static let defaultLLMRequestTimeoutSeconds = 600
  static let llmRequestTimeoutChoices = [60, 180, 300, 600, 900, 1800]
  static let defaultSystemPrompt = SystemPrompt(
    name: "Helpful",
    text:
      "You are a helpful, concise assistant for a private text-only chat app. Prefer clear answers and preserve useful formatting."
  )
  /// The builtin prompts MaiCore ships, seeded into the user prompts once.
  static let goalUserPrompt = UserPrompt.goal
  static let newAppUserPrompt = UserPrompt.newApp
  static let tldrUserPrompt = UserPrompt.tldr
  static let followUpUserPrompt = UserPrompt.followUp
  static let defaultUserPrompts = UserPrompt.builtins
  static let defaultCompactPrompt = """
    Compact the transcript below into durable context for continuing the same chat.

    Output only the compacted context. Do not include hidden reasoning, XML tags, prompt scaffolding, or commentary about the task.

    Preserve:
    - User goals, preferences, constraints, and decisions
    - Important names, projects, files, commands, code snippets, errors, and results
    - Current state, unresolved questions, and next steps

    Drop greetings, filler, repeated text, tool protocol blocks, and implementation details that no longer matter. Write concise bullets grouped by topic when useful.

    Transcript:

    {{transcript}}
    """

  var defaultProvider: ProviderKind = .mlx
  var appleModelID: String = AppSettings.appleDefaultModelID
  var localMLXModelID: String = AppSettings.localMLXDefaultModelID
  var selectedEndpointID: UUID? = nil
  var defaultReasoningLevel: ReasoningLevel = .automatic
  var streamByDefault: Bool = true
  var showThinkingByDefault: Bool = false
  var openAIEndpoints: [OpenAIEndpoint] = []
  var systemPrompts: [SystemPrompt] = [AppSettings.defaultSystemPrompt]
  var userPrompts: [UserPrompt] = AppSettings.defaultUserPrompts
  var defaultSystemPromptID: UUID = AppSettings.defaultSystemPrompt.id
  var compactPrompt: String = AppSettings.defaultCompactPrompt
  var defaultEnabledTools: Set<BuiltInToolID> = AppSettings.defaultTools
  var settingsVersion: Int = AppSettings.currentSettingsVersion
  var stockPromptsVersion: Int = AppSettings.currentStockPromptsVersion
  var defaultEnabledMCPServers: Set<UUID> = AppSettings.defaultMCPServers
  var defaultEnabledMCPTools: Set<String> = AppSettings.defaultMCPTools
  var toolSettings: NativeToolSettings = .defaults
  var mcpServers: [MCPServer] = []
  var mcpRequestTimeoutSeconds: Int = AppSettings.defaultMCPRequestTimeoutSeconds
  var llmRequestTimeoutSeconds: Int = AppSettings.defaultLLMRequestTimeoutSeconds
  var memory: String = ""
  var toolCallingMode: ToolCallingMode = .text
  var maxToolCallsPerTurn: Int = AppSettings.defaultMaxToolCallsPerTurn
  var yoloModeEnabled: Bool = true
  var useToolProxy: Bool = false
  var contextWindowMode: ContextWindowMode = .full
  var includeAssistantResponsesInContext: Bool = true
  var includeReasoningContentInContext: Bool = false
  var followUps: FollowUpSettings = .defaults
  var background: BackgroundActivitySettings = .defaults
  var appearance: AppearanceSettings = .defaults
  var conversation: ConversationSettings = .defaults
  var renderMarkdownInChat: Bool = true
  var renderMarkdownImagesInChat: Bool = true
  var airplaneModeEnabled: Bool = false
  var attachmentImageSize: AttachmentImageSize = .prompt
  var mlxMaxKVSize: MLXKVCacheSize = .auto
  var mlxAutoCompact: Bool = false
  var startupBehavior: AppStartupBehavior = .continueChats
  var lastSelectedConversationID: UUID? = nil
  var openAPIServer: OpenAPIServerSettings = OpenAPIServerSettings()
  var recentChatLanguageIdentifiers: [String] = []
  var conversationFolders: [ConversationFolder] = []
  var conversationFolderDefaults: [String: ConversationFolderDefaults] = [:]
  var selectedConversationFolderID: String = ConversationFolder.defaultID
  /// Named sets of the agent-scoped settings; see `AgentSettings`. The
  /// selected one mirrors the live fields above.
  var agents: [AgentProfile] = [.stock()]
  var selectedAgentID: UUID = AgentProfile.stockID
  /// Asks an agent that can spawn subagents to open a request of several
  /// steps with a short numbered plan before its first `agent_start`; a
  /// single question gets no plan. Carried by the tool's description, so it
  /// costs nothing for an agent without subagents.
  var plansBeforeDelegating: Bool = true

  static let defaults = AppSettings()

  init() {}

  static func clampedMCPRequestTimeoutSeconds(_ seconds: Int) -> Int {
    min(mcpRequestTimeoutRange.upperBound, max(mcpRequestTimeoutRange.lowerBound, seconds))
  }

  static func clampedMaxToolCallsPerTurn(_ calls: Int) -> Int {
    min(maxToolCallsPerTurnRange.upperBound, max(maxToolCallsPerTurnRange.lowerBound, calls))
  }

  static func normalizedLLMRequestTimeoutSeconds(_ seconds: Int) -> Int {
    llmRequestTimeoutChoices.contains(seconds) ? seconds : defaultLLMRequestTimeoutSeconds
  }

  var mcpRequestTimeoutInterval: TimeInterval {
    TimeInterval(Self.clampedMCPRequestTimeoutSeconds(mcpRequestTimeoutSeconds))
  }

  var llmRequestTimeoutInterval: TimeInterval {
    TimeInterval(Self.normalizedLLMRequestTimeoutSeconds(llmRequestTimeoutSeconds))
  }

  func defaultPrompt() -> SystemPrompt {
    systemPrompts.first(where: { $0.id == defaultSystemPromptID }) ?? systemPrompts.first
      ?? AppSettings.defaultSystemPrompt
  }

  var followUpPromptText: String {
    userPrompts.first(where: { $0.id == Self.followUpUserPrompt.id })?.text
      ?? userPrompts.first(where: {
        PromptSlashCommand.normalized($0.commandName) == "followup"
      })?.text
      ?? followUps.prompt
  }

  mutating func recordRecentChatLanguage(_ identifier: String) {
    recentChatLanguageIdentifiers = Self.normalizedRecentChatLanguageIdentifiers(
      [identifier] + recentChatLanguageIdentifiers)
  }

  static func normalizedRecentChatLanguageIdentifiers(_ identifiers: [String]) -> [String] {
    var seen = Set<String>()
    var normalizedIdentifiers: [String] = []
    for identifier in identifiers {
      guard let normalized = SystemLanguageSupport.normalizedLanguageIdentifier(identifier),
        !seen.contains(normalized)
      else { continue }
      seen.insert(normalized)
      normalizedIdentifiers.append(normalized)
      if normalizedIdentifiers.count == recentChatLanguageLimit {
        break
      }
    }
    return normalizedIdentifiers
  }

  static func normalizedConversationFolders(_ folders: [ConversationFolder])
    -> [ConversationFolder]
  {
    var seenIDs = Set<String>()
    return folders.compactMap { folder in
      let id = folder.id.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty,
        !ConversationFolder.reservedIDs.contains(id),
        !seenIDs.contains(id)
      else {
        return nil
      }
      seenIDs.insert(id)
      return ConversationFolder(
        id: id,
        name: folder.name,
        icon: folder.icon,
        tint: folder.tint,
        createdAt: folder.createdAt)
    }
  }

  static func normalizedConversationFolderDefaults(
    _ defaults: [String: ConversationFolderDefaults],
    knownFolderIDs: Set<String>
  ) -> [String: ConversationFolderDefaults] {
    var result: [String: ConversationFolderDefaults] = [:]
    for (rawID, rawDefaults) in defaults {
      let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !id.isEmpty, knownFolderIDs.contains(id) else { continue }
      var folderDefaults = rawDefaults
      folderDefaults.modelID =
        folderDefaults.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
      if folderDefaults.provider == nil {
        folderDefaults.endpointID = nil
        folderDefaults.modelID = ""
      }
      if folderDefaults.provider != .openAICompatible {
        folderDefaults.endpointID = nil
      }
      guard !folderDefaults.usesAppDefaults else { continue }
      result[id] = folderDefaults
    }
    return result
  }

  var defaultOpenAIEndpoint: OpenAIEndpoint? {
    if let selectedEndpointID,
      let endpoint = openAIEndpoints.first(where: { $0.id == selectedEndpointID && $0.isEnabled })
    {
      return endpoint
    }
    return openAIEndpoints.first(where: \.isEnabled)
  }

  var defaultProviderConfiguration: (provider: ProviderKind, endpointID: UUID?, modelID: String) {
    if airplaneModeEnabled && !defaultProvider.isAirplaneModeEligible {
      return (.mlx, nil, localMLXModelID)
    }
    switch defaultProvider {
    case .apple:
      return (.apple, nil, appleModelID)
    case .mlx:
      return (.mlx, nil, localMLXModelID)
    case .openAICompatible:
      guard let endpoint = defaultOpenAIEndpoint else {
        return (.mlx, nil, localMLXModelID)
      }
      return (.openAICompatible, endpoint.id, endpoint.defaultModel)
    }
  }

  enum CodingKeys: String, CodingKey {
    case settingsVersion, stockPromptsVersion
    case defaultProvider, appleModelID, localMLXModelID, selectedEndpointID,
      defaultReasoningLevel, streamByDefault, showThinkingByDefault
    case openAIEndpoints, systemPrompts, userPrompts, defaultSystemPromptID, compactPrompt
    case defaultEnabledTools
    case defaultEnabledMCPServers, defaultEnabledMCPTools
    case toolSettings, mcpServers, mcpRequestTimeoutSeconds, llmRequestTimeoutSeconds, memory,
      toolCallingMode,
      maxToolCallsPerTurn
    case yoloModeEnabled, useToolProxy, contextWindowMode
    case includeAssistantResponsesInContext, includeReasoningContentInContext
    case followUps, background
    case appearance, conversation, renderMarkdownInChat, renderMarkdownImagesInChat
    case airplaneModeEnabled, attachmentImageSize
    case mlxMaxKVSize, mlxAutoCompact
    case startupBehavior, lastSelectedConversationID
    case openAPIServer
    case recentChatLanguageIdentifiers
    case conversationFolders, conversationFolderDefaults, selectedConversationFolderID
    case agents, selectedAgentID, plansBeforeDelegating
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let storedSettingsVersion =
      (try? c.decode(Int.self, forKey: .settingsVersion)) ?? 0
    settingsVersion = Self.currentSettingsVersion
    let storedStockPromptsVersion =
      (try? c.decode(Int.self, forKey: .stockPromptsVersion)) ?? 0
    stockPromptsVersion = Self.currentStockPromptsVersion
    defaultProvider =
      (try? c.decode(ProviderKind.self, forKey: .defaultProvider)) ?? .mlx
    appleModelID = (try? c.decode(String.self, forKey: .appleModelID)) ?? ""
    localMLXModelID =
      (try? c.decode(String.self, forKey: .localMLXModelID))
      ?? AppSettings.localMLXDefaultModelID
    selectedEndpointID = try? c.decode(UUID.self, forKey: .selectedEndpointID)
    defaultReasoningLevel =
      (try? c.decode(ReasoningLevel.self, forKey: .defaultReasoningLevel)) ?? .automatic
    streamByDefault = (try? c.decode(Bool.self, forKey: .streamByDefault)) ?? true
    showThinkingByDefault = (try? c.decode(Bool.self, forKey: .showThinkingByDefault)) ?? false
    openAIEndpoints =
      (try? c.decode([OpenAIEndpoint].self, forKey: .openAIEndpoints)) ?? []
    systemPrompts =
      (try? c.decode([SystemPrompt].self, forKey: .systemPrompts))
      ?? [AppSettings.defaultSystemPrompt]
    userPrompts =
      (try? c.decode([UserPrompt].self, forKey: .userPrompts)) ?? []
    if storedStockPromptsVersion < Self.currentStockPromptsVersion {
      let existingCommands = Set(
        (systemPrompts.map(\.commandName) + userPrompts.map(\.commandName))
          .map(PromptSlashCommand.normalized))
      userPrompts.append(
        contentsOf: Self.defaultUserPrompts.filter {
          !existingCommands.contains(PromptSlashCommand.normalized($0.commandName))
        })
    }
    defaultSystemPromptID =
      (try? c.decode(UUID.self, forKey: .defaultSystemPromptID))
      ?? (systemPrompts.first?.id ?? AppSettings.defaultSystemPrompt.id)
    compactPrompt =
      (try? c.decode(String.self, forKey: .compactPrompt)) ?? AppSettings.defaultCompactPrompt
    let decodedDefaultEnabledTools = BuiltInToolID.knownTools(
      from: try? c.decode([String].self, forKey: .defaultEnabledTools))
    defaultEnabledTools =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultTools : decodedDefaultEnabledTools
    let decodedDefaultEnabledMCPServers =
      (try? c.decode(Set<UUID>.self, forKey: .defaultEnabledMCPServers))
      ?? AppSettings.defaultMCPServers
    let decodedDefaultEnabledMCPTools =
      (try? c.decode(Set<String>.self, forKey: .defaultEnabledMCPTools))
      ?? AppSettings.defaultMCPTools
    defaultEnabledMCPServers =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultMCPServers : decodedDefaultEnabledMCPServers
    defaultEnabledMCPTools =
      storedSettingsVersion < Self.currentSettingsVersion
      ? AppSettings.defaultMCPTools : decodedDefaultEnabledMCPTools
    toolSettings =
      (try? c.decode(NativeToolSettings.self, forKey: .toolSettings)) ?? .defaults
    if storedSettingsVersion < Self.currentSettingsVersion {
      toolSettings.webSearchFetchingEnabled = false
      toolSettings.filesWorkspaceAccessEnabled = false
      toolSettings.filesAdvancedToolsEnabled = false
      toolSettings.calendarEventCreationEnabled = false
    }
    mcpServers = (try? c.decode([MCPServer].self, forKey: .mcpServers)) ?? []
    mcpRequestTimeoutSeconds = Self.clampedMCPRequestTimeoutSeconds(
      (try? c.decode(Int.self, forKey: .mcpRequestTimeoutSeconds))
        ?? Self.defaultMCPRequestTimeoutSeconds)
    llmRequestTimeoutSeconds = Self.normalizedLLMRequestTimeoutSeconds(
      (try? c.decode(Int.self, forKey: .llmRequestTimeoutSeconds))
        ?? Self.defaultLLMRequestTimeoutSeconds)
    memory = (try? c.decode(String.self, forKey: .memory)) ?? ""
    let storedMode = (try? c.decode(String.self, forKey: .toolCallingMode)) ?? "text"
    let migratedFromLegacyProxy = (storedMode == "proxy")
    toolCallingMode =
      ToolCallingMode(rawValue: storedMode) ?? .text
    maxToolCallsPerTurn = Self.clampedMaxToolCallsPerTurn(
      (try? c.decode(Int.self, forKey: .maxToolCallsPerTurn))
        ?? Self.defaultMaxToolCallsPerTurn)
    yoloModeEnabled =
      (try? c.decode(Bool.self, forKey: .yoloModeEnabled)) ?? true
    useToolProxy =
      (try? c.decode(Bool.self, forKey: .useToolProxy)) ?? migratedFromLegacyProxy
    contextWindowMode =
      (try? c.decode(ContextWindowMode.self, forKey: .contextWindowMode)) ?? .full
    includeAssistantResponsesInContext =
      (try? c.decode(Bool.self, forKey: .includeAssistantResponsesInContext)) ?? true
    includeReasoningContentInContext =
      (try? c.decode(Bool.self, forKey: .includeReasoningContentInContext)) ?? false
    followUps =
      (try? c.decode(FollowUpSettings.self, forKey: .followUps)) ?? .defaults
    background =
      (try? c.decode(BackgroundActivitySettings.self, forKey: .background)) ?? .defaults
    appearance =
      (try? c.decode(AppearanceSettings.self, forKey: .appearance)) ?? .defaults
    conversation =
      (try? c.decode(ConversationSettings.self, forKey: .conversation)) ?? .defaults
    renderMarkdownInChat =
      (try? c.decode(Bool.self, forKey: .renderMarkdownInChat)) ?? true
    renderMarkdownImagesInChat =
      (try? c.decode(Bool.self, forKey: .renderMarkdownImagesInChat)) ?? true
    airplaneModeEnabled =
      (try? c.decode(Bool.self, forKey: .airplaneModeEnabled)) ?? false
    attachmentImageSize =
      (try? c.decode(AttachmentImageSize.self, forKey: .attachmentImageSize)) ?? .prompt
    mlxMaxKVSize =
      (try? c.decode(MLXKVCacheSize.self, forKey: .mlxMaxKVSize)) ?? .auto
    mlxAutoCompact = (try? c.decode(Bool.self, forKey: .mlxAutoCompact)) ?? false
    startupBehavior =
      (try? c.decode(AppStartupBehavior.self, forKey: .startupBehavior)) ?? .continueChats
    lastSelectedConversationID = try? c.decode(UUID.self, forKey: .lastSelectedConversationID)
    openAPIServer =
      (try? c.decode(OpenAPIServerSettings.self, forKey: .openAPIServer))
      ?? OpenAPIServerSettings()
    recentChatLanguageIdentifiers = Self.normalizedRecentChatLanguageIdentifiers(
      (try? c.decode([String].self, forKey: .recentChatLanguageIdentifiers)) ?? [])
    conversationFolders = Self.normalizedConversationFolders(
      (try? c.decode([ConversationFolder].self, forKey: .conversationFolders)) ?? [])
    let decodedConversationFolderID =
      Conversation.normalizedFolderID(
        try? c.decode(String.self, forKey: .selectedConversationFolderID))
    let knownConversationFolderIDs =
      Set(
        [ConversationFolder.defaultID, ConversationFolder.iCloudID, ConversationFolder.archivedID]
          + conversationFolders.map(\.id))
    selectedConversationFolderID =
      knownConversationFolderIDs.contains(decodedConversationFolderID)
      ? decodedConversationFolderID : ConversationFolder.defaultID
    conversationFolderDefaults = Self.normalizedConversationFolderDefaults(
      (try? c.decode(
        [String: ConversationFolderDefaults].self,
        forKey: .conversationFolderDefaults)) ?? [:],
      knownFolderIDs: knownConversationFolderIDs)
    agents = (try? c.decode([AgentProfile].self, forKey: .agents)) ?? []
    selectedAgentID =
      (try? c.decode(UUID.self, forKey: .selectedAgentID)) ?? AgentProfile.stockID
    plansBeforeDelegating = (try? c.decode(Bool.self, forKey: .plansBeforeDelegating)) ?? true
    normalizeAgents()
  }
}

struct AnyCodable: Codable, Sendable {
  let value: any Sendable

  init(_ value: any Sendable) {
    self.value = value
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      value = ""
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else if let int = try? container.decode(Int.self) {
      value = int
    } else if let double = try? container.decode(Double.self) {
      value = double
    } else if let string = try? container.decode(String.self) {
      value = string
    } else if let array = try? container.decode([AnyCodable].self) {
      value = array
    } else if let dictionary = try? container.decode([String: AnyCodable].self) {
      value = dictionary
    } else {
      throw DecodingError.dataCorruptedError(
        in: container, debugDescription: "Unsupported JSON value")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case let bool as Bool:
      try container.encode(bool)
    case let int as Int:
      try container.encode(int)
    case let double as Double:
      try container.encode(double)
    case let string as String:
      try container.encode(string)
    case let array as [AnyCodable]:
      try container.encode(array)
    case let dictionary as [String: AnyCodable]:
      try container.encode(dictionary)
    default:
      preconditionFailure("AnyCodable cannot encode value of type \(type(of: value))")
    }
  }
}
