extension AppStore {
  var defaultProviderModelSelection: ProviderModelSelection {
    let configuration = effectiveDefaultProviderConfiguration
    return .init(
      provider: configuration.provider,
      endpointID: configuration.endpointID, modelID: configuration.modelID)
  }

  var providerModelCatalog: ProviderModelCatalog {
    ProviderModelCatalog(
      endpoints: settings.openAIEndpoints, isOffline: settings.isOffline,
      appleAvailable: appleIntelligenceIsAvailable,
      mlxUnavailableReason: LocalMLXAvailability.current.unavailabilityMessage,
      localModelIDs: localMLXModelIDs, defaultLocalModelID: settings.localMLXModelID,
      appleModelID: settings.appleModelID)
  }
}
