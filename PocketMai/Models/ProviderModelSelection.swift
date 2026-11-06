import Foundation
import MaiCore

/// The editable provider/model pair. A nil provider explicitly inherits defaults.
struct ProviderModelSelection: Equatable {
  var provider: ProviderKind?
  var endpointID: UUID? = nil
  var modelID = ""
}

struct ProviderModelCatalog {
  let endpoints: [OpenAIEndpoint]
  let isOffline: Bool
  let appleAvailable: Bool
  let mlxUnavailableReason: String?
  let localModelIDs: [String]
  let defaultLocalModelID: String
  let appleModelID: String

  func endpoint(for selection: ProviderModelSelection) -> OpenAIEndpoint? {
    endpoints.first { $0.id == selection.endpointID && $0.isEnabled }
  }

  func localModelID(preferred: String? = nil) -> String? {
    let candidates = [preferred, defaultLocalModelID, AppSettings.localMLXDefaultModelID]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
    return candidates.first { localModelIDs.contains($0) } ?? localModelIDs.first
  }

  func unavailableReason(for selection: ProviderModelSelection) -> String? {
    switch selection.provider {
    case nil: nil
    case .apple: appleAvailable ? nil : "Apple Intelligence is unavailable."
    case .mlx: mlxUnavailableReason
    case .openAICompatible:
      isOffline
        ? "Airplane Mode is on. Choose an on-device provider."
        : (endpoint(for: selection) == nil ? "Choose an enabled provider in Settings." : nil)
    }
  }

  func validationMessage(for selection: ProviderModelSelection) -> String? {
    if let reason = unavailableReason(for: selection) { return reason }
    if selection.provider == .mlx {
      if localModelIDs.isEmpty {
        return "Download an MLX model in Settings > Providers > Local MLX LLM."
      }
      if !localModelIDs.contains(selection.modelID) { return "Select a downloaded MLX model." }
    }
    return nil
  }

  func selecting(
    _ provider: ProviderKind?, endpointID: UUID? = nil, from current: ProviderModelSelection
  ) -> ProviderModelSelection? {
    var next = ProviderModelSelection(provider: provider, endpointID: endpointID)
    guard unavailableReason(for: next) == nil else { return nil }
    // Selecting the same source must not discard a custom model.
    if provider != nil, current.provider == provider, current.endpointID == endpointID {
      return current
    }
    switch provider {
    case nil: break
    case .apple: next.modelID = appleModelID
    case .mlx: next.modelID = localModelID() ?? ""
    case .openAICompatible: next.modelID = endpoint(for: next)?.defaultModel ?? ""
    }
    return next
  }

  func title(for selection: ProviderModelSelection) -> String {
    switch selection.provider {
    case nil: "Use Agent Defaults"
    case .apple: "Apple Intelligence"
    case .mlx: "MLX Local"
    case .openAICompatible:
      endpoints.first { $0.id == selection.endpointID }?.displayName ?? "Choose Provider"
    }
  }
}

extension Conversation {
  var providerModelSelection: ProviderModelSelection {
    get { .init(provider: provider, endpointID: endpointID, modelID: modelID) }
    set {
      guard let provider = newValue.provider else { return }
      self.provider = provider
      endpointID = newValue.endpointID
      modelID = newValue.modelID
    }
  }
}

extension ConversationFolderDefaults {
  var providerModelSelection: ProviderModelSelection {
    get { .init(provider: provider, endpointID: endpointID, modelID: modelID) }
    set {
      provider = newValue.provider
      endpointID = newValue.endpointID
      modelID = newValue.modelID
    }
  }
}

extension AgentSettings {
  var providerModelSelection: ProviderModelSelection {
    get {
      let model: String
      switch defaultProvider {
      case .apple: model = appleModelID
      case .mlx: model = localMLXModelID
      case .openAICompatible: model = openAIModelID
      }
      return .init(
        provider: defaultProvider,
        endpointID: defaultProvider == .openAICompatible ? selectedEndpointID : nil, modelID: model)
    }
    set {
      guard let provider = newValue.provider else { return }
      defaultProvider = provider
      switch provider {
      case .apple: appleModelID = newValue.modelID
      case .mlx: localMLXModelID = newValue.modelID
      case .openAICompatible:
        selectedEndpointID = newValue.endpointID
        openAIModelID = newValue.modelID
      }
    }
  }
}
