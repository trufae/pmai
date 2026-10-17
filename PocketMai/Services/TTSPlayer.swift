import AVFoundation
import Foundation
import MaiOpenAI
import MediaPlayer

@MainActor
final class TTSPlayer: NSObject, ObservableObject {
  static let shared = TTSPlayer()

  @Published private(set) var isSpeaking: Bool = false
  @Published private(set) var isPaused: Bool = false
  @Published private(set) var currentRole: VoiceRole?
  @Published private(set) var currentTitle: String?
  @Published private(set) var currentText: String?
  @Published private(set) var currentTag: String?
  @Published private(set) var currentMessageID: UUID?
  @Published private(set) var errorMessage: String?

  typealias SpeechSynthesis = @MainActor (OpenAIEndpoint, String, String) async throws -> Data
  private let synthesizeSpeech: SpeechSynthesis

  private lazy var synthesizer: AVSpeechSynthesizer = {
    let synthesizer = AVSpeechSynthesizer()
    synthesizer.delegate = self
    return synthesizer
  }()
  private var remoteCommandsConfigured = false
  private var queuedSpeech: [QueuedSpeech] = []
  private var pendingSpeechAfterCancel: QueuedSpeech?
  private var providerSpeechTask: Task<Void, Never>?
  private var audioPlayer: AVAudioPlayer?
  private var audioFileURL: URL?
  private var boostedAudioEngine: AVAudioEngine?
  private var boostedAudioPlayerNode: AVAudioPlayerNode?
  private var boostedAudioGainUnit: AVAudioUnitEQ?
  private var boostedAudioPlaybackID: UUID?
  private var speechGeneration = 0

  init(
    synthesizeSpeech: @escaping SpeechSynthesis = { endpoint, text, voice in
      try await OpenAICompatibleProvider.synthesizeSpeechAudio(
        endpoint: endpoint, input: text, voice: voice)
    }
  ) {
    self.synthesizeSpeech = synthesizeSpeech
    super.init()
  }

  func dismissError() { errorMessage = nil }

  func speak(
    text: String,
    voice: RoleVoiceSettings,
    role: VoiceRole,
    title: String? = nil,
    tag: String? = nil,
    messageID: UUID? = nil,
    openAIEndpoints: [OpenAIEndpoint] = [],
    skipTechnicalContent: Bool = true,
    interrupt: Bool = true
  ) {
    guard
      let speech = QueuedSpeech(
        text: text,
        voice: voice,
        role: role,
        title: title,
        tag: tag,
        messageID: messageID,
        openAIEndpoints: openAIEndpoints,
        skipTechnicalContent: skipTechnicalContent
      )
    else { return }

    if hasActiveSpeech {
      if interrupt {
        queuedSpeech.removeAll()
        pendingSpeechAfterCancel = speech
        cancelActiveSpeech()
      } else {
        return
      }
      return
    }

    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    beginSpeaking(speech)
  }

  func enqueue(
    text: String,
    voice: RoleVoiceSettings,
    role: VoiceRole,
    title: String? = nil,
    tag: String? = nil,
    messageID: UUID? = nil,
    openAIEndpoints: [OpenAIEndpoint] = [],
    skipTechnicalContent: Bool = true
  ) {
    guard
      let speech = QueuedSpeech(
        text: text,
        voice: voice,
        role: role,
        title: title,
        tag: tag,
        messageID: messageID,
        openAIEndpoints: openAIEndpoints,
        skipTechnicalContent: skipTechnicalContent
      )
    else { return }

    if hasActiveSpeech {
      queuedSpeech.append(speech)
      return
    }

    pendingSpeechAfterCancel = nil
    beginSpeaking(speech)
  }

  func playRecording(
    for message: ChatMessage,
    title: String? = nil,
    interrupt: Bool = true
  ) {
    guard let speech = QueuedSpeech(recordingMessage: message, title: title) else { return }

    if hasActiveSpeech {
      if interrupt {
        queuedSpeech.removeAll()
        pendingSpeechAfterCancel = speech
        cancelActiveSpeech()
      }
      return
    }

    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    beginSpeaking(speech)
  }

