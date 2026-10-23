import AVFoundation
import Foundation
import MaiCore
import MaiOpenAI
import Speech

/// Local grants deliberately live outside revision directories and .xdc exports.
struct WebXDCPermissions: Codable, Equatable {
  var inference = false
  var transcription = false
  var synthesis = false

  static func load(_ id: UUID) -> Self {
    guard let data = try? Data(contentsOf: url(id)),
      let value = try? JSONDecoder().decode(Self.self, from: data)
    else { return Self() }
    return value
  }

  func save(_ id: UUID) throws {
    try JSONEncoder().encode(self).write(to: Self.url(id), options: .atomic)
  }

  private static func url(_ id: UUID) -> URL {
    WebXDCLibrary.appURL(id).appendingPathComponent("pocketmai-permissions.json")
  }
}

struct WebXDCAPIError: LocalizedError {
  let code: String
  let message: String
  var errorDescription: String? { message }
}

/// One host per WKWebView. No AppStore.send, chat history, agent tools or shared TTS player.
@MainActor
final class WebXDCPocketMaiHost {
  static let voicePrompt = """
    You are a friendly voice companion. Reply conversationally, in the user's language.
    Use one or two short, colloquial sentences unless asked for more. Use plain spoken text.
    Avoid Markdown, headings, lists, code, URLs, stage directions and internal reasoning.
    """
  let appID: UUID
  private let settings: () -> AppSettings
  var requestPermission: ((String) async -> Bool)?
  private let emit: ([String: Any]) -> Void
  private var tasks: [String: Task<Void, Never>] = [:]
  private var cancelledRequests: Set<String> = []
  private var speechRequest: String?
  private var engine: LiveSpeechRecognitionEngine?
  private let player = TTSPlayer(integratesWithSystemPlayback: false)
  private var finishListening: (() async -> Void)?
  var isActive = true {
    didSet { if !isActive { cancelAll() } }
  }
  private let completion:
    (ChatCompletionRequest, @escaping @MainActor (String) -> Void) async throws -> String
  private let recognitionEngine:
    (ConversationSettings, SpeechTranscriptionPolicy) throws -> LiveSpeechRecognitionEngine

  init(
    appID: UUID, settings: @escaping () -> AppSettings,
    completion:
      @escaping (ChatCompletionRequest, @escaping @MainActor (String) -> Void) async throws ->
      String = {
        try await ChatProviderRouter.complete(request: $0, onUpdate: $1)
      },
    recognitionEngine:
      @escaping (ConversationSettings, SpeechTranscriptionPolicy) throws ->
      LiveSpeechRecognitionEngine = {
        try SpeechRecognitionEngineFactory.make(settings: $0, policy: $1)
      },
    emit: @escaping ([String: Any]) -> Void
  ) {
    self.appID = appID
    self.settings = settings
    self.emit = emit
    self.completion = completion
    self.recognitionEngine = recognitionEngine
  }

  func cancelAll() {
    for id in Array(tasks.keys) { cancel(id) }
  }

  private func cancel(_ id: String) {
    guard let task = tasks[id], cancelledRequests.insert(id).inserted else { return }
    task.cancel()
    if speechRequest == id {
      engine?.stop()
      player.stop()
    }
    emit(["id": id, "error": ["code": "AbortError", "message": "Request cancelled."]])
  }

