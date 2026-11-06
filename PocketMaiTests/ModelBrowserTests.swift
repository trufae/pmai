import MaiCore
import SwiftUI
import UIKit
import XCTest
@testable import PocketMai

@MainActor
final class ModelBrowserTests: XCTestCase {
  func testProviderSwitchClearsThePreviousProvidersModel() throws {
    let first = OpenAIEndpoint(name: "First", defaultModel: "first-default")
    let second = OpenAIEndpoint(name: "Second", defaultModel: "")
    let catalog = selectionCatalog(endpoints: [first, second])
    let original = ProviderModelSelection(
      provider: .openAICompatible, endpointID: first.id, modelID: "custom-first-model")
    XCTAssertEqual(catalog.selecting(.openAICompatible, endpointID: first.id, from: original), original)
    let switched = try XCTUnwrap(catalog.selecting(.openAICompatible, endpointID: second.id, from: original))
    XCTAssertEqual(switched.endpointID, second.id)
    XCTAssertEqual(switched.modelID, "", "A model from a different provider must not carry over")
    let restored = try XCTUnwrap(catalog.selecting(.openAICompatible, endpointID: first.id, from: switched))
    XCTAssertEqual(restored.modelID, first.defaultModel)
    XCTAssertEqual(catalog.selecting(nil, from: original), ProviderModelSelection(provider: nil))
  }

  func testUnavailableProvidersCannotBeSelected() {
    let enabled = OpenAIEndpoint(name: "Enabled")
    let disabled = OpenAIEndpoint(name: "Disabled", isEnabled: false)
    let current = ProviderModelSelection(provider: .mlx, modelID: "downloaded")
    let catalog = selectionCatalog(endpoints: [enabled, disabled])
    XCTAssertNil(catalog.selecting(.openAICompatible, endpointID: disabled.id, from: current))
    XCTAssertNil(catalog.selecting(.openAICompatible, endpointID: UUID(), from: current))
    let offline = selectionCatalog(endpoints: [enabled], offline: true)
    XCTAssertNil(offline.selecting(.openAICompatible, endpointID: enabled.id, from: current))
    XCTAssertNotNil(offline.selecting(.mlx, from: current))
    let unavailable = selectionCatalog(appleAvailable: false, mlxUnavailableReason: "Unavailable")
    XCTAssertNil(unavailable.selecting(.apple, from: current))
    XCTAssertNil(unavailable.selecting(.mlx, from: current))
  }

  func testLocalSelectionUsesDownloadedModelsAndReportsMissingOnes() throws {
    let catalog = selectionCatalog()
    let remote = ProviderModelSelection(provider: .openAICompatible, modelID: "remote-only")
    let local = try XCTUnwrap(catalog.selecting(.mlx, from: remote))
    XCTAssertEqual(local.modelID, "downloaded")
    XCTAssertNil(local.endpointID)
    XCTAssertNil(catalog.validationMessage(for: local))
    XCTAssertNotNil(catalog.validationMessage(for: .init(provider: .mlx, modelID: "removed")))
    XCTAssertEqual(catalog.localModelID(preferred: " removed "), "downloaded")
  }

  func testSelectionUpdatesOnlyProviderFieldsAcrossEditingScopes() {
    let selection = ProviderModelSelection(provider: .openAICompatible, endpointID: UUID(), modelID: "chosen")
    var conversation = Conversation()
    let conversationID = conversation.id
    conversation.providerModelSelection = selection
    XCTAssertEqual(conversation.providerModelSelection, selection)
    XCTAssertEqual(conversation.id, conversationID)
    var folder = ConversationFolderDefaults(systemPromptID: UUID())
    let promptID = folder.systemPromptID
    folder.providerModelSelection = selection
    XCTAssertEqual(folder.providerModelSelection, selection)
    XCTAssertEqual(folder.systemPromptID, promptID)
    var agent = AgentSettings()
    agent.localMLXModelID = "keep-local-preference"
    agent.providerModelSelection = selection
    XCTAssertEqual(agent.providerModelSelection, selection)
    XCTAssertEqual(agent.localMLXModelID, "keep-local-preference")
  }

  private func selectionCatalog(
    endpoints: [OpenAIEndpoint] = [], offline: Bool = false,
    appleAvailable: Bool = true, mlxUnavailableReason: String? = nil
  ) -> ProviderModelCatalog {
    .init(endpoints: endpoints, isOffline: offline, appleAvailable: appleAvailable,
      mlxUnavailableReason: mlxUnavailableReason, localModelIDs: ["downloaded"],
      defaultLocalModelID: "downloaded", appleModelID: "")
  }

  func testBrowserAtPhoneWidths() async throws {
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previous = scene.keyWindow
    for width in [320.0, 390.0] {
      let content = ModelBrowser(
        selection: .constant("alpha"), models: [
          .init(id: "alpha", capabilities: [.nativeToolCalling, .imageInput, .reasoning], contextWindow: 131072),
          .init(id: "phonon", capabilities: [.audioOutput], voices: ["Freya"]),
          .init(id: "tev1", capabilities: [.toolDecision], contextWindow: 32768),
          .init(id: "unknown"),
        ], title: "Model", refresh: {})
        .preferredColorScheme(.dark)
        .frame(width: width)
      let host = UIHostingController(rootView: content)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer { window.isHidden = true; previous?.makeKeyAndVisible() }
      try await Task.sleep(for: .milliseconds(400))
      host.view.layoutIfNeeded()
      func fields(_ view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap(fields)
      }
      let search = try XCTUnwrap(fields(host.view).first { $0.placeholder == "Search models" })
      let searchFrame = search.convert(search.bounds, to: host.view)
      XCTAssertGreaterThan(searchFrame.minY, 600, "Search stays at the bottom of the browser")
      XCTAssertGreaterThan(searchFrame.width, width * 0.55)
      let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: image)
      attachment.name = "Model browser at \(Int(width))pt"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }

  func testToolModelSelectionDefaultsToNativeAndExplicitOverrideSurvives() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root))
    let loadDeadline = ContinuousClock.now + .seconds(3)
    while !store.hasLoadedPersistedSettings || store.currentConversation == nil {
      guard ContinuousClock.now < loadDeadline else { XCTFail("Settings did not load"); return }
      try await Task.sleep(for: .milliseconds(20))
    }
    let endpoint = OpenAIEndpoint(name: "Catalog test")
    store.settings.openAIEndpoints = [endpoint]
    store.endpointModelDescriptors[endpoint.id] = [.init(id: "tool-model", capabilities: [.nativeToolCalling])]
    store.newConversation()
    store.updateCurrentConversationSettings {
      $0.provider = .openAICompatible
      $0.endpointID = endpoint.id
      $0.modelID = "tool-model"
    }
    XCTAssertEqual(store.currentConversation?.toolCallingMode, .native)
    store.updateCurrentConversationSettings { $0.toolCallingMode = .text }
    let deadline = ContinuousClock.now + .seconds(3)
    while store.currentConversation?.toolCallingMode != .text, ContinuousClock.now < deadline {
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTAssertEqual(store.currentConversation?.toolCallingMode, .text)
  }
}
