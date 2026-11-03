import Foundation

/// How hard a model is asked to think before it answers, as `/set effort` sets
/// it. One level serves every provider: `requestFields` turns it into the
/// fields each API family understands (`reasoning_effort` for OpenAI, `think`
/// for Ollama, `enable_thinking` for Qwen, `thinking` for DeepSeek, the
/// `reasoning` object for OpenRouter), and `promptSection` into guidance for
/// the system prompt, so a model with no reasoning control of its own still
/// hears how much care the task deserves.
public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable, Sendable {
  case automatic
  case disabled
  case minimal
  case low
  case medium
  case high
  case xhigh
  case max

  /// The names a command completes to, from the least effort to the most.
  public static let names = allCases.map(\.rawValue)

  /// The level for a name as people type it: the raw names, `x-high`,
  /// `extra-high`, `maximum`, and the first letters.
  public init?(name: String) {
    let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: "_", with: "")
    switch key {
    case "auto", "automatic", "default", "clear": self = .automatic
    case "off", "none", "disabled", "nothink": self = .disabled
    case "minimal", "min": self = .minimal
    case "low", "l": self = .low
    case "medium", "med", "m": self = .medium
    case "high", "h": self = .high
    case "xhigh", "extrahigh", "veryhigh", "xh": self = .xhigh
    case "max", "maximum", "ultra": self = .max
    default: return nil
    }
  }

  public var displayName: String {
    switch self {
    case .automatic: "Auto"
    case .disabled: "Off"
    case .minimal: "Minimal"
    case .low: "low"
    case .medium: "medium"
    case .high: "high"
    case .xhigh: "very high"
    case .max: "maximum"
    }
  }

  /// What the system prompt asks for at this level.
  public var guidance: String {
    switch self {
    case .automatic: ""
    case .disabled: "Answer directly without a thinking block or extended deliberation."
    case .minimal: "Use only the minimum reasoning needed to answer accurately."
    case .low:
      "Answer directly and briefly. Do not deliberate over alternatives or edge cases unless the task is ambiguous or a mistake would be costly."
    case .medium:
      "Think briefly before answering: plan the steps, check the main assumptions, and keep the reasoning proportionate to the task."
    case .high:
      "Think the problem through before answering: consider the alternatives, work through the tricky cases and the edge cases, and verify the result before presenting it."
    case .xhigh:
      "Reason thoroughly before answering: explore the alternatives, question your assumptions, work through every edge case, and double-check each conclusion. Thoroughness matters more than speed."
    case .max:
      "Take all the reasoning the task needs: examine every alternative, test each assumption, verify each step and the final result, and revisit earlier conclusions when something does not fit. Correctness matters more than speed or brevity."
    }
  }

  // MARK: - System prompt

  /// The system prompt section for a level and the extra guidance a person
  /// set with it; nil when there is neither.
  public static func promptSection(effort: ReasoningEffort?, guidance: String?) -> String? {
    let extra = guidance?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let effort = effort == .automatic ? nil : effort
    guard effort != nil || !extra.isEmpty else { return nil }
    var parts: [String] = []
    if let effort {
      parts.append("Reasoning effort: \(effort.displayName). \(effort.guidance)")
    }
    if !extra.isEmpty { parts.append(extra) }
    return parts.joined(separator: "\n\n")
  }

  /// The section for a request's options: the level `reasoningEffort` names
  /// when it is one of ours (an unknown provider-specific value adds
  /// no section) and `reasoningGuidance`.
  public static func promptSection(for options: GenerationOptions) -> String? {
    promptSection(
      effort: options.reasoningEffort.flatMap(ReasoningEffort.init(name:)),
      guidance: options.reasoningGuidance)
  }

  // MARK: - Provider request fields

  /// The API family an endpoint belongs to, told from the model name, the
  /// provider's id and name, and its base URL.
  public enum APIFamily: Equatable, Sendable {
    case openAI
    case openRouter
    case deepSeek
    case qwen
    case ollama
    case kimi, kimiLocal, minimax, gemma, gemini
    case generic

    public static func detect(model: String, provider: String = "", baseURL: String = "")
      -> APIFamily
    {
      let text = "\(model) \(provider) \(baseURL)".lowercased()
      if text.contains("openrouter.ai") { return .openRouter }
      if text.contains("ollama") || text.contains(":11434") { return .ollama }
      if text.contains("api.moonshot.") || text.contains("api.kimi.") { return .kimi }
      if text.contains("minimax") { return .minimax }
      if text.contains("generativelanguage.googleapis.com") { return .gemini }
      if text.contains("kimi") { return .kimiLocal }
      if text.contains("gemma") { return .gemma }
      if text.contains("dashscope") || text.contains("aliyuncs") || text.contains("qwen") {
        return .qwen
      }
      if text.contains("deepseek") { return .deepSeek }
      if text.contains("api.openai.com") || text.contains("openai.azure.com") { return .openAI }
      return .generic
    }
  }

  /// The request body fields that ask an endpoint for this level, detected
  /// from the model, provider, and base URL. A caller merges them under its
  /// own explicit fields, so a configured `additional` value always wins.
  public func requestFields(model: String, provider: String = "", baseURL: String = "")
    -> [String: JSONValue]
  {
    requestFields(
      family: .detect(model: model, provider: provider, baseURL: baseURL), model: model)
  }

  public func requestFields(family: APIFamily, model: String) -> [String: JSONValue] {
    if self == .automatic {
      // DeepSeek Flash otherwise enables thinking at high effort. Keep the
      // normal pmai path fast and bounded; an explicit effort turns it back on.
      guard Self.isDeepSeekFlash(model) else { return [:] }
      if family == .deepSeek {
        return ["thinking": .object(["type": .string("disabled")])]
      }
      if family == .ollama, model.lowercased().contains("deepseek") {
        return ["think": .bool(false), "reasoning_effort": .string("none")]
      }
      return [:]
    }
    let enabled = self != .disabled
    switch family {
    case .kimi:
      let name = model.lowercased()
      if name.contains("kimi-k3") {
        return [
          "reasoning_effort": .string(
            self == .max
              ? "max" : self == .disabled || self == .minimal || self == .low ? "low" : "high")
        ]
      }
      if name.contains("k2.5") || name.contains("k2.6") {
        return ["thinking": .object(["type": .string(enabled ? "enabled" : "disabled")])]
      }
      // K2 Thinking and K2.7 are always on; older K2 Instruct has no switch.
      return [:]
    case .kimiLocal:
      guard model.contains("2.5") || model.contains("2.6") else { return [:] }
      return ["chat_template_kwargs": .object(["thinking": .bool(enabled)])]
    case .minimax:
      guard model.lowercased().contains("minimax-m3") else { return [:] }
      return ["thinking": .object(["type": .string(enabled ? "adaptive" : "disabled")])]
    case .gemma:
      guard Self.isGemma4(model) else { return [:] }
      return ["chat_template_kwargs": .object(["enable_thinking": .bool(enabled)])]
    case .gemini:
      let name = model.lowercased()
      guard name.contains("gemini-2.5") || name.contains("gemini-3") else { return [:] }
      let canDisable = name.contains("gemini-2.5") && !name.contains("pro")
      return [
        "reasoning_effort": .string(
          self == .disabled
            ? (canDisable ? "none" : "low") : effortName(allowingXHigh: false))
      ]
    case .openRouter:
      return [
        "reasoning": .object([
          "effort": .string(effortName(allowingXHigh: true)),
          "enabled": .bool(enabled),
          "exclude": .bool(!enabled),
        ])
      ]
    case .deepSeek:
      var fields: [String: JSONValue] = [
        "thinking": .object(["type": .string(enabled ? "enabled" : "disabled")])
      ]
      if enabled {
        fields["reasoning_effort"] = .string(
          self == .max ? "max" : self == .low || self == .minimal ? "low" : "high")
      }
      return fields
    case .qwen:
      var fields: [String: JSONValue] = [
        "enable_thinking": .bool(enabled),
        "chat_template_kwargs": .object(["enable_thinking": .bool(enabled)]),
      ]
      if enabled { fields["thinking_budget"] = .integer(thinkingBudget) }
      return fields
    case .ollama:
      let effort = self == .disabled || self == .minimal ? "low" : effortName(allowingXHigh: false)
      if model.lowercased().contains("gpt-oss") {
        return ["think": .string(effort), "reasoning_effort": .string(effort)]
      }
      return [
        "think": .bool(enabled),
        "reasoning_effort": .string(enabled ? effort : "none"),
        "chat_template_kwargs": .object(["enable_thinking": .bool(enabled)]),
      ]
    case .openAI:
      guard Self.isOpenAIReasoningModel(model) else { return [:] }
      let name: String
      if self == .disabled || self == .minimal {
        let text = model.lowercased()
        if self == .disabled && Self.supportsOpenAINone(text) {
          name = "none"
        } else {
          name =
            text.contains("pro")
            ? "medium"
            : text == "gpt-5" || text.hasPrefix("gpt-5-2025")
              || text.hasPrefix("gpt-5-mini") || text.hasPrefix("gpt-5-nano") ? "minimal" : "low"
        }
      } else {
        name = effortName(allowingXHigh: Self.supportsOpenAIXHigh(model))
      }
      return ["reasoning_effort": .string(name)]
    case .generic:
      return ["reasoning_effort": .string(effortName(allowingXHigh: false))]
    }
  }

  /// The `reasoning_effort` value: `low`, `medium`, `high`, and `xhigh` where
  /// the endpoint knows it; `max` is the most an endpoint offers.
  public func effortName(allowingXHigh: Bool) -> String {
    switch self {
    case .automatic: "auto"
    case .disabled: "none"
    case .xhigh, .max: allowingXHigh ? "xhigh" : "high"
    default: rawValue
    }
  }

  /// Qwen's `thinking_budget`, in tokens.
  public var thinkingBudget: Int {
    switch self {
    case .automatic, .disabled: 0
    case .minimal: 256
    case .low: 1024
    case .medium: 4096
    case .high: 8192
    case .xhigh: 32768
    case .max: 65536
    }
  }

  /// Local chat-template controls, used by MLX without a provider-specific UI.
  public func templateContext(model: String) -> [String: any Sendable]? {
    guard self != .automatic else { return nil }
    if model.lowercased().contains("qwen3") || Self.isGemma4(model) {
      return ["enable_thinking": self != .disabled]
    }
    if model.lowercased().contains("kimi-k2.5") || model.lowercased().contains("kimi-k2.6") {
      return ["thinking": self != .disabled]
    }
    if model.lowercased().contains("gpt-oss") {
      return [
        "reasoning_effort": self == .disabled || self == .minimal
          ? "low" : effortName(allowingXHigh: false)
      ]
    }
    return nil
  }

  public var optionValue: String? { self == .automatic ? nil : rawValue }

  public var id: String { rawValue }

  public func limitation(model: String, provider: String = "", baseURL: String = "") -> String? {
    let family = APIFamily.detect(model: model, provider: provider, baseURL: baseURL)
    let name = model.lowercased()
    if self == .automatic {
      return Self.isDeepSeekFlash(model)
        && (family == .deepSeek || family == .ollama && name.contains("deepseek"))
        ? "Thinking is off by default for DeepSeek Flash; choose Low or higher to enable it."
        : nil
    }
    if self != .disabled {
      if family == .minimax || family == .gemma
        || ((family == .kimi || family == .kimiLocal) && !name.contains("kimi-k3"))
      {
        return "This model has no numeric effort control; the level is sent as prompt guidance."
      }
      return nil
    }
    if (family == .minimax && name.contains("minimax-m2"))
      || (name.contains("kimi") && (name.contains("thinking") || name.contains("k2.7")))
    {
      return "This model always thinks; its API has no off switch or effort control."
    }
    if name.contains("kimi-k3")
      || (family == .gemini
        && (name.contains("gemini-3") || name.contains("gemini-2.5-pro")))
      || name.contains("gpt-oss")
      || (family == .openAI && Self.isOpenAIReasoningModel(model)
        && !Self.supportsOpenAINone(model))
    {
      return "This model cannot disable thinking; the lowest supported effort is requested."
    }
    return nil
  }

  /// Apply at the provider boundary so direct iOS requests and runtime requests agree.
  public static func messages(
    _ messages: [AgentMessage], options: GenerationOptions, model: String
  ) -> [AgentMessage] {
    var result = messages
    if let section = promptSection(for: options),
      !result.contains(where: { $0.role == .system && $0.text.contains(section) })
    {
      result.insert(.system(section), at: result.first?.role == .system ? 1 : 0)
    }
    if options.reasoningEffort.flatMap(Self.init(name:)) == .disabled,
      model.lowercased().contains("qwen3"),
      let index = result.lastIndex(where: { $0.role == .user })
    {
      result[index].appendText("\n/no_think")
    }
    return result
  }

  static func isGemma4(_ model: String) -> Bool {
    let name = model.lowercased().replacingOccurrences(of: "-", with: "")
    return name.contains("gemma4")
  }

  static func isDeepSeekFlash(_ model: String) -> Bool {
    model.lowercased().contains("flash")
  }

  /// These APIs require reasoning history independently of display. DeepSeek
  /// consumes it only when the request carries `tools`; without tools it is
  /// ignored and needlessly enlarges the request.
  public static func requiresReasoningHistory(
    model: String, provider: String = "", baseURL: String = "", hasTools: Bool = true
  ) -> Bool {
    switch APIFamily.detect(model: model, provider: provider, baseURL: baseURL) {
    case .deepSeek: hasTools
    case .kimi, .kimiLocal, .minimax: true
    default: false
    }
  }

  static func supportsOpenAINone(_ model: String) -> Bool {
    let text = model.lowercased()
    guard !text.contains("codex"), !text.contains("pro") else { return false }
    return text.hasPrefix("gpt-5.1") || supportsOpenAIXHigh(text)
  }

  /// OpenAI rejects `reasoning_effort` on models without reasoning, so it is
  /// only sent to the ones known to have it: gpt-5 and later, and the o-series.
  static func isOpenAIReasoningModel(_ model: String) -> Bool {
    let text = model.lowercased()
    if text.hasPrefix("gpt-"), let generation = text.dropFirst(4).first?.wholeNumberValue {
      return generation >= 5
    }
    if text.count >= 2, text.first == "o", text.dropFirst().first?.isNumber == true {
      return true
    }
    return false
  }

  /// `xhigh` arrived with gpt-5.1-codex-max and is accepted from gpt-5.2 on.
  static func supportsOpenAIXHigh(_ model: String) -> Bool {
    let text = model.lowercased()
    if text.contains("codex-max") { return true }
    guard text.hasPrefix("gpt-") else { return false }
    let version = text.dropFirst(4).prefix { $0.isNumber || $0 == "." }
    let parts = version.split(separator: ".").compactMap { Int($0) }
    guard let major = parts.first else { return false }
    if major > 5 { return true }
    return major == 5 && (parts.count > 1 ? parts[1] : 0) >= 2
  }
}
