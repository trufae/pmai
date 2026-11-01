import SwiftUI
import XCTest

@testable import PocketMai

final class MarkdownTableLayoutTests: XCTestCase {
  @MainActor
  func testShortColumnsLeaveRoomForWrappedTextAndRowsStayAligned() async throws {
    let cases: [(CGFloat, CGFloat, CGFloat?)] = [
      (320, 17, nil), (390, 17, nil), (320, 24, nil),
      (320, 17, 128), (390, 17, 156),
    ]
    for (width, fontSize, maximumColumnWidth) in cases {
      let ready = expectation(description: "Table cells laid out")
      var frames: [Int: CGRect] = [:]
      let cells = [
        "#", "What's missing", "Where now",
        "10", "SUDO/R2PM_SUDO set to sudo unconditionally", "l.399–406",
      ]
      let content = MarkdownTableLayout(columnCount: 3, maximumColumnWidth: maximumColumnWidth) {
        ForEach(cells.indices, id: \.self) { index in
          Text(cells[index])
            .font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
              GeometryReader { geometry in
                Color.clear.preference(
                  key: TableCellFrames.self,
                  value: [index: geometry.frame(in: .named("table"))])
              }
            }
        }
      }
      .coordinateSpace(name: "table")
      .onPreferenceChange(TableCellFrames.self) { value in
        if frames.isEmpty && value.count == cells.count {
          frames = value
          ready.fulfill()
        }
      }
      .fixedSize(horizontal: maximumColumnWidth != nil, vertical: false)
      .frame(width: width, alignment: .leading)
      let host = UIHostingController(rootView: content)
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
      window.rootViewController = host
      window.isHidden = false
      defer { window.isHidden = true }
      host.view.layoutIfNeeded()
      await fulfillment(of: [ready], timeout: 5)

      let number = try XCTUnwrap(frames[3])
      let description = try XCTUnwrap(frames[4])
      let reference = try XCTUnwrap(frames[5])
      XCTAssertLessThan(number.width, width / 4)
      XCTAssertGreaterThan(description.width, number.width * 2)
      XCTAssertGreaterThan(description.height, try XCTUnwrap(frames[1]).height)
      for column in 0..<3 {
        let header = try XCTUnwrap(frames[column])
        let cell = try XCTUnwrap(frames[column + 3])
        XCTAssertEqual(cell.minX, header.minX, accuracy: 0.5)
        XCTAssertEqual(cell.width, header.width, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(cell.minY, header.maxY - 0.5)
      }
      XCTAssertEqual(number.maxX, description.minX, accuracy: 0.5)
      XCTAssertEqual(description.maxX, reference.minX, accuracy: 0.5)
      XCTAssertLessThanOrEqual(reference.maxX, width + 0.5)
    }
  }
}

private struct TableCellFrames: PreferenceKey {
  static let defaultValue: [Int: CGRect] = [:]

  static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}
