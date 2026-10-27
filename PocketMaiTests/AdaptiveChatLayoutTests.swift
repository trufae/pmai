import SwiftUI
import XCTest

@testable import PocketMai

final class AdaptiveChatLayoutTests: XCTestCase {
  func testSidebarRequiresBothRegularSizeClassAndEnoughRoomForChat() {
    XCTAssertFalse(AdaptiveChatLayout(width: 900, isRegularWidth: false).pinsSidebar)
    XCTAssertFalse(AdaptiveChatLayout(width: 600, isRegularWidth: true).pinsSidebar)
    let expanded = AdaptiveChatLayout(width: 800, isRegularWidth: true)
    XCTAssertTrue(expanded.pinsSidebar)
    XCTAssertGreaterThanOrEqual(expanded.chatWidth, 440)
  }

  func testDrawerLeavesRoomToDismissInNarrowMultitaskingWindows() {
    for width in [CGFloat(240), 280, 320, 390, 600] {
      let layout = AdaptiveChatLayout(width: width, isRegularWidth: false)
      XCTAssertGreaterThan(layout.panelWidth, 0)
      XCTAssertGreaterThanOrEqual(width - layout.panelWidth, 44)
      XCTAssertEqual(layout.sidebarInset, 0)
      XCTAssertEqual(layout.chatWidth, width)
    }
  }

  func testSidebarCanCollapseWithoutReducingTheChatWidth() {
    let layout = AdaptiveChatLayout(
      width: 840, isRegularWidth: true, sidebarIsCollapsed: true)
    XCTAssertTrue(layout.canPinSidebar)
    XCTAssertFalse(layout.pinsSidebar)
    XCTAssertEqual(layout.chatWidth, 840)
  }

  func testUnfoldingAndResizingReturnToCompactLayoutWithoutDeviceChecks() {
    let folded = AdaptiveChatLayout(width: 360, isRegularWidth: false)
    let unfolded = AdaptiveChatLayout(width: 840, isRegularWidth: true)
    let splitView = AdaptiveChatLayout(width: 420, isRegularWidth: true)
    XCTAssertFalse(folded.pinsSidebar)
    XCTAssertTrue(unfolded.pinsSidebar)
    XCTAssertFalse(splitView.pinsSidebar)
    XCTAssertEqual(splitView.chatWidth, 420)
    XCTAssertLessThanOrEqual(unfolded.panelWidth, 320)
  }
}
