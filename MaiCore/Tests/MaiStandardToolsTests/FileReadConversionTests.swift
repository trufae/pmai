import Foundation
import MaiCore
import MaiStandardTools
import Testing

#if canImport(CoreGraphics)
  import CoreGraphics
  import CoreText
  import ImageIO
#endif

@Suite("Files read conversion")
struct FileReadConversionTests {
  @Test("HTML source remains available and Markdown pages use converted UTF-8 offsets")
  func html() async throws {
    try await withWorkspace { root, read in
      let source = "<html><body><h1>Résumé 🦊</h1><p>Hello <strong>world</strong>.</p></body></html>"
      let file = root.appendingPathComponent("page.HTML")
      try Data(source.utf8).write(to: file)
      for format in [nil, "auto", "text"] as [String?] {
        var arguments: [String: JSONValue] = ["path": .string("page.HTML")]
        arguments["format"] = format.map(JSONValue.string)
        let output = try await call(read, arguments)
        #expect(!output.isError)
        #expect(output.text == source)
      }

      let arguments: [String: JSONValue] = [
        "path": .string("page.HTML"), "format": .string("markdown"),
      ]
      let full = try await call(read, arguments)
      try #require(!full.isError)
      #expect(full.text == "# Résumé 🦊\n\nHello **world**.")
      #expect(
        full.structuredContent?.objectValue?["conversion"]
          == .string("converted from HTML to Markdown"))
      if case .file(let content) = full.content.first {
        #expect(content.name == "page.md")
        #expect(content.mimeType == "text/markdown")
      } else {
        Issue.record("Expected a text file result")
      }
      var offset = 0
      var reconstructed = ""
      repeat {
        var pageArguments = arguments
        pageArguments["offset"] = .integer(offset)
        pageArguments["max_bytes"] = .integer(5)
        let page = try await call(read, pageArguments)
        try #require(!page.isError)
        let metadata = try #require(page.structuredContent?.objectValue)
        let next = try #require(metadata["nextOffset"]?.intValue)
        try #require(next > offset)
        #expect(metadata["totalBytes"] == .integer(full.text.utf8.count))
        #expect(metadata["format"] == .string("markdown"))
        if case .file(let content) = page.content.first {
          reconstructed += content.text ?? ""
        }
        if metadata["truncated"] == .bool(true) {
          #expect(page.text.contains("format \"markdown\", offset \(next)"))
        }
        offset = next
      } while offset < full.text.utf8.count
      #expect(reconstructed == full.text)
      #expect(try Data(contentsOf: file) == Data(source.utf8))
      #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["page.HTML"])
    }
  }

  @Test("Markdown mode detects Word without its extension and preserves ordinary text")
  func documentsAndSource() async throws {
    try await withWorkspace { root, read in
      let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/sample.docx")
      let data = try Data(contentsOf: fixture)
      try data.write(to: root.appendingPathComponent("report.docx"))
      try data.write(to: root.appendingPathComponent("download"))
      let automatic = try await call(read, ["path": .string("report.docx")])
      try #require(!automatic.isError)
      #expect(automatic.text.contains("Fixture Report"))
      for path in ["report.docx", "download"] {
        let output = try await call(read, ["path": .string(path), "format": .string("markdown")])
        #expect(!output.isError)
        #expect(output.text == automatic.text)
        #expect(try Data(contentsOf: root.appendingPathComponent(path)) == data)
      }
      let binary = try await call(
        read, ["path": .string("report.docx"), "format": .string("text")])
      #expect(binary.isError)
      #expect(binary.text.contains("binary"))
      for (name, source) in [
        ("empty.txt", ""), ("notes.txt", "hello\n"), ("config.json", "{\"a\": 1}\n"),
      ] {
        try Data(source.utf8).write(to: root.appendingPathComponent(name))
        let output = try await call(read, ["path": .string(name), "format": .string("markdown")])
        #expect(!output.isError)
        #expect(output.text == source)
      }
      for format in [JSONValue.string("invalid"), .integer(1), .bool(true), .null] {
        let output = try await call(read, ["path": .string("notes.txt"), "format": format])
        #expect(output.isError)
        #expect(output.text.contains("format must be auto, markdown, or text"))
      }
    }
  }

  @Test("OCR returns paginated text and respects file access checks")
  func images() async throws {
    let ocr = FixtureOCR()
    try await withWorkspace(ocr: ocr) { root, read in
      // Valid magic bytes are enough for the injected recognizer; real Vision is tested below.
      let data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
      let file = root.appendingPathComponent("scan.png")
      try data.write(to: file)
      for format in ["auto", "markdown"] {
        let output = try await call(read, ["path": .string("scan.png"), "format": .string(format)])
        #expect(!output.isError)
        #expect(output.text == "# Scan\n\nTotal: 42 🦊")
        #expect(
          output.structuredContent?.objectValue?["conversion"]
            == .string("converted from image to Markdown using OCR"))
      }
      let page = try await call(
        read,
        [
          "path": .string("scan.png"), "format": .string("markdown"),
          "offset": .integer(8), "max_bytes": .integer(9),
        ])
      try #require(!page.isError)
      if case .file(let content) = page.content.first {
        #expect(content.name == "scan.md")
        #expect(content.mimeType == "text/markdown")
        #expect(content.text == "Total: 42")
      } else {
        Issue.record("Expected OCR as text, not an image")
      }
      let requests = await ocr.requests
      #expect(requests.count == 3)
      #expect(
        requests.allSatisfy {
          $0.imageData == data && $0.filename == "scan.png" && $0.mimeType == "image/png"
        })

      let original = try await call(read, ["path": .string("scan.png"), "format": .string("text")])
      #expect(original.isError)
      let outside = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).png")
      try data.write(to: outside)
      defer { try? FileManager.default.removeItem(at: outside) }
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("escape.png"), withDestinationURL: outside)
      let denied = try await call(
        read, ["path": .string("escape.png"), "format": .string("markdown")])
      #expect(denied.isError)
      #expect(denied.text.contains("outside the configured workspace"))
      #expect(await ocr.requests.count == 3)
      #expect(try Data(contentsOf: file) == data)
    }
  }

  @Test("OCR errors remain actionable tool errors")
  func ocrFailure() async throws {
    try await withWorkspace(ocr: UnavailableOCRProvider(reason: "fixture unavailable")) {
      root, read in
      try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(
        to: root.appendingPathComponent("scan.png"))
      let output = try await call(
        read, ["path": .string("scan.png"), "format": .string("markdown")])
      #expect(output.isError)
      #expect(output.text.contains("fixture unavailable"))
    }
  }

  #if canImport(PDFKit) && canImport(Vision)
    @Test(
      "Default Apple converters read a PDF and OCR a PNG without a shell or configured provider")
    func nativeConverters() async throws {
      try await withWorkspace { root, read in
        let size = CGRect(x: 0, y: 0, width: 800, height: 200)
        let bitmap = try #require(
          CGContext(
            data: nil, width: 800, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        drawText(in: bitmap, bounds: size)
        let png = NSMutableData()
        let destination = try #require(
          CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(bitmap.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        try (png as Data).write(to: root.appendingPathComponent("scan.png"))

        let pdf = NSMutableData()
        var mediaBox = size
        let consumer = try #require(CGDataConsumer(data: pdf))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &mediaBox, nil))
        context.beginPDFPage(nil)
        drawText(in: context, bounds: size)
        context.endPDFPage()
        context.closePDF()
        try (pdf as Data).write(to: root.appendingPathComponent("report.pdf"))
        for path in ["scan.png", "report.pdf"] {
          for format in ["auto", "markdown"] {
            let output = try await call(read, ["path": .string(path), "format": .string(format)])
            try #require(!output.isError, "\(output.text)")
            #expect(output.text.contains("Invoice total 42"))
          }
        }
      }
    }

    private func drawText(in context: CGContext, bounds: CGRect) {
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(bounds)
      let text = NSAttributedString(
        string: "Invoice total 42",
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
            "Helvetica" as CFString, 48, nil),
          NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
            gray: 0, alpha: 1),
        ])
      context.textPosition = CGPoint(x: 40, y: 90)
      CTLineDraw(CTLineCreateWithAttributedString(text), context)
    }
  #endif

  private func withWorkspace(
    ocr: (any OCRProvider)? = nil,
    _ body: (URL, MaiFileWorkspaceTool) async throws -> Void
  ) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mai-conversion-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let read = try #require(
      MaiFileWorkspaceTool.makeTools(
        configuration: .init(rootURL: root), ocrProvider: ocr
      ).first { $0.operation == .read })
    #expect(read.definition.parameters.contains { $0.name == "format" && !$0.required })
    try await body(root, read)
  }

  private func call(_ tool: MaiFileWorkspaceTool, _ arguments: [String: JSONValue]) async throws
    -> ToolOutput
  {
    try await tool.call(
      arguments: .object(arguments),
      context: ToolExecutionContext(
        run: AgentEventContext(
          runID: UUID(), parentRunID: nil, agentID: "conversion-test", depth: 0),
        modelTurn: 1))
  }
}

private actor FixtureOCR: OCRProvider {
  nonisolated let descriptor = OCRProviderDescriptor(id: "fixture", displayName: "Fixture OCR")
  private(set) var requests: [OCRRequest] = []

  func recognize(_ request: OCRRequest) async throws -> OCRResult {
    requests.append(request)
    return OCRResult(markdown: "# Scan\n\nTotal: 42 🦊")
  }
}
