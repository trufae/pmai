import Foundation

#if canImport(AVFoundation)
  @preconcurrency import AVFoundation
  @preconcurrency import Speech

  /// Device voices are rendered to audio buffers, without playing on the host.
  @MainActor
  public enum SystemSpeech {
    public static var voices: [String] {
      AVSpeechSynthesisVoice.speechVoices().map(\.identifier).sorted()
    }

    public static func synthesize(
      input: String, voice: String, format: String = "wav",
      speed: Double = 1
    ) async throws -> AudioAPIResponse {
      guard !input.isEmpty, input.count <= 4096, ["wav", "pcm"].contains(format),
        speed.isFinite, (0.25...4).contains(speed)
      else {
        throw AudioAPIError.invalidRequest(
          "System speech accepts 1–4096 characters, WAV or PCM, and speed 0.25–4.")
      }
      let selected =
        voice == "default"
        ? nil
        : AVSpeechSynthesisVoice(identifier: voice)
          ?? AVSpeechSynthesisVoice(language: voice)
      if voice != "default", selected == nil {
        throw AudioAPIError.invalidRequest(
          "Unknown system voice. Get available identifiers from /v1/voices.")
      }
      let owner = SpeechSynthesizerOwner()
      let utterance = AVSpeechUtterance(string: input)
      utterance.voice = selected
      utterance.rate = min(
        AVSpeechUtteranceMaximumSpeechRate,
        max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed)))
      let resampler = SpeechPCMEncoder()
      let bytes = AsyncThrowingStream<Data, Error> { continuation in
        owner.synthesizer.write(utterance) { buffer in
          guard let pcm = buffer as? AVAudioPCMBuffer else { return }
          if pcm.frameLength == 0 {
            continuation.finish()
            return
          }
          do {
            let data = try resampler.encode(pcm)
            if !data.isEmpty { continuation.yield(data) }
          } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in
          Task { @MainActor in owner.synthesizer.stopSpeaking(at: .immediate) }
        }
      }
      if format == "pcm" {
        return AudioAPIResponse(contentType: "application/octet-stream", stream: bytes)
      }
      var pcm = Data()
      for try await chunk in bytes { pcm.append(chunk) }
      guard !pcm.isEmpty else {
        throw AudioAPIError.invalidRequest("The system voice produced no audio.")
      }
      return AudioAPIResponse(contentType: "audio/wav", body: wave(pcm))
    }

    /// OpenAI PCM is signed 16-bit little-endian mono at 24 kHz.
    nonisolated public static func wave(_ pcm: Data) -> Data {
      var data = Data("RIFF".utf8)
      func number<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
      }
      number(UInt32(pcm.count + 36))
      data.append(Data("WAVEfmt ".utf8))
      number(UInt32(16))
      number(UInt16(1))
      number(UInt16(1))
      number(UInt32(24000))
      number(UInt32(48000))
      number(UInt16(2))
      number(UInt16(16))
      data.append(Data("data".utf8))
      number(UInt32(pcm.count))
      data.append(pcm)
      return data
    }

    /// The CLI's Apple Speech backend requires an installed on-device recognizer.
    /// iOS hosts use their existing AudioTranscriptionService and privacy policy.
    public static func transcribe(file: URL, language: String?) async throws -> String {
      let status = await withCheckedContinuation { continuation in
        SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
      }
      guard status == .authorized,
        let recognizer = SFSpeechRecognizer(
          locale: language.map(Locale.init(identifier:)) ?? .current),
        recognizer.isAvailable, recognizer.supportsOnDeviceRecognition
      else {
        throw AudioAPIError.invalidRequest(
          "Allow Speech Recognition access and install an on-device language, or choose a provider model."
        )
      }
      let state = SpeechRecognitionState()
      return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          state.install(continuation)
          let request = SFSpeechURLRecognitionRequest(url: file)
          request.requiresOnDeviceRecognition = true
          state.keep(
            recognizer.recognitionTask(with: request) { result, error in
              if let error {
                state.finish(.failure(error))
              } else if let result, result.isFinal {
                state.finish(.success(result.bestTranscription.formattedString))
              }
            })
        }
      } onCancel: {
        state.finish(.failure(CancellationError()))
      }
    }
  }

  @MainActor
  private final class SpeechSynthesizerOwner {
    let synthesizer = AVSpeechSynthesizer()
  }

  private final class SpeechRecognitionState: @unchecked Sendable {
    let lock = NSLock()
    var task: SFSpeechRecognitionTask?
    var continuation: CheckedContinuation<String, Error>?
    var result: Result<String, Error>?
    func install(_ continuation: CheckedContinuation<String, Error>) {
      let result = lock.withLock {
        self.continuation = continuation
        return self.result
      }
      if let result { continuation.resume(with: result) }
    }
    func keep(_ task: SFSpeechRecognitionTask) {
      let finished = lock.withLock {
        self.task = task
        return result != nil
      }
      if finished { task.cancel() }
    }
    func finish(_ result: Result<String, Error>) {
      let pending: (CheckedContinuation<String, Error>?, SFSpeechRecognitionTask?)? = lock.withLock
      {
        guard self.result == nil else { return nil }
        self.result = result
        let pending = (continuation, task)
        continuation = nil
        task = nil
        return pending
      }
      pending?.0?.resume(with: result)
      pending?.1?.cancel()
    }
  }

  private final class SpeechPCMEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Float] = []
    private var position = 0.0
    func encode(_ buffer: AVAudioPCMBuffer) throws -> Data {
      try lock.withLock {
        let channels = Int(buffer.format.channelCount)
        guard channels > 0, buffer.format.sampleRate > 0, let floats = buffer.floatChannelData
        else {
          throw AudioAPIError.invalidRequest(
            "The system voice returned an unsupported audio format.")
        }
        for frame in 0..<Int(buffer.frameLength) {
          var sample: Float = 0
          for channel in 0..<channels {
            sample +=
              buffer.format.isInterleaved
              ? floats[0][frame * channels + channel] : floats[channel][frame]
          }
          pending.append(sample / Float(channels))
        }
        var data = Data()
        let step = buffer.format.sampleRate / 24000
        while Int(position) + 1 < pending.count {
          let i = Int(position)
          let fraction = Float(position - Double(i))
          let sample = pending[i] + (pending[i + 1] - pending[i]) * fraction
          var value = Int16(max(-32768, min(32767, sample * 32767))).littleEndian
          withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
          position += step
        }
        let consumed = min(Int(position), max(0, pending.count - 1))
        pending.removeFirst(consumed)
        position -= Double(consumed)
        return data
      }
    }
  }
#endif
