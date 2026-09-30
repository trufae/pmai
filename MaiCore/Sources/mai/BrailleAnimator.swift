import Foundation

/// A tiny Braille spinner that runs through patterns on a 2×4 dot grid.
///
/// Callers create an animator with a style, then ask for `next()` on a timer
/// to get the single Braille character that should be shown. The styles are
/// built from the 8 dot positions and are easy to extend.
final class BrailleAnimator: @unchecked Sendable {
  enum Style: String, CaseIterable, Sendable {
    case random, circle, snake, spiral, square, topWave, bottomWave, scanline
  }

  private let style: Style
  private var index: Int = 0
  private var randomPattern: UInt8 = 0
  private let lock = NSLock()

  init(style: Style) {
    self.style = style
  }

  /// Picks a style by name. `.random` selects a concrete random style each time.
  convenience init?(named name: String) {
    let lower = name.lowercased()
    if lower == Style.random.rawValue {
      self.init(style: .random)
      return
    }
    guard let style = Style(rawValue: lower), style != .random else { return nil }
    self.init(style: style)
  }

  /// Returns a new animator using a random concrete style.
  static func randomStyle() -> BrailleAnimator {
    let concrete = Style.allCases.filter { $0 != .random }
    return BrailleAnimator(style: concrete.randomElement()!)
  }

  /// Starts (or restarts) the animation from its first frame.
  func start() {
    lock.withLock {
      index = 0
      randomPattern = 0
    }
  }

  /// Advances one frame and returns the Braille character to draw.
  func next() -> String {
    lock.withLock {
      let dot: UInt8
      switch style {
      case .random:
        dot = nextRandom()
      case .circle:
        dot = Self.circle[index % Self.circle.count]
      case .snake:
        dot = Self.snake[index % Self.snake.count]
      case .spiral:
        dot = Self.spiral[index % Self.spiral.count]
      case .square:
        dot = Self.square[index % Self.square.count]
      case .topWave:
        dot = Self.topWave[index % Self.topWave.count]
      case .bottomWave:
        dot = Self.bottomWave[index % Self.bottomWave.count]
      case .scanline:
        dot = Self.scanline[index % Self.scanline.count]
      }
      index += 1
      return Self.braille(dot: dot)
    }
  }

  static var styleNames: [String] { Style.allCases.map { $0.rawValue } }

  // MARK: - Braille encoding

  /// Unicode Braille patterns start at U+2800 with dots ordered 1,2,3,4,5,6,7,8.
  /// The user-facing grid is:
  ///
  ///     0 1
  ///     2 3
  ///     4 5
  ///     6 7
  private static func braille(dot: UInt8) -> String {
    let base = UnicodeScalar(0x2800)
    let offset =
      ((dot & 0x01) >> 0) |  // our 0 -> dot 1 (bit 0)
      ((dot & 0x02) << 2) |  // our 1 -> dot 4 (bit 3)
      ((dot & 0x04) >> 1) |  // our 2 -> dot 2 (bit 1)
      ((dot & 0x08) << 1) |  // our 3 -> dot 5 (bit 4)
      ((dot & 0x10) >> 2) |  // our 4 -> dot 3 (bit 2)
      ((dot & 0x20) >> 0) |  // our 5 -> dot 6 (bit 5)
      ((dot & 0x40) >> 0) |  // our 6 -> dot 7 (bit 6)
      ((dot & 0x80) >> 0)    // our 7 -> dot 8 (bit 7)
    return String(UnicodeScalar(base!.value + UInt32(offset))!)
  }

  // MARK: - Dot indices

  /// The 2×4 grid positions as bit masks.
  ///
  ///     0 1
  ///     2 3
  ///     4 5
  ///     6 7
  private static let dots: [UInt8] = (0..<8).map { 1 << $0 }

  // MARK: - Random

  private func nextRandom() -> UInt8 {
    var pattern = randomPattern
    // Turn off a few dots and turn on a few dots so it twinkles.
    for _ in 0..<3 {
      pattern ^= (1 << Int.random(in: 0..<8))
    }
    randomPattern = pattern
    return pattern
  }

  // MARK: - Circle

  /// Traces the outer rim clockwise around the 2×4 rectangle.
  private static let circle: [UInt8] = [
    dots[0], dots[1], dots[3], dots[5], dots[7], dots[6], dots[4], dots[2],
  ]

  // MARK: - Snake

  /// Slides left-to-right on the top pair, then right-to-left on the next,
  /// weaving down through all four rows.
  private static let snake: [UInt8] = [
    dots[0], dots[1], dots[3], dots[2], dots[4], dots[5], dots[7], dots[6],
  ]

  // MARK: - Spiral

  /// Winds around the outside, then shrinks inward to the center pair.
  private static let spiral: [UInt8] = [
    dots[0], dots[1], dots[3], dots[5], dots[7], dots[6], dots[4], dots[2],
    dots[0] | dots[1], dots[3] | dots[5], dots[7] | dots[6], dots[4] | dots[2],
    dots[2], dots[3],
  ]

  // MARK: - Square

  /// Lights each side of the rectangle in turn, including the horizontal
  /// middle rows so all four rows are active.
  private static let square: [UInt8] = [
    dots[0] | dots[2] | dots[4] | dots[6],  // left edge
    dots[6] | dots[7],                      // bottom edge
    dots[1] | dots[3] | dots[5] | dots[7],  // right edge
    dots[0] | dots[1],                      // top edge
    dots[2] | dots[3],                      // middle-left
    dots[4] | dots[5],                      // middle-right
  ]

  // MARK: - Top wave / bottom wave

  /// The upper six dots (top three rows) fade on, then off.
  private static let topWave: [UInt8] = [
    dots[0] | dots[2] | dots[4],  // left column, rows 0-2
    dots[1] | dots[3] | dots[5],  // right column, rows 0-2
    dots[0] | dots[1] | dots[2] | dots[3] | dots[4] | dots[5],  // full 3×2 block
    dots[0] | dots[2] | dots[4],  // left column, rows 0-2
    dots[1] | dots[3] | dots[5],  // right column, rows 0-2
    0,                             // blank beat
  ]

  /// The lower six dots (bottom three rows) fade on, then off.
  private static let bottomWave: [UInt8] = [
    dots[2] | dots[4] | dots[6],  // left column, rows 1-3
    dots[3] | dots[5] | dots[7],  // right column, rows 1-3
    dots[2] | dots[3] | dots[4] | dots[5] | dots[6] | dots[7],  // full bottom 3×2 block
    dots[2] | dots[4] | dots[6],  // left column, rows 1-3
    dots[3] | dots[5] | dots[7],  // right column, rows 1-3
    0,                             // blank beat
  ]

  // MARK: - Scanline

  /// A three-dot-high horizontal bar that moves from the top row to the
  /// bottom row and back, filling the whole 2×4 cell.
  private static let scanline: [UInt8] = [
    dots[0] | dots[1],              // row 0
    dots[0] | dots[1] | dots[2] | dots[3],  // rows 0-1
    dots[2] | dots[3] | dots[4] | dots[5],  // rows 1-2
    dots[4] | dots[5] | dots[6] | dots[7],  // rows 2-3
    dots[6] | dots[7],              // row 3
    dots[4] | dots[5] | dots[6] | dots[7],  // rows 2-3
    dots[2] | dots[3] | dots[4] | dots[5],  // rows 1-2
    dots[0] | dots[1] | dots[2] | dots[3],  // rows 0-1
  ]
}
