import Foundation
import MaiCore

#if os(macOS) || os(Linux) || os(Android) || os(Windows)
  /// OCR backed by a locally installed `tesseract` command line tool. This is
  /// the portable fallback for hosts without Apple's Vision framework, and it
  /// only fails when an image is actually recognized, so a missing binary never
  /// prevents the host from starting.
  public struct TesseractOCRProvider: OCRProvider {
    public static let factoryKind = "tesseract"
    public static let defaultCommand = "tesseract"

    public let descriptor: OCRProviderDescriptor
    public let command: String
    public let languages: String?
    public let searchPath: [String]

    public init(
      id: String = TesseractOCRProvider.factoryKind,
      command: String = TesseractOCRProvider.defaultCommand,
      languages: String? = nil,
      searchPath: [String]? = nil
    ) {
      self.descriptor = OCRProviderDescriptor(id: id, displayName: "Tesseract OCR")
      self.command = command
      self.languages = languages
      self.searchPath = searchPath ?? LocalExecutable.searchPath()
    }

    /// The absolute path of the tesseract executable, or nil when it is not
    /// installed. Hosts can use this to describe OCR availability up front.
    public var executablePath: String? {
      try? LocalExecutable.resolve(command, searchPath: searchPath)
    }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
      guard let executable = executablePath else {
        throw OCRProviderError.recognitionFailed(
          "'\(command)' was not found in PATH. Install tesseract-ocr to enable OCR.")
      }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("pmai-ocr-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let input = directory.appendingPathComponent(
        "image." + Self.fileExtension(mimeType: request.mimeType, filename: request.filename))
      try request.imageData.write(to: input)

      var arguments = [input.path, "stdout"]
      if let languages, !languages.isEmpty {
        arguments += ["-l", languages]
      }
      let output = try await Task.detached(priority: .userInitiated) {
        try Self.run(executable: executable, arguments: arguments)
      }.value
      let lines = output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }
      let markdown = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
      guard !markdown.isEmpty else { throw OCRProviderError.noText }
      return OCRResult(markdown: markdown)
    }

    private static func run(executable: String, arguments: [String]) throws -> String {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: executable)
      process.arguments = arguments
      let output = Pipe()
      let errors = Pipe()
      process.standardInput = FileHandle.nullDevice
      process.standardOutput = output
      process.standardError = errors
      do {
        try process.run()
      } catch {
        throw OCRProviderError.recognitionFailed(error.localizedDescription)
      }
      let stdout = output.fileHandleForReading.readDataToEndOfFile()
      let stderr = errors.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        let message = String(decoding: stderr, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        throw OCRProviderError.recognitionFailed(
          message.isEmpty
            ? "\(executable) exited with status \(process.terminationStatus)."
            : message)
      }
      return String(decoding: stdout, as: UTF8.self)
    }

    private static func fileExtension(mimeType: String, filename: String) -> String {
      switch mimeType.lowercased() {
      case "image/png": return "png"
      case "image/gif": return "gif"
      case "image/webp": return "webp"
      case "image/tiff": return "tiff"
      case "image/bmp": return "bmp"
      case "image/jpeg", "image/jpg": return "jpg"
      default:
        let existing = (filename as NSString).pathExtension
        return existing.isEmpty ? "png" : existing
      }
    }
  }

  public struct TesseractConfiguredOCRProviderFactory: ConfiguredOCRProviderFactory {
    public let kind = TesseractOCRProvider.factoryKind

    public init() {}

    public func makeOCRProvider(context: PluginFactoryContext) throws -> any OCRProvider {
      let environment = LocalProcess.mergedEnvironment(context.environment)
      let command =
        context.options["command"]?.stringValue
        ?? environment["TESSERACT_COMMAND"]
        ?? TesseractOCRProvider.defaultCommand
      let languages =
        context.options["languages"]?.stringValue
        ?? context.options["language"]?.stringValue
        ?? environment["TESSERACT_LANGUAGES"]
      let searchPath = LocalExecutable.searchPath(in: environment)
      return TesseractOCRProvider(
        id: context.id,
        command: command.isEmpty ? TesseractOCRProvider.defaultCommand : command,
        languages: languages,
        searchPath: searchPath)
    }
  }
#endif
