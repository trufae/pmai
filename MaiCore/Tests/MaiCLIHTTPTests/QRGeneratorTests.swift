import Foundation
import Testing
#if canImport(CoreImage)
  import CoreImage
#endif

@testable import MaiCLI

@Test("Terminal QR encodes arbitrary text and long pairing links without external tools", arguments: [
  "Hello, QR! Bon dia ☀️",
  "pmai-acp://connect/" + String(repeating: "aBcD0123-_", count: 70),
])
func terminalQRRoundTrip(_ text: String) throws {
  var lines: [String] = []
  try QRGenerator.show(text, output: nil) { lines.append($0) }
  let rows = lines.map {
    Array($0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression))
  }
  let columns = try #require(rows.first?.count)
  #expect(columns > 0 && rows.allSatisfy { $0.count == columns })
  #expect(rows.joined().contains { "█▀▄".contains($0) })
  #if canImport(CoreImage)
    let scale = 8
    let width = columns * scale
    let height = rows.count * 2 * scale
    var pixels = [UInt8](repeating: 255, count: width * height)
    for (row, characters) in rows.enumerated() {
      for (column, character) in characters.enumerated() {
        for half in 0...1 {
          if character == "█" || (half == 0 ? character == "▀" : character == "▄") {
            for y in (row * 2 + half) * scale..<(row * 2 + half + 1) * scale {
              for x in column * scale..<(column + 1) * scale { pixels[y * width + x] = 0 }
            }
          }
        }
      }
    }
    let image = CIImage(bitmapData: Data(pixels), bytesPerRow: width,
      size: CGSize(width: width, height: height), format: .L8,
      colorSpace: CGColorSpaceCreateDeviceGray())
    let detector = try #require(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
      options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let decoded = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    #expect(decoded.contains(text))
  #endif
}
