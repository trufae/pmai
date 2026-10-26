import Foundation

/// Shared by graphical browsers and /models. Features are declared by the backend,
/// never guessed from a model's name. Missing metadata remains unknown.
public enum ModelFeature: String, CaseIterable, Codable, Hashable, Sendable {
  case tools, vision, reasoning, decision, voice

  public var title: String { rawValue.capitalized }

  public func isSupported(by model: ModelDescriptor) -> Bool {
    switch self {
    case .tools: model.capabilities.contains(.nativeToolCalling)
    case .vision: model.capabilities.contains(.imageInput)
    case .reasoning: model.capabilities.contains(.reasoning)
    case .decision: model.capabilities.contains(.toolDecision)
    case .voice: !model.capabilities.intersection([.audioInput, .audioOutput]).isEmpty
    }
  }
}

public struct ModelCatalogFilter: Equatable, Sendable {
  public var search: String
  public var features: Set<ModelFeature>
  public var minimumContextWindow: Int?
  public var requiredCapabilities: ProviderCapabilities

  public init(
    search: String = "", features: Set<ModelFeature> = [], minimumContextWindow: Int? = nil,
    requiredCapabilities: ProviderCapabilities = []
  ) {
    self.search = search
    self.features = features
    self.minimumContextWindow = minimumContextWindow
    self.requiredCapabilities = requiredCapabilities
  }

  public func matches(_ model: ModelDescriptor) -> Bool {
    guard features.allSatisfy({ $0.isSupported(by: model) }),
      model.capabilities.isSuperset(of: requiredCapabilities)
    else { return false }
    if let minimumContextWindow, (model.contextWindow ?? 0) < minimumContextWindow { return false }
    let text = ([model.id, model.displayName, model.ownedBy ?? ""] + model.featureLabels)
      .joined(separator: " ")
    return search.split(whereSeparator: \.isWhitespace).allSatisfy {
      text.localizedCaseInsensitiveContains(String($0))
    }
  }

  public func applying(to models: [ModelDescriptor]) -> [ModelDescriptor] {
    models.filter(matches).sorted {
      let order = $0.id.localizedCaseInsensitiveCompare($1.id)
      return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
  }
}

extension ModelDescriptor {
  public var features: [ModelFeature] { ModelFeature.allCases.filter { $0.isSupported(by: self) } }

  public var contextLabel: String? {
    contextWindow.map { $0 >= 1024 ? "\($0 / 1024)K context" : "\($0) context" }
  }

  public var featureLabels: [String] {
    features.map(\.title) + (contextLabel.map { [$0] } ?? [])
  }

  /// Accepts OpenAI-compatible catalog extensions and Ollama /api/show payloads.
  /// Supplying a descriptor enriches it without losing the portable catalog identity.
  public static func catalogEntry(
    _ object: [String: JSONValue], enriching existing: ModelDescriptor? = nil
  ) -> ModelDescriptor? {
    guard let id = existing?.id ?? object["id"]?.stringValue ?? object["model"]?.stringValue
      ?? object["name"]?.stringValue, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }
    var model = existing ?? ModelDescriptor(
      id: id, displayName: object["display_name"]?.stringValue ?? object["name"]?.stringValue,
      ownedBy: object["owned_by"]?.stringValue ?? object["ownedBy"]?.stringValue)
    let architecture = object["architecture"]?.objectValue ?? [:]
    let capabilityObject = object["capabilities"]?.objectValue ?? [:]
    let names = Set((object["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
      .map { $0.lowercased() })
    let parameters = Set(object["supported_parameters"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    func supports(_ aliases: [String]) -> Bool {
      aliases.contains { key in
        names.contains(key) || capabilityObject[key]?.boolValue == true
          || capabilityObject[key]?.objectValue?["supported"]?.boolValue == true
      }
    }
    let modality = architecture["modality"]?.stringValue?.lowercased().components(separatedBy: "->")
    func modalities(_ key: String, index: Int) -> Set<String>? {
      if let values = (architecture[key] ?? object[key])?.arrayValue?.compactMap(\.stringValue) {
        return Set(values.map { $0.lowercased() })
      }
      guard let modality, modality.indices.contains(index), !modality[index].isEmpty else { return nil }
      return Set(modality[index].split(separator: "+").map(String.init))
    }
    model.inputModalities = modalities("input_modalities", index: 0) ?? model.inputModalities
    model.outputModalities = modalities("output_modalities", index: 1) ?? model.outputModalities
    if supports(["vision", "image_input"]) || model.inputModalities?.contains("image") == true {
      model.capabilities.insert(.imageInput)
    }
    if model.inputModalities == nil,
      let supported = capabilityObject["image_input"]?.objectValue?["supported"]?.boolValue {
      model.inputModalities = supported ? ["text", "image"] : ["text"]
    }
    if supports(["audio", "audio_input", "transcription", "speech-to-text"])
      || model.inputModalities?.contains("audio") == true {
      model.capabilities.insert(.audioInput)
    }
    if supports(["tts", "audio_output", "speech", "text-to-speech"])
      || model.outputModalities?.contains("audio") == true {
      model.capabilities.insert(.audioOutput)
    }
    if supports(["tools", "tool_calling", "function_calling"]) || parameters.contains("tools") {
      model.capabilities.insert(.nativeToolCalling)
    }
    if supports(["thinking", "reasoning"]) || parameters.contains("reasoning")
      || parameters.contains("reasoning_effort") {
      model.capabilities.insert(.reasoning)
    }
    if supports(["decision"]) { model.capabilities.insert(.toolDecision) }
    let info = object["model_info"]?.objectValue ?? [:]
    let context = [object["context_length"], object["context_window"], object["max_context_length"],
      object["top_provider"]?.objectValue?["context_length"]]
      + info.keys.sorted().filter { $0.hasSuffix(".context_length") }.map { info[$0] }
    if let size = context.compactMap({ $0?.intValue }).first(where: { $0 > 0 }) {
      model.contextWindow = size
    }
    if let voices = object["voices"]?.arrayValue {
      model.voices = voices.compactMap {
        $0.stringValue ?? $0.objectValue?["id"]?.stringValue ?? $0.objectValue?["name"]?.stringValue
      }.sorted()
    }
    return model
  }
}
