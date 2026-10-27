import Foundation

#if canImport(CoreFoundation)
  import CoreFoundation
#endif

#if canImport(SAXParser)
  import SAXParser
  import XMLCore
#elseif canImport(FoundationXML)
  import FoundationXML
#endif

// Both backends deliver local element and attribute names.
protocol DocumentXMLHandler: AnyObject {
  func startElement(_ name: String, attributes: [String: String])
  func endElement(_ name: String)
  func text(_ string: String)
}

extension DocumentXMLHandler {
  func startElement(_ name: String, attributes: [String: String]) {}
  func endElement(_ name: String) {}
  func text(_ string: String) {}
}

enum DocumentXML {
  @discardableResult
  static func parse(_ data: Data, handler: any DocumentXMLHandler, htmlEntities: Bool = false)
    -> Bool
  {
    guard let text = decoded(data) else { return false }
    let input = htmlEntities ? XHTMLEntities.normalized(text) : text
    #if canImport(SAXParser)
      let bytes = Array(input.utf8)
      var parser = SAXParser(handler: SwiftXMLHandler(handler: handler))
      do {
        try parser.parse(bytes: bytes.span)
        return true
      } catch {
        return false
      }
    #else
      return FoundationXMLHandler(handler: handler).parse(Data(input.utf8))
    #endif
  }

  private static let encodingPattern = try! NSRegularExpression(
    pattern: #"\bencoding\s*=\s*(["'])([A-Za-z][A-Za-z0-9._-]*)\1"#)

  private static func declarationEncoding(_ text: String) -> NSTextCheckingResult? {
    guard text.hasPrefix("<?xml"), text.dropFirst(5).first?.isWhitespace == true,
      let end = text.range(of: "?>")
    else { return nil }
    return encodingPattern.firstMatch(
      in: text, range: NSRange(text.startIndex..<end.lowerBound, in: text))
  }

  private static func stringEncoding(_ name: Substring) -> String.Encoding? {
    #if canImport(CoreFoundation)
      let name = CFStringCreateWithCString(nil, String(name), CFStringBuiltInEncodings.UTF8.rawValue)
      let identifier = CFStringConvertIANACharSetNameToEncoding(name)
      guard identifier != kCFStringEncodingInvalidId else { return nil }
      return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(identifier))
    #else
      switch name.lowercased().replacingOccurrences(of: "_", with: "-") {
      case "utf-8", "utf8": return .utf8
      case "utf-16", "utf16": return .utf16
      case "utf-16be": return .utf16BigEndian
      case "utf-16le": return .utf16LittleEndian
      case "utf-32", "utf32": return .utf32
      case "utf-32be": return .utf32BigEndian
      case "utf-32le": return .utf32LittleEndian
      case "us-ascii", "ascii": return .ascii
      case "iso-8859-1", "latin1": return .isoLatin1
      case "iso-8859-2", "latin2": return .isoLatin2
      case "windows-1250": return .windowsCP1250
      case "windows-1251": return .windowsCP1251
      case "windows-1252": return .windowsCP1252
      case "windows-1253": return .windowsCP1253
      case "windows-1254": return .windowsCP1254
      case "shift-jis", "sjis": return .shiftJIS
      case "euc-jp": return .japaneseEUC
      case "iso-2022-jp": return .iso2022JP
      case "macintosh": return .macOSRoman
      default: return nil
      }
    #endif
  }

  private static func decoded(_ data: Data) -> String? {
    let prefix = Array(data.prefix(4))
    var encoding: String.Encoding = .utf8
    if prefix.starts(with: [0, 0, 0xFE, 0xFF]) || prefix == [0, 0, 0, 0x3C] {
      encoding = .utf32BigEndian
    } else if prefix.starts(with: [0xFF, 0xFE, 0, 0]) || prefix == [0x3C, 0, 0, 0] {
      encoding = .utf32LittleEndian
    } else if prefix.starts(with: [0xFE, 0xFF]) || prefix.starts(with: [0, 0x3C, 0, 0x3F]) {
      encoding = .utf16BigEndian
    } else if prefix.starts(with: [0xFF, 0xFE]) || prefix.starts(with: [0x3C, 0, 0x3F, 0]) {
      encoding = .utf16LittleEndian
    } else {
      let bytes = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
      if bytes.starts(with: Array("<?xml".utf8)), let end = bytes.range(of: Data("?>".utf8)) {
        let header = String(decoding: bytes[..<end.upperBound], as: UTF8.self)
        if let match = declarationEncoding(header),
          let range = Range(match.range(at: 2), in: header)
        {
          guard let declared = stringEncoding(header[range]) else { return nil }
          encoding = declared
        }
      }
    }
    guard var text = String(data: data, encoding: encoding) else { return nil }
    if text.first == "\u{FEFF}" { text.removeFirst() }
    if let match = declarationEncoding(text), let range = Range(match.range(at: 2), in: text) {
      guard stringEncoding(text[range]) != nil else { return nil }
      text.replaceSubrange(range, with: "UTF-8")
    }
    return text
  }
}

#if canImport(SAXParser)
  extension Span where Element == XML.Byte {
    fileprivate var string: String {
      withUnsafeBufferPointer { String(decoding: $0, as: UTF8.self) }
    }
  }

  private struct SwiftXMLHandler: Handler {
    let handler: any DocumentXMLHandler

    func start(
      element name: XML.QualifiedNameView, namespace: Span<XML.Byte>?,
      attributes: XML.ResolvedAttributes
    ) {
      var values: [String: String] = [:]
      for index in attributes.indices {
        let name = attributes.name(at: index)
        let key = name.local.string
        if values[key] == nil || name.prefix == nil {
          values[key] = attributes.value(at: index).string
        }
      }
      handler.startElement(name.local.string, attributes: values)
    }

    func end(element name: XML.QualifiedNameView, namespace: Span<XML.Byte>?) {
      handler.endElement(name.local.string)
    }

    func characters(_ data: Span<XML.Byte>) { handler.text(data.string) }
    func character(data: Span<XML.Byte>) { handler.text(data.string) }
  }
#else
  private final class FoundationXMLHandler: NSObject, XMLParserDelegate {
    let handler: any DocumentXMLHandler

    init(handler: any DocumentXMLHandler) { self.handler = handler }

    func parse(_ data: Data) -> Bool {
      let parser = XMLParser(data: data)
      parser.shouldResolveExternalEntities = false
      parser.delegate = self
      return parser.parse()
    }

    func parser(
      _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
      qualifiedName: String?, attributes: [String: String]
    ) {
      var values: [String: String] = [:]
      for (name, value) in attributes {
        let key = localName(name)
        if values[key] == nil || key == name { values[key] = value }
      }
      handler.startElement(localName(elementName), attributes: values)
    }

    func parser(
      _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
      qualifiedName: String?
    ) {
      handler.endElement(localName(elementName))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { handler.text(string) }
    func parser(_ parser: XMLParser, foundCDATA data: Data) {
      handler.text(String(decoding: data, as: UTF8.self))
    }

    private func localName(_ name: String) -> String {
      String(name.split(separator: ":", maxSplits: 1).last ?? "")
    }
  }
#endif
