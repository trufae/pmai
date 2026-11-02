import UIKit
import XCTest

@testable import PocketMai

final class MarkdownImageTests: XCTestCase {
  private let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="100">
      <rect width="100" height="100" fill="red"/>
      <rect x="100" width="100" height="100" fill="blue"/>
      <text x="10" y="35" font-size="20" fill="black">Hello</text>
    </svg>
    """

  func testEmbeddedImageURLs() throws {
    let encoded = try XCTUnwrap(svg.addingPercentEncoding(withAllowedCharacters: .alphanumerics))
    for source in [
      "data:image/svg+xml;base64," + Data(svg.utf8).base64EncodedString(),
      "data:image/svg+xml;charset=utf-8," + encoded,
    ] {
      let url = try XCTUnwrap(MarkdownImageURL.url(from: source))
      XCTAssertEqual(try MarkdownImageURL.embeddedData(from: url), Data(svg.utf8))
    }
    XCTAssertNotNil(MarkdownImageURL.url(from: "https://example.com/image.svg"))
    XCTAssertNil(MarkdownWebURL.url(from: "data:image/svg+xml;base64,PHN2Zy8+"))
    for source in ["javascript:alert(1)", "file:///tmp/image.svg", "data:text/html,test"] {
      XCTAssertNil(MarkdownImageURL.url(from: source))
    }
    let invalid = try XCTUnwrap(MarkdownImageURL.url(from: "data:image/svg+xml;base64,!!!"))
    XCTAssertThrowsError(try MarkdownImageURL.embeddedData(from: invalid))
  }

  func testSVGCodeBlocksOfferAnImagePreview() throws {
    for language in ["svg", "SVG", "xml", "html", ""] {
      let source = try XCTUnwrap(MarkdownImageURL.svgSource(code: svg, language: language))
      let url = try XCTUnwrap(MarkdownImageURL.url(from: source))
      XCTAssertEqual(try MarkdownImageURL.embeddedData(from: url), Data(svg.utf8))
    }
    XCTAssertNil(MarkdownImageURL.svgSource(code: "<root/>", language: "xml"))
    XCTAssertNil(MarkdownImageURL.svgSource(code: "print(\"<svg>\")", language: "python"))
  }

  @MainActor
  func testSVGPreviewAndPNGExportContainTheImageAtTheSelectedResolution() async throws {
    let source = try XCTUnwrap(MarkdownImageURL.svgSource(code: svg, language: "svg"))
    let url = try XCTUnwrap(MarkdownImageURL.url(from: source))
    let loader = MarkdownRemoteImageLoader()
    await loader.load(url)
    guard case .success(let preview, let data) = loader.phase else {
      return XCTFail("Embedded SVG did not render")
    }
    XCTAssertNotNil(UIImage(data: data))
    assertShapeColors(in: preview)
    for (size, width) in [(AttachmentImageSize.tiny, 100), (.small, 320), (.full, 200)] {
      let png = try await loader.pngData(size: size)
      XCTAssertEqual(Array(png.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
      let image = try XCTUnwrap(UIImage(data: png))
      XCTAssertEqual(image.cgImage?.width, width)
      XCTAssertEqual(image.cgImage?.height, width / 2)
      assertShapeColors(in: image)
    }
  }

  @MainActor
  func testViewBoxOnlySVGAndInvalidSVG() async throws {
    let source = """
      <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 100">
        <rect width="100" height="100" fill="red"/>
        <rect x="100" width="100" height="100" fill="blue"/>
      </svg>
      """
    let image = try await SVGImageRenderer.render(Data(source.utf8), maxDimension: 320)
    XCTAssertEqual(image.cgImage?.width, 320)
    XCTAssertEqual(image.cgImage?.height, 160)
    assertShapeColors(in: image)

    let loader = MarkdownRemoteImageLoader()
    let url = try XCTUnwrap(MarkdownImageURL.url(from: "data:image/svg+xml;base64,bm90IHN2Zw=="))
    await loader.load(url)
    guard case .failure = loader.phase else { return XCTFail("Invalid SVG should fail to decode") }
  }

  private func assertShapeColors(in image: UIImage, file: StaticString = #filePath, line: UInt = #line) {
    var pixels = [UInt8](repeating: 0, count: 8 * 4 * 4)
    let drew = pixels.withUnsafeMutableBytes { bytes -> Bool in
      guard let cgImage = image.cgImage,
        let context = CGContext(
          data: bytes.baseAddress, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 8, height: 4))
      return true
    }
    XCTAssertTrue(drew, file: file, line: line)
    // Sample away from the text to catch blank snapshots as well as stretched or cropped images.
    XCTAssertGreaterThan(pixels[0], 240, file: file, line: line)
    XCTAssertGreaterThan(pixels[3], 240, file: file, line: line)
    XCTAssertGreaterThan(pixels[7 * 4 + 2], 240, file: file, line: line)
    XCTAssertGreaterThan(pixels[7 * 4 + 3], 240, file: file, line: line)
  }
}
