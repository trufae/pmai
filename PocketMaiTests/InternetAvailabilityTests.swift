import Foundation
import MaiCore
import MaiStandardTools
import XCTest

@testable import PocketMai

@MainActor
final class InternetAvailabilityTests: XCTestCase {
  func testNetworkLossIsTransientAndManualAirplaneModeSurvivesReconnect() throws {
    var settings = AppSettings()
    settings.allowAppleServerTranscription = true
    settings.networkAvailable = false
    XCTAssertTrue(settings.isOffline)
    XCTAssertFalse(settings.airplaneModeEnabled)
    XCTAssertFalse(settings.appleServerTranscriptionAllowed)
    let saved = try JSONEncoder().encode(settings)
    let restored = try JSONDecoder().decode(AppSettings.self, from: saved)
    XCTAssertTrue(restored.networkAvailable)
    XCTAssertFalse(restored.isOffline)
    XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("networkAvailable"))
    settings.airplaneModeEnabled = true
    settings.networkAvailable = true
    XCTAssertTrue(settings.isOffline)
    settings.airplaneModeEnabled = false
    XCTAssertFalse(settings.isOffline)
    XCTAssertTrue(settings.appleServerTranscriptionAllowed)
  }

  func testOfflineCatalogBlocksInternetToolsDespiteManualPinsAndPreservesLocalTools() {
    var settings = AppSettings()
    var conversation = Conversation()
    conversation.enabledTools = Set(BuiltInToolID.allCases)
    settings.toolPolicy.groups = ["github": .direct, "weather": .proxy]
    let online = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    let savedPolicy = settings.toolPolicy
    settings.networkAvailable = false
    let offline = ToolAgentRegistry.catalog(for: conversation, settings: settings)
    XCTAssertFalse(offline.enabledDefinitions.contains { $0.annotations.requiresInternet })
    XCTAssertTrue(offline.enabledDefinitions.contains { $0.name == MaiCalculatorTool.name })
    XCTAssertFalse(offline.enabledDefinitions.contains { $0.name == MaiWeatherTool.name })
    XCTAssertFalse(offline.visibleDefinitions.map(\.description).joined().contains("github_pr"))
    XCTAssertEqual(settings.toolPolicy, savedPolicy)
    settings.networkAvailable = true
    XCTAssertEqual(
      ToolAgentRegistry.catalog(for: conversation, settings: settings).modes, online.modes)
  }

  func testReachabilityChangesPublishEffectiveStateAndRevokeServerTranscription() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root), monitorNetwork: false)
    store.settings.allowAppleServerTranscription = true
    var cancelled = false
    _ = try store.speechTranscriptionPolicy.registerServerRequest { cancelled = true }
    store.updateNetworkAvailability(false)
    XCTAssertTrue(store.settings.isOffline)
    XCTAssertTrue(cancelled)
    XCTAssertFalse(store.settings.airplaneModeEnabled)
    store.settings.airplaneModeEnabled = true
    store.updateNetworkAvailability(true)
    XCTAssertTrue(store.settings.isOffline)
    store.setAirplaneMode(false)
    XCTAssertFalse(store.settings.isOffline)
    XCTAssertTrue(store.speechTranscriptionPolicy.allowsServerRecognition)
  }

  func testLiveOfflinePolicyRejectsCallsFromAnOnlineSnapshot() async {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root), monitorNetwork: false)
    store.updateNetworkAvailability(false)
    var conversation = Conversation()
    conversation.enabledTools = [.github, .calculator]
    var onlineSettings = AppSettings()
    for mode in [AgentToolMode.direct, .proxy] {
      onlineSettings.toolPolicy.tools["github_pr"] = mode
      let call = mode == .direct
        ? ParsedToolCall(name: "github_pr", arguments: [:], rawBlock: "")
        : ParsedToolCall(
          name: ToolProxy.callName, arguments: [:],
          argumentValues: ["name": .string("github_pr"), "arguments": .object([:])],
          rawBlock: "")
      let result = await ToolAgentRegistry.execute(
        call: call, conversation: conversation, settings: onlineSettings, store: store)
      XCTAssertEqual(result, "Error: internet tools are disabled while offline.")
    }
    onlineSettings.toolPolicy.tools[MaiCalculatorTool.name] = .direct
    let local = await ToolAgentRegistry.execute(
      call: ParsedToolCall(
        name: MaiCalculatorTool.name, arguments: ["expression": "2+3"], rawBlock: ""),
      conversation: conversation, settings: onlineSettings, store: store)
    XCTAssertEqual(local, "5")
  }
}