  func receive(_ body: [String: Any]) {
    guard let id = body["id"] as? String, !id.isEmpty, id.count <= 100,
      let method = body["method"] as? String
    else { return }
    if method == "cancel" {
      cancel(id)
      return
    }
    if method == "finishListening" {
      guard !cancelledRequests.contains(id), speechRequest == id, let finishListening else {
        return
      }
      self.finishListening = nil
      Task { await finishListening() }
      return
    }
    guard isActive else {
      fail(id, WebXDCAPIError(code: "AbortError", message: "App is not visible."))
      return
    }
    guard tasks[id] == nil else { return }
    guard tasks.count < 8 else {
      fail(
        id, WebXDCAPIError(code: "BusyError", message: "At most eight requests may run at once."))
      return
    }
    let options = body["options"] as? [String: Any] ?? [:]
    tasks[id] = Task { [weak self] in
      guard let self else { return }
      defer {
        tasks[id] = nil
        cancelledRequests.remove(id)
      }
      do {
        try Task.checkCancellation()
        let result = try await run(method, options: options, id: id)
        try Task.checkCancellation()
        guard !cancelledRequests.contains(id) else { return }
        emit(["id": id, "result": result])
      } catch {
        guard !cancelledRequests.contains(id) else { return }
        fail(id, error)
      }
    }
  }

  private func fail(_ id: String, _ error: Error) {
    let code =
      (error as? WebXDCAPIError)?.code
      ?? (error is CancellationError ? "AbortError" : "OperationError")
    emit(["id": id, "error": ["code": code, "message": error.localizedDescription]])
  }

  private func require(_ capability: String) async throws {
    var grants = WebXDCPermissions.load(appID)
    let tools = settings().toolSettings
    let allowed: Bool
    switch capability {
    case "inference": allowed = grants.inference
    case "transcription": allowed = grants.transcription && tools.webxdcAllowMicrophone
    case "synthesis": allowed = grants.synthesis && tools.webxdcAllowAudioPlayback
    default: allowed = false
    }
    let hasGrant = switch capability {
    case "inference": grants.inference
    case "transcription": grants.transcription
    case "synthesis": grants.synthesis
    default: false
    }
    if !hasGrant, let requestPermission {
      let granted = await requestPermission(capability)
      try Task.checkCancellation()
      if granted {
        grants = WebXDCPermissions.load(appID)
        switch capability {
        case "inference": grants.inference = true
        case "transcription": grants.transcription = true
        case "synthesis": grants.synthesis = true
        default: break
        }
        try grants.save(appID)
        return try await require(capability)
      }
    }
    guard allowed else {
      throw WebXDCAPIError(
        code: "NotAllowedError",
        message:
          "Enable \(capability) in this app's PocketMai permissions and the required WebXDC media settings."
      )
    }
  }

  private func endpoint(_ id: String, speech: Bool = false) throws -> OpenAIEndpoint {
    guard
      let endpoint = settings().openAIEndpoints.first(where: {
        $0.id.uuidString == id && $0.isEnabled && (!speech || $0.isSelectableForSpeech)
      })
    else { throw WebXDCAPIError(code: "NotFoundError", message: "Provider is unavailable.") }
    guard !settings().isOffline else {
      throw WebXDCAPIError(
        code: "NotSupportedError", message: "Provider requests are unavailable offline.")
    }
    return endpoint
  }

