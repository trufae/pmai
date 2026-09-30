// Decode the actual terminal block-character output with Apple's QR detector.
// Usage: swift test/qr-terminal-smoke.swift /path/to/gateway.log
import CoreImage
import Foundation

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let prefix = "\u{1B}[30;47m"
let rows = text.split(separator: "\n").filter { $0.hasPrefix(prefix) }.map {
  Array($0.dropFirst(prefix.count).replacingOccurrences(of: "\u{1B}[0m", with: ""))
}
guard let first = rows.first, rows.allSatisfy({ $0.count == first.count }) else {
  fail("Missing or wrapped terminal QR")
}
let scale = 8
let width = first.count * scale
let height = rows.count * 2 * scale
var pixels = [UInt8](repeating: 255, count: width * height)
for (row, characters) in rows.enumerated() {
  for (column, character) in characters.enumerated() {
    for half in 0...1 {
      let dark = character == "█" || (half == 0 ? character == "▀" : character == "▄")
      if dark {
        for y in (row * 2 + half) * scale..<(row * 2 + half + 1) * scale {
          for x in column * scale..<(column + 1) * scale { pixels[y * width + x] = 0 }
        }
      }
    }
  }
}
let image = CIImage(
  bitmapData: Data(pixels), bytesPerRow: width,
  size: CGSize(width: width, height: height), format: .L8,
  colorSpace: CGColorSpaceCreateDeviceGray())
let detector = CIDetector(
  ofType: CIDetectorTypeQRCode, context: CIContext(),
  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])!
let decoded = detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
let uri = text.split(separator: "\n").first { $0.hasPrefix("pmai-acp://connect/") }.map(String.init)
guard let uri, decoded.contains(uri) else {
  fail("Terminal QR did not decode to the connection URI")
}
print("Terminal QR decodes to the exact gateway connection profile: passed")
