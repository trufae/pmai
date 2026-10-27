import Foundation
import MaiCore

/// Audio owns no terminal input. Hosts deliver recognized turns through their normal event loop.
@MainActor public final class VoiceSession {
  public enum State: String, Sendable {
    case off, paused, listening, transcribing, thinking, speaking, error
  }
  public private(set) var state: State = .off
  public private(set) var mode: VoiceCaptureMode
  public private(set) var transcript = ""
  public private(set) var error: String?
  private let settings: ConfiguredVoice
  private let input: any VoiceInputProvider
  private let output: any VoiceOutputProvider
  private let changed: @Sendable (String?) -> Void
  private let submit: @Sendable (String) -> Void
  private var captureTask: Task<Void, Never>?
  private var timer: Task<Void, Never>?
  private var playback: Task<Void, Never>?
  private var generation = UUID()
  private var captureGeneration = UUID()
  private var sentences = VoiceSentenceBuffer()
  private var queue: [String] = []
  private var modelFinished = true
  private var modelHasText = false
  private var enabled = false
  private var paused = false
  private var heardSpeech = false
  private var lastSound = ContinuousClock.now
  private var recordingStarted = ContinuousClock.now
  private var level = 0.0
  private var frame = 0

  public init(
    settings: ConfiguredVoice, input: any VoiceInputProvider,
    output: any VoiceOutputProvider, changed: @escaping @Sendable (String?) -> Void,
    submit: @escaping @Sendable (String) -> Void
  ) {
    self.settings = settings
    self.mode = settings.mode
    self.input = input
    self.output = output
    self.changed = changed
    self.submit = submit
  }

  public func start() {
    enabled = true
    paused = false
    record()
  }

  public func record() {
    guard enabled, modelFinished else { return }
    paused = false
    playback?.cancel()
    playback = nil
    output.stop()
    queue = []
    captureTask?.cancel()
    timer?.cancel()
    input.stop()
    transcript = ""
    error = nil
    heardSpeech = false
    level = 0
    generation = UUID()
    captureGeneration = UUID()
    let generation = generation
    let capture = captureGeneration
    recordingStarted = .now
    lastSound = .now
    state = .listening
    notify()
    captureTask = Task { [self] in
      do {
        try await input.start { [weak self] event in
          Task { @MainActor in self?.receive(event, generation: capture) }
        }
        guard generation == self.generation, !Task.isCancelled else { return }
        timer = Task { [weak self] in
          while !Task.isCancelled {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            guard let self, self.state == .listening, generation == self.generation else { return }
            self.frame += 1
            self.notify()
            if self.recordingStarted.duration(to: .now)
              >= .seconds(self.settings.maximumRecordingSeconds)
              || (self.mode == .realtime && self.heardSpeech
                && self.lastSound.duration(to: .now) >= .seconds(self.settings.silenceSeconds))
            {
              self.send()
              return
            }
          }
        }
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        fail(error)
      }
    }
  }

  private func receive(_ event: VoiceInputEvent, generation: UUID) {
    guard generation == captureGeneration, state == .listening else { return }
    switch event {
    case .level(let level):
      self.level = level
      if level >= settings.speechThreshold {
        heardSpeech = true
        lastSound = .now
      }
    case .transcript(let text):
      if text != transcript {
        heardSpeech = true
        lastSound = .now
      }
      transcript = text
    case .ended: send()
    case .failure(let message): fail(VoiceError.unavailable(message))
    }
  }

  public func send() {
    guard state == .listening else { return }
    timer?.cancel()
    timer = nil
    captureGeneration = UUID()
    state = .transcribing
    notify()
    let generation = generation
    captureTask = Task {
      do {
        let text = try await input.finish().trimmingCharacters(in: .whitespacesAndNewlines)
        try Task.checkCancellation()
        guard generation == self.generation else { return }
        guard !text.isEmpty else {
          ready()
          return
        }
        transcript = text
        state = .thinking
        modelFinished = false
        sentences = VoiceSentenceBuffer()
        notify()
        submit(text)
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        fail(error)
      }
    }
  }

  /// Includes replies to typed turns in the voice agent's tab.
  public func beginReply() {
    guard enabled else { return }
    timer?.cancel()
    input.stop()
    captureTask?.cancel()
    captureGeneration = UUID()
    modelFinished = false
    modelHasText = false
    sentences = VoiceSentenceBuffer()
    state = .thinking
    notify()
  }
  public func consume(_ event: AgentEvent) {
    guard enabled, !paused else { return }
    switch event {
    case .modelStarted: modelHasText = false
    case .provider(_, .textDelta(let delta)):
      modelHasText = true
      enqueue(sentences.append(delta))
    case .toolStarted: enqueue(sentences.finish())
    case .finished(_, let result) where !modelHasText:
      enqueue(sentences.append(result.response.text))
    default: break
    }
  }
  public func finishReply(error: String? = nil) {
    guard enabled else { return }
    if let error {
      fail(VoiceError.unavailable(error))
      return
    }
    enqueue(sentences.finish())
    modelFinished = true
    if playback == nil { ready() }
  }

  private func enqueue(_ text: [String]) {
    guard !paused else { return }
    queue += text
    guard playback == nil, !queue.isEmpty else { return }
    let generation = generation
    playback = Task {
      do {
        while !queue.isEmpty {
          try Task.checkCancellation()
          guard generation == self.generation else { return }
          state = .speaking
          notify()
          let text = queue.removeFirst()
          try await output.speak(text)
        }
        guard generation == self.generation else { return }
        playback = nil
        if modelFinished {
          ready()
        } else {
          state = .thinking
          notify()
        }
      } catch {
        guard generation == self.generation, !Task.isCancelled else { return }
        playback = nil
        fail(error)
      }
    }
  }
  private func ready() {
    guard enabled else { return }
    if mode == .realtime && !paused {
      record()
    } else {
      state = .paused
      notify()
    }
  }
  public func pause() {
    paused = true
    generation = UUID()
    captureGeneration = UUID()
    captureTask?.cancel()
    timer?.cancel()
    playback?.cancel()
    playback = nil
    input.stop()
    output.stop()
    queue = []
    state = .paused
    notify()
  }
  public func stop() {
    enabled = false
    pause()
    state = .off
    changed(nil)
  }
  private func fail(_ error: Error) {
    pause()
    self.error = error.localizedDescription
    state = .error
    notify()
  }
  private func notify() {
    guard enabled else { return }
    let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][frame % 10]
    let meter = String(repeating: "⣿", count: min(8, max(0, Int(level * 80))))
    let icon: String =
      switch state {
      case .listening: "● \(spinner)"
      case .speaking: "◉"
      case .paused: "Ⅱ"
      case .thinking, .transcribing: spinner
      case .error: "⊗"
      case .off: "○"
      }
    let detail = state == .error ? error ?? "" : state == .listening ? "\(meter) \(transcript)" : ""
    changed(
      "\(icon) voice · \(mode.rawValue) · \(state.rawValue) · \(settings.language)  \(detail)  /voice record|send|pause|off"
    )
  }
}
