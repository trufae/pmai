#if os(macOS)
  import Foundation
  @preconcurrency import AVFoundation
  @preconcurrency import Speech
  import MaiCore

  @MainActor enum NativeVoiceCatalog {
    private static var recognitionSupport: [String: (date: Date, supported: Bool)] = [:]

    static func catalog(language: String, role: VoiceProviderRole? = nil) -> VoiceProviderCatalog {
      let tag = language.replacingOccurrences(of: "_", with: "-").lowercased()
      let locales = role == .output ? [] : Array(SFSpeechRecognizer.supportedLocales())
      let byTag = locales.contains {
        let id = $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        return id == tag || id.hasPrefix(tag + "-")
      }
      return .init(
        languages: locales.map { locale in
          let id = locale.identifier.replacingOccurrences(of: "_", with: "-")
          let name = Locale.current.localizedString(forIdentifier: id) ?? id
          // Constructing a recognizer logs missing assets. Only inspect the selected
          // language in the background; an explicit catalog request can inspect more.
          let requested = tag.isEmpty || (byTag
            ? id.lowercased() == tag || id.lowercased().hasPrefix(tag + "-")
            : name.lowercased().contains(tag))
          if let cached = recognitionSupport[id], Date().timeIntervalSince(cached.date) > 30 {
            recognitionSupport[id] = nil
          }
          if requested, recognitionSupport[id] == nil {
            recognitionSupport[id] = (Date(), SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true)
          }
          let support = recognitionSupport[id]?.supported
          return .init(id: id, name: name,
            unavailableReason: support == false ? "on-device recognition unavailable" : nil,
            availabilityChecked: support != nil)
        }.sorted { $0.id < $1.id },
        voices: role == .input ? [] : AVSpeechSynthesisVoice.speechVoices().map {
          let quality: String =
            switch $0.quality {
            case .default: "standard"
            case .enhanced: "enhanced"
            case .premium: "premium"
            @unknown default: "system"
            }
          return .init(id: $0.identifier, name: $0.name, language: $0.language, quality: quality)
        }.sorted { ($0.language ?? "", $0.id) < ($1.language ?? "", $1.id) },
        defaultVoice: role == .input ? nil : preferredVoice(language: language)?.identifier)
    }
    static func preferredVoice(language: String) -> AVSpeechSynthesisVoice? {
      let voices = AVSpeechSynthesisVoice.speechVoices()
      let candidates = voices.map { voice -> VoiceCatalogOption in
        .init(
          id: voice.identifier, name: voice.name, language: voice.language,
          quality: voice.quality == .premium
            ? "premium" : voice.quality == .enhanced ? "enhanced" : "standard")
      }
      if let id = preferredVoiceID(language: language, voices: candidates),
        let preferred = voices.first(where: { $0.identifier == id })
      {
        return preferred
      }
      let primary = language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first
      guard candidates.contains(where: { $0.language?.lowercased().split(separator: "-").first == primary }) else {
        return nil
      }
      return AVSpeechSynthesisVoice(language: language)
    }

    static func preferredVoiceID(language: String, voices: [VoiceCatalogOption]) -> String? {
      let language = language.replacingOccurrences(of: "_", with: "-").lowercased()
      let primary = language.split(separator: "-").first
      func quality(_ voice: VoiceCatalogOption) -> Int {
        voice.quality == "premium" ? 2 : voice.quality == "enhanced" ? 1 : 0
      }
      return voices.filter {
        $0.language?.lowercased().split(separator: "-").first == primary && quality($0) > 0
      }.sorted {
        if quality($0) != quality($1) { return quality($0) > quality($1) }
        let exact0 = $0.language?.lowercased() == language
        let exact1 = $1.language?.lowercased() == language
        if exact0 != exact1 { return exact0 }
        return $0.id < $1.id
      }.first?.id
    }
  }

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
      guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: settings.languageIdentifier)),
        recognizer.supportsOnDeviceRecognition else {
        throw VoiceError.unavailable(
          "voice.input=system cannot recognize \(settings.languageIdentifier) on device on this Mac. A speaking voice does not provide recognition. Check macOS Dictation language downloads, choose another /set voice.language, or use /set voice.input command or openai with a configured transcriber.")
      }
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
        SFSpeechRecognizer.requestAuthorization(
          NativeVoiceCallbacks.authorizationReply { continuation.resume(returning: $0) })
      }
      try Task.checkCancellation()
      guard generation == self.generation else { throw CancellationError() }
      guard microphone, authorized else {
        throw VoiceError.unavailable(
          "Allow microphone and Speech Recognition access in macOS Privacy & Security settings.")
      }
      guard recognizer.isAvailable else {
        throw VoiceError.unavailable(
          "Speech recognition for \(settings.languageIdentifier) is currently unavailable. Check macOS Speech Recognition permissions or use command/openai input."
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
      recognition = recognizer.recognitionTask(
        with: request, resultHandler: recognitionCallback(receive: receive))
      let engine = AVAudioEngine()
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        stop()
        throw VoiceError.unavailable("No microphone input is available.")
      }
      input.installTap(
        onBus: 0, bufferSize: 1600, format: format,
        block: NativeVoiceCallbacks.audioTap(request: request, receive: receive))
      self.engine = engine
      engine.prepare()
      do { try engine.start() } catch {
        stop()
        throw error
      }
    }
    /// Speech invokes this handler on its own queue, regardless of the caller's actor.
    func recognitionCallback(receive: @escaping @Sendable (VoiceInputEvent) -> Void)
      -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void
    {
      let generation = generation
      return { [weak self] result, error in
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

  /// Legacy Apple callbacks are not actor-bound. Construct them outside MainActor
  /// and keep their types Sendable so Swift never inserts a main-queue assertion.
  enum NativeVoiceCallbacks {
    static func authorizationReply(_ reply: @escaping @Sendable (Bool) -> Void)
      -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    {
      { status in reply(status == .authorized) }
    }

    static func audioTap(
      request: SFSpeechAudioBufferRecognitionRequest,
      receive: @escaping @Sendable (VoiceInputEvent) -> Void
    )
      -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void
    {
      { buffer, _ in
        request.append(buffer)
        guard let samples = buffer.floatChannelData else { return }
        var peak = 0.0
        for frame in 0..<Int(buffer.frameLength) {
          peak = max(peak, abs(Double(samples[0][frame])))
        }
        receive(.level(peak))
      }
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
    static func selectedVoice(_ settings: ConfiguredVoice) throws -> AVSpeechSynthesisVoice {
      let voice =
        settings.voice == "default"
        ? NativeVoiceCatalog.preferredVoice(language: settings.languageIdentifier)
        : AVSpeechSynthesisVoice(identifier: settings.voice)
      guard let voice else {
        throw VoiceError.unavailable(
          settings.voice == "default"
            ? "No installed macOS speech voice for \(settings.languageIdentifier). Use /voice voices or install a voice in System Settings → Accessibility → Read & Speak (Spoken Content)."
            : "Unknown macOS voice ID '\(settings.voice)'. Use /voice voices for IDs; set the language with /set voice.language TAG.")
      }
      return voice
    }
    func utterance(_ text: String) throws -> AVSpeechUtterance {
      let utterance = AVSpeechUtterance(string: text)
      utterance.voice = try Self.selectedVoice(settings)
      utterance.rate = min(
        AVSpeechUtteranceMaximumSpeechRate,
        max(
          AVSpeechUtteranceMinimumSpeechRate,
          AVSpeechUtteranceDefaultSpeechRate * Float(settings.speed)))
      return utterance
    }
    func speak(_ text: String) async throws {
      try Task.checkCancellation()
      let utterance = try utterance(text)
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
