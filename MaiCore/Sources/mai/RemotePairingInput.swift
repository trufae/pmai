import Foundation
import MaiACP

enum RemotePairingInput {
  static func read(_ value: String) throws -> String {
    if value.hasPrefix("pmai-tailcat://") || value.hasPrefix("pmai-acp://")
      || (try? OpenCodePairingLink.parse(value)) != nil { return value }
    let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
    if let text = try? String(contentsOf: url, encoding: .utf8),
      (text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pmai-tailcat://")
        || text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("pmai-acp://")
        || (try? OpenCodePairingLink.parse(text)) != nil) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let text = QRGenerator.readImage(at: url) { return text }
    throw JSONRPCError.invalidParams("Pass a pairing URI, a text file containing it, or a QR image (Apple platforms).")
  }
}
