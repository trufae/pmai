import Foundation

/// Braille activity effects sampled from monotonic time. Redrawing or skipping
/// a timer callback never changes the animation's speed or phase.
final class BrailleAnimator: @unchecked Sendable {
  enum Style: String, CaseIterable, Sendable {
    case random, circle, snake, spiral, square, topWave, bottomWave, scanline
    case snakeGame = "snakegame"
    case equalizer, plasma, tunnel
  }

  private let style: Style
  private var startedAt = ProcessInfo.processInfo.systemUptime
  private let lock = NSLock()

  /// Procedural effects have an 8×4 dot canvas; classic spinners use one cell.
  var width: Int {
    switch style {
    case .equalizer, .plasma, .tunnel: 4
    default: 1
    }
  }

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
  func start(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
    lock.withLock { startedAt = time }
  }

  /// Returns the frame at this instant without advancing any mutable state.
  func frame(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) -> String {
    lock.withLock {
      let elapsed = max(0, time - startedAt)
      func sample(_ frames: [UInt8]) -> UInt8 {
        frames[Int((elapsed * 5).truncatingRemainder(dividingBy: Double(frames.count)))]
      }
      let dot: UInt8
      switch style {
      case .random:
        // Hash a time slot, so repeated draws of a twinkle are also stable.
        var seed = UInt64(elapsed * 5) &+ 0x9e3779b97f4a7c15
        seed = (seed ^ (seed >> 30)) &* 0xbf58476d1ce4e5b9
        seed = (seed ^ (seed >> 27)) &* 0x94d049bb133111eb
        dot = UInt8(truncatingIfNeeded: seed ^ (seed >> 31))
      case .circle:
        dot = sample(Self.circle)
      case .snake:
        dot = sample(Self.snake)
      case .snakeGame:
        dot = sample(Self.snakeGame)
      case .spiral:
        dot = sample(Self.spiral)
      case .square:
        dot = sample(Self.square)
      case .topWave:
        dot = sample(Self.topWave)
      case .bottomWave:
        dot = sample(Self.bottomWave)
      case .scanline:
        dot = sample(Self.scanline)
      case .equalizer, .plasma, .tunnel:
        return effect(at: elapsed)
      }
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

  // MARK: - Demoscene effects

  private func effect(at time: TimeInterval) -> String {
    var cells = [UInt8](repeating: 0, count: width)
    for x in 0..<(width * 2) {
      let column = Double(x)
      // Synthetic amplifier levels with a shared beat and independent bands.
      let beat = pow(max(0, cos(time * 10 - column * 0.45)), 4)
      let level = 0.5 + 0.5 * sin(time * (3 + column * 0.17) + column * 1.3)
      let height = min(4, 1 + Int(level * 2 + beat * 2))
      for y in 0..<4 {
        let row = Double(y)
        let lit: Bool
        switch style {
        case .equalizer:
          lit = y >= 4 - height
        case .plasma:
          let field = sin(column * 0.9 + time * 2.8) + sin(row * 1.4 - time * 2.1)
            + sin((column + row) * 0.6 + time * 1.3)
          lit = field > 0.25
        case .tunnel:
          let dx = (column - 3.5) * 0.65
          let dy = row - 1.5
          lit = sin(hypot(dx, dy) * 3 - time * 6 + atan2(dy, dx) * 2) > 0.2
        default:
          lit = false
        }
        if lit { cells[x / 2] |= 1 << (y * 2 + x % 2) }
      }
    }
    return cells.map { Self.braille(dot: $0) }.joined()
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

  /// A three-dot snake turns around the grid, advancing its head and tail
  /// by one adjacent dot per frame, including when the animation loops.
  private static let snakeGame: [UInt8] = [
    dots[4] | dots[2] | dots[0],
    dots[2] | dots[0] | dots[1],
    dots[0] | dots[1] | dots[3],
    dots[1] | dots[3] | dots[5],
    dots[3] | dots[5] | dots[7],
    dots[5] | dots[7] | dots[6],
    dots[7] | dots[6] | dots[4],
    dots[6] | dots[4] | dots[2],
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
