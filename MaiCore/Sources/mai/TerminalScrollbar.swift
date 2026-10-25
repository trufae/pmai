import Foundation

/// Geometry shared by painting and hit-testing a one-column scrollbar.
struct TerminalScrollbar: Equatable {
  let height: Int
  let maximum: Int
  let thumb: Range<Int>

  init(rows: Int, top: Int, height: Int) {
    self.height = max(1, height)
    maximum = max(0, rows - self.height)
    let size =
      maximum == 0
      ? self.height
      : min(self.height, max(1, Int(Double(self.height) * Double(self.height) / Double(rows))))
    let travel = self.height - size
    let start =
      maximum == 0
      ? 0
      : Int((Double(min(maximum, max(0, top))) * Double(travel) / Double(maximum)).rounded())
    thumb = start..<(start + size)
  }

  func offset(at row: Int, grab: Int) -> Int {
    let travel = height - thumb.count
    guard travel > 0 else { return 0 }
    let start = min(travel, max(0, row - min(max(0, grab), thumb.count - 1)))
    return Int((Double(start) * Double(maximum) / Double(travel)).rounded())
  }

  func cell(at row: Int) -> String {
    // Background-colored spaces form solid blocks, including in the last column.
    "\u{1B}[\(thumb.contains(row) ? 47 : 100)m \u{1B}[0m"
  }
}
