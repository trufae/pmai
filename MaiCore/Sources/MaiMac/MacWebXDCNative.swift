import Foundation
import MaiCore
import MaiVoice
import Observation

/// The same JS API as PocketMai, with explicit, session-scoped native permissions.
@MainActor @Observable
final class MacWebXDCNative {
  var permission: String?
  private var permissionReply: CheckedContinuation<Bool, Never>?
  private var permissions: Set<String> = []
  private weak var conversation: MacConversation?
  private let emit: ([String: Any]) -> Void
  private var tasks: [String: Task<Void, Never>] = [:]
  private var listening: MacWebXDCListening?
  private var listeningID: String?
  private var speaking: (any VoiceOutputProvider)?
  private static weak var activeAudio: MacWebXDCNative?
  private var promptID: String?

  init(conversation: MacConversation, emit: @escaping ([String: Any]) -> Void) {
    self.conversation = conversation
    self.emit = emit
  }
  static func stopActiveAudio() { activeAudio?.stop() }

  func receive(_ body: [String: Any]) {
    guard let id = body["id"] as? String, let method = body["method"] as? String else { return }
    if method == "cancel" {
      tasks[id]?.cancel()
      if listeningID == id { listening?.stop() }
      if promptID == id { conversation?.stop() }
      return
    }
    if method == "finishListening" {
      if listeningID == id { listening?.finish() }
      return
    }
    guard tasks[id] == nil else { return }
    let options = body["options"] as? [String: Any] ?? [:]
    tasks[id] = Task { [weak self] in
      guard let self else { return }
      defer { tasks[id] = nil }
      do {
        let result = try await call(method, options: options, id: id)
        try Task.checkCancellation()
        emit(["id": id, "result": result])
      } catch {
        emit(["id": id, "error": ["code": error is CancellationError ? "AbortError" : "NotAllowedError",
          "message": error.localizedDescription]])
      }
    }
  }

