import SwiftUI
import UIKit
import XCTest

@testable import PocketMai

@MainActor
final class NativeToolSettingsLayoutTests: XCTestCase {
  func testExpandedOptionsStayBelowTheirHeadersAtPhoneWidths() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "tool-settings-layout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = AppStore(persistence: PersistenceStore(localBaseURL: root))
    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
    let previousKeyWindow = scene.keyWindow

    for width in [320.0, 390.0] {
      let content = Form {
        DisclosureGroup("Native", isExpanded: .constant(true)) {
          NativeToolSettingsRow(
            tool: .weather, isEnabled: false, isUnavailable: false,
            isExpanded: .constant(true), toggle: {}
          ) {
            TextField("Weather location", text: .constant(""))
            TextField("Second weather option", text: .constant(""))
          }
          NativeToolSettingsRow(
            tool: .webSearch, isEnabled: false, isUnavailable: false,
            isExpanded: .constant(true), toggle: {}
          ) {
            TextField("Search provider URL", text: .constant(""))
            Toggle("Fetching data", isOn: .constant(true))
          }
        }
      }
      .environmentObject(store)
      .preferredColorScheme(.dark)
      .frame(width: width)
      let host = UIHostingController(rootView: content)
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(x: 0, y: 0, width: width, height: 844)
      window.rootViewController = host
      window.makeKeyAndVisible()
      defer {
        window.isHidden = true
        previousKeyWindow?.makeKeyAndVisible()
      }

      func textFields(in view: UIView) -> [UITextField] {
        (view as? UITextField).map { [$0] } ?? view.subviews.flatMap { textFields(in: $0) }
      }
      let deadline = ContinuousClock.now + .seconds(5)
      var fields: [UITextField] = []
      repeat {
        host.view.layoutIfNeeded()
        fields = textFields(in: host.view)
        if fields.count == 3, fields.allSatisfy({ $0.bounds.width > 0 }) { break }
        try await Task.sleep(for: .milliseconds(20))
      } while ContinuousClock.now < deadline

      XCTAssertEqual(fields.count, 3)
      let frames = fields.map { $0.convert($0.bounds, to: host.view) }.sorted { $0.minY < $1.minY }
      for frame in frames {
        XCTAssertGreaterThan(frame.width, width * 0.6, "Options must keep most of the row width")
      }
      if frames.count == 3 {
        XCTAssertGreaterThan(frames[1].minY, frames[0].maxY)
        XCTAssertGreaterThan(frames[2].minY, frames[1].maxY)
      }
      let screenshot = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
        host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
      }
      let attachment = XCTAttachment(image: screenshot)
      attachment.name = "Expanded tool settings at \(Int(width))pt"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
  }
}
