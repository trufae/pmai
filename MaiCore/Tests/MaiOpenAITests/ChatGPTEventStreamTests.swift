import Foundation
import Testing

@testable import MaiOpenAI

struct ChatGPTEventStreamTests {
  @Test(arguments: ["\n", "\r\n", "\r"])
  func preservesEventBoundariesAndMultilineData(newline: String) throws {
    var parser = ChatGPTEventStream()
    let input = [
      "\u{FEFF}: heartbeat", "", "event: ignored", "id: 42", "retry: 1000", "",
      "data: {", "data:   \"text\": \"Hello 👋 café\u{2028}world\"", "data: }", "",
      "data: [DONE]", "", "",
    ].joined(separator: newline)
    var events: [String] = []
    // Feed individual bytes, including split UTF-8 scalars and CRLF pairs.
    for byte in input.utf8 {
      if let event = try parser.consume(byte) { events.append(event) }
    }
    #expect(events == ["{\n  \"text\": \"Hello 👋 café\u{2028}world\"\n}", "[DONE]"])
    #expect(try parser.finish() == nil)
  }

  @Test(arguments: ["", "\n", "\r\n", "\r"])
  func flushesFinalEventWithoutBlankDelimiter(ending: String) throws {
    var parser = ChatGPTEventStream()
    for byte in ("data:{\"type\":\"response.completed\"}" + ending).utf8 {
      #expect(try parser.consume(byte) == nil)
    }
    #expect(try parser.finish() == #"{"type":"response.completed"}"#)
    #expect(try parser.finish() == nil)
  }

  @Test func rejectsInvalidUTF8() throws {
    var parser = ChatGPTEventStream()
    for byte in Array("data: ".utf8) + [0xFF] { _ = try parser.consume(byte) }
    #expect(throws: ChatGPTError.self) { try parser.consume(10) }
  }
}