  private func run(_ method: String, options: [String: Any], id: String) async throws -> Any {
    if method == "capabilities" {
      let grants = WebXDCPermissions.load(appID)
      let tools = settings().toolSettings
      return [
        "host": "pocketmai", "version": 1,
        "permissions": [
          "inference": grants.inference,
          "transcription": grants.transcription && tools.webxdcAllowMicrophone,
          "synthesis": grants.synthesis && tools.webxdcAllowAudioPlayback,
        ],
        "features": [
          "streaming": true, "cancellation": true, "microphone": true,
          "tools": false,
        ], "voicePrompt": Self.voicePrompt,
      ] as [String: Any]
    }
    if method == "providers" {
      // Catalogs may disclose configured services, so they also require a grant.
      let grants = WebXDCPermissions.load(appID)
      guard grants.inference || grants.transcription || grants.synthesis else {
        throw WebXDCAPIError(
          code: "NotAllowedError", message: "Enable at least one PocketMai permission for this app."
        )
      }
      var providers: [[String: Any]] = []
      if grants.inference {
        providers += [
          [
            "id": "apple", "name": "Apple", "capabilities": ["inference"],
            "available": AppleFoundationProvider.unavailableMessage(
              deviceOnly: settings().isOffline) == nil,
          ],
          [
            "id": "mlx", "name": "MLX", "capabilities": ["inference"],
            "available": LocalMLXAvailability.current.unavailabilityMessage == nil,
          ],
        ]
      }
      if grants.synthesis || grants.transcription {
        providers.append([
          "id": "system", "name": "iOS Speech", "available": true,
          "capabilities": (grants.synthesis ? ["synthesis"] : [])
            + (grants.transcription ? ["transcription"] : []),
        ])
      }
      providers += settings().openAIEndpoints.filter(\.isEnabled).map { endpoint in
        var capabilities = grants.inference ? ["inference"] : []
        if endpoint.isSelectableForSpeech && grants.synthesis { capabilities.append("synthesis") }
        if endpoint.kind == .openAICompatible && grants.transcription {
          capabilities.append("transcription")
        }
        return [
          "id": endpoint.id.uuidString, "name": endpoint.name, "available": !settings().isOffline,
          "capabilities": capabilities,
        ] as [String: Any]
      }.filter { !($0["capabilities"] as? [String] ?? []).isEmpty }
      return providers
    }
    let capability: String
    switch method {
    case "complete": capability = "inference"
    case "models":
      let purpose = options["purpose"] as? String ?? "inference"
      guard ["inference", "transcription", "synthesis"].contains(purpose) else {
        throw WebXDCAPIError(code: "TypeError", message: "Unknown model purpose.")
      }
      capability = purpose
    case "voices", "speak": capability = "synthesis"
    case "listen": capability = "transcription"
    case "languages":
      capability =
        (options["purpose"] as? String ?? "transcription") == "synthesis"
        ? "synthesis" : "transcription"
    default: throw WebXDCAPIError(code: "NotSupportedError", message: "Unknown PocketMai method.")
    }
    try await require(capability)
    if method == "models" {
      let provider =
        options["provider"] as? String ?? (capability == "inference" ? defaultProviderID : "system")
      if capability != "inference" {
        if provider == "system" { return [String]() }
        let selected = try endpoint(provider, speech: true)
        if capability == "synthesis" {
          return selected.availableSpeechModels.isEmpty
            ? [selected.effectiveSpeechModel].filter { !$0.isEmpty }
            : selected.availableSpeechModels
        }
        if selected.isDirectGroq { return GroqSpeech.transcriptionModels }
        if selected.id == settings().transcriptionEndpointID, !settings().transcriptionModel.isEmpty
        {
          return [settings().transcriptionModel]
        }
        return try await OpenAICompatibleProvider.fetchModels(endpoint: selected)
      }
      if provider == "apple" { return [settings().appleModelID] }
      if provider == "mlx" { return LocalMLXModelCache.listRepositoryIDs() }
      return try await OpenAICompatibleProvider.fetchModels(endpoint: endpoint(provider))
    }
    if method == "voices" {
      let provider = options["provider"] as? String ?? "system"
      if provider == "system" {
        return AVSpeechSynthesisVoice.speechVoices().map {
          ["id": $0.identifier, "name": $0.name, "language": $0.language]
        }
      }
      var endpoint = try endpoint(provider, speech: true)
      if let model = options["model"] as? String { endpoint.speechModel = model }
      return try await OpenAICompatibleProvider.fetchVoices(endpoint: endpoint).map {
        ["id": $0, "name": $0, "language": ""]
      }
    }
    if method == "languages" {
      let provider = options["provider"] as? String ?? "system"
      // Remote backends do not offer a portable language-enumeration endpoint.
      if provider != "system" {
        _ = try endpoint(provider, speech: capability == "synthesis")
        return [String]()
      }
      if capability == "synthesis" {
        return Array(Set(AVSpeechSynthesisVoice.speechVoices().map(\.language))).sorted()
      }
      return SFSpeechRecognizer.supportedLocales().map(\.identifier).sorted()
    }
    if method == "complete" { return try await complete(options, id: id) }
    guard speechRequest == nil else {
      throw WebXDCAPIError(
        code: "BusyError", message: "This app already has an active speech request.")
    }
    speechRequest = id
    defer { speechRequest = nil }
    if method == "listen" { return try await listen(options, id: id) }
    return try await speak(options)
  }

