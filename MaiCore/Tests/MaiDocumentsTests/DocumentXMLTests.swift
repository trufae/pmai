import Foundation
import Testing

@testable import MaiDocuments

private final class XMLRecorder: DocumentXMLHandler {
  var events: [String] = []
  var content = ""
  var attributes: [String: String] = [:]

  func startElement(_ name: String, attributes: [String: String]) {
    events.append("+" + name)
    self.attributes.merge(attributes) { _, new in new }
  }

  func endElement(_ name: String) { events.append("-" + name) }
  func text(_ string: String) { content += string }
}

@Test("XML events normalize namespaces, decode references, and preserve CDATA")
func documentXMLEvents() {
  let handler = XMLRecorder()
  let xml =
    #"<w:root xmlns:w="urn:word" xmlns:r="urn:rel" w:val="A&amp;B" r:id="link"><w:empty/>a&amp;&#x20AC;<![CDATA[<literal>]]></w:root>"#
  #expect(DocumentXML.parse(Data(xml.utf8), handler: handler))
  #expect(handler.events == ["+root", "+empty", "-empty", "-root"])
  #expect(handler.attributes["val"] == "A&B")
  #expect(handler.attributes["id"] == "link")
  #expect(handler.content == "a&€<literal>")
}

@Test("XML accepts UTF-8, UTF-16 and UTF-32 with either byte order")
func documentXMLUnicode() throws {
  for encoding in [
    String.Encoding.utf8, .utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian,
  ] {
    let xml = "<?xml version='1.0'?><root>日本 café</root>"
    let data = try #require(xml.data(using: encoding))
    let handler = XMLRecorder()
    #expect(DocumentXML.parse(data, handler: handler))
    #expect(handler.content == "日本 café")
  }
  let handler = XMLRecorder()
  #expect(
    DocumentXML.parse(Data([0xEF, 0xBB, 0xBF]) + Data("<root>ok</root>".utf8), handler: handler))
  #expect(handler.content == "ok")
}

@Test("XML declarations retain legacy character encoding support")
func documentXMLLegacyEncodings() {
  for (encoding, bytes, expected) in [
    ("ISO-8859-1", [UInt8(0xE9)], "é"),
    ("windows-1252", [UInt8(0x80)], "€"),
    ("Shift_JIS", [UInt8(0x93), 0xFA, 0x96, 0x7B], "日本"),
  ] {
    let data =
      Data("<?xml version='1.0' encoding='\(encoding)'?><root>".utf8)
      + Data(bytes) + Data("</root>".utf8)
    let handler = XMLRecorder()
    #expect(DocumentXML.parse(data, handler: handler))
    #expect(handler.content == expected)
  }
}

@Test("XML rejects malformed documents, invalid bytes and unknown encodings")
func documentXMLFailures() {
  for data in [
    Data("<root><child></root>".utf8), Data("<root/><other/>".utf8),
    Data("<root>&missing;</root>".utf8), Data("<root>".utf8) + Data([0xFF]) + Data("</root>".utf8),
    Data("<?xml version='1.0' encoding='unknown-pmai-charset'?><root/>".utf8),
    Data([0xEF, 0xBB, 0xBF])
      + Data("<?xml version='1.0' encoding='unknown-pmai-charset'?><root/>".utf8),
  ] {
    #expect(!DocumentXML.parse(data, handler: XMLRecorder()))
  }
}

@Test("XML never loads external entities")
func documentXMLExternalEntities() {
  let handler = XMLRecorder()
  let xml =
    #"<!DOCTYPE root [<!ENTITY external SYSTEM "file:///pmai-must-not-read">]><root>&external;</root>"#
  DocumentXML.parse(Data(xml.utf8), handler: handler)
  #expect(handler.content.isEmpty)
}

@Test("XHTML entities are normalized after decoding the document")
func documentXMLXHTMLEncoding() throws {
  let data = try #require(
    "<?xml version='1.0' encoding='UTF-16'?><root>café&nbsp;&unknown;</root>".data(using: .utf16))
  let handler = XMLRecorder()
  #expect(DocumentXML.parse(data, handler: handler, htmlEntities: true))
  #expect(handler.content == "café\u{A0}&unknown;")
}
