import AVFoundation
import Foundation
import Speech
import UniformTypeIdentifiers

@MainActor
final class SpeechTranscriptionPolicy {
  var allowsServerRecognition = false {
    didSet {
      guard !allowsServerRecognition else { return }
      let cancellations = serverRequests.values
      serverRequests.removeAll()
      for cancel in cancellations { cancel() }
    }
  }
  private var serverRequests: [UUID: () -> Void] = [:]

  func registerServerRequest(cancel: @escaping () -> Void) throws -> UUID {
    guard allowsServerRecognition else {
      throw AudioTranscriptionService.TranscriptionError.serverRecognitionDisabled
    }
    let id = UUID()
    serverRequests[id] = cancel
    return id
  }

  func removeServerRequest(_ id: UUID) {
    serverRequests[id] = nil
  }
}

/// Shared by recorded voice turns, Files imports and shared voice messages.
enum AudioTranscriptionService {
  enum TranscriptionError: LocalizedError, Equatable {
    case permissionDenied
    case recognizerUnavailable(String)
    case onDeviceUnavailable(String)
    case serverRecognitionDisabled
    case unsupportedFormat(String)
    case noSpeech(String)

    var errorDescription: String? {
      switch self {
      case .permissionDenied:
        "PocketMai needs Speech Recognition access to transcribe this audio. "
          + "Enable it in Settings > Privacy > Speech Recognition."
      case .recognizerUnavailable(let language):
        "Speech recognition is not available for \(language)."
      case .onDeviceUnavailable(let language):
        "On-device transcription is not available for \(language). Choose a language installed on this device."
      case .serverRecognitionDisabled:
        "Apple server transcription is disabled. Use an installed on-device language."
      case .unsupportedFormat(let name):
        "\(name) is in an audio format this device cannot decode."
      case .noSpeech(let name):
        "No speech could be recognized in \(name)."
      }
    }
  }

  /// Recognises the speech in `fileURL` and returns the transcript.
  @MainActor
  static func transcribe(
    fileURL: URL, localeIdentifier: String, policy: SpeechTranscriptionPolicy
  ) async throws -> String {
    try Task.checkCancellation()
    let identifier = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    let locale = identifier.isEmpty ? Locale.current : Locale(identifier: identifier)
    let name = fileURL.lastPathComponent
    let prepared = try await decodableURL(for: fileURL)
    defer {
      if prepared != fileURL { try? FileManager.default.removeItem(at: prepared) }
    }

    if #available(iOS 26.0, *) {
      do {
        if let transcript = try await transcribeOnDevice(prepared, locale: locale) {
          return transcript
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // An installed legacy recognizer may still support this language or file.
      }
    }
    try Task.checkCancellation()
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      throw TranscriptionError.recognizerUnavailable(locale.identifier)
    }
    guard recognizer.supportsOnDeviceRecognition || policy.allowsServerRecognition else {
      throw TranscriptionError.onDeviceUnavailable(locale.identifier)
    }
    guard await requestAuthorization() == .authorized else {
      throw TranscriptionError.permissionDenied
    }

