#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
import Testing

@testable import MaiCore

@Test("Image attachment modes resize images and preserve their metadata")
func imageAttachmentResize() async throws {
  let original = try pngData(width: 200, height: 100)
  let part = try await ImageAttachmentImporter.content(
    data: original,
    mimeType: "image/png",
    filename: "fixture.png",
    mode: .tiny)

  guard case .image(let image) = part else {
    Issue.record("Expected resized image content")
    return
  }
  #expect(image.mimeType == "image/jpeg")
  #expect(image.name == "fixture.jpg")
  #expect(image.width == 100)
  #expect(image.height == 50)
  guard case .data(let resized) = image.source else {
    Issue.record("Expected inline resized image data")
    return
  }
  #expect(resized != original)
}

@Test("OCR image mode delegates to a separate provider and returns a Markdown file")
func imageAttachmentOCR() async throws {
  let part = try await ImageAttachmentImporter.content(
    data: Data([0x01, 0x02]),
    mimeType: "image/jpeg",
    filename: "receipt.jpg",
    mode: .ocr,
    ocrProvider: FixtureOCRProvider())

  guard case .file(let file) = part else {
    Issue.record("Expected OCR Markdown file content")
    return
  }
  #expect(file.name == "receipt.md")
  #expect(file.mimeType == "text/markdown")
  #expect(file.text == "# Recognized\n\nHello from OCR")

  await #expect(throws: ImageAttachmentImportError.ocrProviderRequired) {
    try await ImageAttachmentImporter.content(
      data: Data([0x01]),
      mimeType: "image/jpeg",
      filename: "missing.jpg",
      mode: .ocr)
  }
}

private struct FixtureOCRProvider: OCRProvider {
  let descriptor = OCRProviderDescriptor(id: "fixture", displayName: "Fixture OCR")

  func recognize(_ request: OCRRequest) async throws -> OCRResult {
    #expect(request.filename == "receipt.jpg")
    #expect(request.mimeType == "image/jpeg")
    return OCRResult(markdown: "# Recognized\n\nHello from OCR")
  }
}

private func pngData(width: Int, height: Int) throws -> Data {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
  context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  let image = try #require(context.makeImage())
  let data = NSMutableData()
  let destination = try #require(
    CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
  CGImageDestinationAddImage(destination, image, nil)
  try #require(CGImageDestinationFinalize(destination))
  return data as Data
}

#endif
