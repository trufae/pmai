import Testing

@testable import MaiCLI

// Extra redraws and delayed callbacks must not speed up or slow down the
// visible activity indicator. Use fixed times, without scheduler assumptions.
@Test("Braille animation follows elapsed time independently of redraws")
func brailleAnimationTime() {
  for style in BrailleAnimator.Style.allCases {
    let busy = BrailleAnimator(style: style)
    let sparse = BrailleAnimator(style: style)
    busy.start(at: 100)
    sparse.start(at: 100)
    var frames = Set<String>()
    for instant in [100.0, 100.05, 100.21, 100.87, 101.4] {
      let frame = busy.frame(at: instant)
      frames.insert(frame)
      #expect(busy.frame(at: instant) == frame)
    }
    #expect(frames.count > 1)
    #expect(busy.frame(at: 103.75) == sparse.frame(at: 103.75))
    let first = sparse.frame(at: 100)
    busy.start(at: 200)
    #expect(busy.frame(at: 200) == first)
    #expect(busy.frame(at: 203.75) == sparse.frame(at: 103.75))
  }
}

// Switching styles must not shift the status text or overwrite its cells.
@Test("Activity effects always occupy four terminal cells")
func brailleAnimationBounds() {
  for style in BrailleAnimator.Style.allCases {
    let animator = BrailleAnimator(style: style)
    animator.start(at: 0)
    #expect(animator.width == 4)
    for instant in [0.0, 0.1, 0.5, 1.0, 3.75, 3600.0] {
      let frame = animator.frame(at: instant)
      #expect(TerminalScreen.displayWidth(frame) == 4)
      #expect(frame.unicodeScalars.allSatisfy { (0x2800...0x28ff).contains($0.value) })
    }
  }
}