    if recognizer.supportsOnDeviceRecognition {
      do {
        let transcript = try await recognize(
          prepared, with: recognizer, onDevice: true, policy: policy)
        return try recognizedText(transcript, name: name)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard policy.allowsServerRecognition else { throw error }
      }
    }
    let transcript = try await recognize(
      prepared, with: recognizer, onDevice: false, policy: policy)
    return try recognizedText(transcript, name: name)
  }

  private static func recognizedText(_ transcript: String, name: String) throws -> String {
    let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw TranscriptionError.noSpeech(name) }
    return text
  }

  @available(iOS 26.0, *)
  private static func transcribeOnDevice(_ url: URL, locale: Locale) async throws -> String? {
    guard SpeechTranscriber.isAvailable,
      let locale = await SpeechTranscriber.supportedLocale(equivalentTo: locale),
      await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == locale.identifier })
    else { return nil }
    try Task.checkCancellation()
    let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let file = try AVAudioFile(forReading: url)
    return try await withTaskCancellationHandler {
      async let transcript = transcriber.results.reduce("") { $0 + String($1.text.characters) }
      do {
        if let lastSample = try await analyzer.analyzeSequence(from: file) {
          try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
          await analyzer.cancelAndFinishNow()
        }
        let text = try await transcript
        try Task.checkCancellation()
        return try recognizedText(text, name: url.lastPathComponent)
      } catch {
        await analyzer.cancelAndFinishNow()
        throw error
      }
    } onCancel: {
      Task { await analyzer.cancelAndFinishNow() }
    }
  }

  // MARK: - Permission

  private static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
    let status = SFSpeechRecognizer.authorizationStatus()
    guard status == .notDetermined else { return status }
    return await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
  }

  // MARK: - Formats

  /// What a voice message arrives as, for the picker to offer and the importer
  /// to route. Opus and Ogg are not always registered as audio types, so the
  /// file name is read before the system's own answer — that is exactly how
  /// WhatsApp and Telegram voice messages travel. The share extension keeps its
  /// own copy of this list: it runs in a target this service is not part of.
  static let audioExtensions: Set<String> = [
    "opus", "ogg", "oga", "m4a", "mp3", "wav", "wave", "caf", "aac", "aif", "aiff", "aifc",
    "amr", "flac", "mp4a", "mpga", "3gp", "3gpp", "wma",
  ]

  static func isAudioFile(_ url: URL) -> Bool {
    if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
      type.conforms(to: .audio)
    {
      return true
    }
    let ext = url.pathExtension.lowercased()
    if audioExtensions.contains(ext) { return true }
    return UTType(filenameExtension: ext)?.conforms(to: .audio) == true
  }

  /// The types the document picker offers so a recording can be picked there.
  static var pickerContentTypes: [UTType] {
    pickerContentTypes { UTType(filenameExtension: $0) }
  }

  static func pickerContentTypes(resolvingExtension: (String) -> UTType?) -> [UTType] {
    // Extension lookup can return an alias or a dynamic type depending on the
    // device's type registry. Always offer the canonical recording types too.
    var types: [UTType] = [.audio, .mp3, .mpeg4Audio]
    for ext in audioExtensions.sorted() {
      guard let type = resolvingExtension(ext), !types.contains(type) else { continue }
      types.append(type)
    }
    return types
  }

  /// Copies a picked file somewhere the recogniser can read it later: the
  /// picker's access to the original ends as soon as the import call returns.
  static func stagedCopy(of url: URL) throws -> URL {
    let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
    let destination = temporaryURL(extension: ext)
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
  }

  /// Returns a URL the recogniser can read: the file itself when AVFoundation
  /// decodes it, otherwise a temporary PCM copy decoded from Ogg Opus.
  private static func decodableURL(for url: URL) async throws -> URL {
    if await hasAudioTrack(url) { return url }

    let name = url.lastPathComponent
    guard let oggData = try? Data(contentsOf: url, options: [.mappedIfSafe]),
      let caf = OggOpusRemuxer.cafData(from: oggData)
    else {
      throw TranscriptionError.unsupportedFormat(name)
    }

    let cafURL = temporaryURL(extension: "caf")
    defer { try? FileManager.default.removeItem(at: cafURL) }
    do {
      try caf.write(to: cafURL, options: .atomic)
      // The recogniser is far happier with plain PCM than with a repackaged
      // Opus stream, and decoding here also proves the audio is readable.
      return try decodedWAV(from: cafURL)
    } catch {
      throw TranscriptionError.unsupportedFormat(name)
    }
  }

  private static func hasAudioTrack(_ url: URL) async -> Bool {
    let asset = AVURLAsset(url: url)
    guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return false }
    return !tracks.isEmpty
  }

  private static func decodedWAV(from url: URL) throws -> URL {
    let input = try AVAudioFile(forReading: url)
    let format = input.processingFormat
    let outputURL = temporaryURL(extension: "wav")
    let output = try AVAudioFile(
      forWriting: outputURL,
      settings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
      throw TranscriptionError.unsupportedFormat(url.lastPathComponent)
    }
    while true {
      try input.read(into: buffer)
      guard buffer.frameLength > 0 else { break }
      try output.write(from: buffer)
    }
    return outputURL
  }

  private static func temporaryURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("PocketMaiSharedAudio-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)
  }

  // MARK: - Recognition

  @MainActor
  private static func recognize(
    _ url: URL,
    with recognizer: SFSpeechRecognizer,
    onDevice: Bool,
    policy: SpeechTranscriptionPolicy
  ) async throws -> String {
    try Task.checkCancellation()
    // Apple only honors requiresOnDeviceRecognition when this capability is true.
    if onDevice && !recognizer.supportsOnDeviceRecognition {
      throw TranscriptionError.onDeviceUnavailable(recognizer.locale.identifier)
    }
    let box = TranscriptionContinuationBox()
    let serverRequestID: UUID?
    if onDevice {
      serverRequestID = nil
    } else {
      serverRequestID = try policy.registerServerRequest {
        box.finish(.failure(TranscriptionError.serverRecognitionDisabled))
      }
    }
    defer {
      if let serverRequestID { policy.removeServerRequest(serverRequestID) }
    }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        guard box.install(continuation) else { return }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = onDevice
        let completion: @Sendable (SFSpeechRecognitionResult?, Error?) -> Void = { result, error in
          if let error {
            box.finish(.failure(error))
          } else if let result, result.isFinal {
            box.finish(.success(result.bestTranscription.formattedString))
          }
        }
        let task = recognizer.recognitionTask(with: request, resultHandler: completion)
        box.keep(task)
      }
    } onCancel: {
      box.finish(.failure(CancellationError()))
    }
  }
}

/// Cancellation and Speech callbacks may arrive before setup or after completion.
final class TranscriptionContinuationBox: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<String, Error>?
  private var continuation: CheckedContinuation<String, Error>?
  private var task: SFSpeechRecognitionTask?

  func install(_ continuation: CheckedContinuation<String, Error>) -> Bool {
    lock.lock()
    if let result {
      lock.unlock()
      continuation.resume(with: result)
      return false
    }
    self.continuation = continuation
    lock.unlock()
    return true
  }

  func keep(_ task: SFSpeechRecognitionTask) {
    lock.lock()
    if result != nil {
      lock.unlock()
      task.cancel()
      return
    }
    self.task = task
    lock.unlock()
  }

  func finish(_ result: Result<String, Error>) {
    lock.lock()
    guard self.result == nil else {
      lock.unlock()
      return
    }
    self.result = result
    let continuation = self.continuation
    self.continuation = nil
    let task = self.task
    self.task = nil
    lock.unlock()
    task?.cancel()
    continuation?.resume(with: result)
  }
}
