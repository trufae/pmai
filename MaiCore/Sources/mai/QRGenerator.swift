import Foundation
import QRCodeGenerator
#if canImport(CoreImage)
  import CoreImage
  import ImageIO
#endif

enum QRGenerator {
  static func show(_ text: String, output: URL?, write: (String) -> Void = { print($0) }) throws {
    let qr = try QRCode.encode(text: text, ecl: .low)
    let size = qr.size
    for y in stride(from: -4, to: size + 4, by: 2) {
      var line = "\u{1B}[30;47m"
      for x in -4..<size + 4 {
        switch (qr.getModule(x: x, y: y), qr.getModule(x: x, y: y + 1)) {
        case (true, true): line += "█"
        case (true, false): line += "▀"
        case (false, true): line += "▄"
        case (false, false): line += " "
        }
      }
      // Some terminals retain a line's last background colour through the
      // unused cells to its right. Reset first, then erase that tail using
      // the terminal's normal background so the QR stays square.
      write(line + "\u{1B}[0m\u{1B}[K")
    }
    guard let output else { return }
    if output.pathExtension.lowercased() == "svg" {
      try Data(qr.toSVGString(border: 4).utf8).write(to: output, options: .atomic)
    } else {
      #if canImport(CoreImage)
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return }
        let context = CIContext()
        let expanded = image.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let bounds = expanded.extent.insetBy(dx: -32, dy: -32)
        let background = CIImage(color: CIColor.white).cropped(to: bounds)
        guard let cg = context.createCGImage(expanded.composited(over: background), from: bounds) else { return }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { return }
        try (buffer as Data).write(to: output, options: .atomic)
      #else
        guard let executable = TailcatCLI.resolveExecutable("qrencode") else {
          throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedDescriptionKey: "Install qrencode to export PNG, or use an .svg output file.",
          ])
        }
        _ = try TailcatCLI.capture(executable, ["-t", "PNG", "-o", output.path], input: Data(text.utf8))
      #endif
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
  }

  static func readImage(at url: URL) -> String? {
    #if canImport(CoreImage)
      if let image = CIImage(contentsOf: url),
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(),
          options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]),
        let feature = detector.features(in: image).compactMap({ $0 as? CIQRCodeFeature }).first {
        return feature.messageString
      }
    #endif
    return nil
  }
}
