import Foundation
import MaiCore

#if canImport(FoundationModels)
  import FoundationModels
#endif

public enum AppleProviderAvailabilityKind: Equatable, Sendable {
  case checking, available, deviceNotEligible, appleIntelligenceNotEnabled, modelNotReady, unavailable
}

public struct AppleProviderAvailability: Equatable, Sendable {
  public let kind: AppleProviderAvailabilityKind
  public let detail: String
  public init(kind: AppleProviderAvailabilityKind, detail: String) {
    self.kind = kind
    self.detail = detail
  }
  public var isAvailable: Bool { kind == .available }
  public var unavailableMessage: String? {
    kind == .available || kind == .checking ? nil : detail
  }
}

public struct AppleProvider: ChatProvider {
  public static let modelID = "on-device"
  public let descriptor: ProviderDescriptor
  private let deviceOnly: Bool

  public init(id: ProviderID = "apple", displayName: String? = nil, deviceOnly: Bool = false) {
    self.deviceOnly = deviceOnly
    descriptor = .init(
      id: id, displayName: displayName ?? "Apple Intelligence",
      capabilities: [.streaming], defaultModel: Self.modelID)
  }

  public static var unavailabilityMessage: String? { availabilityReport().unavailableMessage }

  public static func availabilityReport(deviceOnly: Bool = false) -> AppleProviderAvailability {
    #if canImport(FoundationModels)
      if #available(macOS 26.0, iOS 26.0, *) {
        switch systemModel(deviceOnly: deviceOnly).availability {
        case .available:
          return .init(kind: .available, detail: "Apple Intelligence is supported and enabled.")
        case .unavailable(.appleIntelligenceNotEnabled):
          return .init(kind: .appleIntelligenceNotEnabled, detail: "Enable Apple Intelligence in " + settingsLocation + ".")
        case .unavailable(.deviceNotEligible):
          return .init(kind: .deviceNotEligible, detail: "Apple Intelligence requires a supported Apple silicon Mac, iPhone, or iPad.")
        case .unavailable(.modelNotReady):
          return .init(kind: .modelNotReady, detail: "Apple Intelligence is downloading its model. Keep the device online and wait for it to finish in " + settingsLocation + ".")
        default:
          return .init(kind: .unavailable, detail: "Apple Intelligence is unavailable. Check the device's language, region, and settings in " + settingsLocation + ".")
        }
      }
    #endif
    return .init(kind: .unavailable, detail: "Apple Foundation Models require macOS 26 or iOS 26 or later, and a build made with a matching SDK.")
  }

  private static var settingsLocation: String {
    #if os(macOS)
      "System Settings > Apple Intelligence & Siri"
    #else
      "Settings > Apple Intelligence & Siri"
    #endif
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    if let reason = Self.availabilityReport(deviceOnly: deviceOnly).unavailableMessage {
      throw LocalProviderError(reason)
    }
    return [.init(id: Self.modelID, displayName: "Apple on-device model", capabilities: [.streaming])]
  }

  public func complete(
    _ request: ProviderRequest, emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    guard request.model.isEmpty || request.model == Self.modelID else {
      throw LocalProviderError("Apple Intelligence uses the on-device model. Select /model \(descriptor.id)::\(Self.modelID).")
    }
    let input = AppleConversationInput(
      instructions: "", messages: try LocalProviderInput.messages(request.messages))
    return try await complete(input: input, options: request.options, stream: request.stream, emit: emit)
  }

  /// Both hosts supply their own conversation policy; native generation and overflow recovery are shared.
  public func complete(
    input originalInput: AppleConversationInput, options: MaiCore.GenerationOptions = .init(),
    stream: Bool = true, emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    if let reason = Self.availabilityReport(deviceOnly: deviceOnly).unavailableMessage {
      throw LocalProviderError(reason)
    }
    #if canImport(FoundationModels)
      if #available(macOS 26.0, iOS 26.0, *) {
        var input = originalInput
        guard !input.prompt.isEmpty else { throw LocalProviderError("Apple Intelligence needs a text prompt.") }
        let model = Self.systemModel(deviceOnly: deviceOnly)
        var maximumResponseTokens = options.maxOutputTokens ?? 1_200
        #if PMAI_FOUNDATION_MODELS_26_4
          if #available(macOS 26.4, iOS 26.4, *) {
            let available = try? await input.trimToFit(
              contextSize: model.contextSize, reservingTokens: maximumResponseTokens
            ) { input in
              let entries = Array(Self.transcript(for: input)) + [
                Transcript.Entry.prompt(.init(segments: [.text(.init(content: input.prompt))]))
              ]
              return try await model.tokenCount(for: entries)
            }
            if let available {
              guard available > 0 else {
                throw LocalProviderError("Apple Intelligence context is full even without older history. Shorten the current request, context, or tool results.")
              }
              maximumResponseTokens = min(maximumResponseTokens, available)
            }
          }
        #endif
        let generationOptions = FoundationModels.GenerationOptions(
          temperature: options.temperature, maximumResponseTokens: maximumResponseTokens)
        var attempts = 0
        while true {
          try Task.checkCancellation()
          do {
            let session = LanguageModelSession(model: model, transcript: Self.transcript(for: input))
            let response: LanguageModelSession.Response<String>
            if stream {
              var previous = ""
              let responses = session.streamResponse(to: input.prompt, options: generationOptions)
              for try await partial in responses {
                try Task.checkCancellation()
                if partial.content.hasPrefix(previous) {
                  let delta = String(partial.content.dropFirst(previous.count))
                  if !delta.isEmpty { await emit(.textDelta(delta)) }
                }
                previous = partial.content
              }
              response = try await responses.collect()
            } else {
              response = try await session.respond(to: input.prompt, options: generationOptions)
            }
            let usage = Self.usage(of: response)
            if let usage { await emit(.usage(usage)) }
            return .init(message: .assistant(response.content), usage: usage, stopReason: .stop)
          } catch {
            guard attempts < 3, Self.isContextOverflowError(error),
              input.trimForRetry(lastAttempt: attempts == 2) else { throw error }
            attempts += 1
          }
        }
      }
    #endif
    throw LocalProviderError(Self.unavailabilityMessage ?? "Apple Intelligence is unavailable.")
  }

  public func completeSuggestions(prompt: String, count: Int) async throws -> ProviderResponse {
    if let reason = Self.availabilityReport(deviceOnly: deviceOnly).unavailableMessage {
      throw LocalProviderError(reason)
    }
    #if canImport(FoundationModels)
      if #available(macOS 26.0, iOS 26.0, *) {
        let items = DynamicGenerationSchema(type: String.self, guides: [])
        let options = DynamicGenerationSchema(arrayOf: items, minimumElements: count, maximumElements: count)
        let root = DynamicGenerationSchema(
          name: "FollowUpSuggestions", description: "Short messages the user can send next.",
          properties: [.init(name: "options", description: "Distinct follow-up messages written in the user's voice.", schema: options)])
        let schema = try GenerationSchema(root: root, dependencies: [])
        let session = LanguageModelSession(
          model: Self.systemModel(deviceOnly: deviceOnly),
          instructions: "Generate only the requested follow-up suggestions. Keep them concise and distinct.")
        let response = try await session.respond(to: prompt, schema: schema, options: .init(maximumResponseTokens: 240))
        return .init(message: .assistant(response.content.jsonString), usage: Self.usage(of: response), stopReason: .stop)
      }
    #endif
    throw LocalProviderError(Self.unavailabilityMessage ?? "Apple Intelligence is unavailable.")
  }

  #if canImport(FoundationModels)
    @available(macOS 26.0, iOS 26.0, *)
    private static func systemModel(deviceOnly: Bool) -> SystemLanguageModel {
      deviceOnly ? SystemLanguageModel(useCase: .general, guardrails: .default) : .default
    }

    @available(macOS 26.0, iOS 26.0, *)
    public static func transcript(for input: AppleConversationInput) -> Transcript {
      Transcript(entries: input.messages.dropLast(input.prompt.isEmpty ? 0 : 1).map { message in
        let segments: [Transcript.Segment] = [.text(.init(content: message.text))]
        switch message.role {
        case .system, .developer: return .instructions(.init(segments: segments, toolDefinitions: []))
        case .assistant: return .response(.init(assetIDs: [], segments: segments))
        case .user, .tool: return .prompt(.init(segments: segments))
        }
      })
    }

    @available(macOS 26.0, iOS 26.0, *)
    private static func usage<Content: Generable>(of response: LanguageModelSession.Response<Content>) -> TokenUsage? {
      #if PMAI_FOUNDATION_MODELS_27
        if #available(macOS 27.0, iOS 27.0, *) { return tokenUsage(response.usage) }
      #endif
      return nil
    }

    #if PMAI_FOUNDATION_MODELS_27
      @available(macOS 27.0, iOS 27.0, *)
      public static func tokenUsage(_ usage: LanguageModelSession.Usage) -> TokenUsage {
        .init(inputTokens: usage.input.totalTokenCount, outputTokens: usage.output.totalTokenCount,
              cachedTokens: usage.input.cachedTokenCount, reasoningTokens: usage.output.reasoningTokenCount)
      }
    #endif
  #endif

  public static func isContextOverflowError(_ error: Error) -> Bool {
    #if canImport(FoundationModels)
      #if PMAI_FOUNDATION_MODELS_27
        if #available(macOS 27.0, iOS 27.0, *), let error = error as? LanguageModelError,
          case .contextSizeExceeded = error { return true }
      #endif
      if #available(macOS 26.0, iOS 26.0, *), let error = error as? LanguageModelSession.GenerationError,
        case .exceededContextWindowSize = error { return true }
    #endif
    return false
  }
}