  func toggleRecordingPlayback(for message: ChatMessage, title: String? = nil) {
    guard currentMessageID == message.id, isSpeaking else {
      playRecording(for: message, title: title)
      return
    }
    if isPaused {
      resume()
    } else {
      pause()
    }
  }

  func speakFromHere(
    messages: [ChatMessage],
    voices: VoiceSettings,
    openAIEndpoints: [OpenAIEndpoint] = [],
    skipTechnicalContent: Bool = true
  ) {
    let items = messages.compactMap { message -> QueuedSpeech? in
      let role: VoiceRole
      switch message.role {
      case .user: role = .user
      case .assistant: role = .assistant
      default: return nil
      }
      if message.role == .user,
        let recorded = QueuedSpeech(recordingMessage: message, title: message.role.displayName)
      {
        return recorded
      }
      return QueuedSpeech(
        text: MessageContentFilter.render(message.presentationText).visibleText,
        voice: voices.settings(for: role),
        role: role,
        title: message.role.displayName,
        tag: nil,
        messageID: message.id,
        openAIEndpoints: openAIEndpoints,
        skipTechnicalContent: skipTechnicalContent
      )
    }
    guard let first = items.first else { return }

    queuedSpeech = Array(items.dropFirst())
    if hasActiveSpeech {
      pendingSpeechAfterCancel = first
      cancelActiveSpeech()
      return
    }

    pendingSpeechAfterCancel = nil
    beginSpeaking(first)
  }

  private func beginSpeaking(_ requestedSpeech: QueuedSpeech) {
    var speech = requestedSpeech
    if speech.voice.provider == .openAICompatible, speech.openAIEndpoint?.isDirectOpenAI == true {
      let chunks = OpenAISpeech.textChunks(speech.text)
      speech.text = chunks.first ?? speech.text
      queuedSpeech.insert(
        contentsOf: chunks.dropFirst().map { text in
          var next = requestedSpeech
          next.text = text
          return next
        }, at: 0)
    }
    errorMessage = nil
    setupRemoteCommands()
    activateAudioSession()
    speechGeneration += 1

    currentRole = speech.role
    currentTitle = speech.title
    currentText = speech.text
    currentTag = speech.tag
    currentMessageID = speech.messageID
    isSpeaking = true
    isPaused = false
    updateNowPlaying()

    if speech.voice.provider == .openAICompatible {
      guard let endpoint = speech.openAIEndpoint else {
        failSpeech(
          "The selected voice provider is missing or disabled. Choose a provider in Settings > Voices."
        )
        return
      }
      guard !speech.voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        failSpeech("Select a voice in Settings > Voices before speaking.")
        return
      }
      beginProviderSpeaking(speech, endpoint: endpoint, generation: speechGeneration)
      return
    }

    if let recordingURL = speech.recordingURL {
      beginAudioFileSpeaking(speech, url: recordingURL, generation: speechGeneration)
      return
    }

