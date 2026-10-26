import MaiCore
import SwiftUI
import UIKit
import XCTest
@testable import PocketMai

@MainActor
final class ModelBrowserTests: XCTestCase {
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
