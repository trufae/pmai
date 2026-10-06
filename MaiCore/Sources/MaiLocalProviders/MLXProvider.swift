import Foundation
import MaiCore

#if canImport(MLX)
  import Metal
  import MLX
  import MLXLLM
  import MLXLMCommon
  import MLXLMHFAPI
  import MLXLMTokenizers
#endif

public actor MLXProvider: ChatProvider {
  public static let defaultModelID = MLXModels.defaultModelID
  public nonisolated let descriptor: ProviderDescriptor
  private let configuration: ConfiguredProvider
  #if canImport(MLX)
    private var container: ModelContainer?
    private var loadedModel: String?
    private var generationTail: Task<Void, Never>?
    private let downloader: (any Downloader)?
    private let availability: MLXAvailability
  #endif

  public init(configuration: ConfiguredProvider) {
    self.configuration = configuration
    descriptor = .init(
      id: ProviderID(configuration.id), displayName: configuration.displayName ?? "MLX Local",
      capabilities: [.streaming, .reasoning],
      defaultModel: configuration.defaultModel ?? Self.defaultModelID)
    #if canImport(MLX)
      downloader = nil
      availability = .current
    #endif
  }

  #if canImport(MLX)
    public init(
      configuration: ConfiguredProvider = .init(id: "mlx", kind: .mlx),
      downloader: any Downloader, availability: MLXAvailability = .current
    ) {
      self.configuration = configuration
      self.downloader = downloader
      self.availability = availability
      descriptor = .init(
        id: ProviderID(configuration.id), displayName: configuration.displayName ?? "MLX Local",
        capabilities: [.streaming, .reasoning], defaultModel: configuration.defaultModel ?? Self.defaultModelID)
    }

    public func load(
      modelID: String, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
      try await serialized {
        try await self.loadModel(modelID: modelID, progressHandler: progressHandler)
      }
    }

    private func loadModel(
      modelID: String, progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws {
      if let reason = availability.unavailableReason { throw LocalProviderError(reason) }
      try Task.checkCancellation()
      guard loadedModel != modelID else { return }
      container = nil
      loadedModel = nil
      let loaded: ModelContainer
      if modelID.hasPrefix("/") || modelID.hasPrefix("~") || modelID.hasPrefix(".") {
        let directory = URL(fileURLWithPath: (modelID as NSString).expandingTildeInPath)
        loaded = try await LLMModelFactory.shared.loadContainer(from: directory, using: TokenizersLoader())
      } else {
        guard MLXModels.isValid(modelID) else {
          throw LocalProviderError("Use an MLX-ready Hugging Face model ID (org/model) or a local model directory.")
        }
        let effectiveDownloader: any Downloader
        if let downloader { effectiveDownloader = downloader }
        else if let key = try configuration.resolvedAPIKey(environment: ProcessInfo.processInfo.environment) {
          effectiveDownloader = HubClient(host: HubClient.defaultHost, bearerToken: key)
        } else { effectiveDownloader = HubClient.default }
        loaded = try await LLMModelFactory.shared.loadContainer(
          from: effectiveDownloader, using: TokenizersLoader(), configuration: .init(id: modelID),
          progressHandler: progressHandler)
      }
      try Task.checkCancellation()
      container = loaded
      loadedModel = modelID
    }

    public func unload(modelID: String) async {
      try? await serialized { await self.unloadModel(modelID: modelID) }
    }

    private func unloadModel(modelID: String) {
      guard loadedModel == modelID else { return }
      container = nil
      loadedModel = nil
    }
  #endif

  public static var unavailabilityMessage: String? {
    #if os(iOS) || (os(macOS) && arch(arm64))
      #if canImport(MLX)
        return MLXAvailability.current.unavailableReason
      #else
        return "This pmai build does not include MLX. Rebuild with make repl-install and PMAI_NO_MLX unset."
      #endif
    #else
      return "MLX requires macOS on Apple silicon."
    #endif
  }

  public func availableModels() async throws -> [ModelDescriptor] {
    if let reason = Self.unavailabilityMessage { throw LocalProviderError(reason) }
    let models = [descriptor.defaultModel ?? Self.defaultModelID] + MLXModels.presets
    var seen: Set<String> = []
    return models.filter { seen.insert($0).inserted }.map {
      .init(id: $0, capabilities: descriptor.capabilities)
    }
  }

  public func complete(
    _ request: ProviderRequest, emit: @escaping ProviderEventHandler
  ) async throws -> ProviderResponse {
    if let reason = Self.unavailabilityMessage { throw LocalProviderError(reason) }
    #if canImport(MLX)
      return try await complete(request, emit: emit, onGenerationInfo: { _ in })
    #else
      throw LocalProviderError(Self.unavailabilityMessage ?? "MLX is unavailable.")
    #endif
  }

  #if canImport(MLX)
    public func complete(
      _ request: ProviderRequest, emit: @escaping ProviderEventHandler,
      onGenerationInfo: @Sendable @escaping (GenerateCompletionInfo) async -> Void
    ) async throws -> ProviderResponse {
      if let reason = availability.unavailableReason { throw LocalProviderError(reason) }
      return try await serialized {
        try await self.generate(request, emit: emit, onGenerationInfo: onGenerationInfo)
      }
    }
  #endif

  #if canImport(MLX)
    /// Model loads, settings preloads, unloading, and agent generation share one queue.
    private func serialized<Value: Sendable>(
      _ operation: @Sendable @escaping () async throws -> Value
    ) async throws -> Value {
      let previous = generationTail
      let job = Task {
        await previous?.value
        try Task.checkCancellation()
        return try await operation()
      }
      generationTail = Task { _ = try? await job.value }
      return try await withTaskCancellationHandler {
        try await job.value
      } onCancel: { job.cancel() }
    }

    private func generate(
      _ request: ProviderRequest, emit: @escaping ProviderEventHandler,
      onGenerationInfo: @Sendable @escaping (GenerateCompletionInfo) async -> Void
    ) async throws -> ProviderResponse {
      #if os(macOS)
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let library = executable.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: library.path) else {
          throw LocalProviderError("MLX Metal shaders are missing beside pmai. Run make repl-build or reinstall the macOS arm64 release, including mlx.metallib.")
        }
        _ = try MTLCreateSystemDefaultDevice()?.makeLibrary(URL: library)
      #endif
      let model = request.model.isEmpty ? descriptor.defaultModel! : request.model
      try await loadModel(modelID: model)
      guard let container else { throw LocalProviderError("MLX model did not finish loading.") }
      let messages = try LocalProviderInput.messages(request.messages).map { message -> Chat.Message in
        switch message.role {
        case .system, .developer: return .system(message.text)
        case .assistant: return .assistant(message.text)
        case .user: return .user(message.text)
        case .tool: return .user("Host tool results:\n" + message.text)
        }
      }
      let maxTokens = request.options.maxOutputTokens ?? 1_200
      let maxKVSize = request.options.additional["mlxMaxKVSize"]?.intValue
        ?? configuration.options["maxKVSize"]?.intValue ?? 32_768
      guard maxTokens > 0, maxKVSize > 512 else {
        throw LocalProviderError("MLX output tokens must be positive and maxKVSize must exceed 512 tokens.")
      }
      let parameters = GenerateParameters(
        maxTokens: maxTokens, maxKVSize: maxKVSize,
        temperature: Float(request.options.temperature ?? 0.7))
      let (stream, generationTask) = try await container.perform(
        nonSendable: UserInput(
          chat: messages, tools: Self.toolSpecs(request.tools),
          additionalContext: request.options.reasoningEffort.flatMap(ReasoningEffort.init(name:))?
            .templateContext(model: model))
      ) { context, userInput in
        let input = try await context.processor.prepare(input: userInput)
        guard input.text.tokens.size + min(maxTokens, 512) <= maxKVSize else {
          throw LocalProviderError("MLX context length exceeded. Compact the conversation or shorten the prompt.")
        }
        let iterator = try TokenIterator(input: input, model: context.model, parameters: parameters)
        return MLXLMCommon.generateTask(
          promptTokenCount: input.text.tokens.size, modelConfiguration: context.configuration,
          tokenizer: context.tokenizer, iterator: iterator, tools: Self.toolSpecs(request.tools))
      }
      return try await withTaskCancellationHandler {
        var reasoning = ReasoningStream()
        var usage: TokenUsage?
        var toolCalls: [ContentPart] = []
        func emitParts(_ parts: [ContentPart]) async {
          guard request.stream else { return }
          for part in parts {
            switch part {
            case .text(let text): await emit(.textDelta(text))
            case .reasoning(let text): await emit(.reasoningDelta(text))
            default: break
            }
          }
        }
        do {
          for await event in stream {
            try Task.checkCancellation()
            switch event {
            case .chunk(let text): await emitParts(reasoning.append(text))
            case .info(let info):
              usage = .init(inputTokens: info.promptTokenCount, outputTokens: info.generationTokenCount)
              await onGenerationInfo(info)
            case .toolCall(let call):
              await emitParts(reasoning.flush())
              let arguments = JSONValue(json: call.function.arguments.mapValues { $0.anyValue })
              let toolCall = MaiCore.ToolCall(
                id: UUID().uuidString, name: call.function.name, arguments: arguments)
              toolCalls.append(.toolCall(toolCall))
            }
          }
          await emitParts(reasoning.flush())
          await generationTask.value
          try Task.checkCancellation()
          if let usage { await emit(.usage(usage)) }
          return .init(
            message: .init(role: .assistant, content: reasoning.parts + toolCalls), usage: usage,
            stopReason: !toolCalls.isEmpty ? .toolCall
              : (usage?.outputTokens ?? 0) >= maxTokens ? .length : .stop)
        } catch {
          generationTask.cancel()
          await generationTask.value
          throw error
        }
      } onCancel: { generationTask.cancel() }
    }

    private static func toolSpecs(_ tools: [ToolDefinition]) -> [ToolSpec]? {
      guard !tools.isEmpty else { return nil }
      return tools.map { tool in
        let properties: [String: any Sendable] = Dictionary(uniqueKeysWithValues: tool.parameters.map {
          ($0.name, ["type": $0.type, "description": $0.description] as [String: any Sendable])
        })
        return ["type": "function", "function": [
          "name": tool.providerName ?? tool.name, "description": tool.description,
          "parameters": ["type": "object", "properties": properties,
                         "required": tool.parameters.filter(\.required).map(\.name)] as [String: any Sendable]
        ] as [String: any Sendable]]
      }
    }
  #endif
}
