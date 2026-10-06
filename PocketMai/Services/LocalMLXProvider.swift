import Foundation
import MaiCore
import MaiLocalProviders
import MLXLLM
import MLXLMCommon
import MLXLMHFAPI
import MLXLMTokenizers

typealias LocalMLXModels = MLXModels

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

typealias LocalMLXRepoIDValidator = MLXModels

actor LocalMLXProvider {
  static let shared = LocalMLXProvider()

  private let provider: MLXProvider
  private let availability: LocalMLXAvailability

  init(
    downloader: any Downloader = LocalMLXImmediateCancelDownloader(),
    availability: LocalMLXAvailability = .current
  ) {
    self.provider = MLXProvider(downloader: downloader, availability: availability)
    self.availability = availability
  }

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

    do {
      try await provider.load(modelID: modelID, progressHandler: progressHandler)
    } catch {
      if !wasCachedBeforeLoad { try? LocalMLXModelCache.deleteRepository(modelID) }
      throw error
    }
  }

  func unload(modelID: String) async {
    await provider.unload(modelID: Self.normalizedModelID(modelID))
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
    let messages = Self.chatMessages(
      conversation: request.conversation, settings: request.settings, context: request.context,
      toolPrompt: request.nativeTools == nil ? request.toolPrompt : "",
      toolPromptInContext: request.toolPromptInContext, messageLimitOverride: request.messageLimitOverride)
    guard messages.contains(where: { $0.role == .user }) else { throw LocalMLXError.emptyPrompt }
    let maxKVSize = (request.conversation.mlxMaxKVSize ?? request.settings.mlxMaxKVSize).effectiveSize
    let accumulator = await MainActor.run { CoreProviderEventAccumulator(onUpdate: onUpdate) }
    let metrics = LocalMLXGenerationMetrics()
    let response = try await provider.complete(
      .init(model: modelID, messages: messages, tools: request.nativeTools ?? [],
            options: .init(temperature: request.hasToolCalling ? 0.2 : 0.7, maxOutputTokens: 1_200,
                           reasoningEffort: request.conversation.reasoningLevel.rawValue,
                           additional: ["mlxMaxKVSize": .integer(maxKVSize)]),
            stream: request.conversation.usesStreaming),
      emit: { await accumulator.consume($0) },
      onGenerationInfo: { await metrics.record($0) })
    let (output, timing) = try await accumulator.finish(response: response)
    let stats: GenerationStats
    if let info = await metrics.info {
      stats = GenerationStats(
        providerLabel: "MLX", modelID: modelID, inputTokens: info.promptTokenCount,
        userInputTokens: request.userInputTokens, outputTokens: info.generationTokenCount,
        receivedTextTokens: GenerationStats.estimatedTokenCount(forCharacterCount: output.count),
        promptSeconds: info.promptTime, generationSeconds: info.generateTime, firstTokenSeconds: info.promptTime)
    } else {
      stats = GenerationStats.measured(
        providerLabel: "MLX", modelID: modelID, usage: response.usage,
        estimatedInputTokens: GenerationStats.estimatedTokenCount(
          forCharacterCount: messages.reduce(0) { $0 + $1.text.count }),
        outputCharacterCount: output.count, timing: timing, userInputTokens: request.userInputTokens)
    }
    await UsageStatsStore.record(stats, assistantMessageID: request.assistantMessageID)
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
  ) -> [AgentMessage] {
    let baseSystem = PromptComposer.systemPrompt(settings: settings, conversation: conversation)
    let systemContent =
      context.isEmpty
      ? baseSystem
      : "\(baseSystem)\n\n## Context\n\(context)"
    var messages: [AgentMessage] = [.system(systemContent)]

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

  private static func normalizedModelID(_ modelID: String) -> String {
    modelID.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

private actor LocalMLXGenerationMetrics {
  private(set) var info: GenerateCompletionInfo?
  func record(_ info: GenerateCompletionInfo) { self.info = info }
}