  private var defaultProviderID: String {
    let configuration = settings().defaultProviderConfiguration
    return configuration.endpointID?.uuidString ?? configuration.provider.rawValue
  }

  private func complete(_ options: [String: Any], id: String) async throws -> Any {
    var settings = settings()
    var conversation = Conversation()
    let provider = options["provider"] as? String ?? defaultProviderID
    switch provider {
    case "apple":
      conversation.provider = .apple
      conversation.modelID = settings.appleModelID
    case "mlx":
      conversation.provider = .mlx
      conversation.modelID = settings.localMLXModelID
    default:
      let endpoint = try endpoint(provider)
      conversation.provider = .openAICompatible
      conversation.endpointID = endpoint.id
      conversation.modelID = endpoint.defaultModel
    }
    if options["provider"] == nil {
      conversation.modelID = settings.defaultProviderConfiguration.modelID
    }
    if let model = options["model"] as? String { conversation.modelID = model }
    let prompt =
      options["systemPrompt"] as? String
      ?? ((options["mode"] as? String) == "voice"
        ? Self.voicePrompt : "You are a helpful assistant.")
    guard prompt.utf8.count <= 64_000,
      let messages = options["messages"] as? [[String: String]], !messages.isEmpty,
      messages.count <= 200,
      messages.reduce(0, { $0 + ($1["content"]?.utf8.count ?? 0) }) <= 256_000
    else {
      throw WebXDCAPIError(
        code: "TypeError",
        message: "Supply 1–200 messages (up to 256 KB) and a system prompt up to 64 KB.")
    }
    conversation.messages = try messages.map { message in
      guard let text = message["content"], let role = message["role"],
        role == "user" || role == "assistant"
      else {
        throw WebXDCAPIError(
          code: "TypeError", message: "Messages require role user/assistant and content.")
      }
      return ChatMessage(role: role == "user" ? .user : .assistant, text: text)
    }
    let system = SystemPrompt(name: "WebXDC", text: prompt)
    settings.systemPrompts = [system]
    settings.memory = ""
    conversation.systemPromptID = system.id
    conversation.toolsEnabled = false
    conversation.enabledTools = []
    conversation.usesStreaming = true
    if let message = ChatProviderRouter.preflightMessage(
      conversation: conversation, settings: settings)
    {
      throw WebXDCAPIError(code: "NotSupportedError", message: message)
    }
    let request = ChatCompletionRequest(
      conversation: conversation, settings: settings, context: "", assistantMessageID: UUID())
    let text = try await completion(request) { [weak self] text in
      guard let self, !cancelledRequests.contains(id), !Task.isCancelled else { return }
      emit(["id": id, "event": "text", "text": MessageContentFilter.render(text).visibleText])
    }
    return ["text": MessageContentFilter.render(text).visibleText]
  }