    beginSystemSpeaking(speech)
  }

  private func beginAudioFileSpeaking(
    _ speech: QueuedSpeech,
    url: URL,
    generation: Int
  ) {
    do {
      guard speechGeneration == generation else { return }
      if try beginBoostedAudioFileSpeaking(url: url, generation: generation) {
        return
      }
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.prepareToPlay()
      if player.play() {
        audioPlayer = player
        return
      }
    } catch {
      // Fall through to stopped state.
    }
    handleStopped()
  }

  private func beginBoostedAudioFileSpeaking(url: URL, generation: Int) throws -> Bool {
    cleanupBoostedAudioEngine()

    let file = try AVAudioFile(forReading: url)
    guard file.length > 0 else { return false }

    let engine = AVAudioEngine()
    let playerNode = AVAudioPlayerNode()
    let gainUnit = AVAudioUnitEQ(numberOfBands: 1)
    gainUnit.bands.first?.bypass = true
    gainUnit.globalGain = speechPlaybackGainDecibels(for: file)

    engine.attach(playerNode)
    engine.attach(gainUnit)
    engine.connect(playerNode, to: gainUnit, format: file.processingFormat)
    engine.connect(gainUnit, to: engine.mainMixerNode, format: file.processingFormat)

    try engine.start()
    let playbackID = UUID()
    boostedAudioEngine = engine
    boostedAudioPlayerNode = playerNode
    boostedAudioGainUnit = gainUnit
    boostedAudioPlaybackID = playbackID

    playerNode.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) {
      [weak self] _ in
      Task { @MainActor in
        guard
          let self,
          self.speechGeneration == generation,
          self.boostedAudioPlaybackID == playbackID
        else {
          return
        }
        self.handleFinished()
      }
    }
    if !isPaused { playerNode.play() }
    return true
  }

  private func beginSystemSpeaking(_ speech: QueuedSpeech) {
    let utterance = AVSpeechUtterance(string: speech.text)
    if !speech.voice.voiceIdentifier.isEmpty,
      let v = AVSpeechSynthesisVoice(identifier: speech.voice.voiceIdentifier)
    {
      utterance.voice = v
    } else if !speech.voice.language.isEmpty {
      utterance.voice = AVSpeechSynthesisVoice(language: speech.voice.language)
    }
    utterance.rate = Float(max(0, min(1, speech.voice.rate)))
    utterance.pitchMultiplier = Float(max(0.5, min(2, speech.voice.pitch)))
    utterance.volume = 1.0

    synthesizer.speak(utterance)
  }

  private func beginProviderSpeaking(
    _ speech: QueuedSpeech,
    endpoint: OpenAIEndpoint,
    generation: Int
  ) {
    let voice = speech.voice.openAIVoice.trimmingCharacters(in: .whitespacesAndNewlines)
    let synthesizeSpeech = self.synthesizeSpeech
    providerSpeechTask = Task { [weak self] in
      do {
        try Task.checkCancellation()
        let data = try await synthesizeSpeech(endpoint, speech.text, voice)
        try Task.checkCancellation()
        guard let self, self.speechGeneration == generation else { return }
        if !self.playProviderAudio(data, fileExtension: "wav", generation: generation) {
          self.failSpeech(
            "Speech synthesis returned audio that could not be played. Check the provider's WAV output."
          )
        }
      } catch {
        guard !Task.isCancelled, !(error is CancellationError),
          let self, self.speechGeneration == generation
        else { return }
        self.failSpeech(
          "\(endpoint.displayName) speech (\(endpoint.effectiveSpeechModel.isEmpty ? "provider default" : endpoint.effectiveSpeechModel), \(voice)): \(error.localizedDescription)"
        )
      }
    }
  }

  private func failSpeech(_ message: String) {
    handleStopped()
    errorMessage = message
  }

  private func playProviderAudio(
    _ data: Data,
    fileExtension: String,
    generation: Int
  ) -> Bool {
    guard speechGeneration == generation else { return true }
    var url: URL?
    do {
      cleanupAudioFile()
      let candidateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("PocketMaiTTS-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
      url = candidateURL
      let url = candidateURL
      let playableData = normalizedProviderAudioData(data, fileExtension: fileExtension)
      try playableData.write(to: url, options: .atomic)
      audioFileURL = url
      if try beginBoostedAudioFileSpeaking(url: url, generation: generation) {
        providerSpeechTask = nil
        return true
      }
      let player = try AVAudioPlayer(contentsOf: url)
      player.delegate = self
      player.volume = 1.0
      player.prepareToPlay()
      if isPaused || player.play() {
        audioPlayer = player
        providerSpeechTask = nil
        return true
      }
      try? FileManager.default.removeItem(at: url)
      return false
    } catch {
      if let url {
        try? FileManager.default.removeItem(at: url)
      }
      cleanupAudioFile()
      return false
    }
  }

  private func normalizedProviderAudioData(_ data: Data, fileExtension: String) -> Data {
    guard fileExtension.lowercased() == "wav" else { return data }
    return data.withRepairedWAVChunkSizes()
  }

  func pause() {
    if providerSpeechTask != nil && !isPaused {
      isPaused = true
      updateNowPlaying()
      return
    }
    if let boostedAudioPlayerNode, boostedAudioPlayerNode.isPlaying, !isPaused {
      boostedAudioPlayerNode.pause()
      isPaused = true
      updateNowPlaying()
      return
    }
    if let audioPlayer, audioPlayer.isPlaying, !isPaused {
      audioPlayer.pause()
      isPaused = true
      updateNowPlaying()
      return
    }
    guard synthesizer.isSpeaking, !isPaused else { return }
    synthesizer.pauseSpeaking(at: .word)
  }

  func resume() {
    guard isPaused else { return }
    if providerSpeechTask != nil {
      isPaused = false
      updateNowPlaying()
      return
    }
    if let boostedAudioPlayerNode {
      boostedAudioPlayerNode.play()
      isPaused = false
      updateNowPlaying()
      return
    }
    if let audioPlayer {
      audioPlayer.play()
      isPaused = false
      updateNowPlaying()
      return
    }
    synthesizer.continueSpeaking()
  }

  func stop() {
    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    if providerSpeechTask != nil || audioPlayer != nil || boostedAudioPlayerNode != nil {
      cancelProviderSpeech()
      handleStopped()
      return
    }
    handleStopped()
  }

  func isPlaying(tag: String) -> Bool {
    isSpeaking && currentTag == tag
  }

  private func handleFinished() {
    if audioPlayer != nil || boostedAudioPlayerNode != nil {
      audioPlayer = nil
      cleanupBoostedAudioEngine()
      cleanupAudioFile()
    }
    if !queuedSpeech.isEmpty {
      let next = queuedSpeech.removeFirst()
      beginSpeaking(next)
      return
    }
    handleStopped()
  }

  private func handleCancelled() {
    if let next = pendingSpeechAfterCancel {
      pendingSpeechAfterCancel = nil
      beginSpeaking(next)
      return
    }
    handleStopped()
  }

  private func handleStopped() {
    speechGeneration += 1
    queuedSpeech.removeAll()
    pendingSpeechAfterCancel = nil
    providerSpeechTask?.cancel()
    providerSpeechTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    cleanupBoostedAudioEngine()
    cleanupAudioFile()
    isSpeaking = false
    isPaused = false
    currentRole = nil
    currentTitle = nil
    currentText = nil
    currentTag = nil
    currentMessageID = nil
    clearNowPlaying()
    deactivateAudioSession()
  }

  private var hasActiveSpeech: Bool {
    synthesizer.isSpeaking || providerSpeechTask != nil || audioPlayer != nil
      || boostedAudioPlayerNode != nil
  }

  private func cancelActiveSpeech() {
    if synthesizer.isSpeaking {
      synthesizer.stopSpeaking(at: .immediate)
      return
    }
    cancelProviderSpeech()
    handleCancelled()
  }

  private func cancelProviderSpeech() {
    providerSpeechTask?.cancel()
    providerSpeechTask = nil
    audioPlayer?.stop()
    audioPlayer = nil
    cleanupBoostedAudioEngine()
    cleanupAudioFile()
  }

  private func cleanupBoostedAudioEngine() {
    let engine = boostedAudioEngine
    boostedAudioPlayerNode?.stop()
    engine?.stop()
    if let boostedAudioPlayerNode {
      engine?.detach(boostedAudioPlayerNode)
    }
    if let boostedAudioGainUnit {
      engine?.detach(boostedAudioGainUnit)
    }
    boostedAudioPlayerNode = nil
    boostedAudioGainUnit = nil
    boostedAudioPlaybackID = nil
    boostedAudioEngine = nil
  }

  private func speechPlaybackGainDecibels(for file: AVAudioFile) -> Float {
    let originalFramePosition = file.framePosition
    defer { file.framePosition = originalFramePosition }

    file.framePosition = 0
    let chunkFrameCapacity: AVAudioFrameCount = 4096
    guard
      let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: chunkFrameCapacity)
    else {
      return 0
    }

    var peak: Float = 0
    var sumSquares: Double = 0
    var sampleCount = 0

    do {
      while file.framePosition < file.length {
        let remainingFrames = file.length - file.framePosition
        let framesToRead = AVAudioFrameCount(min(Int64(chunkFrameCapacity), remainingFrames))
        try file.read(into: buffer, frameCount: framesToRead)
        guard let channelData = buffer.floatChannelData else { return 0 }
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { break }

        for channel in 0..<channelCount {
          let samples = channelData[channel]
          for frame in 0..<frameLength {
            let value = samples[frame]
            let magnitude = abs(value)
            peak = max(peak, magnitude)
            sumSquares += Double(value * value)
            sampleCount += 1
          }
        }
      }
    } catch {
      return 0
    }

    guard peak > 0, sampleCount > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms > 0, rms.isFinite else { return 0 }

    let targetRMS = 0.22
    let targetPeak = 0.95
    let rmsGain = 20.0 * log10(targetRMS / rms)
    let peakHeadroom = 20.0 * log10(targetPeak / Double(peak))
    let gain = min(18.0, rmsGain, peakHeadroom)
    guard gain.isFinite, gain > 0 else { return 0 }
    return Float(gain)
  }

  private func cleanupAudioFile() {
    if let audioFileURL {
      try? FileManager.default.removeItem(at: audioFileURL)
    }
    audioFileURL = nil
  }

  private func activateAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // Live voice recording leaves the session in playAndRecord. Switch TTS back
      // to playback so assistant speech uses the normal media volume path.
      try session.setCategory(.playback, mode: .default, options: [])
      try session.setActive(true, options: [])
    } catch {
      // Best-effort: TTS still plays in foreground without an active session.
    }
  }

  private func deactivateAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      guard session.category != .playAndRecord else { return }
      try session.setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      // Ignore: the session may already be inactive.
    }
  }

  private func updateNowPlaying() {
    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = currentTitle ?? "Spoken Message"
    if let role = currentRole {
      info[MPMediaItemPropertyArtist] = role == .user ? "User" : "Assistant"
    }
    if let text = currentText, !text.isEmpty {
      info[MPMediaItemPropertyAlbumTitle] = String(text.prefix(120))
    }
    info[MPNowPlayingInfoPropertyPlaybackRate] = isPaused ? 0.0 : 1.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  private func clearNowPlaying() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  private func setupRemoteCommands() {
    guard !remoteCommandsConfigured else { return }
    remoteCommandsConfigured = true
    let center = MPRemoteCommandCenter.shared()

    center.playCommand.isEnabled = true
    center.playCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.resume() }
      return .success
    }
    center.pauseCommand.isEnabled = true
    center.pauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.pause() }
      return .success
    }
    center.stopCommand.isEnabled = true
    center.stopCommand.addTarget { [weak self] _ in
      Task { @MainActor in self?.stop() }
      return .success
    }
    center.togglePlayPauseCommand.isEnabled = true
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        if self.isPaused {
          self.resume()
        } else if self.isSpeaking {
          self.pause()
        }
      }
      return .success
    }
  }

  private struct QueuedSpeech {
    var text: String
    let voice: RoleVoiceSettings
    let role: VoiceRole
    let title: String?
    let tag: String?
    let messageID: UUID?
    let openAIEndpoints: [OpenAIEndpoint]
    let recordingURL: URL?
    var openAIEndpoint: OpenAIEndpoint? {
      guard let id = voice.openAIEndpointID else { return nil }
      return openAIEndpoints.first(where: { $0.id == id && $0.isEnabled })
    }

    init?(
      text: String,
      voice: RoleVoiceSettings,
      role: VoiceRole,
      title: String?,
      tag: String?,
      messageID: UUID?,
      openAIEndpoints: [OpenAIEndpoint],
      skipTechnicalContent: Bool
    ) {
      let sanitized = TTSSpeechTextSanitizer.sanitized(
        text,
        skipTechnicalContent: skipTechnicalContent)
      guard !sanitized.isEmpty else { return nil }
      self.text = sanitized
      self.voice = voice
      self.role = role
      self.title = title
      self.tag = tag
      self.messageID = messageID
      self.openAIEndpoints = openAIEndpoints
      self.recordingURL = nil
    }

    init?(recordingMessage message: ChatMessage, title: String?) {
      guard message.role == .user,
        let filename = message.voiceRecordingFilename,
        let url = PocketMaiDirectories.voiceRecordingURL(filename: filename),
        FileManager.default.fileExists(atPath: url.path)
      else {
        return nil
      }
      self.text = MessageContentFilter.render(message.presentationText).visibleText
      self.voice = .defaults
      self.role = .user
      self.title = title
      self.tag = nil
      self.messageID = message.id
      self.openAIEndpoints = []
      self.recordingURL = url
    }
  }
}