  func answerPermission(_ allowed: Bool) {
    let capability = permission
    permission = nil
    if allowed, let capability { permissions.insert(capability) }
    let reply = permissionReply
    permissionReply = nil
    reply?.resume(returning: allowed)
  }
  func stop() {
    answerPermission(false)
    for task in tasks.values { task.cancel() }
    listening?.stop()
    speaking?.stop()
    if promptID != nil { conversation?.stop() }
    if Self.activeAudio === self { Self.activeAudio = nil }
  }
  private func authorize(_ capability: String) async throws {
    if permissions.contains(capability) { return }
    guard permissionReply == nil else { throw WebXDCNativeError("Another permission request is open.") }
    let allowed = await withTaskCancellationHandler {
      await withCheckedContinuation { reply in
        if Task.isCancelled { reply.resume(returning: false); return }
        permissionReply = reply
        permission = capability
      }
    } onCancel: { Task { @MainActor [weak self] in self?.answerPermission(false) } }
    try Task.checkCancellation()
    guard allowed else { throw WebXDCNativeError("Access to \(capability) was denied.") }
  }
  private var capabilities: [String: Any] {
    ["permissions": Dictionary(uniqueKeysWithValues: ["inference", "transcription", "synthesis"].map { ($0, permissions.contains($0)) }),
      "features": ["chat": conversation?.connected == true, "isolated": false], "voicePrompt": VoicePrompt.instructions]
  }
  private func call(_ method: String, options: [String: Any], id: String) async throws -> Any {
    guard let conversation else { throw CancellationError() }
    if method == "capabilities" { return capabilities }
    if method == "requestPermissions" {
      for capability in options["capabilities"] as? [String] ?? [] {
        guard ["inference", "transcription", "synthesis"].contains(capability) else {
          throw WebXDCNativeError("Unsupported capability: \(capability)")
        }
        try await authorize(capability)
      }
      return capabilities
    }
    let configuration = try MacVoice.configuration(for: conversation)
    var settings = configuration.voice
    if let language = options["language"] as? String, !language.isEmpty { settings.language = language }
    let registry = PluginRegistry()
    try await registry.install(MaiVoicePlugin())
    let environment = ProcessInfo.processInfo.environment
    switch method {
    case "providers":
      return [
        ["id": "chat", "name": conversation.modelName ?? "Current chat", "available": conversation.connected, "capabilities": ["inference"]],
        ["id": settings.input, "name": "Configured transcription", "available": true, "capabilities": ["transcription"]],
        ["id": settings.output, "name": "Configured speech", "available": true, "capabilities": ["synthesis"]],
      ]
    case "models": return conversation.modelName.map { [$0] } ?? []
    case "voices", "languages":
      let role: VoiceProviderRole = method == "voices" ? .output : .input
      let catalog = try await registry.voiceFactory(kind: method == "voices" ? settings.output : settings.input)
        .catalog(for: role, settings: settings, configuration: configuration, environment: environment)
      return (method == "voices" ? catalog.voices : catalog.languages).map {
        ["id": $0.id, "name": $0.name, "language": $0.language ?? ""]
      }
    case "listen":
      try await authorize("transcription")
      guard listening == nil, speaking == nil else { throw WebXDCNativeError("Audio is already in use by this app.") }
      if Self.activeAudio !== self { Self.activeAudio?.stop() }
      MacVoice.stopActive()
      Self.activeAudio = self
      settings.mode = .realtime
      if let seconds = options["silenceSeconds"] as? Double { settings.silenceSeconds = seconds }
      if let seconds = options["maxSeconds"] as? Double { settings.maximumRecordingSeconds = seconds }
      let input = try await registry.voiceFactory(kind: settings.input)
        .makeInput(settings: settings, configuration: configuration, environment: environment)
      let listener = MacWebXDCListening()
      listening = listener
      listeningID = id
      defer { if listeningID == id { listening = nil; listeningID = nil } }
      let text = try await listener.listen(settings: settings, input: input) { [weak self] text in
        self?.emit(["id": id, "event": "transcript", "text": text])
      }
      return ["text": text]
    case "speak":
      try await authorize("synthesis")
      guard let text = options["text"] as? String, text.utf8.count <= 100_000 else {
        throw WebXDCNativeError("Supply speech text shorter than 100 KB.")
      }
      guard listening == nil, speaking == nil else { throw WebXDCNativeError("Audio is already in use by this app.") }
      if Self.activeAudio !== self { Self.activeAudio?.stop() }
      MacVoice.stopActive()
      Self.activeAudio = self
      if let voice = options["voice"] as? String, !voice.isEmpty { settings.voice = voice }
      if let speed = options["speed"] as? Double { settings.speed = speed }
      let output = try await registry.voiceFactory(kind: settings.output)
        .makeOutput(settings: settings, configuration: configuration, environment: environment)
      speaking = output
      defer { speaking = nil }
      try await output.speak(VoiceSentenceBuffer.speechText(text))
      return ["spoken": true]
    case "complete":
      try await authorize("inference")
      guard options["scope"] as? String == "chat" else {
        throw WebXDCNativeError("On Mac, use scope: 'chat' to converse with this chat's configured agent.")
      }
      guard promptID == nil else { throw WebXDCNativeError("An app request is already running.") }
      let messages = options["messages"] as? [[String: Any]] ?? []
      guard let text = messages.last(where: { $0["role"] as? String == "user" })?["content"] as? String,
        !text.isEmpty, text.utf8.count <= 1_000_000 else { throw WebXDCNativeError("Supply a user message shorter than 1 MB.") }
      promptID = id
      defer { promptID = nil }
      let answer: String = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { reply in
          guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
          let accepted = conversation.sendApp(text) { reply.resume(with: $0) }
          if !accepted { reply.resume(throwing: WebXDCNativeError("The chat is busy or disconnected. Try again when it is ready.")) }
        }
      } onCancel: { Task { @MainActor [weak self] in
        if self?.promptID == id { self?.conversation?.stop() }
      } }
      emit(["id": id, "event": "text", "text": answer])
      return ["text": answer]
    default: throw WebXDCNativeError("Unsupported native method: \(method)")
    }
  }
}

private struct WebXDCNativeError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}

@MainActor private final class MacWebXDCListening {
  private var session: VoiceSession?
  private var reply: CheckedContinuation<String, Error>?
  func listen(settings: ConfiguredVoice, input: any VoiceInputProvider,
    changed: @escaping @MainActor @Sendable (String) -> Void) async throws -> String {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { reply in
        guard !Task.isCancelled else { reply.resume(throwing: CancellationError()); return }
        self.reply = reply
        session = VoiceSession(settings: settings, input: input, output: MacWebXDCSilentOutput(),
          changed: { [weak self] _ in Task { @MainActor in
            guard let self, let session = self.session else { return }
            changed(session.transcript)
            if let error = session.error { self.finish(.failure(WebXDCNativeError(error))) }
          } }, submit: { [weak self] _, text in Task { @MainActor in self?.finish(.success(text)) } })
        session?.start()
      }
    } onCancel: { Task { @MainActor [weak self] in self?.stop() } }
  }
  func finish() { session?.send() }
  func stop() { finish(.failure(CancellationError())) }
  private func finish(_ result: Result<String, Error>) {
    let reply = reply
    self.reply = nil
    session?.stop()
    session = nil
    reply?.resume(with: result)
  }
}

@MainActor private final class MacWebXDCSilentOutput: VoiceOutputProvider {
  func speak(_ text: String) async throws {}
  func stop() {}
}
