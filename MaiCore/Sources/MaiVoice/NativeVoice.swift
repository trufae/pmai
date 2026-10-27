#if os(macOS)
  import Foundation
  @preconcurrency import AVFoundation
  @preconcurrency import Speech
  import MaiCore

  @MainActor final class NativeVoiceInput: VoiceInputProvider {
    let settings: ConfiguredVoice
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognizer: SFSpeechRecognizer?
    private var recognition: SFSpeechRecognitionTask?
    private var latest = ""
    private var final = false
    private var failure: String?
    private var generation = UUID()

    init(settings: ConfiguredVoice) { self.settings = settings }
    func start(receive: @escaping @Sendable (VoiceInputEvent) -> Void) async throws {
      stop()
      let generation = self.generation
      // A CLI built outside SwiftPM must also carry these usage descriptions.
      guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
        Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
      else {
        throw VoiceError.unavailable(
          "This executable lacks microphone/speech privacy descriptions. Rebuild pmai with SwiftPM, or select command voice providers."
        )
      }
      let microphone = await AVCaptureDevice.requestAccess(for: .audio)
      let authorized = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization {
          continuation.resume(returning: $0 == .authorized)
        }
      }
      try Task.checkCancellation()
      guard generation == self.generation else { throw CancellationError() }
      guard microphone, authorized else {
        throw VoiceError.unavailable(
          "Allow microphone and Speech Recognition access in macOS Privacy & Security settings.")
      }
      guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.language)),
        recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
      else {
        throw VoiceError.unavailable(
          "No installed on-device speech recognizer for \(settings.language). Install that language or select command/openai input."
        )
      }
      self.recognizer = recognizer
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      request.addsPunctuation = true
      self.request = request
      latest = ""
      final = false
      failure = nil
      recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString
        let final = result?.isFinal ?? false
        let failure = error?.localizedDescription
        Task { @MainActor in
          guard let self, generation == self.generation else { return }
          if let text {
            self.latest = text
            receive(.transcript(text))
          }
          self.final = final
          if let failure {
            self.failure = failure
            receive(.failure(failure))
          } else if final {
            receive(.ended)
          }
        }
      }
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        stop()
        throw VoiceError.unavailable("No microphone input is available.")
      }
      input.installTap(onBus: 0, bufferSize: 1600, format: format) { buffer, _ in
        request.append(buffer)
        guard let samples = buffer.floatChannelData else { return }
        var peak = 0.0
        for frame in 0..<Int(buffer.frameLength) {
          peak = max(peak, abs(Double(samples[0][frame])))
        }
        receive(.level(peak))
      }
      self.engine = engine
      engine.prepare()
      do { try engine.start() } catch {
        stop()
        throw error
      }
    }
    func finish() async throws -> String {
      let generation = generation
      engine?.inputNode.removeTap(onBus: 0)
      engine?.stop()
      engine = nil
      request?.endAudio()
      // Final recognition may arrive after the audio tap closes; retain the best partial on timeout.
      for _ in 0..<30 {
        if final || failure != nil { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      guard generation == self.generation else { throw CancellationError() }
      let text = latest
      let failure = failure
      stop()
      if text.isEmpty, let failure { throw VoiceError.unavailable(failure) }
      return text
    }
    func stop() {
      generation = UUID()
      engine?.inputNode.removeTap(onBus: 0)
      engine?.stop()
      engine = nil
      recognition?.cancel()
      recognition = nil
      recognizer = nil
      request?.endAudio()
      request = nil
    }
  }

  @MainActor
  final class NativeVoiceOutput: NSObject, VoiceOutputProvider, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let settings: ConfiguredVoice
    private var pending: CheckedContinuation<Void, Error>?
    private var utteranceID: ObjectIdentifier?
    init(settings: ConfiguredVoice) {
      self.settings = settings
      super.init()
      synthesizer.delegate = self
    }
    func speak(_ text: String) async throws {
      try Task.checkCancellation()
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice =
        settings.voice == "default"
        ? AVSpeechSynthesisVoice(
          language: settings.language.replacingOccurrences(of: "_", with: "-"))
        : AVSpeechSynthesisVoice(identifier: settings.voice)
          ?? AVSpeechSynthesisVoice(language: settings.voice)
      let id = ObjectIdentifier(utterance)
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          pending = continuation
          utteranceID = ObjectIdentifier(utterance)
          synthesizer.speak(utterance)
        }
      } onCancel: {
        Task { @MainActor in if self.utteranceID == id { self.stop() } }
      }
    }
    func stop() {
      let continuation = pending
      pending = nil
      utteranceID = nil
      synthesizer.stopSpeaking(at: .immediate)
      continuation?.resume(throwing: CancellationError())
    }
    nonisolated func speechSynthesizer(
      _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
      let id = ObjectIdentifier(utterance)
      Task { @MainActor in
        guard self.utteranceID == id else { return }
        let continuation = self.pending
        self.pending = nil
        self.utteranceID = nil
        continuation?.resume()
      }
    }
    nonisolated func speechSynthesizer(
      _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
      let id = ObjectIdentifier(utterance)
      Task { @MainActor in
        guard self.utteranceID == id else { return }
        let continuation = self.pending
        self.pending = nil
        self.utteranceID = nil
        continuation?.resume(throwing: CancellationError())
      }
    }
  }
#endif
