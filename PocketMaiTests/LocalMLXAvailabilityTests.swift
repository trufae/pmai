import Foundation
import XCTest

@testable import PocketMai

final class LocalMLXAvailabilityTests: XCTestCase {
  func testGPUCapabilitiesDetermineSupport() {
    for gpu in ["Apple A12 GPU", "Apple A12Z GPU", "Apple A13 GPU"] {
      XCTAssertEqual(
        LocalMLXAvailability.evaluate(isSimulator: false, gpuName: gpu, supportsApple7: false),
        .unsupportedGPU(gpu))
    }
    // Capability checks also accept future devices without a model-name allowlist.
    for gpu in ["Apple A14 GPU", "Apple A15 GPU", "Apple M1", "Future Apple GPU"] {
      XCTAssertEqual(
        LocalMLXAvailability.evaluate(isSimulator: false, gpuName: gpu, supportsApple7: true),
        .available)
    }
    XCTAssertEqual(
      LocalMLXAvailability.evaluate(isSimulator: false, gpuName: nil, supportsApple7: true),
      .metalUnavailable)
    XCTAssertEqual(
      LocalMLXAvailability.evaluate(isSimulator: true, gpuName: "Apple M1", supportsApple7: true),
      .simulator)
  }

  func testSimulatorNeverUsesHostGPUForAvailability() {
    #if targetEnvironment(simulator)
      XCTAssertEqual(LocalMLXAvailability.current, .simulator)
    #endif
  }

  func testHardwarePreflightTakesPriorityOverModelDownloadAdvice() {
    var conversation = Conversation()
    conversation.provider = .mlx
    var settings = AppSettings.defaults
    settings.localMLXModelID = ""
    for model in ["", "missing/model", "https://huggingface.co/org/model"] {
      conversation.modelID = model
      let availability = LocalMLXAvailability.unsupportedGPU("Apple A12 GPU")
      XCTAssertEqual(
        ChatProviderRouter.preflightMessage(
          conversation: conversation, settings: settings, mlxAvailability: availability),
        availability.unavailabilityMessage)
    }
  }

  func testNewChatsUseAvailableProvidersWithoutChangingSavedDefaults() {
    var settings = AppSettings.defaults
    settings.defaultProvider = .mlx
    settings.openAIEndpoints = []
    let preferred = settings.defaultProviderConfiguration
    let setup = settings.availableProviderConfiguration(
      preferred, appleAvailable: false, mlxAvailable: false)
    XCTAssertEqual(setup.provider, .openAICompatible)
    XCTAssertNil(setup.endpointID)
    XCTAssertEqual(setup.modelID, "")
    XCTAssertEqual(settings.defaultProvider, .mlx)

    let endpoint = OpenAIEndpoint(baseURL: "http://localhost:11434/v1", authMethod: .apiKey)
    settings.openAIEndpoints = [endpoint]
    let remote = settings.availableProviderConfiguration(
      preferred, appleAvailable: false, mlxAvailable: false)
    XCTAssertEqual(remote.endpointID, endpoint.id)
    XCTAssertEqual(
      settings.availableProviderConfiguration(
        preferred, appleAvailable: true, mlxAvailable: false
      ).provider, .apple)
    XCTAssertEqual(
      settings.availableProviderConfiguration(
        preferred, appleAvailable: false, mlxAvailable: true
      ).provider, .mlx)

    settings.airplaneModeEnabled = true
    let offline = settings.availableProviderConfiguration(
      preferred, appleAvailable: false, mlxAvailable: false)
    XCTAssertNil(offline.endpointID)
    XCTAssertNotEqual(offline.provider, .mlx)
  }

  func testRecoveryAdviceOnlySuggestsAvailableLocalProviders() throws {
    let unavailable = LocalMLXAvailability.unsupportedGPU("Apple A12 GPU")
    XCTAssertFalse(unavailable.alternativeProviderSuggestion.contains("Use MLX"))
    XCTAssertTrue(
      unavailable.offlineGuidance(appleAvailable: false).contains("Turn off Airplane Mode"))
    XCTAssertFalse(unavailable.offlineGuidance(appleAvailable: false).contains("MLX"))
    XCTAssertTrue(unavailable.offlineGuidance(appleAvailable: true).contains("Apple Intelligence"))
    XCTAssertTrue(
      LocalMLXAvailability.available.offlineGuidance(appleAvailable: false).contains(
        "downloaded model"))
    let message = try XCTUnwrap(unavailable.unavailabilityMessage)
    XCTAssertTrue(message.contains("A12"))
    XCTAssertTrue(message.contains("Add Provider"))
  }
}