extension TTSPlayer: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleFinished() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in self.handleCancelled() }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isPaused = true
      self.updateNowPlaying()
    }
  }

  nonisolated func speechSynthesizer(
    _ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance
  ) {
    Task { @MainActor in
      self.isPaused = false
      self.updateNowPlaying()
    }
  }
}

extension TTSPlayer: AVAudioPlayerDelegate {
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    let playerID = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
      if flag {
        self.handleFinished()
      } else {
        self.failSpeech("Audio playback did not finish successfully.")
      }
    }
  }

  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    let playerID = ObjectIdentifier(player)
    Task { @MainActor in
      guard self.audioPlayer.map(ObjectIdentifier.init) == playerID else { return }
      self.failSpeech(error?.localizedDescription ?? "The speech audio could not be decoded.")
    }
  }
}

extension Data {
  fileprivate func withRepairedWAVChunkSizes() -> Data {
    guard count >= 44,
      matchesASCII("RIFF", at: 0),
      matchesASCII("WAVE", at: 8)
    else { return self }

    var repaired = self
    repaired.writeLittleEndianUInt32(UInt32(clamping: count - 8), at: 4)

    var offset = 12
    while offset + 8 <= repaired.count {
      let chunkIDOffset = offset
      let chunkSizeOffset = offset + 4
      let chunkSize = repaired.littleEndianUInt32(at: chunkSizeOffset)
      let chunkDataOffset = offset + 8
      if repaired.matchesASCII("data", at: chunkIDOffset) {
        let actualDataSize = Swift.max(0, repaired.count - chunkDataOffset)
        repaired.writeLittleEndianUInt32(UInt32(clamping: actualDataSize), at: chunkSizeOffset)
        return repaired
      }

      let nextOffset = chunkDataOffset + Int(chunkSize) + (Int(chunkSize) & 1)
      guard nextOffset > offset else { return repaired }
      if nextOffset > repaired.count {
        return repaired
      }
      offset = nextOffset
    }

    return repaired
  }

  fileprivate func matchesASCII(_ string: String, at offset: Int) -> Bool {
    let bytes = Array(string.utf8)
    guard offset >= 0, offset + bytes.count <= count else { return false }
    for index in bytes.indices where self[offset + index] != bytes[index] {
      return false
    }
    return true
  }

  fileprivate func littleEndianUInt32(at offset: Int) -> UInt32 {
    guard offset >= 0, offset + 4 <= count else { return 0 }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }

  fileprivate mutating func writeLittleEndianUInt32(_ value: UInt32, at offset: Int) {
    guard offset >= 0, offset + 4 <= count else { return }
    self[offset] = UInt8(value & 0xff)
    self[offset + 1] = UInt8((value >> 8) & 0xff)
    self[offset + 2] = UInt8((value >> 16) & 0xff)
    self[offset + 3] = UInt8((value >> 24) & 0xff)
  }
}
