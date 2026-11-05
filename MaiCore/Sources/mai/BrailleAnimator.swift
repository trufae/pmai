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

  /// Every style shares an 8×4 dot canvas spanning four terminal cells.
  let width = 4

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
      effect(at: max(0, time - startedAt))
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

  // MARK: - Canvas effects

  private func effect(at time: TimeInterval) -> String {
    var cells = [UInt8](repeating: 0, count: width)
    func plot(_ x: Int, _ y: Int) {
      cells[x / 2] |= 1 << (y * 2 + x % 2)
    }
    func head(on path: [Int], speed: Double) -> Int {
      Int((time * speed).truncatingRemainder(dividingBy: Double(path.count)))
    }
    func trail(on path: [Int], head: Int, length: Int) {
      for age in 0..<length {
        let dot = path[(head - age + path.count) % path.count]
        plot(dot % 8, dot / 8)
      }
    }

    switch style {
    case .random:
      // Independent twinkles per cell, stable throughout each time slot.
      for cell in cells.indices {
        var seed = UInt64(time * 5) &+ (UInt64(cell + 1) &* 0x9e3779b97f4a7c15)
        seed = (seed ^ (seed >> 30)) &* 0xbf58476d1ce4e5b9
        seed = (seed ^ (seed >> 27)) &* 0x94d049bb133111eb
        cells[cell] = UInt8(truncatingIfNeeded: seed ^ (seed >> 31))
      }
    case .circle:
      // A long comet and a short satellite orbit the rounded rim.
      let step = head(on: Self.orbit, speed: 10)
      trail(on: Self.orbit, head: step, length: 6)
      trail(on: Self.orbit, head: step + Self.orbit.count / 2, length: 2)
    case .square:
      // Two opposing trails turn sharp corners around the full canvas.
      let step = head(on: Self.perimeter, speed: 10)
      trail(on: Self.perimeter, head: step, length: 6)
      trail(on: Self.perimeter, head: step + Self.perimeter.count / 2, length: 6)
    case .snakeGame:
      // A snake weaves through every row, eating a pellet every eight steps.
      let step = head(on: Self.snakePath, speed: 10)
      trail(on: Self.snakePath, head: step, length: 8)
      let food = Self.snakePath[((step / 8 + 1) * 8) % Self.snakePath.count]
      plot(food % 8, food / 8)
    default:
      for x in 0..<(width * 2) {
        let column = Double(x)
        for y in 0..<4 {
          let row = Double(y)
          let lit: Bool
          switch style {
          case .snake:
            // A continuous ribbon slithers across all eight dot columns.
            let spine = 1.5 + 1.4 * sin(column * 0.75 - time * 4)
            lit = abs(row - spine) < 0.65
          case .spiral:
            let dx = (column - 3.5) * 0.5
            let dy = row - 1.5
            // Two curved arms rotate around the middle of the canvas.
            lit = cos(atan2(dy, dx) * 2 - hypot(dx, dy) * 1.8 + time * 4) > 0.35
          case .topWave, .bottomWave:
            let direction = style == .topWave ? -1.0 : 1.0
            let height = 2 + 1.4 * sin(column * 0.85 + direction * time * 3.5)
            lit = style == .topWave ? row + 0.5 < height : 3.5 - row < height
          case .scanline:
            // A tilted sweeping beam with a stippled glow on adjacent rows.
            let beam = 1.5 + 1.5 * sin(time * 3) + (column - 3.5) * 0.22
            let distance = abs(row - beam)
            lit = distance < 0.55 || (distance < 1.2 && x % 2 == y % 2)
          case .equalizer:
            // Synthetic amplifier levels with a shared beat and independent bands.
            let beat = pow(max(0, cos(time * 10 - column * 0.45)), 4)
            let level = 0.5 + 0.5 * sin(time * (3 + column * 0.17) + column * 1.3)
            let height = min(4, 1 + Int(level * 2 + beat * 2))
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
          if lit { plot(x, y) }
        }
      }
    }
    return cells.map { Self.braille(dot: $0) }.joined()
  }

  // Closed paths use row-major dot indices (y * 8 + x).
  private static let orbit = [
    1, 2, 3, 4, 5, 6, 15, 23, 30, 29, 28, 27, 26, 25, 16, 8,
  ]
  private static let perimeter = [
    0, 1, 2, 3, 4, 5, 6, 7, 15, 23, 31, 30, 29, 28, 27, 26, 25, 24, 16, 8,
  ]
  private static let snakePath = [
    0, 1, 2, 3, 4, 5, 6, 7, 15, 14, 13, 12, 11, 10, 9, 17,
    18, 19, 20, 21, 22, 23, 31, 30, 29, 28, 27, 26, 25, 24, 16, 8,
  ]
}
