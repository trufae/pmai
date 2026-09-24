import Foundation
import MaiCore
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

enum LocalMLXModels {
  static let presets = [
    AppSettings.localMLXDefaultModelID,
    "mlx-community/LFM2-350M-MLX",
    "mlx-community/LFM2-2.6B-4bit",
    "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
    "Irfanuruchi/SmolLM2-135M-Instruct-MLX-4bit",
    "mlx-community/Qwen2.5-1.5B-Instruct-4bit",
    "Irfanuruchi/SmolLM2-360M-Instruct-MLX-4bit",
    "mlx-community/Llama-3.2-1B-Instruct-4bit",
    "mlx-community/MiniCPM5-1B-4bit",
    "mlx-community/Qwen3-0.6B-4bit",
    "mlx-community/gemma-3-1b-it-4bit",
    "mlx-community/Jan-v3-4B-base-instruct-4bit",
  ]
}

enum LocalMLXError: LocalizedError {
  case unavailable(LocalMLXAvailability)
  case invalidModelID(String)
  case modelNotDownloaded(String)
  case noDownloadedModels
  case noModelSelected
  case emptyPrompt
  case contextLengthExceeded(tokenCount: Int)

  var errorDescription: String? {
    switch self {
    case .unavailable(let availability):
      return availability.unavailabilityMessage
    case .invalidModelID(let id):
      if id.isEmpty {
        return "Enter a Hugging Face repo id in the form org/model-name."
      }
      return
        "Invalid MLX model id: \(id). Use a Hugging Face repo id in the form org/model-name, not a URL or local path."
    case .modelNotDownloaded(let id):
      return
        "\(id) is not downloaded. Download it in Settings > Providers > Local MLX LLM "
        + "before using MLX."
    case .noDownloadedModels:
      return "Download an MLX model in Settings > Providers > Local MLX LLM before using MLX."
    case .noModelSelected:
      return "Choose a downloaded MLX model before using MLX."
    case .emptyPrompt:
      return "Enter a prompt before generating."
    case .contextLengthExceeded(let count):
      return
        "MLX context length exceeded: the prompt is \(count) tokens. "
        + "Reduce the context window size in Settings or start a shorter conversation."
    }
  }
}

enum LocalMLXRepoIDValidator {
  private static let allowed = CharacterSet(
    charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"
  )

  static func isValid(_ repoID: String) -> Bool {
    let parts = repoID.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return false }
    return parts.allSatisfy { part in
      isValidRepoComponent(String(part))
    }
  }

  private static func isValidRepoComponent(_ component: String) -> Bool {
    guard !component.isEmpty, component.count <= 96 else { return false }
    guard component.rangeOfCharacter(from: allowed.inverted) == nil else { return false }
    guard !component.hasPrefix("."), !component.hasPrefix("-") else { return false }
    guard !component.hasSuffix("."), !component.hasSuffix("-") else { return false }
    guard !component.contains(".."), !component.contains("--") else { return false }
    return true
  }
}

