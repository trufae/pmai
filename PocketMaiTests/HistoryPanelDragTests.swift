import Foundation
import XCTest

@testable import PocketMai

final class HistoryPanelDragTests: XCTestCase {
  func testLongLeftSwipeFromFoldersDoesNotOvershootConversations() {
    let drag = HistoryPanelDrag(startingDepth: 2, panelWidth: 390)
    XCTAssertEqual(drag.offset(for: -100), -100)
    XCTAssertEqual(drag.offset(for: -390), -390)
    XCTAssertEqual(drag.offset(for: -600), -390)
    XCTAssertEqual(drag.targetDepth(translation: -600, velocity: -800), 1)
  }

  func testLongSwipesStayWithinOneAdjacentPanelAtEveryDepth() {
    for depth in 0...3 {
      for direction in [CGFloat(-1), CGFloat(1)] {
        let drag = HistoryPanelDrag(startingDepth: depth, panelWidth: 300)
        let expectedDepth = min(max(depth + Int(direction), 0), 3)
        let expectedOffset = CGFloat(expectedDepth - depth) * 300
        XCTAssertEqual(drag.offset(for: direction * 900), expectedOffset)
        XCTAssertEqual(
          drag.targetDepth(translation: direction * 900, velocity: direction * 2000),
          expectedDepth)
      }
    }
  }

  func testRightSwipesFromHostsDoNothing() {
    let drag = HistoryPanelDrag(startingDepth: 3, panelWidth: 390)
    for translation in [CGFloat(0), CGFloat(100), CGFloat(600)] {
      XCTAssertEqual(drag.offset(for: translation), 0)
      for velocity in [CGFloat(0), CGFloat(800), CGFloat(3000)] {
        XCTAssertEqual(drag.targetDepth(translation: translation, velocity: velocity), 3)
      }
    }
  }

  func testFoldersCanRevealHostsAndHostsCanReturnToFolders() {
    let folders = HistoryPanelDrag(startingDepth: 2, panelWidth: 390)
    XCTAssertEqual(folders.targetDepth(translation: 250, velocity: 0), 3)
    let hosts = HistoryPanelDrag(startingDepth: 3, panelWidth: 390)
    XCTAssertEqual(hosts.targetDepth(translation: -900, velocity: -1000), 2)
  }

  func testShortFolderSwipeStaysOnFoldersUnlessFlickedLeft() {
    let drag = HistoryPanelDrag(startingDepth: 2, panelWidth: 390)
    XCTAssertEqual(drag.targetDepth(translation: -30, velocity: 0), 2)
    XCTAssertEqual(drag.targetDepth(translation: -30, velocity: -1000), 1)
  }
}
