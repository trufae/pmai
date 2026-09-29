import Foundation
#if canImport(CoreImage)
  import CoreImage
  import ImageIO
#endif

/// Native QR generation on Apple platforms; qrencode provides the same workflow
/// on Linux/Android. The URI is always printed as a copy/paste fallback.
enum TailcatQR {
  static func show(_ text: String, output: URL?) throws {
    #if canImport(CoreImage)
      guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
      filter.setValue(Data(text.utf8), forKey: "inputMessage")
      filter.setValue("L", forKey: "inputCorrectionLevel")
      guard let image = filter.outputImage else { return }
      let context = CIContext()
      let size = Int(image.extent.width)
      var pixels = [UInt8](repeating: 0, count: size * size)
      context.render(image, toBitmap: &pixels, rowBytes: size, bounds: image.extent,
        format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
      func dark(_ x: Int, _ y: Int) -> Bool {
        guard x >= 0, y >= 0, x < size, y < size else { return false }
        return pixels[y * size + x] < 128
      }
      for y in stride(from: -4, to: size + 4, by: 2) {
        var line = "\u{1B}[30;47m"
        for x in -4..<size + 4 {
          switch (dark(x, y), dark(x, y + 1)) {
          case (true, true): line += "█"
          case (true, false): line += "▀"
          case (false, true): line += "▄"
          case (false, false): line += " "
          }
        }
        print(line + "\u{1B}[0m")
      }
      if let output {
        let data: Data
        if output.pathExtension.lowercased() == "svg" {
          var path = ""
          for y in 0..<size {
            for x in 0..<size where dark(x, y) { path += "M\(x+4) \(y+4)h1v1h-1z" }
          }
          data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(size+8) \(size+8)\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"white\"/><path d=\"\(path)\" fill=\"black\"/></svg>".utf8)
        } else {
          let expanded = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
          let bounds = expanded.extent.insetBy(dx: -32, dy: -32)
          let background = CIImage(color: CIColor.white).cropped(to: bounds)
          guard let cg = context.createCGImage(expanded.composited(over: background), from: bounds) else { return }
          let buffer = NSMutableData()
          guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { return }
          CGImageDestinationAddImage(destination, cg, nil)
          guard CGImageDestinationFinalize(destination) else { return }
          data = buffer as Data
        }
        try data.write(to: output, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      }
    #else
      guard let executable = TailcatCLI.resolveExecutable("qrencode") else {
        if output != nil { throw TailcatCLI.Error.message("Install qrencode to export a QR image.") }
        FileHandle.standardError.write(Data("Install qrencode for a terminal QR; the pairing URI works without it.\n".utf8))
        return
      }
      let rendered = try TailcatCLI.capture(executable, ["-t", "UTF8"], input: Data(text.utf8))
      print(rendered)
      if let output {
        _ = try TailcatCLI.capture(executable,
          ["-t", output.pathExtension.lowercased() == "svg" ? "SVG" : "PNG", "-o", output.path],
          input: Data(text.utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
      }
    #endif
  }

  static func read(_ value: String) throws -> String {
    if value.hasPrefix("pmai-tailcat://") { return value }
    let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    if let text = try? String(contentsOf: url, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pmai-tailcat://") {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #if canImport(CoreImage)
      if let image = CIImage(contentsOf: url),
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
        let feature = detector.features(in: image).compactMap({ $0 as? CIQRCodeFeature }).first,
        let text = feature.messageString { return text }
    #endif
    throw TailcatCLI.Error.message("Pass a pairing URI, a text file containing it, or a QR image (Apple platforms).")
  }
}
