import Foundation

/// A request must become smaller before this failure can be retried.
public struct ProviderContextLimitError: LocalizedError, Sendable {
  public let message: String
  public let contextWindowTokens: Int?

  public init(message: String, contextWindowTokens: Int? = nil) {
    self.message = message
    self.contextWindowTokens = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
  }

  public var errorDescription: String? { message }

  /// Backends differ in both their HTTP status and error envelope. Recognize
  /// the diagnostic, rather than treating every HTTP 400 as a context error.
  public static func recognize(_ error: any Error) -> Self? {
    if let error = error as? Self { return error }
    let message = error.localizedDescription
    let lower = message.lowercased()
    guard
      lower.contains("context_length_exceeded")
        || lower.contains("exceededcontextwindowsize")
        || lower.contains("maximum context length")
        || lower.contains("exceeds the context")
        || lower.contains("exceeds the available context")
        || lower.contains("context window is full")
        || lower.contains("prompt is too long")
        || lower.contains("max_model_len")
    else { return nil }
    let patterns = [
      #"maximum context length(?: is| of)?\s*([\d,]+)"#,
      #"max_model_len[\s\"':=()]+([\d,]+)"#,
    ]
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(
          in: lower, range: NSRange(lower.startIndex..., in: lower)),
        let range = Range(match.range(at: 1), in: lower),
        let tokens = Int(lower[range].replacingOccurrences(of: ",", with: "")), tokens > 0
      else { continue }
      return Self(message: message, contextWindowTokens: tokens)
    }
    return Self(message: message)
  }
}

extension AgentRuntime {
  func contextWindow(provider: ProviderID, model: String, options: GenerationOptions) -> Int? {
    let learned = contextWindows[provider]?[model]
    if let configured = options.contextWindowTokens {
      return min(configured, learned ?? configured)
    }
    return learned
  }

  /// Account for UTF-8 text, tool schemas, message framing and reply space.
  /// Tokenization is approximate; a provider rejection can tighten this budget.
  static func contextTokens(_ request: ProviderRequest) -> Int {
    let bytes =
      request.messages.reduce(0) { total, message in
        total + ((try? JSONEncoder().encode(message).count) ?? message.text.utf8.count)
      } + ((try? JSONEncoder().encode(request.tools).count) ?? 0)
    return bytes / 3 + request.messages.count * 8 + 64
  }

  static func inputTokenBudget(window: Int, options: GenerationOptions) -> Int {
    let reply = max(1, options.maxOutputTokens ?? min(4_096, window / 4))
    return max(1, window - min(window, reply) - min(1_024, window / 16))
  }
}
