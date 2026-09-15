import AVFoundation
import Foundation

/// Keeps the process running after the screen locks by rendering silence
/// through the `audio` background mode the app already declares for voice
/// chats and TTS. Opt-in from Settings, and only engaged while a reply is in
/// flight and the app is in the background.
@MainActor
final class BackgroundKeepAlive {
  private static let sampleRate: Double = 44100
  private static let watchdogInterval: Duration = .seconds(10)

  var isActive: Bool { isRequested && engine?.isRunning == true && player?.isPlaying == true }
  private var isRequested = false
  private var engine: AVAudioEngine?
  private var player: AVAudioPlayerNode?
  private var watchdog: Task<Void, Never>?

  func start() {
    guard !isRequested else { return }
    isRequested = true
    startEngine()
    // TTS and voice sessions reconfigure the shared audio session; if that
    // stops the engine, bring it back once they are done.
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: Self.watchdogInterval)
        guard !Task.isCancelled, let self, self.isRequested else { return }
        if self.engine?.isRunning != true {
          self.startEngine()
        }
      }
    }
  }

  func stop() {
    guard isRequested else { return }
    isRequested = false
    watchdog?.cancel()
    watchdog = nil
    player?.stop()
    engine?.stop()
    player = nil
    engine = nil
    let session = AVAudioSession.sharedInstance()
    // Release the session only when it still carries the keep-alive profile;
    // a voice chat or TTS playback owns it otherwise.
    guard session.category == .playback, session.categoryOptions.contains(.mixWithOthers)
    else {
      return
    }
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func startEngine() {
    let session = AVAudioSession.sharedInstance()
    if session.category != .playAndRecord,
      session.category != .playback || !session.categoryOptions.contains(.mixWithOthers)
    {
      // Mix so the user's music keeps playing; the track itself is silent.
      try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
    do {
      try session.setActive(true, options: [])
    } catch {
      return
    }

    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    engine.attach(player)
    let frameCount = AVAudioFrameCount(Self.sampleRate)
    guard
      let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
    else {
      return
    }
    buffer.frameLength = frameCount
    engine.connect(player, to: engine.mainMixerNode, format: format)
    engine.mainMixerNode.outputVolume = 0.001
    do {
      try engine.start()
    } catch {
      return
    }
    player.scheduleBuffer(buffer, at: nil, options: .loops)
    player.play()
    self.engine = engine
    self.player = player
  }
}