  private func listen(_ options: [String: Any], id: String) async throws -> Any {
    let policy = SpeechTranscriptionPolicy()
    policy.configure(settings())
    if let provider = options["provider"] as? String {
      if provider == "system" {
        policy.providerEndpoint = nil
      } else {
        let selected = try endpoint(provider)
        guard selected.kind == .openAICompatible else {
          throw WebXDCAPIError(
            code: "NotSupportedError", message: "This provider does not support transcription.")
        }
        policy.providerEndpoint = selected
      }
    }
    if policy.providerEndpoint != nil && policy.isOffline {
      throw WebXDCAPIError(
        code: "NotSupportedError", message: "Provider transcription is unavailable offline.")
    }
    if let model = options["model"] as? String { policy.providerModel = model }
    var configuration = settings().conversation
    if let language = options["language"] as? String {
      configuration.speechRecognitionLanguageIdentifier = language
    }
    if let silence = options["silenceSeconds"] as? Double, silence.isFinite {
      configuration.silenceTimeoutSeconds = ConversationSettings.clampedSilenceTimeout(silence)
    }
    if let backend = options["backend"] as? String {
      switch backend {
      case "file": configuration.speechRecognitionBackend = .nativeIOS
      case "live": configuration.speechRecognitionBackend = .nativeIOSSpeechTranscriber
      default:
        throw WebXDCAPIError(code: "TypeError", message: "Use transcription backend file or live.")
      }
    }
    let engine = try recognitionEngine(configuration, policy)
    self.engine = engine
    defer {
      engine.stop()
      self.engine = nil
      finishListening = nil
      if let filename = engine.recordingFilename,
        let url = PocketMaiDirectories.voiceRecordingURL(filename: filename)
      {
        try? FileManager.default.removeItem(at: url)
      }
    }
    let (events, continuation) = AsyncThrowingStream<LiveSpeechRecognitionEvent, Error>.makeStream()
    engine.onTranscript = { [weak self] event in
      guard let self, tasks[id] != nil, !cancelledRequests.contains(id) else { return }
      emit([
        "id": id, "event": "transcript", "text": event.text, "isFinal": event.isFinal,
        "language": event.languageIdentifier,
      ])
      if event.isFinal {
        continuation.yield(event)
        continuation.finish()
      }
    }
    engine.onError = { continuation.finish(throwing: $0) }
    finishListening = {
      do {
        if let event = try await engine.finalize() {
          continuation.yield(event)
          continuation.finish()
        } else {
          continuation.finish(
            throwing: WebXDCAPIError(code: "OperationError", message: "No speech detected."))
        }
      } catch { continuation.finish(throwing: error) }
    }
    try await engine.start()
    try Task.checkCancellation()
    // Bound unattended microphone use, including silence and live recognition.
    let seconds = min(
      120, max(1, (options["maxSeconds"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 30))
    let timer = Task {
      do {
        try await Task.sleep(for: .seconds(seconds))
        if let event = try await engine.finalize() {
          continuation.yield(event)
          continuation.finish()
        } else {
          continuation.finish(
            throwing: WebXDCAPIError(code: "OperationError", message: "No speech detected."))
        }
      } catch { continuation.finish(throwing: error) }
    }
    defer {
      timer.cancel()
      continuation.finish()
    }
    for try await event in events {
      return ["text": event.text, "language": event.languageIdentifier]
    }
    throw CancellationError()
  }

  private func speak(_ options: [String: Any]) async throws -> Any {
    guard let text = options["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      text.utf8.count <= 32_000
    else {
      throw WebXDCAPIError(code: "TypeError", message: "Supply nonempty speech text up to 32 KB.")
    }
    var voice = settings().toolSettings.voices.assistant
    if let provider = options["provider"] as? String {
      if provider == "system" {
        voice.provider = .system
      } else {
        voice.provider = .openAICompatible
        voice.openAIEndpointID = try endpoint(provider, speech: true).id
      }
    }
    if voice.provider == .openAICompatible {
      guard let id = voice.openAIEndpointID else {
        throw WebXDCAPIError(code: "NotFoundError", message: "Select a speech provider.")
      }
      _ = try endpoint(id.uuidString, speech: true)
    }
    if let identifier = options["voice"] as? String {
      voice.voiceIdentifier = identifier
      voice.openAIVoice = identifier
    }
    if let language = options["language"] as? String { voice.language = language }
    if let rate = options["rate"] as? Double, rate.isFinite { voice.rate = min(1, max(0, rate)) }
    if let pitch = options["pitch"] as? Double, pitch.isFinite {
      voice.pitch = min(2, max(0.5, pitch))
    }
    var endpoints = settings().openAIEndpoints
    if let model = options["model"] as? String,
      let index = endpoints.firstIndex(where: { $0.id == voice.openAIEndpointID })
    {
      endpoints[index].speechModel = model
    }
    guard !TTSSpeechTextSanitizer.sanitized(text, skipTechnicalContent: true).isEmpty else {
      throw WebXDCAPIError(code: "TypeError", message: "Text contains no speakable content.")
    }
    defer { player.stop() }
    player.speak(
      text: text, voice: voice, role: .assistant, openAIEndpoints: endpoints)
    while player.isSpeaking {
      try await Task.sleep(for: .milliseconds(40))
    }
    try Task.checkCancellation()
    if let error = player.errorMessage {
      throw WebXDCAPIError(code: "OperationError", message: error)
    }
    return ["spoken": true]
  }
}

/// This namespace is a PocketMai extension, never a webxdc standard API.
enum WebXDCPocketMaiBridge {
  static let script = #"""
    (function () {
      if (window.top !== window || location.protocol !== 'xdc:' || !window.webxdc) return;
      const pending = new Map();
      let sequence = 0;
      const prefix = Date.now().toString(36) + Math.random().toString(36).slice(2);
      function post(message) { window.webkit.messageHandlers.pocketmai.postMessage(message); }
      function error(code, message) { const e = new Error(message); e.name = code; return e; }
      window.__pocketmaiReply = function (reply) {
        const request = pending.get(reply.id);
        if (!request) return;
        if (reply.event) {
          if (request.onUpdate) {
            try { request.onUpdate(reply); } catch (e) { console.error(e); }
          }
          return;
        }
        pending.delete(reply.id);
        request.cleanup();
        if (reply.error) request.reject(error(reply.error.code, reply.error.message));
        else request.resolve(reply.result);
      };
      function call(method, options = {}) {
        const { signal, onUpdate, ...values } = options;
        const id = prefix + ':' + (++sequence);
        let abort;
        const promise = new Promise((resolve, reject) => {
          if (signal && signal.aborted) { reject(error('AbortError', 'Request cancelled.')); return; }
          abort = function () {
            const request = pending.get(id);
            if (!request) return;
            pending.delete(id);
            request.cleanup();
            try { post({id, method: 'cancel'}); } catch (_) {}
            reject(error('AbortError', 'Request cancelled.'));
          };
          pending.set(id, {resolve, reject, onUpdate,
            cleanup() { if (signal) signal.removeEventListener('abort', abort); }});
          if (signal) signal.addEventListener('abort', abort, {once: true});
          try { post({id, method, options: JSON.parse(JSON.stringify(values))}); }
          catch (e) { pending.delete(id); if (signal) signal.removeEventListener('abort', abort); reject(e); }
        });
        promise.cancel = () => { if (abort) abort(); };
        if (method === 'listen') promise.finish = () => { if (pending.has(id)) post({id, method: 'finishListening'}); };
        return promise;
      }
      window.addEventListener('pagehide', () => {
        for (const [id, request] of pending) {
          try { post({id, method: 'cancel'}); } catch (_) {}
          request.cleanup(); request.reject(error('AbortError', 'Page closed.'));
        }
        pending.clear();
      });
      window.webxdc.pocketmai = Object.freeze({
        host: 'pocketmai', version: 1,
        capabilities: options => call('capabilities', options),
        providers: options => call('providers', options),
        models: options => call('models', options),
        voices: options => call('voices', options),
        languages: options => call('languages', options),
        complete: options => call('complete', options),
        listen: options => call('listen', options),
        speak: options => call('speak', options)
      });
    })();
    """#
}
