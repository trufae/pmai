import AVFoundation

/// Keep PiP's audio session alive between listening and speaking turns. Audio
/// engines still stop their own capture/playback; only session deactivation waits.
@MainActor
enum BackgroundAudioRetention {
  private static var owners: Set<UUID> = []
  private static var audioActive = false

  static func acquire() throws -> UUID {
    let session = AVAudioSession.sharedInstance()
    if session.category != .playAndRecord && session.category != .playback {
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }
    try session.setActive(true)
    let token = UUID()
    owners.insert(token)
    return token
  }

  static func release(_ token: UUID) {
    owners.remove(token)
    if owners.isEmpty, !audioActive {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  static func deactivate() {
    audioActive = false
    if owners.isEmpty {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
  }

  static func activated() { audioActive = true }
}