actor LocalMLXProvider {
  static let shared = LocalMLXProvider()

  private var container: ModelContainer?
  private var loadedModelID: String?
  private let downloader: any Downloader
  private let availability: LocalMLXAvailability

  init(
    downloader: any Downloader = LocalMLXImmediateCancelDownloader(),
    availability: LocalMLXAvailability = .current
  ) {
    self.downloader = downloader
    self.availability = availability
  }

  // Minimum headroom reserved for output tokens within the KV window.
  private static let outputHeadroom = 512

  func load(
    modelID rawModelID: String,
    allowDownload: Bool = false,
    progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
  ) async throws {
    guard availability.isAvailable else { throw LocalMLXError.unavailable(availability) }
    let modelID = Self.normalizedModelID(rawModelID)
    guard !modelID.isEmpty else {
      throw LocalMLXError.noModelSelected
    }
    guard LocalMLXRepoIDValidator.isValid(modelID) else {
      throw LocalMLXError.invalidModelID(modelID)
    }
    let wasCachedBeforeLoad = LocalMLXModelCache.containsRepository(modelID)
    // Chat loads existing models; only an explicit Settings action may fetch a new one.
    guard wasCachedBeforeLoad || allowDownload else {
      throw LocalMLXError.modelNotDownloaded(modelID)
    }

    if container != nil, loadedModelID == modelID {
      return
    }

    do {
      try Task.checkCancellation()
      let config = ModelConfiguration(id: modelID)
      let loadedContainer = try await loadModelContainer(
        // Settings downloads into LocalMLXHub's app-owned cache. Using the
        // default HubClient here selected a different cache and could make a
        // supposedly downloaded model fetch its files again before chat.
        from: downloader,
        using: TokenizersLoader(),
        configuration: config,
        progressHandler: progressHandler
      )
      try Task.checkCancellation()
      container = loadedContainer
      loadedModelID = modelID
    } catch {
      if !wasCachedBeforeLoad {
        try? LocalMLXModelCache.deleteRepository(modelID)
      }
      throw error
    }
  }

  func unload(modelID: String) {
      guard loadedModelID == LocalMLXProvider.normalizedModelID(modelID) else { return }
    container = nil
    loadedModelID = nil
  }

  func complete(
    request: ChatCompletionRequest,
    onUpdate: @escaping @MainActor (String) -> Void
  ) async throws -> String {
    guard availability.isAvailable else { throw LocalMLXError.unavailable(availability) }
    let modelID = Self.effectiveModelID(
      conversation: request.conversation,
      settings: request.settings
    )
    guard !modelID.isEmpty else {
      let error: LocalMLXError =
        LocalMLXModelCache.listRepositoryIDs().isEmpty ? .noDownloadedModels : .noModelSelected
      throw error
    }
    guard LocalMLXRepoIDValidator.isValid(modelID) else {
      throw LocalMLXError.invalidModelID(modelID)
    }

    try await load(modelID: modelID)
    guard let container else {
      throw ChatProviderError.providerRequestFailed("MLX model did not finish loading.")
    }

    let messages = Self.chatMessages(
      conversation: request.conversation,
      settings: request.settings,
      context: request.context,
      toolPrompt: request.nativeTools == nil ? request.toolPrompt : "",
      toolPromptInContext: request.toolPromptInContext,
      messageLimitOverride: request.messageLimitOverride
    )
    guard messages.contains(where: { $0.role == .user }) else {
      throw LocalMLXError.emptyPrompt
    }

    let maxKVSize = (request.conversation.mlxMaxKVSize ?? request.settings.mlxMaxKVSize).effectiveSize
    let promptTokenLimit = maxKVSize - Self.outputHeadroom
    let temperature: Float = request.hasToolCalling ? 0.2 : 0.7
    let parameters = GenerateParameters(
      maxTokens: 1_200, maxKVSize: maxKVSize, temperature: temperature)

    // Keep the generation task for the whole request rather than using the
    // convenience stream API, which hides it. Preparing the input and building
    // the iterator inside ModelContainer's serialized access also keeps all
    // MLX state on its owner.
    let (stream, generationTask, promptTokenCount) = try await container.perform(
      nonSendable: UserInput(
        chat: messages, tools: Self.mlxToolSpecs(from: request.nativeTools),
        additionalContext: request.conversation.reasoningLevel.templateContext(
          model: modelID))
    ) { context, userInput in
      let input = try await context.processor.prepare(input: userInput)
      let promptTokenCount = input.text.tokens.size
      if promptTokenCount > promptTokenLimit {
        throw LocalMLXError.contextLengthExceeded(tokenCount: promptTokenCount)
      }
      let iterator = try TokenIterator(
        input: input, model: context.model, parameters: parameters)
      let (stream, task) = MLXLMCommon.generateTask(
        promptTokenCount: promptTokenCount,
        modelConfiguration: context.configuration,
        tokenizer: context.tokenizer,
        iterator: iterator,
        tools: Self.mlxToolSpecs(from: request.nativeTools)
      )
      return (stream, task, promptTokenCount)
    }

    let requestStart = Date()
    var reasoning = ReasoningStream()
    var rendered = ReasoningText()
    var completionInfo: GenerateCompletionInfo?
    for await generation in stream {
      try Task.checkCancellation()
      switch generation {
      case .chunk(let text):
        for part in reasoning.append(text) { rendered.append(part) }
        if request.conversation.usesStreaming {
          await onUpdate(rendered.rendered)
        }
      case .info(let info):
        completionInfo = info
      case .toolCall(let toolCall):
        for part in reasoning.flush() { rendered.append(part) }
        rendered.append(.text("\n\n" + Self.toolCallTextBlock(toolCall)))
        if request.conversation.usesStreaming {
          await onUpdate(rendered.rendered)
        }
      }
    }
    // In particular, wait if iteration was stopped by cancellation or a stream
    // consumer change before the producer completed its MLX work.
    await generationTask.value
    for part in reasoning.flush() { rendered.append(part) }
    let output = rendered.rendered

    if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      throw ChatProviderError.emptyResponse
    }
    let stats: GenerationStats
    if let info = completionInfo {
      stats = GenerationStats(
        providerLabel: "MLX",
        modelID: modelID,
        inputTokens: info.promptTokenCount,
        userInputTokens: request.userInputTokens,
        outputTokens: info.generationTokenCount,
        receivedTextTokens: GenerationStats.estimatedTokenCount(forCharacterCount: output.count),
        promptSeconds: info.promptTime,
        generationSeconds: info.generateTime,
        // Prompt evaluation is what stands between the request and the first
        // token for on-device generation.
        firstTokenSeconds: info.promptTime)
    } else {
      stats = GenerationStats(
        providerLabel: "MLX",
        modelID: modelID,
        inputTokens: promptTokenCount,
        userInputTokens: request.userInputTokens,
        outputTokens: GenerationStats.estimatedTokenCount(forCharacterCount: output.count),
        receivedTextTokens: GenerationStats.estimatedTokenCount(forCharacterCount: output.count),
        promptSeconds: 0,
        generationSeconds: max(0, Date().timeIntervalSince(requestStart)),
        tokensEstimated: true)
    }
    await UsageStatsStore.record(stats, assistantMessageID: request.assistantMessageID)
    await onUpdate(output)
    return output
  }

  static func effectiveModelID(conversation: Conversation, settings: AppSettings) -> String {
    let model = normalizedModelID(conversation.modelID)
    if !model.isEmpty { return model }
    let defaultModel = normalizedModelID(settings.localMLXModelID)
    return LocalMLXModelCache.containsRepository(defaultModel) ? defaultModel : ""
  }

  static func message(for error: Error, action: String, modelID: String) -> String {
    if let localError = error as? LocalMLXError {
      return localError.localizedDescription
    }

    if let factoryError = error as? ModelFactoryError {
      switch factoryError {
      case .unsupportedModelType:
        return
          "PocketMai cannot run the model architecture used by \(modelID). Choose a preset MLX model in Settings > Providers > Local MLX LLM, or update PocketMai for newer model support."
      case .noModelFactoryAvailable:
        return "MLX model support is missing from this build. Update PocketMai or choose another provider."
      case .configurationFileError, .configurationDecodingError, .invalidConfiguration,
        .unsupportedProcessorType:
        return
          "Unsupported MLX model configuration for \(modelID): \(factoryError.localizedDescription)"
      }
    }

    let nsError = error as NSError
    let detail = error.localizedDescription
    let lowercasedDetail = detail.lowercased()

    if nsError.domain == NSURLErrorDomain || error is URLError
      || lowercasedDetail.contains("network")
      || lowercasedDetail.contains("timed out")
      || lowercasedDetail.contains("could not connect")
    {
      return "Download failed for \(modelID): \(detail) Check your connection and available storage, then retry."
    }

    if lowercasedDetail.contains("out of memory")
      || lowercasedDetail.contains("memory allocation")
      || lowercasedDetail.contains("failed to allocate")
      || lowercasedDetail.contains("resource exhausted")
    {
      return "Not enough memory to run \(modelID). Try a smaller 4-bit model such as Qwen2.5-0.5B, "
        + "reduce MLX KV Cache in Settings, or use a remote provider. Download size is smaller than the memory needed to run a model."
    }

    if lowercasedDetail.contains("not found")
      || lowercasedDetail.contains("404")
      || lowercasedDetail.contains("repository")
    {
      return
        "Invalid model id or unavailable Hugging Face repo: \(modelID). Use an MLX-ready repo id such as org/model-name."
    }

    if lowercasedDetail.contains("safetensor")
      || lowercasedDetail.contains("config.json")
      || lowercasedDetail.contains("unsupported")
    {
      return "Unsupported model format for \(modelID): \(detail)"
    }

    return "\(action) failed for \(modelID): \(detail)"
  }

  private static func chatMessages(
    conversation: Conversation,
    settings: AppSettings,
    context: String,
    toolPrompt: String,
    toolPromptInContext: Bool,
    messageLimitOverride: Int?
  ) -> [Chat.Message] {
    let baseSystem = PromptComposer.systemPrompt(settings: settings, conversation: conversation)
    let systemContent =
      context.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context\n\(context)"
    var messages: [Chat.Message] = [.system(systemContent)]

    let effectiveLimit =
      messageLimitOverride
      ?? conversation.contextWindowMode?.messageLimit
      ?? settings.contextWindowMode.messageLimit
    let limited = PromptComposer.contextMessages(
      from: conversation, settings: settings, limit: effectiveLimit)

    for message in limited {
      for entry in PromptComposer.contextTranscriptEntries(from: message, settings: settings) {
        switch entry.displayName {
        case ChatRole.system.displayName:
          messages.append(.system(entry.content))
        case ChatRole.assistant.displayName:
          messages.append(.assistant(entry.content))
        default:
          messages.append(.user(entry.content))
        }
      }
    }

    if let reminder = PromptComposer.toolCallingReminder(
      toolPrompt: toolPrompt,
      includeToolPrompt: !toolPromptInContext)
    {
      messages.append(.user(reminder))
    }

    return messages
  }

  private static func mlxToolSpecs(from tools: [ToolDefinition]?) -> [ToolSpec]? {
    guard let tools, !tools.isEmpty else { return nil }
    return tools.map { tool in
      let properties: [String: any Sendable] = Dictionary(
        uniqueKeysWithValues: tool.parameters.map { parameter in
          (
            parameter.name,
            [
              "type": parameter.type,
              "description": parameter.description,
            ] as [String: any Sendable]
          )
        })
      let parameters: [String: any Sendable] = [
        "type": "object",
        "properties": properties,
        "required": tool.parameters.filter(\.required).map(\.name),
      ]
      let function: [String: any Sendable] = [
        "name": tool.providerName ?? tool.name,
        "description": tool.description,
        "parameters": parameters,
      ]
      return [
        "type": "function",
        "function": function,
      ] as ToolSpec
    }
  }

  private static func toolCallTextBlock(_ toolCall: MLXLMCommon.ToolCall) -> String {
    let argsObject = toolCall.function.arguments.mapValues { $0.anyValue }
    let rawArguments = jsonString(from: argsObject)
    return AgentTooling.makeNativeToolCall(
      id: nil,
      name: toolCall.function.name,
      rawArguments: rawArguments
    ).textBlock
  }

  private static func jsonString(from object: [String: Any]) -> String {
    guard JSONSerialization.isValidJSONObject(object),
      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  private static func normalizedModelID(_ modelID: String) -> String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
