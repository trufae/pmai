import Foundation
import ImageIO
import MaiCore
import MaiDocuments
import UniformTypeIdentifiers

struct MacAttachment: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let symbol: String
  let content: ContentPart

  static func load(_ url: URL, allowsLocalReferences: Bool) throws -> Self {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let name = url.lastPathComponent
    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
      guard allowsLocalReferences else { throw ImportError.localReference }
      return Self(name: name, symbol: "folder", content: .text("Attached folder on this Mac: \(url.path)"))
    }
    let data = try DocumentAttachmentImporter.data(at: url)
    if DocumentAttachmentImporter.kind(for: data, filename: name) == .image {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 2048,
        ] as CFDictionary) else { throw ImportError.invalidImage }
      let encoded = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
        throw ImportError.invalidImage
      }
      CGImageDestinationAddImage(destination, thumbnail, nil)
      guard CGImageDestinationFinalize(destination), encoded.length <= 10 * 1024 * 1024 else {
        throw ImportError.invalidImage
      }
      return Self(name: name, symbol: "photo", content: .image(.init(
        source: .data(encoded as Data), mimeType: "image/png", name: name,
        width: thumbnail.width, height: thumbnail.height)))
    }
    do {
      let document = try DocumentAttachmentImporter.attachment(data: data, filename: name)
      return Self(name: name, symbol: "doc", content: document.content)
    } catch DocumentImportError.binaryFile {
      guard allowsLocalReferences else { throw ImportError.localReference }
      return Self(name: name, symbol: "doc", content: .text("Attached file on this Mac: \(url.path)"))
    }
  }

  enum ImportError: LocalizedError {
    case invalidImage, localReference
    var errorDescription: String? {
      switch self {
      case .invalidImage: "The image could not be prepared. Choose a supported image of at most 10 MB after resizing."
      case .localReference: "Folders and binary file references require a local chat. Text, documents, and images can be sent to a remote host."
      }
    }
  }
}
