import Foundation
import Testing

@testable import MaiCore

@Test("Reasoning tags survive every chunk boundary and preserve intervening answers")
func reasoningStreamChunkBoundaries() {
  let text = "<think>first</think>answer<think>second</think>done"
  let expected: [ContentPart] = [
    .reasoning("first"), .text("answer"), .reasoning("second"), .text("done"),
  ]
  for split in 0...text.count {
    var stream = ReasoningStream()
    _ = stream.append(String(text.prefix(split)))
    _ = stream.append(String(text.dropFirst(split)))
    _ = stream.flush()
    #expect(stream.parts == expected)
  }
  var stream = ReasoningStream()
  for character in text { _ = stream.append(String(character)) }
  _ = stream.flush()
  #expect(stream.parts == expected)
}

@Test("Native and inline reasoning share ordered parts without eating code or incomplete tags")
func reasoningMixedSources() {
  var stream = ReasoningStream()
  _ = stream.appendReasoning("first")
  _ = stream.append("answer")
  _ = stream.appendReasoning("second")
  _ = stream.append("```xml\n<think>literal</think>\n```\npartial <thi")
  _ = stream.flush()
  #expect(
    stream.parts == [
      .reasoning("first"), .text("answer"), .reasoning("second"),
      .text("```xml\n<think>literal</think>\n```\npartial <thi"),
    ])
  let text = ReasoningText.render(stream.parts)
  #expect(text.hasPrefix("<think>\nfirst\n</think>\n\nanswer\n\n<think>\nsecond"))
  #expect(text.hasSuffix("partial <thi"))
  #expect(MessageContentFilter.render(text).hiddenSections.filter { $0.tag == "think" }.count == 2)
  var literal = ReasoningStream()
  _ = literal.append("Write `<think>` and `</think>` literally.")
  _ = literal.flush()
  #expect(literal.parts == [.text("Write `<think>` and `</think>` literally.")])
  var emptyNative = ReasoningStream()
  _ = emptyNative.append("<think>first<thi")
  #expect(emptyNative.appendReasoning("").isEmpty)
  _ = emptyNative.append("nk>second</think>answer")
  _ = emptyNative.flush()
  #expect(emptyNative.parts == [.reasoning("firstsecond"), .text("answer")])
  var next = ReasoningStream()
  _ = next.append("fresh answer")
  #expect(next.parts == [.text("fresh answer")])
}

@Test("Thinking previews are bounded, strip controls and wrap using frontend cell widths")
func thinkingPreviewRows() {
  var preview = ThinkingPreview()
  preview.append(String(repeating: "old", count: 1000))
  preview.append("\nnew\nnewest")
  #expect(preview.text.count == ThinkingPreview.capacity)
  #expect(ThinkingPreview.lines(preview.text, count: 1, width: 80) == ["newest"])
  #expect(ThinkingPreview.lines("a\nb\nc\nd", count: 3, width: 80) == ["b", "c", "d"])
  #expect(ThinkingDisplay.five.lineCount == 5)
  #expect(
    ThinkingPreview.lines("a\nb\nc\nd\ne\nf", count: ThinkingDisplay.five.lineCount, width: 80)
      == ["b", "c", "d", "e", "f"])
  #expect(ThinkingPreview.lines("abcdef", count: 3, width: 2) == ["ab", "cd", "ef"])
  #expect(
    ThinkingPreview.lines("界界a", count: 3, width: 3, measure: { $0 == "界" ? 2 : 1 }) == ["界", "界a"])
  #expect(!ThinkingPreview.lines("x\u{1B}[2Jy", count: 1, width: 80).joined().contains("\u{1B}"))
}

@Test("Terminal thinking carousels flatten whitespace and slide by characters")
func thinkingCarouselRows() {
  #expect(
    ThinkingPreview.carouselLines("one\n\n two\r\nthree\tfour", count: 1, width: 40)
      == ["one two three four"])
  #expect(ThinkingPreview.carouselLines("abcdefgh", count: 1, width: 5) == ["defgh"])
  #expect(ThinkingPreview.carouselLines("abcdef", count: 3, width: 4) == ["abcd", "ef"])
  #expect(
    ThinkingPreview.carouselLines("abcdefghijklm", count: 3, width: 4)
      == ["bcde", "fghi", "jklm"])
  #expect(
    ThinkingPreview.carouselLines("abcdefghijklmnop", count: 5, width: 3)
      == ["bcd", "efg", "hij", "klm", "nop"])
  #expect(ThinkingPreview.carouselLines("abc", count: 0, width: 5).isEmpty)
  #expect(ThinkingPreview.carouselLines("abc", count: 1, width: 0).isEmpty)

  let measure: (String) -> Int = { $0 == "界" || $0 == "🙂" ? 2 : $0.count }
  #expect(
    ThinkingPreview.carouselLines("ab界e\u{301}🙂", count: 1, width: 5, measure: measure)
      == ["界e\u{301}🙂"])
  #expect(ThinkingPreview.carouselLines("界🙂", count: 1, width: 1, measure: measure) == [" "])
  #expect(
    !ThinkingPreview.carouselLines("x\u{1B}[2Jy\u{7}", count: 1, width: 40)
      .joined().unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })

  let text = "one\r\n\n two\tthree 界e\u{301}🙂 four"
  let expected = ThinkingPreview.carouselLines(text, count: 3, width: 5, measure: measure)
  for split in 0...text.count {
    var preview = ThinkingPreview()
    preview.append(String(text.prefix(split)))
    preview.append(String(text.dropFirst(split)))
    #expect(
      ThinkingPreview.carouselLines(preview.text, count: 3, width: 5, measure: measure)
        == expected)
  }
}

@Test("Gemma thought channels normalize across every chunk boundary")
func reasoningGemmaChannels() {
  let text = "<|channel>thought\nconsider<channel|>answer"
  for split in 0...text.count {
    var stream = ReasoningStream()
    _ = stream.append(String(text.prefix(split)))
    _ = stream.append(String(text.dropFirst(split)))
    _ = stream.flush()
    #expect(stream.parts == [.reasoning("consider"), .text("answer")])
  }
}
